import Foundation

public struct EnglishFeedbackAttemptRecord: Identifiable, Sendable {
    public let id: String
    public let currentSourceID: String
    public let priorSourceIDs: [String]
    public let state: String
    public let result: EnglishPracticeResponse?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let error: String?
    public let createdAt: String
}
private struct StoredEnglishFeedback: Codable { let suggestions: [EnglishSuggestionProposal]; let comparisons: [EnglishComparisonProposal] }

extension VoiceOSStore {
    public func reserveEnglishFeedback(_ snapshot: EnglishPracticeSnapshot, configuration: ModelConfiguration, commandID: String = UUID().uuidString) throws -> String {
        guard configuration.destination == snapshot.destination, configuration.destination == .cloud else { throw VoiceOSError("英文反馈只能在明确云端目的地下预留") }
        try validateEnglishPractice(snapshot)
        let snapshotJSON = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        // The immutable content digest excludes the per-preview UUID, so repeating
        // the same prepared input remains idempotent across UI refreshes.
        let digest = snapshot.contentDigest
        if let existing = try db.query("SELECT id FROM english_feedback_attempts WHERE snapshot_digest=?", [digest]).first { return existing["id"]! }
        let contextID = try persistLocalContext(snapshot.context, commandID: "english-practice:" + digest, destination: .cloud)
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,execution_kind,created_at,producer_sequence) VALUES(?,?,?,?,?,?,'reserved','discussion_derivation',?,?)", [id, contextID, "english_feedback:" + configuration.provider, configuration.model, configuration.promptVersion, configuration.schemaVersion, Self.now(), try db.nextModelProducerSequence()])
            try db.execute("INSERT INTO english_feedback_attempts(id,current_source_id,prior_source_ids_json,snapshot_json,snapshot_digest,state,created_at) VALUES(?,?,?,?,?,'reserved',?)", [id, snapshot.currentSourceID, String(decoding: try JSONEncoder().encode(snapshot.priorSourceIDs), as: UTF8.self), snapshotJSON, digest, Self.now()])
        }
        return id
    }
    public func completeEnglishFeedback(attemptID: String, response: EnglishPracticeResponse) throws {
        guard let row = try db.query("SELECT * FROM english_feedback_attempts WHERE id=? AND state='reserved'", [attemptID]).first,
              let json = row["snapshot_json"] else { throw VoiceOSError("英文反馈预留记录缺失或摘要不符") }
        let snapshot = try JSONDecoder().decode(EnglishPracticeSnapshot.self, from: Data(json.utf8)); try validateEnglishPractice(snapshot)
        let result = StoredEnglishFeedback(suggestions: response.suggestions, comparisons: response.comparisons)
        try Self.validateEnglishProposals(suggestions: result.suggestions, comparisons: result.comparisons, snapshot: snapshot)
        let resultJSON = String(decoding: try JSONEncoder().encode(result), as: UTF8.self), digest = Self.relevanceHash(Data(resultJSON.utf8))
        let usage = String(decoding: try JSONEncoder().encode(["input_tokens": response.inputTokens, "output_tokens": response.outputTokens].compactMapValues { $0 }), as: UTF8.self)
        try db.transaction {
            try db.execute("UPDATE english_feedback_attempts SET result_json=?,result_digest=?,usage_json=?,state='completed',error=NULL WHERE id=? AND state='reserved'", [resultJSON, digest, usage, attemptID])
            try db.execute("UPDATE model_attempts SET state='completed',result_digest=?,usage_json=? WHERE id=? AND state='reserved'", [digest, usage, attemptID])
        }
    }
    public func markEnglishFeedbackUnknown(attemptID: String, reason: String = "英文反馈结果未知；不自动重发", inputTokens: Int? = nil, outputTokens: Int? = nil) throws {
        let usage = String(decoding: try JSONEncoder().encode(["input_tokens": inputTokens, "output_tokens": outputTokens].compactMapValues { $0 }), as: UTF8.self)
        try db.transaction {
            try db.execute("UPDATE english_feedback_attempts SET state='unknown',error=?,usage_json=? WHERE id=? AND state='reserved'", [reason, usage, attemptID])
            try db.execute("UPDATE model_attempts SET state='unknown',error=?,usage_json=? WHERE id=? AND state='reserved'", [reason, usage, attemptID])
        }
    }
    /// Executes exactly one reserved request. Any transport or validation failure
    /// becomes a terminal unknown attempt; callers must explicitly prepare a new
    /// snapshot before trying again.
    public func performEnglishFeedback(_ snapshot: EnglishPracticeSnapshot, using port: any EnglishPracticeModelPort) async throws -> EnglishFeedbackAttemptRecord {
        let attemptID = try reserveEnglishFeedback(snapshot, configuration: port.configuration)
        if let existing = try englishFeedbackAttempts().first(where: { $0.id == attemptID }), existing.state != "reserved" { return existing }
        do {
            let response = try await port.generate(EnglishPracticeRequest(attemptID: attemptID, snapshot: snapshot, configuration: port.configuration))
            try completeEnglishFeedback(attemptID: attemptID, response: response)
        } catch let failure as ModelPortFailure {
            switch failure {
            case .rejected(let reason, let input, let output):
                try markEnglishFeedbackUnknown(attemptID: attemptID, reason: reason, inputTokens: input, outputTokens: output)
            }
            throw failure
        } catch {
            try markEnglishFeedbackUnknown(attemptID: attemptID, reason: "英文反馈请求失败；不自动重发")
            throw error
        }
        guard let record = try englishFeedbackAttempts().first(where: { $0.id == attemptID }) else { throw VoiceOSError("英文反馈完成记录缺失") }
        return record
    }
    public func englishFeedbackAttempts() throws -> [EnglishFeedbackAttemptRecord] {
        try db.query("SELECT * FROM english_feedback_attempts ORDER BY created_at,id").map { row in
            let input = row["result_json"].flatMap { try? JSONDecoder().decode(StoredEnglishFeedback.self, from: Data($0.utf8)) }
            let usage = row["usage_json"].flatMap { try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) }
            return EnglishFeedbackAttemptRecord(id: row["id"]!, currentSourceID: row["current_source_id"]!, priorSourceIDs: (try? JSONDecoder().decode([String].self, from: Data(row["prior_source_ids_json"]!.utf8))) ?? [], state: row["state"]!, result: input.map { EnglishPracticeResponse(suggestions: $0.suggestions, comparisons: $0.comparisons, inputTokens: usage?["input_tokens"], outputTokens: usage?["output_tokens"]) }, inputTokens: usage?["input_tokens"], outputTokens: usage?["output_tokens"], error: row["error"], createdAt: row["created_at"]!)
        }
    }
}
