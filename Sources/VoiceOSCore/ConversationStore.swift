import Foundation
import CryptoKit

/// Input-independent local discussion history; AI replies retain a separate identity.
public struct ConversationRecord: Identifiable, Sendable {
    public let id: String
    public let version: Int
    public let state: String
    public let validity: String
    public let entryContextID: String
}
public struct ConversationUserTurn: Identifiable, Sendable {
    public let id: String
    public let ordinal: Int
    public let sourceID: String
    public let transcriptVersionID: String
    public let text: String
    public let contextID: String
}
public struct ConversationTurnReference: Equatable, Codable, Sendable {
    public let turnID: String
    public let sourceID: String
    public let transcriptVersionID: String
}
/// The exact text-only input to a future discussion call, before any model invocation.
public struct PreparedConversationInput: Codable, Sendable {
    public let conversationID: String
    public let conversationVersion: Int
    public let contextID: String
    public let historySourceIDs: [String]
    public let userTurns: [ConversationTurnReference]
    public let destination: ModelDestination
}

/// AI summaries guide the topic; only evidence quotations are personal/source text.
public struct ConversationThoughtAnchor: Codable, Sendable {
    public let claimID: String
    public let reviewVersion: Int
    public let summary: String
    public let ownership: String
    public let evidence: [OutcomeSourceEvidence]
}
public struct ConversationThoughtTask: Codable, Sendable {
    public let actionID: String
    public let version: Int
    public let title: String
    public let state: String
    public let feedbackSourceIDs: [String]
    public var kind: String? = nil
    public var goalID: String? = nil
    public var feedbackActionVersions: [String: Int]? = nil
    public var claimID: String? = nil
}
public struct ConversationThoughtFocus: Codable, Sendable {
    public let selected: ConversationThoughtAnchor
    public let related: [ConversationThoughtAnchor]
    public let tasks: [ConversationThoughtTask]
    public var selectedActionID: String? = nil
}

