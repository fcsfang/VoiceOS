import Foundation

public struct DiscussionPart: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case quotation, aiSuggestion = "ai_suggestion" }
    public let kind: Kind
    public let text: String
    public let references: [ClaimReference]
    public init(kind:Kind,text:String,references:[ClaimReference] = []) { self.kind=kind;self.text=text;self.references=references }
}
public struct DiscussionPriorReply: Codable, Sendable {
    public let attemptID: String
    public let replyToTurnID: String
    public let digest: String
    public let parts: [DiscussionPart]
}
public struct DiscussionSnapshot: Codable, Sendable {
    public let input: PreparedConversationInput
    public let context: LocalTranscriptContext
    public let priorReplies: [DiscussionPriorReply]
}
public struct DiscussionModelRequest: Sendable {
    public let attemptID: String
    public let snapshot: DiscussionSnapshot
    public let configuration: ModelConfiguration
}
public struct DiscussionModelResponse: Sendable {
    public let status: ModelResponse.Status
    public let parts: [DiscussionPart]
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(status:ModelResponse.Status,parts:[DiscussionPart],inputTokens:Int? = nil,outputTokens:Int? = nil) {
        self.status=status;self.parts=parts;self.inputTokens=inputTokens;self.outputTokens=outputTokens
    }
}
/// One direct text request. No implicit retry, queued send, tools or raw audio.
public protocol DiscussionModelPort: Sendable {
    var configuration: ModelConfiguration { get }
    func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse
}
public struct DiscussionAttemptRecord: Identifiable, Sendable {
    public let id: String
    public let replyToTurnID: String
    public let state: String
    public let validity: String
    public let parts: [DiscussionPart]
    public let usage: [String:Int]?
    public let billingState: String
}

