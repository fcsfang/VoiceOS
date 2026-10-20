import Foundation
import CryptoKit

public struct RelevanceModelRequest: Sendable {
    public let attemptID: String
    public let snapshot: RelevanceSnapshot
    public let configuration: ModelConfiguration
}
public struct RelevanceModelResponse: Sendable {
    public let status: ModelResponse.Status
    public let selection: RelevanceSelection?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(status: ModelResponse.Status, selection: RelevanceSelection?, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.status = status; self.selection = selection; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}
/// One direct request; no tools, queued sends or implicit retries. No raw audio.
public protocol RelevanceModelPort: Sendable {
    var configuration: ModelConfiguration { get }
    func select(_ request: RelevanceModelRequest) async throws -> RelevanceModelResponse
}
public struct RelevanceAttemptRecord: Sendable, Identifiable {
    public let id: String
    public let queryID: UUID
    public let state: String
    public let validity: String
    public let model: String
    public let usage: [String: Int]?
    public let billingState: String
}
extension VoiceOSStore {
    public func performRelevanceSelection(_ snapshot: RelevanceSnapshot, using port: any RelevanceModelPort) async throws -> [RetrievalHit] {
        try Task.checkCancellation()
        try validateRelevanceSnapshot(snapshot, currentQueryID: snapshot.queryID)
        let config = port.configuration
        guard config.destination == snapshot.destination, !config.provider.isEmpty, !config.model.isEmpty,
              !config.promptVersion.isEmpty, !config.schemaVersion.isEmpty else { throw VoiceOSError("相关性端口身份或目的地不一致") }
        let fingerprint = try Self.relevanceFingerprint(snapshot.contentDigest, config)
        let command = "relevance:" + fingerprint
        guard try db.query("SELECT id FROM relevance_attempts WHERE command_id=?", [command]).isEmpty else {
            throw VoiceOSError("这轮查询已有相关性调用记录；请查看历史，不自动重发")
        }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("""
            INSERT INTO relevance_attempts(id,command_id,fingerprint,snapshot_json,snapshot_digest,destination,provider,model,prompt_version,schema_version,state,validity,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,'reserved','current',?)
            """, [id,command,fingerprint,try Self.relevanceJSON(snapshot),snapshot.contentDigest,snapshot.destination.rawValue,
                    config.provider,config.model,config.promptVersion,config.schemaVersion,ISO8601DateFormatter().string(from: Date())])
            for (ordinal, hit) in snapshot.candidates.enumerated() {
                try db.execute("INSERT INTO relevance_inputs(id,attempt_id,source_id,transcript_version_id,policy_version,ordinal) VALUES(?,?,?,?,?,?)",
                               [UUID().uuidString,id,hit.document.sourceID,hit.document.transcriptVersionID,String(hit.document.policyVersion),String(ordinal)])
            }
        }
        try checkpoint(.relevanceReserved)
        let response: RelevanceModelResponse
        do {
            try Task.checkCancellation()
            // Synchronous recheck immediately before entering the direct-send contract.
            try validateRelevanceSnapshot(snapshot, currentQueryID: snapshot.queryID)
            response = try await port.select(RelevanceModelRequest(attemptID: id, snapshot: snapshot, configuration: config))
        } catch ModelPortFailure.rejected(_, let input, let output) {
            var usage: [String: Int] = [:]
            if let input, input >= 0 { usage["input_tokens"] = input }
            if let output, output >= 0 { usage["output_tokens"] = output }
            try db.execute("UPDATE relevance_attempts SET state='rejected',usage_json=?,error='模型响应拒绝或格式不符；不自动重发' WHERE id=? AND state='reserved'", [usage.isEmpty ? nil : try Self.relevanceJSON(usage),id])
            throw VoiceOSError("相关性响应未接纳，已保留调用及已知用量")
        } catch {
            try db.execute("UPDATE relevance_attempts SET state='unknown',error='传输未登记结果；费用未知，不自动重发' WHERE id=? AND state='reserved'", [id])
            throw VoiceOSError("相关性调用结果未知，已保留记录，不会自动重发")
        }
        guard (response.inputTokens ?? 0) >= 0, (response.outputTokens ?? 0) >= 0 else {
            try db.execute("UPDATE relevance_attempts SET state='rejected',error='无效用量' WHERE id=?", [id])
            throw VoiceOSError("相关性响应用量无效")
        }
        var usage: [String: Int] = [:]
        if let value = response.inputTokens { usage["input_tokens"] = value }
        if let value = response.outputTokens { usage["output_tokens"] = value }
        if !usage.isEmpty { try db.execute("UPDATE relevance_attempts SET usage_json=? WHERE id=?", [try Self.relevanceJSON(usage),id]) }
        let hits: [RetrievalHit]
        do {
            guard response.status == .completed, let selection = response.selection else { throw VoiceOSError("响应未完成或被拒绝") }
            hits = try acceptRelevanceSelection(selection, for: snapshot, currentQueryID: snapshot.queryID)
            try db.transaction {
                guard try db.query("SELECT state,validity FROM relevance_attempts WHERE id=?", [id]).first == ["state":"reserved", "validity":"current"] else { throw VoiceOSError("相关性调用已失效") }
                let result = try Self.relevanceJSON(selection.candidateIDs)
                try db.execute("UPDATE relevance_attempts SET state='completed',selection_json=?,result_digest=? WHERE id=?",
                               [result,Self.relevanceHash(Data(result.utf8)),id])
                try checkpoint(.relevanceUncommitted)
            }
        } catch {
            try db.execute("UPDATE relevance_attempts SET state='rejected',validity='frozen',error='响应身份、查询、出处、授权或状态不符' WHERE id=? AND state='reserved'", [id])
            throw VoiceOSError("相关性结果未接纳，已保留调用及用量记录")
        }
        try checkpoint(.relevanceCommitted)
        return hits
    }

