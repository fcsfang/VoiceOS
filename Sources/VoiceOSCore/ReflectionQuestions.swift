import Foundation

public struct ReflectionQuestion: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    /// User titles have their own expression; AI labels are metadata anchored to real material.
    public let sourceID: String
    public let createdAt: String
    public let updatedAt: String
    public var isAIOrganized: Bool? = nil
    public var organization: TopicOrganizationSummary? = nil
}

public enum ReflectionQuestionEntryKind: String, CaseIterable, Codable, Sendable {
    case observation, change, experiment, result
    public var label: String {
        switch self {
        case .observation: "我的认识"
        case .change: "认识变化"
        case .experiment: "小验证"
        case .result: "实际结果"
        }
    }
}

public struct ReflectionQuestionEntry: Identifiable, Codable, Sendable {
    public let id: String
    public let questionID: String
    public let kind: ReflectionQuestionEntryKind
    public let text: String
    public let sourceID: String
    public let sourceIDs: [String]
    public let unavailableSourceIDs: [String]
    public let createdAt: String
}

public struct ReflectionQuestionContext: Codable, Sendable {
    public let id: String
    public let title: String
    public let sourceID: String
    public let version: Int
    public let entries: [ReflectionQuestionEntry]
    public var isAIOrganized: Bool? = nil
}

extension VoiceOSStore {
    static func validateStoredReflectionQuestions(_ database: Database) throws {
        for row in try database.query("SELECT q.*,s.kind,s.origin,s.speaker FROM reflection_questions q LEFT JOIN sources s ON s.id=q.title_source_id") {
            let aiNamed = row["ai_named"] == "1"
            if let json=row["organization_json"] {
                let summary=try JSONDecoder().decode(TopicOrganizationSummary.self,from:Data(json.utf8))
                guard !summary.responseID.isEmpty, !summary.summary.isEmpty, !summary.sourceVersions.isEmpty,
                      Set(summary.sourceVersions.keys) == Set(summary.policyVersions.keys) else { throw VoiceOSError("主题整理缺少实际来源") }
                for (id,version) in summary.sourceVersions {
                    guard try !database.query("SELECT v.id FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id WHERE t.source_id=? AND v.id=?",[id,version]).isEmpty else { throw VoiceOSError("主题整理的原文版本不存在") }
                }
            }
            let validTitle = aiNamed ? row["organization_json"] != nil : row["kind"] == "user_text" && row["origin"] == "user" && row["speaker"] == "user"
            guard validTitle,
                  try (aiNamed || !database.query("SELECT v.id FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id WHERE t.source_id=? AND v.text=?", [row["title_source_id"],row["title"]]).isEmpty), let version = row["version"].flatMap(Int.init), version >= 1,
                  ConversationReflectionFocus.date(row["created_at"] ?? "") != nil,
                  ConversationReflectionFocus.date(row["updated_at"] ?? "") != nil else { throw VoiceOSError("长期问题标题与个人原文不一致") }
        }
        for row in try database.query("SELECT e.*,s.kind AS source_kind,s.origin,s.speaker FROM reflection_question_entries e LEFT JOIN sources s ON s.id=e.source_id") {
            let ids = try JSONDecoder().decode([String].self, from: Data((row["source_ids_json"] ?? "").utf8))
            let versions = try JSONDecoder().decode([String: String].self, from: Data((row["evidence_versions_json"] ?? "").utf8))
            guard ReflectionQuestionEntryKind(rawValue: row["kind"] ?? "") != nil,
                  ["active","inactive"].contains(row["state"] ?? ""), Set(ids).count == ids.count,
                  let sequence = row["sequence"].flatMap(Int64.init), sequence >= 1,
                  row["source_kind"] == "user_text", row["origin"] == "user", row["speaker"] == "user",
                  try !database.query("SELECT id FROM reflection_questions WHERE id=?", [row["question_id"]]).isEmpty,
                  ConversationReflectionFocus.date(row["created_at"] ?? "") != nil else { throw VoiceOSError("长期问题记录与来源不一致") }
            guard Set(versions.keys) == Set(ids),
                  try database.query("SELECT v.text FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id WHERE v.id=? AND t.source_id=?", [row["note_version_id"],row["source_id"]]).first?["text"] == row["text"] else { throw VoiceOSError("问题记录的文字版本不一致") }
            for id in ids {
                guard try !database.query("SELECT id FROM sources WHERE id=?", [id]).isEmpty else { throw VoiceOSError("问题记录引用了不存在的资料") }
                if let version = versions[id] {
                    guard try !database.query("SELECT v.id FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id WHERE v.id=? AND t.source_id=?", [version,id]).isEmpty else { throw VoiceOSError("问题记录的证据版本不一致") }
                }
            }
        }
        guard try database.query("SELECT question_id FROM reflection_question_entries GROUP BY question_id,sequence HAVING COUNT(*)>1").isEmpty else { throw VoiceOSError("长期问题记录顺序重复") }
        guard try database.query("""
        SELECT l.id FROM reflection_question_sources l LEFT JOIN reflection_questions q ON q.id=l.question_id LEFT JOIN sources s ON s.id=l.source_id
        WHERE q.id IS NULL OR s.id IS NULL OR l.id IS NULL
        """).isEmpty else { throw VoiceOSError("长期问题资料关联不一致") }
    }

