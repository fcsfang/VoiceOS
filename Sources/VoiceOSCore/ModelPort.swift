import Foundation
import CryptoKit

public enum ModelDestination: String, Codable, Sendable { case local, cloud }
public struct ModelConfiguration: Sendable {
    public let provider: String
    public let model: String
    public let promptVersion: String
    public let schemaVersion: String
    public let destination: ModelDestination
    public init(provider: String, model: String, promptVersion: String, schemaVersion: String, destination: ModelDestination) {
        self.provider = provider; self.model = model; self.promptVersion = promptVersion; self.schemaVersion = schemaVersion; self.destination = destination
    }
    /// A request may use this port only when it carries the same identity and
    /// both sides target the cloud. Every port is built with a cloud destination,
    /// so this is the one place the identity rule is expressed.
    public func accepts(_ request: ModelConfiguration) -> Bool {
        destination == .cloud && request.destination == .cloud
            && provider == request.provider && model == request.model
            && promptVersion == request.promptVersion && schemaVersion == request.schemaVersion
    }
}
public struct ModelRequest: Sendable {
    public let attemptID: String
    public let context: LocalTranscriptContext
    public let configuration: ModelConfiguration
}
public struct ModelResponse: Sendable {
    public enum Status: Sendable { case completed, incomplete, refused }
    public let status: Status
    public let claims: [ClaimProposal]
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(status: Status, claims: [ClaimProposal], inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.status = status; self.claims = claims; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}
/// Implementations must start the one authorized request directly, without queued sends,
/// implicit retries or tools. Raw audio is absent from this text-only contract.
public protocol ModelPort: Sendable {
    var configuration: ModelConfiguration { get }
    func generate(_ request: ModelRequest) async throws -> ModelResponse
}
extension VoiceOSStore {
    /// Cloud cognition must wait for the recording's full audio/context review.
    /// Local reading and local models remain available while that review is pending.
    func requireReviewedTranscriptions(sourceIDs: [String], destination: ModelDestination) throws {
        guard destination == .cloud else { return }
        let pending = try sourceRecords(ids: sourceIDs).filter(\.needsTranscriptionReview)
        guard !pending.isEmpty else { return }
        for source in pending {
            // Completed cloud derivations from the unchecked transcript remain
            // historical evidence, never a current route around the new barrier.
            for row in try db.query("SELECT DISTINCT c.id FROM contexts c JOIN context_inputs i ON i.context_id=c.id WHERE i.source_id=? AND c.destination='cloud' AND c.state='current'",[source.id]) {
                try freezeContext(row["id"]!)
            }
        }
        throw VoiceOSError("请先完成这份 Qwen 录音的全文转写校正，再进行云端理解或跟进")
    }
    public func generateClaims(contextID: String, using port: any ModelPort) async throws -> [String] {
        try Task.checkCancellation()
        let config = port.configuration
        guard !config.provider.isEmpty, !["local_fixture","discussion_derivation","segmented_derivation"].contains(config.provider), !config.provider.hasPrefix("discussion_outcome:"), !config.model.isEmpty,
              !config.promptVersion.isEmpty, !config.schemaVersion.isEmpty else { throw VoiceOSError("模型端口配置缺少身份或版本") }
        guard try db.query("SELECT destination FROM contexts WHERE id=?", [contextID]).first?["destination"] == config.destination.rawValue else { throw VoiceOSError("模型目的地与上下文不一致") }
        let context = try localContext(id: contextID)
        try requireReviewedTranscriptions(sourceIDs:context.sources.map(\.sourceID),destination:config.destination)
        if config.destination == .cloud, context.sources.contains(where: \.localOnly) { throw VoiceOSError("仅本地来源禁止云端发送") }
        let attempt = UUID().uuidString
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at,producer_sequence) VALUES(?,?,?,?,?,?,'reserved',?,?)", [attempt,contextID,config.provider,config.model,config.promptVersion,config.schemaVersion,ISO8601DateFormatter().string(from: Date()),try db.nextModelProducerSequence()])
        try checkpoint(.modelReserved)
        let response: ModelResponse
        do { response = try await port.generate(ModelRequest(attemptID: attempt, context: context, configuration: config)) }
        catch ModelPortFailure.rejected(let reason, let input, let output) {
            var usage: [String: Int] = [:]
            if let input, input >= 0 { usage["input_tokens"] = input }
            if let output, output >= 0 { usage["output_tokens"] = output }
            if !usage.isEmpty {
                let encoded = try JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys])
                try db.execute("UPDATE model_attempts SET usage_json=? WHERE id=?", [String(decoding: encoded, as: UTF8.self),attempt])
            }
            try db.execute("UPDATE model_attempts SET state='rejected',error=? WHERE id=? AND state='reserved'", [reason,attempt])
            throw VoiceOSError("模型响应被拒绝：" + reason)
        }
        catch {
            try db.execute("UPDATE model_attempts SET state='unknown',error='传输未返回结果；费用未知，不自动重发' WHERE id=? AND state='reserved'", [attempt])
            throw VoiceOSError("模型请求结果未知，已保留调用记录，不会自动重发")
        }
        guard (response.inputTokens ?? 0) >= 0, (response.outputTokens ?? 0) >= 0 else {
            try db.execute("UPDATE model_attempts SET state='rejected',error='响应未完成、被拒绝或用量字段无效' WHERE id=?", [attempt])
            throw VoiceOSError("模型没有返回可接纳的完整响应")
        }
        var usage: [String: Int] = [:]
        if let value = response.inputTokens { usage["input_tokens"] = value }
        if let value = response.outputTokens { usage["output_tokens"] = value }
        if !usage.isEmpty {
            let encoded = try JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys])
            try db.execute("UPDATE model_attempts SET usage_json=? WHERE id=?", [String(decoding: encoded, as: UTF8.self),attempt])
        }
        guard response.status == .completed else {
            try db.execute("UPDATE model_attempts SET state='rejected',error='响应未完成或被拒绝' WHERE id=?", [attempt])
            throw VoiceOSError("模型没有返回可接纳的完整响应")
        }
        do {
            try Task.checkCancellation()
            try requireReviewedTranscriptions(sourceIDs:context.sources.map(\.sourceID),destination:config.destination)
            return try commitClaims(attemptID: attempt, proposals: response.claims)
        } catch {
            try db.execute("UPDATE model_attempts SET state='rejected',error='结果因取消、来源或提交状态未接纳；不自动重发' WHERE id=? AND state='reserved'", [attempt])
            throw error
        }
    }
}

