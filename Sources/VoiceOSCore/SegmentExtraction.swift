import Foundation

public struct SegmentExtractionRequest: Codable, Sendable {
    public let attemptID: String
    public let batchID: String
    public let scopeDigest: String
    public let sourceID: String
    public let sourceVersionID: String
    public let transcriptVersionID: String
    public let policyVersion: Int
    public let origin: String
    public let speaker: String
    public let localOnly: Bool
    public let segment: TranscriptSegment
    public let configuration: ProcessingModelIdentity
}
public struct SegmentExtractionResponse: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case completed, incomplete, refused }
    public let status: Status
    public let proposals: [SegmentEvidenceProposal]
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(status: Status = .completed, proposals: [SegmentEvidenceProposal], inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.status = status; self.proposals = proposals; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}
/// Start exactly one text-only request directly. No tools, uploads or implicit retries.
public protocol SegmentExtractionPort: Sendable {
    var configuration: ModelConfiguration { get }
    func extract(_ request: SegmentExtractionRequest) async throws -> SegmentExtractionResponse
}
public enum SegmentExtractionState: String, Codable, Sendable { case reserved, completed, unknown, rejected }
public struct SegmentExtractionAttempt: Identifiable, Sendable {
    public let id: String
    public let batchID: String
    public let request: SegmentExtractionRequest
    public let producerSequence: Int64
    public let state: SegmentExtractionState
    public let validity: String
    public let response: SegmentExtractionResponse?
    public let usage: [String:Int]?
    public let error: String?
}
extension VoiceOSStore {
    static func segmentRequest(id: String, batchID: String, scope: SegmentedExpressionProcessingScope, segment: TranscriptSegment) -> SegmentExtractionRequest {
        let source = scope.plan.source
        return .init(attemptID:id,batchID:batchID,scopeDigest:scope.contentDigest,sourceID:source.sourceID,
            sourceVersionID:source.sourceVersionID,transcriptVersionID:source.transcriptVersionID,policyVersion:scope.plan.policyVersion,
            origin:source.origin,speaker:source.speaker,localOnly:source.localOnly,segment:segment,configuration:scope.extraction)
    }
    static func segmentValueDigest<T: Encodable>(_ value: T) throws -> String { relevanceHash(Data(try relevanceJSON(value).utf8)) }
    static func segmentUsage(input: Int?, output: Int?) -> [String:Int] {
        var usage: [String:Int] = [:]
        if let input, input >= 0 { usage["input_tokens"] = input }
        if let output, output >= 0 { usage["output_tokens"] = output }
        return usage
    }
    static func segmentAttempt(_ row: [String:String]) throws -> SegmentExtractionAttempt {
        guard let id = row["id"], let batch = row["batch_id"], let json = row["input_json"],
              let state = SegmentExtractionState(rawValue:row["state"] ?? ""),
              let sequence = row["producer_sequence"].flatMap(Int64.init), let validity = row["validity"] else { throw VoiceOSError("片段尝试记录格式无效") }
        return .init(id:id,batchID:batch,request:try JSONDecoder().decode(SegmentExtractionRequest.self,from:Data(json.utf8)),
            producerSequence:sequence,state:state,validity:validity,
            response:try row["result_json"].map { try JSONDecoder().decode(SegmentExtractionResponse.self,from:Data($0.utf8)) },
            usage:try row["usage_json"].map { try JSONDecoder().decode([String:Int].self,from:Data($0.utf8)) },error:row["error"])
    }
    public func segmentExtractionAttempts(batchID: String) throws -> [SegmentExtractionAttempt] {
        try Self.validateStoredSegmentExtraction(db)
        return try db.query("SELECT * FROM segmented_extraction_attempts WHERE batch_id=? ORDER BY producer_sequence",[batchID]).map(Self.segmentAttempt)
    }
    func segmentTerminalParent(_ id: String, state: SegmentedProcessingBatchState, error: String) throws {
        try db.execute("UPDATE segmented_processing_batches SET state=?,error=?,updated_at=? WHERE id=? AND state='queued'",
            [state.rawValue,error,Self.processingNow(),id])
        if state == .blocked { try db.execute("UPDATE segmented_extraction_attempts SET validity='frozen' WHERE batch_id=?",[id]) }
    }
    /// One serial segment step per library. Success remains staged; it never creates
    /// cognitive claims, questions, actions or outbox writes. Nil means no dispatch.
    public func runNextSegmentExtraction(batchID: String, using port: any SegmentExtractionPort) async throws -> SegmentExtractionAttempt? {
        guard ready else { throw VoiceOSError("资料库尚未准备好") }
        guard !segmentExtractionActive else { return nil }
        segmentExtractionActive = true; defer { segmentExtractionActive = false }
        try Task.checkCancellation()
        let initial = try segmentedProcessingBatch(id:batchID)
        let batch = try checkSegmentedProcessingBatch(id:batchID,extraction:port.configuration,aggregation:Self.processingIdentity(initial.scope.aggregation))
        guard batch.state == .queued else { return nil }
        let attempts = try segmentExtractionAttempts(batchID:batchID)
        var selected: TranscriptSegment?
        for segment in batch.scope.plan.segments {
            if let prior = attempts.first(where: { $0.request.segment.id == segment.id }) {
                guard prior.state == .completed, prior.validity == "current" else {
                    if prior.state == .reserved {
                        try failSegmentExtraction(id:prior.id,batchID:batchID,state:.unknown,reason:"未登记片段结果，不自动重发",usage:[:])
                        return try segmentExtractionAttempts(batchID:batchID).first(where: { $0.id == prior.id })
                    }
                    try segmentTerminalParent(batchID,state:prior.state == .rejected ? .rejected : .unknown,error:"片段结果不可续发，未自动重试")
                    return prior
                }
            } else { selected = segment; break }
        }
        guard let segment = selected else { return nil }
        let id = UUID().uuidString, request = Self.segmentRequest(id:id,batchID:batchID,scope:batch.scope,segment:segment), now = Self.processingNow()
        try db.transaction {
            try db.execute("INSERT INTO segmented_extraction_attempts(id,batch_id,segment_id,producer_sequence,input_json,input_digest,state,validity,created_at,updated_at) VALUES(?,?,?,?,?,?,'reserved','current',?,?)",
                [id,batchID,segment.id,try db.nextModelProducerSequence(),try Self.relevanceJSON(request),try Self.segmentValueDigest(request),now,now])
        }
        try checkpoint(.segmentExtractionReserved)
        var receivedUsage: [String:Int] = [:]
        do {
            let response = try await port.extract(request)
            receivedUsage = Self.segmentUsage(input:response.inputTokens,output:response.outputTokens)
            var state: SegmentExtractionState = .completed, validity = "current", reason: String?
            do {
                guard response.status == .completed, (response.inputTokens ?? 0) >= 0, (response.outputTokens ?? 0) >= 0 else { throw VoiceOSError("片段响应未完成、被拒绝或用量无效") }
                _ = try Self.validatedSegmentEvidence(scope:batch.scope,segment:segment,proposals:response.proposals)
            } catch { state = .rejected; reason = error.localizedDescription }
            let current = try segmentedProcessingBatch(id:batchID)
            if current.state != .queued { validity = "frozen" }
            else {
                do {
                    try Task.checkCancellation()
                    try validateSegmentedExpressionProcessingScope(batch.scope,extraction:port.configuration,aggregation:Self.processingIdentity(batch.scope.aggregation))
                } catch { validity = "frozen"; reason = error.localizedDescription }
            }
            let usage = Self.segmentUsage(input:response.inputTokens,output:response.outputTokens)
            try db.transaction {
                try db.execute("UPDATE segmented_extraction_attempts SET state=?,validity=?,result_json=?,result_digest=?,usage_json=?,error=?,updated_at=? WHERE id=? AND state='reserved'",
                    [state.rawValue,validity,try Self.relevanceJSON(response),try Self.segmentValueDigest(response),usage.isEmpty ? nil : try Self.relevanceJSON(usage),reason,Self.processingNow(),id])
                if validity == "frozen" { try segmentTerminalParent(batchID,state:.blocked,error:reason ?? "片段返回时父批次不再有效") }
                else if state == .rejected { try segmentTerminalParent(batchID,state:.rejected,error:reason ?? "片段响应拒绝") }
                try checkpoint(.segmentExtractionUncommitted)
            }
            try checkpoint(.segmentExtractionCommitted)
        } catch ModelPortFailure.rejected(let reason,let input,let output) {
            try failSegmentExtraction(id:id,batchID:batchID,state:.rejected,reason:reason,usage:Self.segmentUsage(input:input,output:output))
        } catch {
            try failSegmentExtraction(id:id,batchID:batchID,state:.unknown,reason:"片段结果未登记；费用未知，不自动重发",usage:receivedUsage)
        }
        guard let row = try db.query("SELECT * FROM segmented_extraction_attempts WHERE id=?",[id]).first else { throw VoiceOSError("片段尝试丢失") }
        return try Self.segmentAttempt(row)
    }
    func failSegmentExtraction(id: String, batchID: String, state: SegmentExtractionState, reason: String, usage: [String:Int]) throws {
        // A post-commit checkpoint failure must not rewrite a completed receipt.
        guard try db.query("SELECT state FROM segmented_extraction_attempts WHERE id=?",[id]).first?["state"] == "reserved" else { return }
        let batch = try segmentedProcessingBatch(id:batchID)
        try db.transaction {
            try db.execute("UPDATE segmented_extraction_attempts SET state=?,validity=?,usage_json=?,error=?,updated_at=? WHERE id=? AND state='reserved'",
                [state.rawValue,batch.state == .queued ? "current":"frozen",usage.isEmpty ? nil : try Self.relevanceJSON(usage),reason,Self.processingNow(),id])
            try segmentTerminalParent(batchID,state:state == .rejected ? .rejected:.unknown,error:reason)
        }
    }
    /// Consume only complete, current durable segment receipts. Arbitrary local
    /// proposal inputs cannot be substituted for successful model attempts here.
    public func preparePersistedSegmentedEvidenceLedger(batchID: String, extraction: ModelConfiguration,
        aggregation: ModelConfiguration) throws -> SegmentedEvidenceLedger {
        let batch = try segmentedProcessingBatch(id:batchID), attempts = try segmentExtractionAttempts(batchID:batchID)
        guard attempts.count == batch.scope.plan.segments.count,
              attempts.allSatisfy({ $0.state == .completed && $0.validity == "current" && $0.response != nil }) else { throw VoiceOSError("全部片段尚未完成，不能准备整篇模型证据") }
        return try prepareSegmentedEvidenceLedger(batchID:batchID,inputs:attempts.map { .init(segmentID:$0.request.segment.id,proposals:$0.response!.proposals) },extraction:extraction,aggregation:aggregation)
    }
    func recoverSegmentExtractionAttempts() throws {
        try Self.validateStoredSegmentExtraction(db)
        try db.transaction {
            try db.execute("UPDATE segmented_extraction_attempts SET state='unknown',error='进程退出前片段结果未登记；不自动重发',updated_at=? WHERE state='reserved'",[Self.processingNow()])
            for row in try db.query("SELECT DISTINCT batch_id,state FROM segmented_extraction_attempts WHERE state IN ('unknown','rejected')") {
                try segmentTerminalParent(row["batch_id"]!,state:row["state"] == "unknown" ? .unknown:.rejected,error:"片段结果未完成，不自动重发")
            }
        }
    }
    static func validateStoredSegmentExtraction(_ db: Database) throws {
        guard try db.query("SELECT producer_sequence FROM (SELECT producer_sequence FROM model_attempts UNION ALL SELECT producer_sequence FROM segmented_extraction_attempts) GROUP BY producer_sequence HAVING COUNT(*)>1").isEmpty else { throw VoiceOSError("跨端口成果生产者顺序重复") }
        for row in try db.query("SELECT * FROM segmented_extraction_attempts") {
            let attempt = try segmentAttempt(row)
            guard let parent = try db.query("SELECT * FROM segmented_processing_batches WHERE id=?",[attempt.batchID]).first else { throw VoiceOSError("片段缺少父批次") }
            try validateStoredSegmentedBatch(db,row:parent)
            let scope = try segmentedBatchRecord(parent).scope
            guard UUID(uuidString:attempt.id) != nil, attempt.producerSequence > 0, ["current","frozen"].contains(attempt.validity),
                  let segment = scope.plan.segments.first(where: { $0.id == row["segment_id"] }),
                  try relevanceJSON(attempt.request) == relevanceJSON(segmentRequest(id:attempt.id,batchID:attempt.batchID,scope:scope,segment:segment)),
                  row["input_digest"] == (try segmentValueDigest(attempt.request)),
                  attempt.usage?.allSatisfy({ ["input_tokens","output_tokens"].contains($0.key) && $0.value >= 0 }) ?? true else { throw VoiceOSError("片段请求、权限或用量绑定无效") }
            if let response = attempt.response {
                guard row["result_digest"] == (try segmentValueDigest(response)), [.completed,.rejected].contains(attempt.state),
                      (attempt.usage ?? [:]) == segmentUsage(input:response.inputTokens,output:response.outputTokens) else { throw VoiceOSError("片段响应回执或用量不一致") }
                if attempt.state == .completed {
                    guard response.status == .completed, (response.inputTokens ?? 0) >= 0, (response.outputTokens ?? 0) >= 0 else { throw VoiceOSError("片段完成状态与响应不符") }
                    _ = try validatedSegmentEvidence(scope:scope,segment:segment,proposals:response.proposals)
                }
            } else {
                guard row["result_digest"] == nil, attempt.state != .completed else { throw VoiceOSError("片段缺少完整结果") }
            }
        }
    }
}
