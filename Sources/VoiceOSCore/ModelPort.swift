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
public struct SourcePolicy: Sendable {
    public let localOnly: Bool
    public let version: Int
}
extension VoiceOSStore {
    public func sourcePolicy(sourceID: String) throws -> SourcePolicy {
        guard let row = try db.query("SELECT local_only,policy_version FROM sources WHERE id=?", [sourceID]).first else { throw VoiceOSError("来源不存在") }
        guard let version = row["policy_version"].flatMap(Int.init), version > 0 else { throw VoiceOSError("来源授权版本无效") }
        return SourcePolicy(localOnly: row["local_only"] != "0", version: version)
    }
    @discardableResult
    public func setSourceLocalOnly(sourceID: String, expectedVersion: Int, localOnly: Bool, commandID: String = UUID().uuidString) throws -> Int {
        let fingerprint = SHA256.hash(data: try JSONSerialization.data(withJSONObject: [sourceID,String(expectedVersion),String(localOnly)])).map { String(format: "%02x", $0) }.joined()
        if let receipt = try db.query("SELECT * FROM source_policy_revisions WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == fingerprint else { throw VoiceOSError("同一授权命令不能改变内容") }
            return Int(receipt["to_version"]!)!
        }
        let result = try db.transaction {
            let old = try sourcePolicy(sourceID: sourceID)
            guard old.version == expectedVersion else { throw VoiceOSError("来源授权已经更新，请重新读取") }
            guard old.localOnly != localOnly else { throw VoiceOSError("来源授权没有变化") }
            let next = old.version + 1
            try db.execute("INSERT INTO source_policy_revisions(id,source_id,from_version,to_version,from_local_only,to_local_only,command_id,input_fingerprint,actor,created_at) VALUES(?,?,?,?,?,?,?,?,'user',?)", [UUID().uuidString,sourceID,String(old.version),String(next),old.localOnly ? "1":"0",localOnly ? "1":"0",commandID,fingerprint,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE sources SET local_only=?,policy_version=? WHERE id=?", [localOnly ? "1":"0",String(next),sourceID])
            try invalidateCognition(sourceID: sourceID)
            try checkpoint(.policyUncommitted)
            return next
        }
        try checkpoint(.policyCommitted)
        return result
    }
    public func generateClaims(contextID: String, using port: any ModelPort) async throws -> [String] {
        let config = port.configuration
        guard !config.provider.isEmpty, config.provider != "local_fixture", !config.model.isEmpty,
              !config.promptVersion.isEmpty, !config.schemaVersion.isEmpty else { throw VoiceOSError("模型端口配置缺少身份或版本") }
        guard try db.query("SELECT destination FROM contexts WHERE id=?", [contextID]).first?["destination"] == config.destination.rawValue else { throw VoiceOSError("模型目的地与上下文不一致") }
        let context = try localContext(id: contextID)
        if config.destination == .cloud, context.sources.contains(where: \.localOnly) { throw VoiceOSError("仅本地来源禁止云端发送") }
        let attempt = UUID().uuidString
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at) VALUES(?,?,?,?,?,?,'reserved',?)", [attempt,contextID,config.provider,config.model,config.promptVersion,config.schemaVersion,ISO8601DateFormatter().string(from: Date())])
        try checkpoint(.modelReserved)
        let response: ModelResponse
        do { response = try await port.generate(ModelRequest(attemptID: attempt, context: context, configuration: config)) }
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
        return try commitClaims(attemptID: attempt, proposals: response.claims)
    }
}

public struct ModelAttemptRecord: Identifiable, Sendable {
    public let id: String
    public let state: String
    public let provider: String
    public let model: String
    public let usage: [String: Int]?
    public let billingState: String
}
extension VoiceOSStore {
    public func modelAttempts() throws -> [ModelAttemptRecord] {
        try db.query("SELECT * FROM model_attempts ORDER BY created_at,id").map { row in
            ModelAttemptRecord(id: row["id"]!, state: row["state"]!, provider: row["provider"]!, model: row["model"]!, usage: try row["usage_json"].map { try JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) }, billingState: "unknown")
        }
    }
}