    public func relevanceAttempts() throws -> [RelevanceAttemptRecord] {
        try db.query("SELECT * FROM relevance_attempts ORDER BY created_at,id").map { row in
            let snapshot = try JSONDecoder().decode(RelevanceSnapshot.self, from: Data(row["snapshot_json"]!.utf8))
            return RelevanceAttemptRecord(id: row["id"]!, queryID: snapshot.queryID, state: row["state"]!, validity: row["validity"]!,
                                          model: row["model"]!, usage: try row["usage_json"].map { try JSONDecoder().decode([String:Int].self, from: Data($0.utf8)) }, billingState: "unknown")
        }
    }
    public func relevanceResult(attemptID: String, currentQueryID: UUID) throws -> [RetrievalHit] {
        guard let row = try db.query("SELECT * FROM relevance_attempts WHERE id=? AND state='completed' AND validity='current'", [attemptID]).first,
              let result = row["selection_json"], row["result_digest"] == Self.relevanceHash(Data(result.utf8)) else { throw VoiceOSError("相关性结果未知、已失效或不存在") }
        let snapshot = try JSONDecoder().decode(RelevanceSnapshot.self, from: Data(row["snapshot_json"]!.utf8))
        let ids = try JSONDecoder().decode([String].self, from: Data(result.utf8))
        return try acceptRelevanceSelection(RelevanceSelection(snapshotID: snapshot.id, queryID: snapshot.queryID, candidateIDs: ids), for: snapshot, currentQueryID: currentQueryID)
    }

    static func relevanceJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func relevanceHash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func relevanceFingerprint(_ digest: String, _ config: ModelConfiguration) throws -> String {
        relevanceHash(Data(try relevanceJSON(["relevance-attempt-v1",digest,config.provider,config.model,config.promptVersion,config.schemaVersion,config.destination.rawValue]).utf8))
    }

