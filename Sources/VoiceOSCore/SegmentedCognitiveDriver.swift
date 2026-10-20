import Foundation

public struct SegmentedCognitiveResult: Sendable {
    public let state: SegmentedProcessingBatchState
    public let claimIDs: [String]?
}
extension VoiceOSStore {
    /// Continue only this explicitly queued batch. No source scanning or new grant.
    public func processSegmentedCognition(batchID: String, extraction: any SegmentExtractionPort,
                                         aggregation: any SegmentAggregationPort) async throws -> SegmentedCognitiveResult {
        if let ids=try segmentedCognitiveClaimIDs(batchID:batchID) {
            return .init(state:try segmentedProcessingBatch(id:batchID).state,claimIDs:ids)
        }
        let initial=try checkSegmentedProcessingBatch(id:batchID,extraction:extraction.configuration,aggregation:aggregation.configuration)
        guard initial.state == .queued else { return .init(state:initial.state,claimIDs:nil) }
        for _ in initial.scope.plan.segments {
            try Task.checkCancellation()
            let before=try segmentExtractionAttempts(batchID:batchID)
            if before.count == initial.scope.plan.segments.count && before.allSatisfy({ $0.state == .completed && $0.validity == "current" }) { break }
            guard let attempt=try await runNextSegmentExtraction(batchID:batchID,using:extraction) else {
                // Busy is not success, and cannot authorize aggregation.
                return .init(state:try segmentedProcessingBatch(id:batchID).state,claimIDs:nil)
            }
            guard attempt.state == .completed,attempt.validity == "current" else {
                return .init(state:try segmentedProcessingBatch(id:batchID).state,claimIDs:nil)
            }
        }
        try Task.checkCancellation()
        guard let result=try await runSegmentAggregation(batchID:batchID,using:aggregation),result.state == .completed,result.validity == "current" else {
            return .init(state:try segmentedProcessingBatch(id:batchID).state,claimIDs:nil)
        }
        try Task.checkCancellation()
        let ids=try commitSegmentedCognition(batchID:batchID,extraction:extraction.configuration,aggregation:aggregation.configuration)
        return .init(state:try segmentedProcessingBatch(id:batchID).state,claimIDs:ids)
    }
}