extension VoiceOSStore {
    /// One durable request per user turn, even if a different preparation command/model is used.
    /// An unknown request is not retried by re-preparing its input.
    public func performConversationReply(_ input:PreparedConversationInput, using port:any DiscussionModelPort) async throws -> String {
        try Task.checkCancellation()
        let context = try validateConversationInput(input), configuration = port.configuration
        guard configuration.destination == input.destination, !configuration.provider.isEmpty, !configuration.model.isEmpty,
              !configuration.promptVersion.isEmpty, !configuration.schemaVersion.isEmpty,
              let last = input.userTurns.last else { throw VoiceOSError("讨论端口配置或个人发言不符") }
        guard try db.query("SELECT id FROM discussion_attempts WHERE conversation_id=? AND reply_to_turn_id=?",[input.conversationID,last.turnID]).isEmpty else { throw VoiceOSError("这轮已有模型调用记录，请查看历史；不会自动重发") }
        let snapshot = DiscussionSnapshot(input:input,context:context,priorReplies:try currentDiscussionPriorReplies(input))
        try Self.validateDiscussionBudget(snapshot)
        let json = try Self.relevanceJSON(snapshot), digest = Self.relevanceHash(Data(json.utf8)), id = UUID().uuidString
        try db.execute("""
        INSERT INTO discussion_attempts(id,conversation_id,reply_to_turn_id,context_id,destination,provider,model,prompt_version,schema_version,snapshot_json,snapshot_digest,state,validity,created_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,'reserved','current',?)
        """,[id,input.conversationID,last.turnID,input.contextID,input.destination.rawValue,configuration.provider,configuration.model,configuration.promptVersion,configuration.schemaVersion,json,digest,Self.now()])
        try checkpoint(.discussionReserved)
        let response:DiscussionModelResponse
        do {
            try Task.checkCancellation()
            try validateDiscussionSnapshot(snapshot)
            response = try await port.reply(DiscussionModelRequest(attemptID:id,snapshot:snapshot,configuration:configuration))
        } catch ModelPortFailure.rejected(_,let inputTokens,let outputTokens) {
            if (inputTokens ?? 0) >= 0, (outputTokens ?? 0) >= 0 {
                try recordDiscussionUsage(id,inputTokens:inputTokens,outputTokens:outputTokens)
            }
            try db.execute("UPDATE discussion_attempts SET state='rejected',error='模型拒绝或格式不符；不自动重发' WHERE id=? AND state='reserved'",[id])
            throw VoiceOSError("讨论响应未接纳，已保留调用记录和已知用量")
        } catch {
            try db.execute("UPDATE discussion_attempts SET state='unknown',error='结果未登记；费用未知，不自动重发' WHERE id=? AND state='reserved'",[id])
            throw VoiceOSError("讨论调用结果未知，不会自动重发")
        }
        do {
            try recordDiscussionUsage(id,inputTokens:response.inputTokens,outputTokens:response.outputTokens)
            try Task.checkCancellation()
            guard response.status == .completed else { throw VoiceOSError("讨论响应未完成") }
            try validateDiscussionSnapshot(snapshot)
            try Self.validateDiscussionParts(response.parts,context:context)
            let result = try Self.relevanceJSON(response.parts)
            try db.transaction {
                guard try db.query("SELECT state,validity FROM discussion_attempts WHERE id=?",[id]).first == ["state":"reserved","validity":"current"] else { throw VoiceOSError("讨论调用已经失效") }
                try db.execute("UPDATE discussion_attempts SET state='completed',result_json=?,result_digest=? WHERE id=?",[result,Self.relevanceHash(Data(result.utf8)),id])
                try checkpoint(.discussionUncommitted)
            }
        } catch {
            try db.execute("UPDATE discussion_attempts SET state='rejected',validity='frozen',error='响应、来源、授权或讨论状态不符' WHERE id=? AND state='reserved'",[id])
            throw VoiceOSError("讨论结果未接纳，已保存调用状态；不创建观点或任务")
        }
        try checkpoint(.discussionCommitted)
        return id
    }
    public func discussionAttempts(conversationID:String) throws -> [DiscussionAttemptRecord] {
        _ = try conversation(id:conversationID)
        return try db.query("SELECT a.* FROM discussion_attempts a JOIN conversation_user_turns t ON t.id=a.reply_to_turn_id WHERE a.conversation_id=? ORDER BY t.ordinal",[conversationID]).map { row in
            let parts = try Self.discussionParts(row)
            return DiscussionAttemptRecord(id:row["id"]!,replyToTurnID:row["reply_to_turn_id"]!,state:row["state"]!,validity:row["validity"]!,parts:parts,
                                           usage:try row["usage_json"].map { try JSONDecoder().decode([String:Int].self,from:Data($0.utf8)) },billingState:"unknown")
        }
    }
    private func recordDiscussionUsage(_ id:String,inputTokens:Int?,outputTokens:Int?) throws {
        guard (inputTokens ?? 0) >= 0, (outputTokens ?? 0) >= 0 else { throw VoiceOSError("讨论响应用量无效") }
        var usage:[String:Int] = [:]
        if let inputTokens { usage["input_tokens"] = inputTokens }; if let outputTokens { usage["output_tokens"] = outputTokens }
        if !usage.isEmpty { try db.execute("UPDATE discussion_attempts SET usage_json=? WHERE id=?",[try Self.relevanceJSON(usage),id]) }
    }
    private func currentDiscussionPriorReplies(_ input:PreparedConversationInput) throws -> [DiscussionPriorReply] {
        var result:[DiscussionPriorReply] = []
        for row in try db.query("SELECT a.* FROM discussion_attempts a JOIN conversation_user_turns t ON t.id=a.reply_to_turn_id WHERE a.conversation_id=? AND a.state='completed' AND a.validity='current' ORDER BY t.ordinal",[input.conversationID]) {
            guard input.userTurns.dropLast().contains(where: { $0.turnID == row["reply_to_turn_id"] }) else { throw VoiceOSError("讨论回复顺序与输入不符") }
            let past = try JSONDecoder().decode(DiscussionSnapshot.self,from:Data(row["snapshot_json"]!.utf8))
            _ = try localContext(id:past.input.contextID)
            let parts = try Self.discussionParts(row)
            if input.destination == .cloud, past.context.sources.contains(where:\.localOnly) { throw VoiceOSError("仅本地衍生回复不能进入云端讨论") }
            result.append(DiscussionPriorReply(attemptID:row["id"]!,replyToTurnID:row["reply_to_turn_id"]!,digest:row["result_digest"]!,parts:parts))
        }
        return result
    }
    private func validateDiscussionSnapshot(_ snapshot:DiscussionSnapshot) throws {
        let current = try validateConversationInput(snapshot.input)
        let prior = try currentDiscussionPriorReplies(snapshot.input)
        guard try Self.relevanceJSON(current) == Self.relevanceJSON(snapshot.context),
              try Self.relevanceJSON(prior) == Self.relevanceJSON(snapshot.priorReplies) else { throw VoiceOSError("讨论实际输入或旧回复已变化") }
        try Self.validateDiscussionBudget(snapshot)
    }
    static func validateDiscussionBudget(_ snapshot:DiscussionSnapshot) throws {
        // Whole transcript texts are included once; role references do not duplicate their content.
        let count = snapshot.context.sources.reduce(0) { $0+$1.text.unicodeScalars.count }
                    + snapshot.priorReplies.reduce(0) { $0+$1.parts.reduce(0) { $0+$1.text.unicodeScalars.count } }
        guard count <= snapshot.context.scalarBudget else { throw VoiceOSError("完整讨论输入超过预算；不会静默丢弃早期历史") }
    }
    static func validateDiscussionParts(_ parts:[DiscussionPart],context:LocalTranscriptContext) throws {
        guard !parts.isEmpty else { throw VoiceOSError("讨论响应为空") }
        for part in parts {
            guard !part.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VoiceOSError("讨论段落无效") }
            var seen:Set<String> = []
            for ref in part.references {
                guard seen.insert(ref.sourceID+":"+ref.transcriptVersionID+":"+ref.spanID).inserted,
                      let source = context.sources.first(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID }),
                      let span = source.spans.first(where: { $0.id == ref.spanID }) else { throw VoiceOSError("讨论引用没有对应的实际输入") }
                if part.kind == .quotation {
                    let text = Array(source.text.unicodeScalars)
                    guard span.textStart >= 0, span.textEnd <= text.count, span.textStart < span.textEnd,
                          String(String.UnicodeScalarView(text[span.textStart..<span.textEnd])).contains(part.text) else { throw VoiceOSError("讨论引文与原文不符") }
                }
            }
            if part.kind == .quotation, part.references.count != 1 { throw VoiceOSError("原文引用必须保留单一明确出处") }
        }
    }
    static func discussionParts(_ row:[String:String]) throws -> [DiscussionPart] {
        guard row["state"] == "completed" else {
            guard row["result_json"] == nil, row["result_digest"] == nil else { throw VoiceOSError("未接纳调用不能带已提交回复") }; return []
        }
        guard let result = row["result_json"], row["result_digest"] == relevanceHash(Data(result.utf8)) else { throw VoiceOSError("讨论结果摘要不一致") }
        let parts = try JSONDecoder().decode([DiscussionPart].self,from:Data(result.utf8))
        let snapshot = try JSONDecoder().decode(DiscussionSnapshot.self,from:Data(row["snapshot_json"]!.utf8))
        try validateDiscussionParts(parts,context:snapshot.context)
        return parts
    }
    static func validateStoredDiscussionAttempts(_ db:Database) throws {
        for row in try db.query("SELECT * FROM discussion_attempts") {
            guard let json = row["snapshot_json"], json.utf8.count <= 4000000,
                  row["snapshot_digest"] == relevanceHash(Data(json.utf8)) else { throw VoiceOSError("讨论调用快照不一致") }
            let s = try JSONDecoder().decode(DiscussionSnapshot.self,from:Data(json.utf8))
            guard s.input.conversationID == row["conversation_id"], s.input.userTurns.last?.turnID == row["reply_to_turn_id"],
                  s.input.contextID == row["context_id"], s.input.destination.rawValue == row["destination"],
                  !s.input.userTurns.isEmpty, s.input.conversationVersion == s.input.userTurns.count+1,
                  let session = try db.query("SELECT * FROM conversations WHERE id=?",[row["conversation_id"]]).first,
                  let entry = try db.query("SELECT snapshot_json FROM contexts WHERE id=?",[session["entry_context_id"]]).first,
                  let context = try db.query("SELECT * FROM contexts WHERE id=?",[row["context_id"]]).first,
                  context["destination"] == row["destination"],
                  row["validity"] != "current" || (session["validity"] == "current" && context["state"] == "current"),
                  try relevanceJSON(s.context) == context["snapshot_json"],
                  s.input.historySourceIDs == (try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(entry["snapshot_json"]!.utf8)).sources.map(\.sourceID)),
                  ["provider","model","prompt_version","schema_version"].allSatisfy({ !(row[$0] ?? "").isEmpty }) else { throw VoiceOSError("讨论调用身份、历史或配置不符") }
            let turns = try db.query("SELECT t.*,c.snapshot_json FROM conversation_user_turns t JOIN contexts c ON c.id=t.context_id WHERE t.conversation_id=? ORDER BY t.ordinal",[row["conversation_id"]])
            guard turns.count >= s.input.userTurns.count else { throw VoiceOSError("讨论调用缺少个人回合") }
            for (index,ref) in s.input.userTurns.enumerated() {
                let turn = turns[index], text = try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(turn["snapshot_json"]!.utf8))
                guard turn["id"] == ref.turnID, turn["source_id"] == ref.sourceID, text.sources.first?.transcriptVersionID == ref.transcriptVersionID else { throw VoiceOSError("讨论调用个人回合顺序不符") }
            }
            let entryContext = try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(entry["snapshot_json"]!.utf8))
            guard try relevanceJSON(entryContext.conversationFocus) == relevanceJSON(s.context.conversationFocus) else { throw VoiceOSError("讨论焦点与保存入口不一致") }
            guard try relevanceJSON(entryContext.reflectionFocus) == relevanceJSON(s.context.reflectionFocus) else { throw VoiceOSError("周期回顾与保存入口不一致") }
            var historicalSources = entryContext.sources
            for turn in turns.prefix(s.input.userTurns.count) {
                let saved = try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(turn["snapshot_json"]!.utf8))
                for source in saved.sources where !historicalSources.contains(where: { $0.sourceID == source.sourceID }) { historicalSources.append(source) }
            }
            guard try relevanceJSON(historicalSources) == relevanceJSON(s.context.sources) else { throw VoiceOSError("讨论实际文本与回合来源不符") }
            let ids = historicalSources.map(\.sourceID)
            guard s.context.sources.map(\.sourceID) == ids,
                  s.input.destination == .local || s.context.sources.allSatisfy({ !$0.localOnly }),
                  Set(s.priorReplies.map(\.attemptID)).count == s.priorReplies.count else { throw VoiceOSError("讨论实际来源或衍生限制不符") }
            let canonical = try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(context["snapshot_json"]!.utf8))
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            guard canonical.contentDigest == relevanceHash(try encoder.encode(canonical.sources)), canonical.contentDigest == context["digest"] else { throw VoiceOSError("讨论输入上下文摘要不符") }
            let precedingIDs = Set(s.input.userTurns.dropLast().map(\.turnID))
            let precedingCompleted = try db.query("SELECT a.id,a.reply_to_turn_id FROM discussion_attempts a JOIN conversation_user_turns t ON t.id=a.reply_to_turn_id WHERE a.conversation_id=? AND a.state='completed' ORDER BY t.ordinal",[row["conversation_id"]]).filter { precedingIDs.contains($0["reply_to_turn_id"]!) }
            guard s.priorReplies.map(\.attemptID) == precedingCompleted.map({ $0["id"]! }) else { throw VoiceOSError("讨论历史AI回合缺失或顺序不符") }
            for prior in s.priorReplies {
                guard s.input.userTurns.dropLast().contains(where: { $0.turnID == prior.replyToTurnID }),
                      let past = try db.query("SELECT * FROM discussion_attempts WHERE id=? AND conversation_id=? AND reply_to_turn_id=? AND state='completed'",[prior.attemptID,row["conversation_id"],prior.replyToTurnID]).first,
                      past["result_digest"] == prior.digest,
                      try relevanceJSON(prior.parts) == past["result_json"] else { throw VoiceOSError("讨论历史AI回合没有对应结果") }
            }
            try validateDiscussionBudget(s)
            _ = try discussionParts(row)
            if let usage = row["usage_json"] {
                let values = try JSONDecoder().decode([String:Int].self,from:Data(usage.utf8))
                guard Set(values.keys).isSubset(of:["input_tokens","output_tokens"]), values.values.allSatisfy({ $0 >= 0 }) else { throw VoiceOSError("讨论历史用量无效") }
            }
        }
    }
}