    /// Validate historical snapshots against immutable versions and the recorded policy chain.
    /// Frozen history remains valid history; it is never reactivated by restore.
    static func validateStoredRelevance(_ db: Database) throws {
        for row in try db.query("SELECT * FROM relevance_attempts") {
            guard let json = row["snapshot_json"], json.utf8.count <= 65536 else { throw VoiceOSError("相关性历史快照超限") }
            let s = try JSONDecoder().decode(RelevanceSnapshot.self, from: Data(json.utf8))
            guard UUID(uuidString: s.id) != nil, !s.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  s.query.unicodeScalars.count <= 512, (1...8).contains(s.candidates.count),
                  Set(s.candidates.map(\.id)).count == s.candidates.count, (1...4000).contains(s.scalarBudget),
                  s.query.unicodeScalars.count + s.candidates.reduce(0, { $0 + $1.document.text.unicodeScalars.count }) <= s.scalarBudget,
                  s.destination.rawValue == row["destination"], (s.destination == .local || (s.cloudQueryAllowed && s.candidates.allSatisfy({ !$0.document.localOnly }))),
                  try relevanceDigest(query:s.query,queryID:s.queryID,candidates:s.candidates,destination:s.destination,cloudQueryAllowed:s.cloudQueryAllowed,scalarBudget:s.scalarBudget) == s.contentDigest,
                  s.contentDigest == row["snapshot_digest"] else { throw VoiceOSError("相关性历史身份或预算不一致") }
            let config = ModelConfiguration(provider:row["provider"]!,model:row["model"]!,promptVersion:row["prompt_version"]!,schemaVersion:row["schema_version"]!,destination:s.destination)
            guard !config.provider.isEmpty, !config.model.isEmpty, !config.promptVersion.isEmpty, !config.schemaVersion.isEmpty,
                  row["fingerprint"] == (try relevanceFingerprint(s.contentDigest,config)), row["command_id"] == "relevance:" + row["fingerprint"]! else { throw VoiceOSError("相关性历史调用配置不一致") }
            let inputs = try db.query("SELECT * FROM relevance_inputs WHERE attempt_id=? ORDER BY ordinal", [row["id"]])
            guard inputs.count == s.candidates.count else { throw VoiceOSError("相关性历史缺少完整输入") }
            for (ordinal, hit) in s.candidates.enumerated() {
                let d = hit.document, input = inputs[ordinal]
                guard hit.score.isFinite, (0...1).contains(hit.score), ["exact","local_semantic"].contains(hit.method),
                      d.id == d.sourceID+":"+d.transcriptVersionID+":"+String(d.textStart),
                      input["ordinal"] == String(ordinal), input["source_id"] == d.sourceID,
                      input["transcript_version_id"] == d.transcriptVersionID, input["policy_version"] == String(d.policyVersion),
                      let version = try db.query("SELECT v.*,t.current_version_id,t.input_version_id,t.source_id,s.origin,s.name,s.created_at AS source_created,s.local_only,s.policy_version FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?", [d.transcriptVersionID]).first,
                      version["source_id"] == d.sourceID, version["input_version_id"] == d.sourceVersionID,
                      version["origin"] == d.origin, version["name"] == d.name, version["source_created"] == d.createdAt,
                      d.policyVersion > 0, d.policyVersion <= Int(version["policy_version"]!)! else { throw VoiceOSError("相关性历史引用身份不一致") }
                let scalars = Array(version["text"]!.unicodeScalars)
                let spans = try JSONDecoder().decode([TranscriptSpan].self, from: Data(version["spans_json"]!.utf8))
                guard d.textStart >= 0, d.textEnd > d.textStart, d.textEnd - d.textStart == d.text.unicodeScalars.count, !d.spanID.isEmpty,
                      isPrunedHistoricalTranscript(version, historical: row["validity"] == "frozen") ||
                        (d.textEnd <= scalars.count && spans.contains(where: { $0.id == d.spanID && $0.textStart <= d.textStart && $0.textEnd >= d.textEnd }) &&
                         String(String.UnicodeScalarView(scalars[d.textStart..<d.textEnd])) == d.text) else { throw VoiceOSError("相关性历史摘录不一致") }
                let historicalLocal = d.policyVersion == Int(version["policy_version"]!)! ? version["local_only"] : try db.query("SELECT from_local_only FROM source_policy_revisions WHERE source_id=? AND from_version=?", [d.sourceID,String(d.policyVersion)]).first?["from_local_only"]
                guard historicalLocal == (d.localOnly ? "1":"0") else { throw VoiceOSError("相关性历史权限不一致") }
            }
            if row["state"] == "completed" {
                guard let text = row["selection_json"], row["result_digest"] == relevanceHash(Data(text.utf8)) else { throw VoiceOSError("相关性历史结果摘要不一致") }
                let ids = try JSONDecoder().decode([String].self, from: Data(text.utf8))
                guard ids.count <= 3, Set(ids).count == ids.count, Set(ids).isSubset(of: Set(s.candidates.map(\.id))) else { throw VoiceOSError("相关性历史结果引用不一致") }
            } else if row["selection_json"] != nil || row["result_digest"] != nil { throw VoiceOSError("未完成的相关性历史不能有已接纳结果") }
            if let usage = row["usage_json"] {
                let values = try JSONDecoder().decode([String:Int].self, from: Data(usage.utf8))
                guard Set(values.keys).isSubset(of: ["input_tokens","output_tokens"]), values.values.allSatisfy({ $0 >= 0 }) else { throw VoiceOSError("相关性历史用量不一致") }
            }
        }
        guard try db.query("PRAGMA foreign_key_check").isEmpty else { throw VoiceOSError("相关性历史引用缺失") }
    }
}