    private func requireReflectionQuestionsReady() throws {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
    }

    private func reflectionQuestionRow(_ id: String) throws -> [String: String] {
        try requireReflectionQuestionsReady()
        guard let row = try db.query("SELECT * FROM reflection_questions WHERE id=?", [id]).first else { throw VoiceOSError("找不到这个长期问题") }
        return row
    }

    private func reflectionQuestionRecord(_ row: [String: String]) -> ReflectionQuestion {
        var question = ReflectionQuestion(id: row["id"]!, title: row["title"]!, sourceID: row["title_source_id"]!, createdAt: row["created_at"]!, updatedAt: row["updated_at"]!)
        question.isAIOrganized = row["ai_named"] == "1"
        if let json = row["organization_json"], let summary = try? JSONDecoder().decode(TopicOrganizationSummary.self, from: Data(json.utf8)),
           (try? topicSummaryIsCurrent(summary, questionID: question.id)) == true { question.organization = summary }
        return question
    }

    public func reflectionQuestions() throws -> [ReflectionQuestion] {
        try requireReflectionQuestionsReady()
        return try db.query("SELECT * FROM reflection_questions ORDER BY updated_at DESC,id").map(reflectionQuestionRecord)
    }

    @discardableResult
    public func createReflectionQuestion(title: String) throws -> ReflectionQuestion {
        try requireReflectionQuestionsReady()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= 200 else { throw VoiceOSError("请填写不超过 200 字的长期问题") }
        let sourceID = try recordUserExpression(title), id = UUID().uuidString, now = Self.now()
        try db.transaction {
            try db.execute("INSERT INTO reflection_questions(id,title,title_source_id,created_at,updated_at) VALUES(?,?,?,?,?)", [id,title,sourceID,now,now])
            try db.execute("INSERT INTO reflection_question_sources(id,question_id,source_id) VALUES(?,?,?)", [UUID().uuidString,id,sourceID])
        }
        return reflectionQuestionRecord(try reflectionQuestionRow(id))
    }

    public func renameReflectionQuestion(id: String, title: String) throws {
        let row = try reflectionQuestionRow(id), title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= 200 else { throw VoiceOSError("请填写不超过 200 字的长期问题") }
        if title == row["title"], try sources().first(where: { $0.id == row["title_source_id"] })?.transcript == title { return }
        let sourceID = try recordUserExpression(title)
        try db.transaction {
            if row["ai_named"] != "1" { try db.execute("DELETE FROM reflection_question_sources WHERE question_id=? AND source_id=?", [id,row["title_source_id"]]) }
            try db.execute("INSERT INTO reflection_question_sources(id,question_id,source_id) VALUES(?,?,?)", [UUID().uuidString,id,sourceID])
            try db.execute("UPDATE reflection_questions SET title=?,title_source_id=?,organization_json=NULL,ai_named=0,version=version+1,updated_at=? WHERE id=?", [title,sourceID,Self.now(),id])
        }
    }