extension VoiceOSStore {
    /// Size the complete selected evidence once; no unrelated source scan or text truncation.
    func prepareFullDiscussionContext(sourceIDs: [String], minimumBudget: Int = 1, replyCharacters: Int = 0) throws -> LocalTranscriptContext {
        let expandedIDs=try completeConversationSourceIDs(sourceIDs)
        let full = try prepareLocalTranscriptContext(sourceIDs:expandedIDs,scalarBudget:Int.max)
        let size = full.sources.reduce(0) { $0 + $1.text.unicodeScalars.count } + replyCharacters
        return LocalTranscriptContext(sources:full.sources,scalarBudget:max(minimumBudget,size),contentDigest:full.contentDigest,recordingContexts:full.recordingContexts)
    }
    public func conversations(limit:Int = 100) throws -> [ConversationRecord] {
        guard ready,(1...500).contains(limit) else { throw VoiceOSError("讨论历史范围无效") }
        return try db.query("SELECT id FROM conversations ORDER BY created_at DESC,id DESC LIMIT ?",[String(limit)]).map { try conversation(id:$0["id"]!) }
    }
    public func conversationsForSource(sourceID:String) throws -> [ConversationRecord] {
        guard ready else { throw VoiceOSError("资料库尚未恢复") }
        return try db.query("SELECT DISTINCT c.id,c.created_at FROM conversations c LEFT JOIN conversation_user_turns t ON t.conversation_id=c.id LEFT JOIN context_inputs i ON i.context_id=c.entry_context_id WHERE t.source_id=? OR i.source_id=? ORDER BY c.created_at DESC,c.id DESC LIMIT 100",[sourceID,sourceID]).map { try conversation(id:$0["id"]!) }
    }
    /// Immutable entry text for historical display; never grants processing permission.
    public func conversationHistorySources(conversationID:String) throws -> [ContextTranscript] {
        let session=try conversation(id:conversationID)
        return try storedConversationContext(session.entryContextID).sources
    }
    /// Only an explicit entry command creates a session. Entry never processes or endorses text.
    public func beginConversation(sourceIDs: [String], commandID: String = UUID().uuidString) throws -> String {
        guard ready, !commandID.isEmpty, !sourceIDs.isEmpty, Set(sourceIDs).count == sourceIDs.count else {
            throw VoiceOSError("请明确选择讨论来源和有效进入命令")
        }
        if let old = try db.query("SELECT * FROM conversations WHERE entry_command_id=?", [commandID]).first {
            let snapshot = try storedConversationContext(old["entry_context_id"]!)
            guard snapshot.sources.map(\.sourceID) == (try completeConversationSourceIDs(sourceIDs)) else { throw VoiceOSError("同一进入命令不能更换讨论来源") }
            return old["id"]!
        }
        let snapshot = try prepareFullDiscussionContext(sourceIDs:sourceIDs)
        guard snapshot.sources.contains(where: { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) else {
            throw VoiceOSError("讨论来源没有可用文字")
        }
        let context = try persistLocalContext(snapshot)
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO conversations(id,entry_command_id,entry_context_id,version,state,validity,created_at) VALUES(?,?,?,1,'active','current',?)", [id,commandID,context,Self.now()])
            try checkpoint(.conversationUncommitted)
        }
        try checkpoint(.conversationCommitted)
        return id
    }
    /// Starts with an actual thought and its source evidence, without inventing a user turn.
    public func beginConversationForThought(claimID: String, commandID: String = UUID().uuidString) throws -> String {
        try beginFocusedConversation(claimID: claimID, actionID: nil, commandID: commandID)
    }
    public func beginConversationForAction(actionID: String, commandID: String = UUID().uuidString) throws -> String {
        guard let action = try actions(includeHistory: true).first(where: { $0.id == actionID }),
              action.validity == "current", action.state != "dismissed", action.intentActor == "user" else { throw VoiceOSError("行动已变化，请从当前任务或目标重新进入") }
        return try beginFocusedConversation(claimID: action.claimID, actionID: actionID, commandID: commandID)
    }
    private func beginFocusedConversation(claimID: String, actionID: String?, commandID: String) throws -> String {
        guard ready, !commandID.isEmpty else { throw VoiceOSError("讨论进入命令无效") }
        if let old = try db.query("SELECT * FROM conversations WHERE entry_command_id=?", [commandID]).first {
            let focus = try storedConversationContext(old["entry_context_id"]!).conversationFocus
            guard focus?.selected.claimID == claimID, focus?.selectedActionID == actionID else { throw VoiceOSError("同一进入命令不能更换观点或行动") }
            return old["id"]!
        }
        let claims = try candidateClaims(), byID = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0) })
        let latest = try latestCandidateClaimsBySource()
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        let actions = try actions(includeHistory: true)
        let selectedAction = actions.first { $0.id == actionID }
        let goal = selectedAction?.intent?.goalID.flatMap { goalID in actions.first { $0.id == goalID && $0.validity == "current" && $0.state != "dismissed" } }
        let durableClaims = Set([selectedAction, goal].compactMap { $0 }.map(\.claimID))
        func anchor(_ id: String) throws -> ConversationThoughtAnchor {
            guard let claim = byID[id], durableClaims.contains(id) || claim.reviewState == "endorsed" || claim.references.allSatisfy({ ref in latest[ref.sourceID]?.contains(where: { $0.id == id }) == true }) else { throw VoiceOSError("观点已更新，请重新选择当前观点") }
            let evidence = try claim.references.map { ref -> OutcomeSourceEvidence in
                guard let source = catalog[ref.sourceID], source.transcriptVersionID == ref.transcriptVersionID,
                      let text = source.transcript, let span = source.spans.first(where: { $0.id == ref.spanID }) else { throw VoiceOSError("观点原话已变化") }
                let scalars = Array(text.unicodeScalars)
                return .init(reference: ref, quote: String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])))
            }
            return .init(claimID: id, reviewVersion: claim.reviewVersion, summary: claim.statement, ownership: claim.ownership, evidence: evidence)
        }
        let selected = try anchor(claimID)
        var related: [ConversationThoughtAnchor] = []
        if let goal, goal.claimID != claimID { related.append(try anchor(goal.claimID)) }
        let followups = try recordingFollowups(), validities = try recordingFollowupValidities(followups)
        for receipt in followups where receipt.state == "completed" {
            guard let validity = validities[receipt.id] else { continue }
            for update in receipt.result?.thoughtUpdates ?? [] where validity.thoughtIsCurrent(update.claimID) {
                guard selected.evidence.contains(where: { $0.reference.sourceID == receipt.sourceID && $0.quote.contains(update.currentQuote) }), update.claimID != claimID,
                      !related.contains(where: { $0.claimID == update.claimID }), let old = try? anchor(update.claimID) else { continue }
                related.append(old)
            }
        }
        let nearby = Set(claims.filter { claim in claim.references.contains { ref in selected.evidence.contains { $0.reference.sourceID == ref.sourceID && $0.reference.transcriptVersionID == ref.transcriptVersionID && $0.reference.spanID == ref.spanID } } }.map(\.id))
        let tasks = try actions.filter { action in
            guard action.validity == "current", action.state != "dismissed" else { return false }
            if let actionID { return action.id == actionID || action.id == goal?.id }
            return action.kind == "task" && nearby.contains(action.claimID)
        }.map { task in
            let feedback = try actionFeedback(actionID: task.id).filter { $0.sourceState == "saved" }
            return ConversationThoughtTask(actionID: task.id, version: task.version, title: task.title, state: task.state, feedbackSourceIDs: feedback.map(\.sourceID), kind: task.intent?.intentType ?? task.kind, goalID: task.intent?.goalID,
                                           feedbackActionVersions: Dictionary(uniqueKeysWithValues: feedback.map { ($0.sourceID, $0.actionVersion) }))
        }
        let focus = ConversationThoughtFocus(selected: selected, related: related, tasks: tasks, selectedActionID: actionID)
        var ids: [String] = []
        for id in ([selected] + related).flatMap({ $0.evidence.map { $0.reference.sourceID } }) + tasks.flatMap(\.feedbackSourceIDs) where !ids.contains(id) { ids.append(id) }
        var snapshot = try prepareFullDiscussionContext(sourceIDs:ids)
        snapshot.conversationFocus = focus
        let context = try persistLocalContext(snapshot), id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO conversations(id,entry_command_id,entry_context_id,version,state,validity,created_at) VALUES(?,?,?,1,'active','current',?)", [id,commandID,context,Self.now()])
            try checkpoint(.conversationUncommitted)
        }
        try checkpoint(.conversationCommitted)
        return id
    }

    func validateConversationThoughtFocus(_ focus: ConversationThoughtFocus) throws {
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id, $0) })
        let latest = try latestCandidateClaimsBySource()
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        let actions = Dictionary(uniqueKeysWithValues: try actions(includeHistory: true).map { ($0.id, $0) })
        var durableClaims = Set<String>()
        if let actionID = focus.selectedActionID {
            guard let action = actions[actionID], action.validity == "current", action.state != "dismissed", action.claimID == focus.selected.claimID,
                  focus.tasks.contains(where: { $0.actionID == actionID }) else { throw VoiceOSError("讨论中的行动已变化") }
            durableClaims.insert(action.claimID)
            if let goalID = action.intent?.goalID, let goal = actions[goalID], goal.validity == "current", goal.state != "dismissed" { durableClaims.insert(goal.claimID) }
        }
        for anchor in [focus.selected] + focus.related {
            guard let claim = claims[anchor.claimID], claim.reviewVersion == anchor.reviewVersion, claim.statement == anchor.summary, claim.ownership == anchor.ownership,
                  durableClaims.contains(claim.id) || claim.reviewState == "endorsed" || claim.references.allSatisfy({ ref in latest[ref.sourceID]?.contains(where: { $0.id == claim.id }) == true }) else { throw VoiceOSError("讨论观点已更正，请从当前观点重新进入") }
            guard try Self.relevanceJSON(claim.references) == Self.relevanceJSON(anchor.evidence.map(\.reference)) else { throw VoiceOSError("讨论观点出处不一致") }
            for evidence in anchor.evidence {
                let ref = evidence.reference
                guard let source = catalog[ref.sourceID], source.transcriptVersionID == ref.transcriptVersionID,
                      let text = source.transcript, let span = source.spans.first(where: { $0.id == ref.spanID }) else { throw VoiceOSError("讨论原话已变化") }
                let scalars = Array(text.unicodeScalars)
                guard String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])) == evidence.quote else { throw VoiceOSError("讨论引文已变化") }
            }
        }
        for task in focus.tasks {
            let feedback = try actionFeedback(actionID: task.actionID).filter { $0.sourceState == "saved" }
            guard let actual = actions[task.actionID], actual.validity == "current", actual.version == task.version, actual.title == task.title, actual.state == task.state,
                  task.kind == nil || (task.kind == (actual.intent?.intentType ?? actual.kind) && task.goalID == actual.intent?.goalID),
                  task.feedbackActionVersions == nil || task.feedbackActionVersions == Dictionary(uniqueKeysWithValues: feedback.map { ($0.sourceID, $0.actionVersion) }),
                  feedback.map(\.sourceID) == task.feedbackSourceIDs else { throw VoiceOSError("讨论中的任务或结果已更新，请从当前观点重新进入") }
        }
    }

    public func conversation(id: String) throws -> ConversationRecord {
        guard ready, let row = try db.query("SELECT * FROM conversations WHERE id=?",[id]).first else { throw VoiceOSError("讨论不存在") }
        // Reading a historical session can invalidate it, but cannot reactivate or process it.
        if row["validity"] == "current" {
            let contextIDs = [row["entry_context_id"]!] + (try db.query("SELECT context_id FROM conversation_user_turns WHERE conversation_id=? ORDER BY ordinal",[id])).compactMap { $0["context_id"] }
            for contextID in contextIDs {
                do {
                    let context = try localContext(id:contextID)
                    guard try completeConversationSourceIDs(context.sources.map(\.sourceID)) == context.sources.map(\.sourceID) else { throw VoiceOSError("完整表达的成员已变化") }
                }
                catch { try db.transaction { try freezeContext(contextID) }; break }
            }
            if let focus = try storedConversationContext(row["entry_context_id"]!).reflectionFocus {
                do { try validateReflectionFocus(focus) }
                catch { try db.transaction { try freezeContext(row["entry_context_id"]!) } }
            }
        }
        let current = try db.query("SELECT * FROM conversations WHERE id=?",[id]).first!
        return ConversationRecord(id:id,version:Int(current["version"]!)!,state:current["state"]!,validity:current["validity"]!,entryContextID:current["entry_context_id"]!)
    }
    /// A saved personal text/recording is attached with its exact current transcript version.
    /// Imported external or unknown-speaker media cannot become a user turn.
    public func appendConversationUserSource(conversationID: String, sourceID: String, expectedVersion: Int,
                                              commandID: String = UUID().uuidString) throws -> String {
        guard ready, !commandID.isEmpty, expectedVersion > 0, expectedVersion < Int.max else { throw VoiceOSError("讨论回合命令或版本无效") }
        if let old = try db.query("SELECT * FROM conversation_user_turns WHERE command_id=?",[commandID]).first {
            guard old["conversation_id"] == conversationID, old["source_id"] == sourceID,
                  old["ordinal"] == String(expectedVersion) else { throw VoiceOSError("同一发言命令不能更换讨论、来源或版本") }
            return old["id"]!
        }
        let session = try conversation(id:conversationID)
        guard session.state == "active", session.validity == "current", session.version == expectedVersion,
              expectedVersion < Int.max else { throw VoiceOSError("讨论已结束、来源已变化或会话版本不符；请重新核对") }
        guard try db.query("SELECT id FROM conversation_user_turns WHERE conversation_id=? AND source_id=?",[conversationID,sourceID]).isEmpty else { throw VoiceOSError("此来源已属于本次讨论，不重复保存为新发言") }
        let snapshot = try prepareFullDiscussionContext(sourceIDs:[sourceID])
        guard let source = snapshot.sources.first, source.origin == "user", source.speaker == "user",
              !source.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VoiceOSError("讨论发言需要已保存的个人表达") }
        let context = try persistLocalContext(snapshot), id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO conversation_user_turns(id,command_id,conversation_id,ordinal,source_id,context_id,speaker,created_at) VALUES(?,?,?,?,?,?,'user',?)", [id,commandID,conversationID,String(expectedVersion),sourceID,context,Self.now()])
            try db.execute("UPDATE conversations SET version=version+1 WHERE id=?",[conversationID])
            try checkpoint(.conversationTurnUncommitted)
        }
        try checkpoint(.conversationTurnCommitted)
        return id
    }
    /// Historical text remains readable after invalidation; consuming it for a new request is separate.
    public func conversationUserTurns(conversationID: String) throws -> [ConversationUserTurn] {
        _ = try conversation(id:conversationID)
        return try db.query("SELECT * FROM conversation_user_turns WHERE conversation_id=? ORDER BY ordinal",[conversationID]).map { row in
            let snapshot = try storedConversationContext(row["context_id"]!)
            guard let source = snapshot.sources.first, source.sourceID == row["source_id"],
                  source.origin == "user", source.speaker == "user" else { throw VoiceOSError("讨论发言出处不一致") }
            return ConversationUserTurn(id:row["id"]!,ordinal:Int(row["ordinal"]!)!,sourceID:source.sourceID,
                                        transcriptVersionID:source.transcriptVersionID,text:source.text,contextID:row["context_id"]!)
        }
    }
    public func endConversation(id: String, expectedVersion: Int, commandID: String = UUID().uuidString) throws {
        guard ready, !commandID.isEmpty, expectedVersion > 0, expectedVersion < Int.max else { throw VoiceOSError("结束讨论命令或版本无效") }
        if let old = try db.query("SELECT * FROM conversations WHERE end_command_id=?",[commandID]).first {
            guard old["id"] == id, old["version"] == String(expectedVersion+1) else { throw VoiceOSError("同一结束命令不能更换讨论或版本") }
            return
        }
        let session = try conversation(id:id)
        // Even a frozen session can be explicitly closed. Closing never endorses AI content.
        guard session.state == "active", session.version == expectedVersion else { throw VoiceOSError("讨论已结束或会话版本已变化") }
        try db.transaction {
            try db.execute("UPDATE conversations SET state='ended',end_command_id=?,ended_at=?,version=version+1 WHERE id=?",[commandID,Self.now(),id])
            try checkpoint(.conversationEndUncommitted)
        }
        try checkpoint(.conversationEndCommitted)
    }
    /// Retain every selected historical source and every user turn. Budget overflow is explicit.
    /// This prepares durable text input; it neither starts a model nor grants cloud access.
    public func prepareConversationInput(id:String, expectedVersion:Int, destination:ModelDestination,
                                         scalarBudget:Int = 8000, commandID:String = UUID().uuidString) throws -> PreparedConversationInput {
        guard !commandID.isEmpty, (1...12000).contains(scalarBudget) else { throw VoiceOSError("讨论上下文预算或准备命令无效") }
        let session = try conversation(id:id)
        guard session.state == "active", session.validity == "current", session.version == expectedVersion else { throw VoiceOSError("讨论已经结束或版本、来源已变化") }
        let entry = try storedConversationContext(session.entryContextID)
        let history = entry.sources.map(\.sourceID)
        guard try completeConversationSourceIDs(history) == history else { throw VoiceOSError("讨论依据已增加节目上下文，请从当前材料重新进入") }
        try validateLocalTranscriptContext(entry)
        let turns = try conversationUserTurns(conversationID:id)
        guard !turns.isEmpty else { throw VoiceOSError("请先保存一轮个人发言") }
        var ids = history
        for turn in turns {
            for source in try storedConversationContext(turn.contextID).sources where !ids.contains(source.sourceID) { ids.append(source.sourceID) }
        }
        try requireReviewedTranscriptions(sourceIDs:ids,destination:destination)
        if let focus = entry.conversationFocus { try validateConversationThoughtFocus(focus) }
        if let focus = entry.reflectionFocus { try validateReflectionFocus(focus) }
        let replyCharacters = try discussionAttempts(conversationID:id).filter { $0.state == "completed" && $0.validity == "current" }.reduce(0) { $0 + $1.parts.reduce(0) { $0 + $1.text.unicodeScalars.count } }
        var snapshot = try prepareFullDiscussionContext(sourceIDs:ids,minimumBudget:scalarBudget,replyCharacters:replyCharacters)
        snapshot.conversationFocus = entry.conversationFocus
        snapshot.reflectionFocus = entry.reflectionFocus
        let contextID = try persistLocalContext(snapshot,commandID:commandID,destination:destination)
        return PreparedConversationInput(conversationID:id,conversationVersion:expectedVersion,contextID:contextID,
                                         historySourceIDs:history,userTurns:turns.map { ConversationTurnReference(turnID:$0.id,sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID) },destination:destination)
    }
    /// Use both immediately before sending and before accepting an asynchronous reply.
    /// End, a new turn, source correction or any input-policy change invalidates this input.
    public func validateConversationInput(_ input:PreparedConversationInput) throws -> LocalTranscriptContext {
        let session = try conversation(id:input.conversationID)
        guard session.state == "active", session.validity == "current", session.version == input.conversationVersion,
              try db.query("SELECT destination FROM contexts WHERE id=?",[input.contextID]).first?["destination"] == input.destination.rawValue else { throw VoiceOSError("讨论输入已失效或处理目的不符") }
        let entry = try storedConversationContext(session.entryContextID)
        let history = entry.sources.map(\.sourceID)
        guard try completeConversationSourceIDs(history) == history else { throw VoiceOSError("讨论依据已增加节目上下文，请从当前材料重新进入") }
        try validateLocalTranscriptContext(entry)
        let turns = try conversationUserTurns(conversationID:input.conversationID)
        let refs = turns.map { ConversationTurnReference(turnID:$0.id,sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID) }
        guard history == input.historySourceIDs, refs == input.userTurns else { throw VoiceOSError("讨论历史或发言身份不一致") }
        var ids = history
        for turn in turns {
            for source in try storedConversationContext(turn.contextID).sources where !ids.contains(source.sourceID) { ids.append(source.sourceID) }
        }
        try requireReviewedTranscriptions(sourceIDs:ids,destination:input.destination)
        let snapshot = try localContext(id:input.contextID)
        if let focus = snapshot.conversationFocus { try validateConversationThoughtFocus(focus) }
        if let focus = snapshot.reflectionFocus { try validateReflectionFocus(focus) }
        guard try Self.relevanceJSON(snapshot.conversationFocus) == Self.relevanceJSON(entry.conversationFocus) else { throw VoiceOSError("讨论焦点与入口不一致") }
        guard try Self.relevanceJSON(snapshot.reflectionFocus) == Self.relevanceJSON(entry.reflectionFocus) else { throw VoiceOSError("完整讨论范围与入口不一致") }
        guard snapshot.sources.map(\.sourceID) == (try completeConversationSourceIDs(ids)) else { throw VoiceOSError("实际讨论输入缺少来源或混入未选择历史") }
        return snapshot
    }
    func conversationHistoryContext(_ conversationID: String) throws -> LocalTranscriptContext {
        try storedConversationContext(conversation(id: conversationID).entryContextID)
    }
    func completeConversationSourceIDs(_ sourceIDs: [String]) throws -> [String] {
        let expressions = try recordingExpressions()
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        var ids = sourceIDs
        for id in sourceIDs {
            let expression = expressions.first(where: { $0.sourceIDs.contains(id) })
            guard catalog[id]?.presentation?.expression == nil || expression != nil else { throw VoiceOSError("完整表达的成员或许可已变化，请重新整理") }
            if let expression {
                guard expression.state == "completed" else { throw VoiceOSError("完整表达仍在整理，请完成后讨论") }
                for member in expression.sourceIDs where !ids.contains(member) { ids.append(member) }
            }
        }
        return try recordingContextSourceIDs(sourceIDs: ids)
    }
    func storedConversationContext(_ id:String) throws -> LocalTranscriptContext {
        guard let row = try db.query("SELECT snapshot_json FROM contexts WHERE id=?",[id]).first else { throw VoiceOSError("讨论缺少原始上下文") }
        return try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(row["snapshot_json"]!.utf8))
    }
    static func validateStoredConversations(_ db:Database) throws {
        func checkedContext(_ id:String?, frozen:Bool) throws -> (LocalTranscriptContext,String) {
            guard let row = try db.query("SELECT * FROM contexts WHERE id=? AND destination='local'",[id]).first else { throw VoiceOSError("讨论缺少本地上下文") }
            let snapshot = try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(row["snapshot_json"]!.utf8))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let digest = SHA256.hash(data:try encoder.encode(snapshot.sources)).map { String(format:"%02x",$0) }.joined()
            let inputs = try db.query("SELECT * FROM context_inputs WHERE context_id=?",[id])
            guard snapshot.scalarBudget > 0, !snapshot.sources.isEmpty, inputs.count == snapshot.sources.count,
                  Set(snapshot.sources.map(\.sourceID)).count == snapshot.sources.count,
                  snapshot.sources.reduce(0, { $0 + $1.text.unicodeScalars.count }) <= snapshot.scalarBudget,
                  digest == snapshot.contentDigest, digest == row["digest"] else { throw VoiceOSError("讨论上下文摘要或预算不一致") }
            for source in snapshot.sources {
                guard let version = try db.query("SELECT v.*,t.source_id,t.current_version_id,s.version_id,s.origin,s.speaker,s.duration FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?",[source.transcriptVersionID]).first,
                      inputs.contains(where: { $0["source_id"] == source.sourceID && $0["transcript_version_id"] == source.transcriptVersionID }),
                      version["source_id"] == source.sourceID, version["version_id"] == source.sourceVersionID,
                      version["origin"] == source.origin, version["speaker"] == source.speaker,
                      try isPrunedHistoricalTranscript(version, historical: frozen && row["state"] == "stale") ||
                        (version["text"] == source.text && encoder.encode(source.spans) == encoder.encode(JSONDecoder().decode([TranscriptSpan].self,from:Data(version["spans_json"]!.utf8)))) else { throw VoiceOSError("讨论上下文历史与来源不一致") }
                try SpeechText(text: source.text, spans: source.spans).validate(duration: version["duration"].flatMap(Double.init))
            }
            return (snapshot,row["state"]!)
        }
        for row in try db.query("SELECT * FROM conversations") {
            let turns = try db.query("SELECT * FROM conversation_user_turns WHERE conversation_id=? ORDER BY ordinal",[row["id"]])
            let (_,entryState) = try checkedContext(row["entry_context_id"], frozen: row["validity"] == "frozen")
            guard !(row["entry_command_id"] ?? "").isEmpty,
                  row["validity"] != "current" || entryState == "current",
                  row["version"] == String(1+turns.count+(row["state"] == "ended" ? 1 : 0)),
                  (row["state"] == "active" && row["end_command_id"] == nil && row["ended_at"] == nil) ||
                  (row["state"] == "ended" && !(row["end_command_id"] ?? "").isEmpty && row["ended_at"] != nil) else { throw VoiceOSError("讨论状态或版本链不一致") }
            for (index,turn) in turns.enumerated() {
                let (snapshot,turnState) = try checkedContext(turn["context_id"], frozen: row["validity"] == "frozen")
                guard turn["ordinal"] == String(index+1), turn["speaker"] == "user", !(turn["command_id"] ?? "").isEmpty,
                      row["validity"] != "current" || turnState == "current" else { throw VoiceOSError("讨论发言版本或上下文不一致") }
                guard let source = snapshot.sources.first, source.sourceID == turn["source_id"],
                      source.origin == "user", source.speaker == "user", !source.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                      let original = try db.query("SELECT origin,speaker FROM sources WHERE id=?",[turn["source_id"]]).first,
                      original["origin"] == "user", original["speaker"] == "user" else { throw VoiceOSError("讨论个人发言身份不一致") }
            }
        }
    }
}
