import Foundation

public struct SegmentAggregationInputReceipt: Codable, Sendable {
    public let attemptID: String
    public let segmentID: String
    public let resultDigest: String
    public let producerSequence: Int64
}
public struct SegmentAggregationRequest: Codable, Sendable {
    public let attemptID: String
    public let batchID: String
    public let scopeDigest: String
    public let ledger: SegmentedEvidenceLedger
    public let receipts: [SegmentAggregationInputReceipt]
    public let configuration: ProcessingModelIdentity
}
public struct SegmentAggregationResponse: Codable, Sendable {
    public let status: SegmentExtractionResponse.Status
    public let review: SegmentAggregationReview
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(status: SegmentExtractionResponse.Status = .completed, review: SegmentAggregationReview, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.status = status; self.review = review; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}
/// Exactly one text-only aggregation request. No implicit retry or action tools.
public protocol SegmentAggregationPort: Sendable {
    var configuration: ModelConfiguration { get }
    func aggregate(_ request: SegmentAggregationRequest) async throws -> SegmentAggregationResponse
}
public struct SegmentAggregationAttempt: Identifiable, Sendable {
    public let id: String
    public let request: SegmentAggregationRequest
    public let state: SegmentExtractionState
    public let validity: String
    public let response: SegmentAggregationResponse?
    public let usage: [String:Int]?
}
extension VoiceOSStore {
    static func aggregationRequest(_ db: Database, id: String, batch: SegmentedProcessingBatch) throws -> SegmentAggregationRequest {
        let rows = try db.query("SELECT * FROM segmented_extraction_attempts WHERE batch_id=? ORDER BY producer_sequence",[batch.id])
        let attempts = try rows.map(segmentAttempt)
        guard attempts.count == batch.scope.plan.segments.count, attempts.allSatisfy({ $0.state == .completed && $0.response != nil }) else {
            throw VoiceOSError("聚合缺少全部片段的完整回执")
        }
        let inputs = attempts.map { SegmentEvidenceInput(segmentID:$0.request.segment.id,proposals:$0.response!.proposals) }
        let ledger = try segmentedEvidenceLedger(batchID:batch.id,scope:batch.scope,inputs:inputs)
        guard !ledger.requiresBoundaryResolution else { throw VoiceOSError("跨段未完句尚未解决，未预留聚合调用") }
        return .init(attemptID:id,batchID:batch.id,scopeDigest:batch.scope.contentDigest,ledger:ledger,
            receipts:try rows.map { .init(attemptID:$0["id"]!,segmentID:$0["segment_id"]!,resultDigest:$0["result_digest"]!,producerSequence:try segmentAttempt($0).producerSequence) },
            configuration:batch.scope.aggregation)
    }
    static func aggregationAttempt(_ row: [String:String]) throws -> SegmentAggregationAttempt {
        guard let id=row["id"], let input=row["input_json"], let state=SegmentExtractionState(rawValue:row["state"] ?? ""), let validity=row["validity"] else { throw VoiceOSError("聚合记录格式无效") }
        return .init(id:id,request:try JSONDecoder().decode(SegmentAggregationRequest.self,from:Data(input.utf8)),state:state,validity:validity,
            response:try row["result_json"].map { try JSONDecoder().decode(SegmentAggregationResponse.self,from:Data($0.utf8)) },
            usage:try row["usage_json"].map { try JSONDecoder().decode([String:Int].self,from:Data($0.utf8)) })
    }
    public func segmentAggregationAttempt(batchID: String) throws -> SegmentAggregationAttempt? {
        try Self.validateStoredSegmentExtraction(db)
        try Self.validateStoredSegmentAggregation(db)
        return try db.query("SELECT * FROM segmented_aggregation_attempts WHERE batch_id=?",[batchID]).first.map(Self.aggregationAttempt)
    }
    /// Persist a whole-source judgment, without committing cognitive entities yet.
    public func runSegmentAggregation(batchID: String, using port: any SegmentAggregationPort) async throws -> SegmentAggregationAttempt? {
        guard ready else { throw VoiceOSError("资料库尚未准备好") }
        guard !segmentAggregationActive else { return nil }
        segmentAggregationActive=true; defer { segmentAggregationActive=false }
        try Task.checkCancellation()
        let initial = try segmentedProcessingBatch(id:batchID)
        let batch = try checkSegmentedProcessingBatch(id:batchID,extraction:Self.processingIdentity(initial.scope.extraction),aggregation:port.configuration)
        guard batch.state == .queued else { return try segmentAggregationAttempt(batchID:batchID) }
        if let prior = try segmentAggregationAttempt(batchID:batchID) {
            if prior.state == .reserved { try failSegmentAggregation(id:prior.id,batchID:batchID,state:.unknown,usage:[:],reason:"未登记聚合结果，不自动重发") }
            return try segmentAggregationAttempt(batchID:batchID)
        }
        // Includes validity/current-scope checks. Budget failure is an explicit parent block;
        // incomplete segment receipts remain waiting and must not reserve aggregation.
        let attempts = try segmentExtractionAttempts(batchID:batchID)
        guard attempts.count == batch.scope.plan.segments.count, attempts.allSatisfy({ $0.state == .completed && $0.validity == "current" }) else { throw VoiceOSError("片段尚未全部完成，未预留聚合调用") }
        let id=UUID().uuidString
        let request: SegmentAggregationRequest
        do { request = try Self.aggregationRequest(db,id:id,batch:batch) }
        catch { try db.transaction { try segmentTerminalParent(batchID,state:.blocked,error:error.localizedDescription) }; throw error }
        let now=Self.processingNow()
        try db.transaction {
            try db.execute("INSERT INTO segmented_aggregation_attempts(id,batch_id,producer_sequence,input_json,input_digest,state,validity,created_at,updated_at) VALUES(?,?,?,?,?,'reserved','current',?,?)",
                [id,batchID,try db.nextModelProducerSequence(),try Self.relevanceJSON(request),try Self.segmentValueDigest(request),now,now])
        }
        try checkpoint(.segmentAggregationReserved)
        var knownUsage: [String:Int]=[:]
        do {
            let response = try await port.aggregate(request)
            knownUsage=Self.segmentUsage(input:response.inputTokens,output:response.outputTokens)
            var state: SegmentExtractionState = .completed, validity="current", reason: String?
            do {
                guard response.status == .completed, (response.inputTokens ?? 0)>=0, (response.outputTokens ?? 0)>=0 else { throw VoiceOSError("聚合响应不完整、拒绝或用量无效") }
                _ = try Self.validateSegmentAggregationReview(response.review,ledger:request.ledger)
            } catch { state = .rejected; reason=error.localizedDescription }
            let current=try segmentedProcessingBatch(id:batchID)
            if current.state != .queued { validity="frozen" }
            else {
                do {
                    try Task.checkCancellation()
                    try validateSegmentedExpressionProcessingScope(batch.scope,extraction:Self.processingIdentity(batch.scope.extraction),aggregation:port.configuration)
                } catch { validity="frozen"; reason=error.localizedDescription }
            }
            try db.transaction {
                try db.execute("UPDATE segmented_aggregation_attempts SET state=?,validity=?,result_json=?,result_digest=?,usage_json=?,error=?,updated_at=? WHERE id=? AND state='reserved'",
                    [state.rawValue,validity,try Self.relevanceJSON(response),try Self.segmentValueDigest(response),knownUsage.isEmpty ? nil:try Self.relevanceJSON(knownUsage),reason,Self.processingNow(),id])
                if validity == "frozen" { try segmentTerminalParent(batchID,state:.blocked,error:reason ?? "聚合返回时父批次不再有效") }
                else if state == .rejected { try segmentTerminalParent(batchID,state:.rejected,error:reason ?? "聚合拒绝") }
                try checkpoint(.segmentAggregationUncommitted)
            }
            try checkpoint(.segmentAggregationCommitted)
        } catch ModelPortFailure.rejected(let reason,let input,let output) {
            try failSegmentAggregation(id:id,batchID:batchID,state:.rejected,usage:Self.segmentUsage(input:input,output:output),reason:reason)
        } catch {
            try failSegmentAggregation(id:id,batchID:batchID,state:.unknown,usage:knownUsage,reason:"聚合结果未登记，不自动重发；未观测用量仍未知")
        }
        return try segmentAggregationAttempt(batchID:batchID)
    }
    func failSegmentAggregation(id: String,batchID: String,state: SegmentExtractionState,usage: [String:Int],reason: String) throws {
        guard try db.query("SELECT state FROM segmented_aggregation_attempts WHERE id=?",[id]).first?["state"] == "reserved" else { return }
        let batch=try segmentedProcessingBatch(id:batchID)
        try db.transaction {
            try db.execute("UPDATE segmented_aggregation_attempts SET state=?,validity=?,usage_json=?,error=?,updated_at=? WHERE id=? AND state='reserved'",
                [state.rawValue,batch.state == .queued ? "current":"frozen",usage.isEmpty ? nil:try Self.relevanceJSON(usage),reason,Self.processingNow(),id])
            try segmentTerminalParent(batchID,state:state == .rejected ? .rejected:.unknown,error:reason)
        }
    }
    func recoverSegmentAggregationAttempts() throws {
        try Self.validateStoredSegmentAggregation(db)
        try db.transaction {
            try db.execute("UPDATE segmented_aggregation_attempts SET state='unknown',error='进程退出前聚合结果未登记；不自动重发',updated_at=? WHERE state='reserved'",[Self.processingNow()])
            for row in try db.query("SELECT batch_id,state FROM segmented_aggregation_attempts WHERE state IN ('unknown','rejected')") {
                try segmentTerminalParent(row["batch_id"]!,state:row["state"] == "unknown" ? .unknown:.rejected,error:"聚合未完成，不自动重发")
            }
        }
    }
    static func validateStoredSegmentAggregation(_ db: Database) throws {
        for row in try db.query("SELECT * FROM segmented_aggregation_attempts") {
            let a=try aggregationAttempt(row)
            guard let parent=try db.query("SELECT * FROM segmented_processing_batches WHERE id=?",[row["batch_id"]]).first else { throw VoiceOSError("聚合父批次缺失") }
            try validateStoredSegmentedBatch(db,row:parent)
            let canonical=try aggregationRequest(db,id:a.id,batch:segmentedBatchRecord(parent))
            guard UUID(uuidString:a.id) != nil, let sequence=row["producer_sequence"].flatMap(Int64.init),sequence>0,
                  a.request.batchID == row["batch_id"], ["current","frozen"].contains(a.validity),
                  try relevanceJSON(a.request) == relevanceJSON(canonical), row["input_digest"] == (try segmentValueDigest(a.request)),
                  a.request.receipts.allSatisfy({ $0.producerSequence < sequence }),
                  a.usage?.allSatisfy({ ["input_tokens","output_tokens"].contains($0.key) && $0.value>=0 }) ?? true else { throw VoiceOSError("聚合范围、片段回执或生产者顺序无效") }
            if let response=a.response {
                guard [.completed,.rejected].contains(a.state),row["result_digest"] == (try segmentValueDigest(response)),
                      (a.usage ?? [:]) == segmentUsage(input:response.inputTokens,output:response.outputTokens) else { throw VoiceOSError("聚合响应摘要或用量不一致") }
                if a.state == .completed {
                    guard response.status == .completed,(response.inputTokens ?? 0)>=0,(response.outputTokens ?? 0)>=0 else { throw VoiceOSError("聚合完成状态无效") }
                    _ = try validateSegmentAggregationReview(response.review,ledger:a.request.ledger)
                }
            } else { guard a.state != .completed,row["result_digest"] == nil else { throw VoiceOSError("聚合缺少完整结果") } }
        }
    }
}
