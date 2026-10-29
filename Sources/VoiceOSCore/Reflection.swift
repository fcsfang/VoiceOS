import Foundation

public enum ReflectionPeriod: String, CaseIterable, Codable, Sendable {
    case day, week, month
    public var label: String {
        switch self { case .day: "日"; case .week: "周"; case .month: "月" }
    }
    public var component: Calendar.Component {
        switch self { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }
    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: component, for: date)!
    }
}

public struct ReflectionExpression: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let date: Date
    public let usesImportDate: Bool
    public let isInPeriod: Bool
}
public struct ReflectionCompletion: Identifiable, Codable, Sendable {
    public let actionID: String
    public let revision: ActionRevision
    public var id: String { revision.id }
}
public struct ReflectionConnection: Identifiable, Codable, Sendable {
    public let receiptID: String
    public let sourceID: String
    public let update: ThoughtUpdate
    public var id: String { receiptID + ":" + update.claimID + ":" + update.currentQuote }
}
/// A selected period plus the complete evidence behind its thoughts and actions.
/// Earlier sources and results are context, never counted as activity in this period.
public struct ConversationReflectionFocus: Codable, Sendable {
    public let start: Date
    public let end: Date
    public let timeZoneID: String
    public let expressions: [ReflectionExpression]
    public let thoughts: [ConversationThoughtAnchor]
    public let tasks: [ConversationThoughtTask]
    public let outcomes: [ActionFeedbackRecord]
    public let completions: [ReflectionCompletion]
    public let connections: [ReflectionConnection]
    public var question: ReflectionQuestionContext? = nil
    public var period: ReflectionPeriod? = nil
    public var isTopicOverview: Bool { period == nil && (question != nil || (start == .distantPast && end == .distantFuture)) }
    public var sourceIDs: [String] {
        var ids = expressions.map(\.id)
        let questionIDs = question.map { [$0.sourceID] + $0.entries.flatMap { entry in
            [entry.sourceID] + entry.sourceIDs.filter { !entry.unavailableSourceIDs.contains($0) }
        } } ?? []
        for id in outcomes.map(\.sourceID) + thoughts.flatMap({ $0.evidence.map { $0.reference.sourceID } }) + questionIDs where !ids.contains(id) { ids.append(id) }
        return ids
    }
    public func contains(_ date: Date) -> Bool { date >= start && date < end }
    public func contains(timestamp: String) -> Bool { Self.date(timestamp).map(contains) ?? false }
    public static func date(_ text: String) -> Date? {
        // Format styles reuse Foundation's parser cache instead of allocating ICU
        // formatters for every visible row and every workspace update.
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: text.utf8.contains(46)).parse(text)
    }
}

extension VoiceOSStore {
    public func reflectionContentsForSources(sourceIDs: [String], timeZoneID: String) throws -> ConversationReflectionFocus {
        try reflectionContents(start: .distantPast, end: .distantFuture, timeZoneID: timeZoneID, selectedSourceIDs: Set(sourceIDs))
    }

    public func reflection(start: Date, end: Date, timeZoneID: String) throws -> ConversationReflectionFocus {
        try reflectionContents(start: start, end: end, timeZoneID: timeZoneID, selectedSourceIDs: nil)
    }