    public func reflectionQuestionEntries(questionID: String) throws -> [ReflectionQuestionEntry] {
        _ = try reflectionQuestionRow(questionID)
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id,$0) })
        let withdrawn = Set(try db.query("SELECT source_id FROM reflection_question_entries WHERE question_id=? AND state='inactive'", [questionID]).map { $0["source_id"]! })
        return try db.query("SELECT * FROM reflection_question_entries WHERE question_id=? AND state='active' ORDER BY sequence,id", [questionID]).map { row in
            let ids = try JSONDecoder().decode([String].self, from: Data(row["source_ids_json"]!.utf8)), sourceID = row["source_id"]!
            let evidenceVersions = try JSONDecoder().decode([String: String].self, from: Data(row["evidence_versions_json"]!.utf8))
            let unavailable = ([sourceID] + ids).filter { id in
                guard let source = catalog[id] else { return true }
                let expectedVersion = id == sourceID ? row["note_version_id"] : evidenceVersions[id]
                return withdrawn.contains(id) || !["saved","reference_only"].contains(source.state) || source.transcript?.isEmpty != false || expectedVersion != source.transcriptVersionID
            }
            guard let kind = ReflectionQuestionEntryKind(rawValue: row["kind"]!) else { throw VoiceOSError("问题记录类型无效") }
            return .init(id: row["id"]!, questionID: questionID, kind: kind, text: row["text"]!, sourceID: sourceID, sourceIDs: ids, unavailableSourceIDs: unavailable, createdAt: row["created_at"]!)
        }
    }

    @discardableResult
    public func addReflectionQuestionEntry(questionID: String, kind: ReflectionQuestionEntryKind, text: String, sourceIDs: [String] = []) throws -> ReflectionQuestionEntry {
        _ = try reflectionQuestionRow(questionID)
        guard Set(sourceIDs).count == sourceIDs.count else { throw VoiceOSError("证据来源不能重复") }
        if !sourceIDs.isEmpty {
            let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id,$0) })
            let budget = max(1, sourceIDs.reduce(0) { $0 + (catalog[$1]?.transcript?.unicodeScalars.count ?? 0) })
            _ = try prepareLocalTranscriptContext(sourceIDs: sourceIDs, scalarBudget: budget)
        }
        let sourceID = try recordUserExpression(text), id = UUID().uuidString
        let json = String(decoding: try JSONEncoder().encode(sourceIDs), as: UTF8.self)
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id,$0) })
        guard let noteVersion = catalog[sourceID]?.transcriptVersionID else { throw VoiceOSError("问题记录缺少文字版本") }
        let evidenceVersions = Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0,catalog[$0]!.transcriptVersionID!) })
        let evidenceJSON = String(decoding: try JSONEncoder().encode(evidenceVersions), as: UTF8.self)
        try db.transaction {
            let sequence = try db.query("SELECT COALESCE(MAX(sequence),0)+1 AS next FROM reflection_question_entries WHERE question_id=?", [questionID]).first?["next"]
            try db.execute("INSERT INTO reflection_question_entries(id,question_id,kind,text,source_id,source_ids_json,note_version_id,evidence_versions_json,sequence,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)", [id,questionID,kind.rawValue,text,sourceID,json,noteVersion,evidenceJSON,sequence,Self.now()])
            try db.execute("UPDATE reflection_questions SET version=version+1,updated_at=? WHERE id=?", [Self.now(),questionID])
        }
        return try reflectionQuestionEntries(questionID: questionID).first { $0.id == id }!
    }

    public func stopReflectionQuestionEntry(id: String) throws {
        try requireReflectionQuestionsReady()
        guard let row = try db.query("SELECT question_id,state FROM reflection_question_entries WHERE id=?", [id]).first else { throw VoiceOSError("找不到这条问题记录") }
        guard row["state"] == "active" else { return }
        try db.transaction {
            try db.execute("UPDATE reflection_question_entries SET state='inactive' WHERE id=?", [id])
            try db.execute("UPDATE reflection_questions SET version=version+1,updated_at=? WHERE id=?", [Self.now(),row["question_id"]])
        }
    }

    public func reflectionQuestionSourceIDs(questionID: String) throws -> [String] {
        let row = try reflectionQuestionRow(questionID)
        let withdrawn=Set(try db.query("SELECT source_id FROM reflection_question_entries WHERE state='inactive'").compactMap { $0["source_id"] })
        let linked = try db.query("SELECT source_id FROM reflection_question_sources WHERE question_id=? ORDER BY source_id", [questionID]).map { $0["source_id"]! }
        let entries = try reflectionQuestionEntries(questionID: questionID)
        var ids = [row["title_source_id"]!]
        for id in linked + entries.flatMap({ [$0.sourceID] + $0.sourceIDs }) where !ids.contains(id) { ids.append(id) }
        return ids.filter { !withdrawn.contains($0) }
    }

    public func reflectionQuestionSources() throws -> [String: [String]] {
        try requireReflectionQuestionsReady()
        let withdrawn = Set(try db.query("SELECT source_id FROM reflection_question_entries WHERE state='inactive'").compactMap { $0["source_id"] })
        var result = Dictionary(uniqueKeysWithValues: try db.query("SELECT id,title_source_id FROM reflection_questions").map { ($0["id"]!, [$0["title_source_id"]!]) })
        for row in try db.query("SELECT question_id,source_id FROM reflection_question_sources ORDER BY question_id,source_id") {
            result[row["question_id"]!, default: []].append(row["source_id"]!)
        }
        for row in try db.query("SELECT question_id,source_id,source_ids_json FROM reflection_question_entries WHERE state='active' ORDER BY question_id,sequence,id") {
            let evidence = try JSONDecoder().decode([String].self, from: Data(row["source_ids_json"]!.utf8))
            result[row["question_id"]!, default: []].append(contentsOf: [row["source_id"]!] + evidence)
        }
        return result.mapValues { ids in
            var seen = Set<String>()
            return ids.filter { !withdrawn.contains($0) && seen.insert($0).inserted }
        }
    }

    public func linkReflectionQuestionSource(questionID: String, sourceID: String) throws {
        _ = try reflectionQuestionRow(questionID)
        let source = try sources().first { $0.id == sourceID }
        _ = try prepareLocalTranscriptContext(sourceIDs: [sourceID], scalarBudget: max(1, source?.transcript?.unicodeScalars.count ?? 0))
        guard try db.query("SELECT source_id FROM reflection_question_sources WHERE question_id=? AND source_id=?", [questionID,sourceID]).isEmpty else { return }
        try db.transaction {
            try db.execute("INSERT INTO reflection_question_sources(id,question_id,source_id) VALUES(?,?,?)", [UUID().uuidString,questionID,sourceID])
            try db.execute("UPDATE reflection_questions SET version=version+1,updated_at=? WHERE id=?", [Self.now(),questionID])
        }
    }

    /// Linking a knowledge or task card keeps its original attribution and
    /// sources. It does not endorse the claim or change the task's state.
    public func linkTopicClaim(questionID: String, claimID: String, expectedReviewVersion: Int) throws {
        _ = try reflectionQuestionRow(questionID)
        guard let claim = try candidateClaim(id: claimID),
              claim.reviewVersion == expectedReviewVersion else { throw VoiceOSError("这条认识已变化，请刷新后再关联") }
        try linkTopicEvidence(questionID: questionID, references: claim.references)
    }

    public func linkTopicAction(questionID: String, actionID: String, expectedVersion: Int) throws {
        _ = try reflectionQuestionRow(questionID)
        guard let action = try actions(includeHistory: true).first(where: { $0.id == actionID }),
              action.validity == "current", action.version == expectedVersion,
              let claim = try candidateClaim(id: action.claimID),
              claim.reviewVersion == action.claimReviewVersion else { throw VoiceOSError("这项任务或原话已变化，请刷新后再关联") }
        try linkTopicEvidence(questionID: questionID, references: claim.references)
    }

    private func linkTopicEvidence(questionID: String, references: [ClaimReference]) throws {
        let ids = Set(references.map(\.sourceID)).sorted()
        guard !ids.isEmpty else { throw VoiceOSError("这张卡片还没有可关联的原话依据") }
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id,$0) })
        for reference in references {
            guard let source = catalog[reference.sourceID], source.transcriptVersionID == reference.transcriptVersionID,
                  source.spans.contains(where: { $0.id == reference.spanID }) else { throw VoiceOSError("卡片的原话依据已变化，请重新核对") }
        }
        let budget = max(1, ids.reduce(0) { $0 + (catalog[$1]?.transcript?.unicodeScalars.count ?? 0) })
        _ = try prepareLocalTranscriptContext(sourceIDs: ids, scalarBudget: budget)
        let linked = Set(try db.query("SELECT source_id FROM reflection_question_sources WHERE question_id=?", [questionID]).map { $0["source_id"]! })
        let newIDs = ids.filter { !linked.contains($0) }
        guard !newIDs.isEmpty else { return }
        try db.transaction {
            for id in newIDs {
                try db.execute("INSERT INTO reflection_question_sources(id,question_id,source_id) VALUES(?,?,?)", [UUID().uuidString,questionID,id])
            }
            try db.execute("UPDATE reflection_questions SET version=version+1,updated_at=? WHERE id=?", [Self.now(),questionID])
        }
    }

    public func unlinkReflectionQuestionSource(questionID: String, sourceID: String) throws {
        let row = try reflectionQuestionRow(questionID)
        let entries = try reflectionQuestionEntries(questionID: questionID)
        guard sourceID != row["title_source_id"], !entries.contains(where: { $0.sourceID == sourceID || $0.sourceIDs.contains(sourceID) }) else { throw VoiceOSError("这是问题标题或记录的依据，请先撤回相关记录") }
        guard !(try db.query("SELECT source_id FROM reflection_question_sources WHERE question_id=? AND source_id=?", [questionID,sourceID])).isEmpty else { return }
        try db.transaction {
            try db.execute("DELETE FROM reflection_question_sources WHERE question_id=? AND source_id=?", [questionID,sourceID])
            try db.execute("UPDATE reflection_questions SET version=version+1,updated_at=? WHERE id=?", [Self.now(),questionID])
        }
    }

    /// A topic is a continuous thread. Dates order its evidence but do not
    /// exclude linked material at week or month boundaries.
    public func reflectionForTopic(questionID: String, timeZoneID: String) throws -> ConversationReflectionFocus {
        try reflectionForQuestion(questionID: questionID, start: .distantPast, end: .distantFuture, timeZoneID: timeZoneID)
    }

    public func reflectionForQuestion(questionID: String, start: Date, end: Date, timeZoneID: String) throws -> ConversationReflectionFocus {
        let row = try reflectionQuestionRow(questionID)
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id,$0) })
        guard row["ai_named"] == "1" || catalog[row["title_source_id"]!]?.transcript == row["title"] else { throw VoiceOSError("问题标题来源已变化，请重新保存标题") }
        // Missing evidence remains visible on the local journal but is never sent
        // as if it were still usable. Every transmitted note has its own source.
        let entries = try reflectionQuestionEntries(questionID: questionID).filter { !$0.unavailableSourceIDs.contains($0.sourceID) }
        let withdrawn=Set(try db.query("SELECT source_id FROM reflection_question_entries WHERE state='inactive'").compactMap { $0["source_id"] })
        let manuallyLinked = try db.query("SELECT source_id FROM reflection_question_sources WHERE question_id=?", [questionID]).map { $0["source_id"]! }
        let ids = Set((manuallyLinked + entries.flatMap { entry in
            [entry.sourceID] + entry.sourceIDs.filter { !entry.unavailableSourceIDs.contains($0) }
        }).filter { !withdrawn.contains($0) })
        var focus = try reflectionContents(start: start, end: end, timeZoneID: timeZoneID, selectedSourceIDs: ids)
        focus.question = .init(id: questionID, title: row["title"]!, sourceID: row["title_source_id"]!, version: Int(row["version"]!)!, entries: entries)
        focus.question?.isAIOrganized = row["ai_named"] == "1"
        return focus
    }

    func validateReflectionQuestionContext(_ context: ReflectionQuestionContext) throws {
        let row = try reflectionQuestionRow(context.id)
        let entries = try reflectionQuestionEntries(questionID: context.id).filter { !$0.unavailableSourceIDs.contains($0.sourceID) }
        let titleSource = try sources().first { $0.id == context.sourceID }
        guard row["version"] == String(context.version), row["title"] == context.title,
              row["title_source_id"] == context.sourceID, (row["ai_named"] == "1" || titleSource?.transcript == context.title),
              try Self.relevanceJSON(entries) == Self.relevanceJSON(context.entries) else { throw VoiceOSError("问题、认识记录或关联资料已变化，请重新进入回顾") }
    }
}