public struct ModelAttemptRecord: Identifiable, Sendable {
    public let producerSequence:Int64
    public let executionKind: String
    public let id: String
    public let state: String
    public let provider: String
    public let model: String
    public let usage: [String: Int]?
    public let billingState: String
    public let contextState: String
}
extension VoiceOSStore {
    public func modelAttempts(sourceID: String? = nil) throws -> [ModelAttemptRecord] {
        let rows: [[String: String]]
        if let sourceID {
            rows = try db.query("SELECT a.*,c.state AS context_state FROM model_attempts a JOIN contexts c ON c.id=a.context_id WHERE a.context_id IN (SELECT context_id FROM context_inputs WHERE source_id=?) ORDER BY a.created_at,a.id", [sourceID])
        } else { rows = try db.query("SELECT a.*,c.state AS context_state FROM model_attempts a JOIN contexts c ON c.id=a.context_id ORDER BY a.created_at,a.id") }
        return try rows.map(Self.modelAttemptRecord)
    }
    public func modelAttemptsBySource() throws -> [String: [ModelAttemptRecord]] {
        var result: [String: [ModelAttemptRecord]] = [:]
        for row in try db.query("SELECT a.*,c.state AS context_state,i.source_id FROM model_attempts a JOIN contexts c ON c.id=a.context_id JOIN context_inputs i ON i.context_id=c.id ORDER BY a.created_at,a.id") {
            result[row["source_id"]!, default: []].append(try Self.modelAttemptRecord(row))
        }
        return result
    }
    private static func modelAttemptRecord(_ row: [String: String]) throws -> ModelAttemptRecord {
        ModelAttemptRecord(producerSequence:Int64(row["producer_sequence"]!)!,executionKind:row["execution_kind"]!,id: row["id"]!, state: row["state"]!, provider: row["provider"]!, model: row["model"]!, usage: try row["usage_json"].map { try JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) }, billingState:row["execution_kind"] == "segmented_derivation" || row["execution_kind"] == "discussion_derivation" && row["provider"]?.hasPrefix("english_feedback:") != true ? "not_applicable" : "unknown", contextState: row["context_state"]!)
    }
}

// A source version/configuration has one explicit understanding attempt, including failures.
// New source text or policy permits new work; reopening a window never resends old work.
extension VoiceOSStore {
    public func understandSource(sourceID: String, using port: any ModelPort, retryKey: String? = nil) async throws -> [String] {
        let source = try sources().first { $0.id == sourceID }
        let budget = source?.kind == "external_text" ? max(1, source?.transcript?.unicodeScalars.count ?? 0) : 4000
        let context = try prepareLocalTranscriptContext(sourceIDs: [sourceID], scalarBudget: budget)
        guard try db.query("""
        SELECT o.id FROM conversation_outcome_attempts o JOIN conversation_user_turns t ON t.conversation_id=o.conversation_id
        JOIN context_inputs i ON i.context_id=t.context_id
        WHERE t.source_id=? AND i.transcript_version_id=? LIMIT 1
        """,[sourceID,context.sources[0].transcriptVersionID]).isEmpty else { throw VoiceOSError("这轮原话已有讨论成果理解记录；请查看原成果，不会跨入口重复发送。独立重整与共享身份待后续接入") }
        let policy = try sourcePolicy(sourceID: sourceID)
        // A contract/model upgrade is not permission to replay an existing expression attempt.
        // Only the explicit reprocess command may add a new attempt for the same scope.
        if retryKey == nil {
            guard try db.query("""
            SELECT a.id FROM model_attempts a JOIN context_inputs i ON i.context_id=a.context_id JOIN contexts x ON x.id=a.context_id
            WHERE i.source_id=? AND i.transcript_version_id=? AND COALESCE(i.policy_version,1)=CAST(? AS INTEGER)
              AND x.digest=?
              AND a.execution_kind='model_request' LIMIT 1
            """, [sourceID, context.sources[0].transcriptVersionID, String(policy.version), context.contentDigest]).isEmpty else {
                throw VoiceOSError("当前原话与授权已有理解尝试；模型或Schema更新不会重发，请查看原记录")
            }
        }
        let config = port.configuration
        let identity = ["understand-v1", sourceID, context.contentDigest, String(policy.version), config.provider, config.model, config.promptVersion, config.schemaVersion, config.destination.rawValue]
        let digest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: identity)).map { String(format: "%02x", $0) }.joined()
        let commandID = retryKey.map { "understand-retry:" + $0 + ":" + digest } ?? "understand:" + digest
        let contextID = try persistLocalContext(context, commandID: commandID, destination: config.destination)
        guard try db.query("SELECT id FROM model_attempts WHERE context_id=?", [contextID]).isEmpty else {
            throw VoiceOSError("这份文字与授权版本已有理解记录；请查看结果，不会重复发送")
        }
        return try await generateClaims(contextID: contextID, using: port)
    }
}