    func reflectionContents(start: Date, end: Date, timeZoneID: String, selectedSourceIDs: Set<String>?) throws -> ConversationReflectionFocus {
        guard ready, start < end, TimeZone(identifier: timeZoneID) != nil else { throw VoiceOSError("回顾时间范围无效") }
        let claims = try candidateClaims(), byID = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0) })
        // Retaining a discussion result adds knowledge; it must not replace the
        // original understanding of every recording included in that discussion.
        var latestAttempt: [String: String] = [:]
        for row in try db.query("""
        SELECT i.source_id,a.id FROM model_attempts a JOIN context_inputs i ON i.context_id=a.context_id
        WHERE a.state='completed' AND a.provider NOT LIKE 'english_feedback:%'
        AND a.provider!='discussion_derivation' AND substr(a.provider,1,19)!='discussion_outcome:'
        ORDER BY a.producer_sequence DESC,a.created_at DESC,a.id DESC
        """) where latestAttempt[row["source_id"]!] == nil { latestAttempt[row["source_id"]!] = row["id"]! }
        let claimAttempts = Dictionary(uniqueKeysWithValues: try db.query("SELECT id,attempt_id FROM claims").map { ($0["id"]!, $0["attempt_id"]!) })
        let sources = try sources().filter { ["saved", "reference_only"].contains($0.state) && !($0.transcript ?? "").isEmpty }
        let catalog = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        func inPeriod(_ date: Date) -> Bool { date >= start && date < end }
        func expressionDate(_ source: SourceRecord) -> Date { source.expressedDate ?? ConversationReflectionFocus.date(source.createdAt) ?? .distantPast }
        let selected = sources.filter { selectedSourceIDs?.contains($0.id) ?? inPeriod(expressionDate($0)) }
        let selectedIDs = Set(selected.map(\.id))
        let actions = try actions(includeHistory: true).filter { $0.validity == "current" }
        let feedback = try reflectionFeedback(claims: byID)
        let completionRows = try db.query("SELECT * FROM action_revisions WHERE state='completed' ORDER BY created_at,id")
        let completions = completionRows.compactMap { row -> ReflectionCompletion? in
            guard let action = actions.first(where: { $0.id == row["action_id"] && $0.kind == "task" }),
                  let date = ConversationReflectionFocus.date(row["created_at"]!), inPeriod(date) else { return nil }
            return .init(actionID: action.id, revision: .init(id: row["id"]!, version: Int(row["version"]!)!, state: "completed", note: row["note"]!, createdAt: row["created_at"]!, actor: row["actor"]!))
        }
        let eventActions = Set(completions.map(\.actionID) + feedback.filter { ConversationReflectionFocus.date($0.createdAt).map(inPeriod) == true }.map(\.actionID))
        let relevantActions = actions.filter { action in
            (selectedSourceIDs == nil && eventActions.contains(action.id)) ||
            byID[action.claimID]?.references.contains(where: { selectedIDs.contains($0.sourceID) }) == true ||
            feedback.contains(where: { $0.actionID == action.id && selectedIDs.contains($0.sourceID) })
        }
        let actionIDs = Set(relevantActions.map(\.id))
        let outcomes = feedback.filter { actionIDs.contains($0.actionID) }
        let tasks = relevantActions.map { action in
            let results = outcomes.filter { $0.actionID == action.id }
            return ConversationThoughtTask(actionID: action.id, version: action.version, title: action.title, state: action.state,
                feedbackSourceIDs: results.map(\.sourceID), kind: action.intent?.intentType ?? action.kind, goalID: action.intent?.goalID,
                feedbackActionVersions: Dictionary(uniqueKeysWithValues: results.map { ($0.sourceID, $0.actionVersion) }), claimID: action.claimID)
        }
        var claimIDs = Set(relevantActions.map(\.claimID))
        for claim in claims where claim.references.contains(where: { ref in
            selectedIDs.contains(ref.sourceID) && (claim.ownership == "ai_candidate" || claim.reviewState == "endorsed" || latestAttempt[ref.sourceID] == claimAttempts[claim.id])
        }) { claimIDs.insert(claim.id) }
        // A link is between a recording and an earlier thought. A coarse transcript
        // span cannot establish which of several new thoughts the model meant.
        let receipts = try recordingFollowups(), validities = try recordingFollowupValidities(receipts)
        var connections: [ReflectionConnection] = [], seen = Set<String>()
        for receipt in receipts.reversed() where selectedIDs.contains(receipt.sourceID) && receipt.state == "completed" {
            for update in receipt.result?.thoughtUpdates ?? [] where validities[receipt.id]?.thoughtIsCurrent(update.claimID) == true {
                let key = receipt.sourceID + ":" + update.claimID + ":" + update.currentQuote
                guard byID[update.claimID] != nil, seen.insert(key).inserted else { continue }
                connections.append(.init(receiptID: receipt.id, sourceID: receipt.sourceID, update: update))
                claimIDs.insert(update.claimID)
            }
        }
        let thoughts = try claims.filter { claimIDs.contains($0.id) }.map { claim in
            let evidence = try claim.references.map { ref -> OutcomeSourceEvidence in
                guard let source = catalog[ref.sourceID], source.transcriptVersionID == ref.transcriptVersionID,
                      let text = source.transcript, let span = source.spans.first(where: { $0.id == ref.spanID }) else { throw VoiceOSError("回顾原话已变化，请刷新") }
                let scalars = Array(text.unicodeScalars)
                return .init(reference: ref, quote: String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])))
            }
            return ConversationThoughtAnchor(claimID: claim.id, reviewVersion: claim.reviewVersion, summary: claim.statement, ownership: claim.ownership, evidence: evidence)
        }
        let evidenceIDs = Set(thoughts.flatMap { $0.evidence.map { $0.reference.sourceID } })
        let outcomeSources = Set(outcomes.map(\.sourceID))
        var expressions: [ReflectionExpression] = []
        for source in sources where !outcomeSources.contains(source.id) && (selectedIDs.contains(source.id) || evidenceIDs.contains(source.id)) {
            expressions.append(.init(id: source.id, title: source.displayTitle, date: expressionDate(source), usesImportDate: source.expressedDate == nil, isInPeriod: inPeriod(expressionDate(source))))
        }
        expressions.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        return .init(start: start, end: end, timeZoneID: timeZoneID, expressions: expressions, thoughts: thoughts, tasks: tasks,
                     outcomes: outcomes, completions: completions.filter { actionIDs.contains($0.actionID) }, connections: connections)
    }

    private func reflectionFeedback(claims: [String: CandidateClaim]) throws -> [ActionFeedbackRecord] {
        try db.query("""
        SELECT f.*,s.state AS source_state,s.feedback_json,v.text
        FROM action_feedback f JOIN actions a ON a.id=f.action_id JOIN sources s ON s.id=f.source_id
        JOIN transcripts t ON t.source_id=s.id JOIN transcript_versions v ON v.id=t.current_version_id
        WHERE a.validity='current' AND s.state IN ('saved','reference_only') ORDER BY f.created_at,f.sequence
        """).compactMap { row in
            let intent = try Self.feedbackIntent(row["feedback_json"])
            guard intent?.organizedClaimID.map({ claims[$0] != nil }) ?? true else { return nil }
            return ActionFeedbackRecord(id: row["id"]!, actionID: row["action_id"]!, actionVersion: Int(row["action_version"]!)!, sourceID: row["source_id"]!, kind: row["kind"]!, text: row["text"]!, sourceState: row["source_state"]!, createdAt: row["created_at"]!, recordingSourceID: intent?.recordingSourceID, relation: intent?.relation)
        }
    }

    public func beginConversationForReflection(_ focus: ConversationReflectionFocus, commandID: String = UUID().uuidString) throws -> String {
        guard ready, !commandID.isEmpty, !focus.sourceIDs.isEmpty else { throw VoiceOSError("这个周期还没有可回顾的文字") }
        if let old = try db.query("SELECT * FROM conversations WHERE entry_command_id=?", [commandID]).first {
            let saved = try conversationHistoryContext(old["id"]!)
            guard try Self.relevanceJSON(saved.reflectionFocus) == Self.relevanceJSON(focus) else { throw VoiceOSError("同一次进入不能更换回顾资料") }
            return old["id"]!
        }
        try validateReflectionFocus(focus)
        var context = try prepareFullDiscussionContext(sourceIDs:focus.sourceIDs)
        context.reflectionFocus = focus
        let contextID = try persistLocalContext(context), id = UUID().uuidString
        try db.execute("INSERT INTO conversations(id,entry_command_id,entry_context_id,version,state,validity,created_at) VALUES(?,?,?,1,'active','current',?)", [id, commandID, contextID, Self.now()])
        return id
    }

    public func conversationReflectionFocus(conversationID: String) throws -> ConversationReflectionFocus? {
        try conversationHistoryContext(conversationID).reflectionFocus
    }

    // A retained AI paragraph shares this basis. Check it while reading its
    // context too, so a changed task cannot circulate stale knowledge before
    // somebody happens to open the original review conversation.
    func validateReflectionBasis(_ focus: ConversationReflectionFocus) throws {
        if let question = focus.question { try validateReflectionQuestionContext(question) }
        for thought in focus.thoughts {
            guard let row = try db.query("""
            SELECT c.review_version,c.validity,c.statement,c.ownership,r.statement AS reviewed_statement,r.ownership AS reviewed_ownership,r.decision,x.state
            FROM claims c JOIN model_attempts a ON a.id=c.attempt_id JOIN contexts x ON x.id=a.context_id
            LEFT JOIN claim_reviews r ON r.claim_id=c.id AND r.version=c.review_version WHERE c.id=?
            """, [thought.claimID]).first,
                  row["validity"] == "current", row["state"] == "current", row["decision"] != "rejected",
                  row["review_version"] == String(thought.reviewVersion),
                  (row["reviewed_statement"] ?? row["statement"]) == thought.summary,
                  (row["reviewed_ownership"] ?? row["ownership"]) == thought.ownership else { throw VoiceOSError("回顾观点已变化，请重新进入这个周期") }
        }
        for task in focus.tasks {
            guard let row = try db.query("SELECT * FROM actions WHERE id=?", [task.actionID]).first,
                  row["validity"] == "current", row["version"] == String(task.version), row["state"] == task.state,
                  row["title"] == task.title, row["claim_id"] == task.claimID else { throw VoiceOSError("回顾任务已变化，请重新进入这个周期") }
            let actual = try db.query("""
            SELECT f.*,s.state AS source_state,s.feedback_json,v.text
            FROM action_feedback f JOIN sources s ON s.id=f.source_id
            JOIN transcripts t ON t.source_id=s.id JOIN transcript_versions v ON v.id=t.current_version_id
            WHERE f.action_id=? AND s.state IN ('saved','reference_only') ORDER BY f.created_at,f.sequence
            """, [task.actionID]).compactMap { row -> ActionFeedbackRecord? in
                let intent = try Self.feedbackIntent(row["feedback_json"])
                if let id = intent?.organizedClaimID, try db.query("SELECT validity FROM claims WHERE id=?", [id]).first?["validity"] != "current" { return nil }
                return ActionFeedbackRecord(id: row["id"]!, actionID: row["action_id"]!, actionVersion: Int(row["action_version"]!)!, sourceID: row["source_id"]!, kind: row["kind"]!, text: row["text"]!, sourceState: row["source_state"]!, createdAt: row["created_at"]!, recordingSourceID: intent?.recordingSourceID, relation: intent?.relation)
            }
            guard try Self.relevanceJSON(actual) == Self.relevanceJSON(focus.outcomes.filter { $0.actionID == task.actionID }) else { throw VoiceOSError("回顾结果已变化，请重新进入这个周期") }
        }
    }

    func validateReflectionFocus(_ focus: ConversationReflectionFocus) throws {
        if let question = focus.question { try validateReflectionQuestionContext(question) }
        guard focus.start < focus.end, TimeZone(identifier: focus.timeZoneID) != nil else { throw VoiceOSError("回顾周期无效") }
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id, $0) })
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        let actions = Dictionary(uniqueKeysWithValues: try actions(includeHistory: true).map { ($0.id, $0) })
        for expression in focus.expressions {
            guard let source = catalog[expression.id], source.displayTitle == expression.title,
                  (source.expressedDate ?? ConversationReflectionFocus.date(source.createdAt)) == expression.date,
                  expression.usesImportDate == (source.expressedDate == nil), expression.isInPeriod == focus.contains(expression.date) else { throw VoiceOSError("回顾来源或日期已变化，请重新进入这个周期") }
        }
        for thought in focus.thoughts {
            guard let claim = claims[thought.claimID], claim.reviewVersion == thought.reviewVersion, claim.statement == thought.summary, claim.ownership == thought.ownership,
                  try Self.relevanceJSON(claim.references) == Self.relevanceJSON(thought.evidence.map(\.reference)) else { throw VoiceOSError("回顾中的观点已更新，请重新进入这个周期") }
            for evidence in thought.evidence {
                let ref = evidence.reference
                guard let source = catalog[ref.sourceID], source.transcriptVersionID == ref.transcriptVersionID,
                      let text = source.transcript, let span = source.spans.first(where: { $0.id == ref.spanID }) else { throw VoiceOSError("回顾原话已变化") }
                let scalars = Array(text.unicodeScalars)
                guard String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])) == evidence.quote else { throw VoiceOSError("回顾引用与原话不一致") }
            }
        }
        let feedback = try reflectionFeedback(claims: claims)
        for task in focus.tasks {
            let results = feedback.filter { $0.actionID == task.actionID }
            guard let action = actions[task.actionID], action.validity == "current", action.version == task.version, action.title == task.title, action.state == task.state,
                  action.claimID == task.claimID,
                  (action.intent?.intentType ?? action.kind) == task.kind, action.intent?.goalID == task.goalID,
                  results.map(\.sourceID) == task.feedbackSourceIDs else { throw VoiceOSError("回顾中的任务或结果已更新，请重新进入这个周期") }
        }
        let ids = Set(focus.tasks.map(\.actionID))
        guard try Self.relevanceJSON(feedback.filter { ids.contains($0.actionID) }) == Self.relevanceJSON(focus.outcomes) else { throw VoiceOSError("回顾中的实际反馈已更新，请重新进入这个周期") }
        for completion in focus.completions {
            guard focus.contains(timestamp: completion.revision.createdAt),
                  let current = try actionHistory(actionID: completion.actionID).first(where: { $0.id == completion.id }),
                  try Self.relevanceJSON(current) == Self.relevanceJSON(completion.revision) else { throw VoiceOSError("回顾中的完成记录不一致") }
        }
        let receipts = try recordingFollowups(), validities = try recordingFollowupValidities(receipts)
        for connection in focus.connections {
            guard let receipt = receipts.first(where: { $0.id == connection.receiptID && $0.sourceID == connection.sourceID }),
                  validities[receipt.id]?.thoughtIsCurrent(connection.update.claimID) == true,
                  try (receipt.result?.thoughtUpdates ?? []).contains(where: { try Self.relevanceJSON($0) == Self.relevanceJSON(connection.update) }) else { throw VoiceOSError("回顾中的思想关联已变化，请重新进入这个周期") }
        }
    }
}
