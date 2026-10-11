import Foundation
import CryptoKit

/// Input-independent local discussion history. This slice does not generate AI replies.
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
public struct ConversationTurnReference: Equatable, Sendable {
    public let turnID: String
    public let sourceID: String
    public let transcriptVersionID: String
}
/// The exact text-only input to a future discussion call, before any model invocation.
public struct PreparedConversationInput: Sendable {
    public let conversationID: String
    public let conversationVersion: Int
    public let contextID: String
    public let historySourceIDs: [String]
    public let userTurns: [ConversationTurnReference]
    public let destination: ModelDestination
}

extension VoiceOSStore {
    /// Only an explicit entry command creates a session. Entry never processes or endorses text.
    public func beginConversation(sourceIDs: [String], commandID: String = UUID().uuidString) throws -> String {
        guard ready, !commandID.isEmpty, !sourceIDs.isEmpty, Set(sourceIDs).count == sourceIDs.count else {
            throw VoiceOSError("请明确选择讨论来源和有效进入命令")
        }
        if let old = try db.query("SELECT * FROM conversations WHERE entry_command_id=?", [commandID]).first {
            let snapshot = try storedConversationContext(old["entry_context_id"]!)
            guard snapshot.sources.map(\.sourceID) == sourceIDs else { throw VoiceOSError("同一进入命令不能更换讨论来源") }
            return old["id"]!
        }
        let snapshot = try prepareLocalTranscriptContext(sourceIDs:sourceIDs)
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
    public func conversation(id: String) throws -> ConversationRecord {
        guard ready, let row = try db.query("SELECT * FROM conversations WHERE id=?",[id]).first else { throw VoiceOSError("讨论不存在") }
        // Reading a historical session can invalidate it, but cannot reactivate or process it.
        if row["validity"] == "current" {
            let contextIDs = [row["entry_context_id"]!] + (try db.query("SELECT context_id FROM conversation_user_turns WHERE conversation_id=? ORDER BY ordinal",[id])).compactMap { $0["context_id"] }
            for contextID in contextIDs {
                do { _ = try localContext(id:contextID) }
                catch { try db.execute("UPDATE conversations SET validity='frozen' WHERE id=?",[id]); break }
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
              expectedVersion <= 40 else { throw VoiceOSError("讨论已结束、来源已变化或会话版本不符；请重新核对") }
        guard try db.query("SELECT id FROM conversation_user_turns WHERE conversation_id=? AND source_id=?",[conversationID,sourceID]).isEmpty else { throw VoiceOSError("此来源已属于本次讨论，不重复保存为新发言") }
        let snapshot = try prepareLocalTranscriptContext(sourceIDs:[sourceID])
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
            guard let source = snapshot.sources.first, snapshot.sources.count == 1, source.sourceID == row["source_id"],
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
        let history = try storedConversationContext(session.entryContextID).sources.map(\.sourceID)
        let turns = try conversationUserTurns(conversationID:id)
        guard !turns.isEmpty else { throw VoiceOSError("请先保存一轮个人发言") }
        var ids = history
        for turn in turns where !ids.contains(turn.sourceID) { ids.append(turn.sourceID) }
        let snapshot = try prepareLocalTranscriptContext(sourceIDs:ids,scalarBudget:scalarBudget)
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
        let history = try storedConversationContext(session.entryContextID).sources.map(\.sourceID)
        let turns = try conversationUserTurns(conversationID:input.conversationID)
        let refs = turns.map { ConversationTurnReference(turnID:$0.id,sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID) }
        guard history == input.historySourceIDs, refs == input.userTurns else { throw VoiceOSError("讨论历史或发言身份不一致") }
        var ids = history
        for turn in turns where !ids.contains(turn.sourceID) { ids.append(turn.sourceID) }
        let snapshot = try localContext(id:input.contextID)
        guard snapshot.sources.map(\.sourceID) == ids else { throw VoiceOSError("实际讨论输入缺少来源或混入未选择历史") }
        return snapshot
    }
    private func storedConversationContext(_ id:String) throws -> LocalTranscriptContext {
        guard let row = try db.query("SELECT snapshot_json FROM contexts WHERE id=?",[id]).first else { throw VoiceOSError("讨论缺少原始上下文") }
        return try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(row["snapshot_json"]!.utf8))
    }
    static func validateStoredConversations(_ db:Database) throws {
        func checkedContext(_ id:String?) throws -> (LocalTranscriptContext,String) {
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
                guard let version = try db.query("SELECT v.*,t.source_id,s.version_id,s.origin,s.speaker FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?",[source.transcriptVersionID]).first,
                      inputs.contains(where: { $0["source_id"] == source.sourceID && $0["transcript_version_id"] == source.transcriptVersionID }),
                      version["source_id"] == source.sourceID, version["version_id"] == source.sourceVersionID,
                      version["text"] == source.text, version["origin"] == source.origin, version["speaker"] == source.speaker,
                      try encoder.encode(source.spans) == encoder.encode(JSONDecoder().decode([TranscriptSpan].self,from:Data(version["spans_json"]!.utf8))) else { throw VoiceOSError("讨论上下文历史与来源不一致") }
            }
            return (snapshot,row["state"]!)
        }
        for row in try db.query("SELECT * FROM conversations") {
            let turns = try db.query("SELECT * FROM conversation_user_turns WHERE conversation_id=? ORDER BY ordinal",[row["id"]])
            let (_,entryState) = try checkedContext(row["entry_context_id"])
            guard !(row["entry_command_id"] ?? "").isEmpty,
                  row["validity"] != "current" || entryState == "current",
                  turns.count <= 40,
                  row["version"] == String(1+turns.count+(row["state"] == "ended" ? 1 : 0)),
                  (row["state"] == "active" && row["end_command_id"] == nil && row["ended_at"] == nil) ||
                  (row["state"] == "ended" && !(row["end_command_id"] ?? "").isEmpty && row["ended_at"] != nil) else { throw VoiceOSError("讨论状态或版本链不一致") }
            for (index,turn) in turns.enumerated() {
                let (snapshot,turnState) = try checkedContext(turn["context_id"])
                guard turn["ordinal"] == String(index+1), turn["speaker"] == "user", !(turn["command_id"] ?? "").isEmpty,
                      row["validity"] != "current" || turnState == "current" else { throw VoiceOSError("讨论发言版本或上下文不一致") }
                guard snapshot.sources.count == 1, let source = snapshot.sources.first, source.sourceID == turn["source_id"],
                      source.origin == "user", source.speaker == "user", !source.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                      let original = try db.query("SELECT origin,speaker FROM sources WHERE id=?",[turn["source_id"]]).first,
                      original["origin"] == "user", original["speaker"] == "user" else { throw VoiceOSError("讨论个人发言身份不一致") }
            }
        }
    }
}
