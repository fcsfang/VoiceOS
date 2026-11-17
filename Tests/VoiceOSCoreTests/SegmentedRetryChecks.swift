import Foundation
import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

// Pseudoports drive the segmented retry state machine without a model service.
// Production identities keep the evidence budget at the real 128k instead of
// the 4k fallback, so the fixture exercises retry rather than the budget guard.
private let extractionConfiguration = ModelConfiguration(provider: "fixture", model: "segmented-retry",
    promptVersion: "segment-extraction-v4-wait600-stream", schemaVersion: "segment-extraction-v4-wait600-stream", destination: .local)
private let aggregationConfiguration = ModelConfiguration(provider: "fixture", model: "segmented-retry",
    promptVersion: "segment-aggregation-v4-wait600-stream", schemaVersion: "segment-aggregation-v4-wait600-stream", destination: .local)

private actor RetrySegmentExtraction: SegmentExtractionPort {
    enum Behavior { case valid, invalidEvidence, transient }
    let configuration: ModelConfiguration
    var behavior: Behavior
    var calls = 0
    init(_ behavior: Behavior) { configuration = extractionConfiguration; self.behavior = behavior }
    func extract(_ request: SegmentExtractionRequest) async throws -> SegmentExtractionResponse {
        calls += 1
        switch behavior {
        case .transient:
            throw URLError(.timedOut)
        case .invalidEvidence:
            return .init(proposals: [.init(kind: .statement, statement: "被替换的引用", quote: "这不是本段原文",
                textStart: request.segment.textStart, textEnd: request.segment.textEnd,
                spanIDs: request.segment.references.map(\.spanID))], inputTokens: 12, outputTokens: 6)
        case .valid:
            return .init(proposals: [.init(kind: .statement, statement: request.segment.text, quote: request.segment.text,
                textStart: request.segment.textStart, textEnd: request.segment.textEnd,
                spanIDs: request.segment.references.map(\.spanID))], inputTokens: 12, outputTokens: 6)
        }
    }
}

private actor RetrySegmentAggregation: SegmentAggregationPort {
    let configuration: ModelConfiguration
    var calls = 0
    init() { configuration = aggregationConfiguration }
    func aggregate(_ request: SegmentAggregationRequest) async throws -> SegmentAggregationResponse {
        calls += 1
        let ledger = request.ledger
        return .init(review: .init(batchID: ledger.batchID, ledgerDigest: ledger.contentDigest,
                reviewedEvidenceIDs: ledger.evidence.map(\.id), actionDecisions: []),
            finalClaims: [.init(statement: "整篇表达提出了一项观点。", evidenceIDs: [ledger.evidence[0].id])],
            inputTokens: 20, outputTokens: 10)
    }
}

final class SegmentedRetryChecks: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-segmented-retry-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func queuedBatch() async throws -> (VoiceOSStore, SegmentedProcessingBatch) {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        let text = (1...9).map { "第\($0)段完整表达，验证长录音分段理解在本地校验失败后可以显式整批重试。" }.joined()
        let sourceID = try await store.recordUserExpression(text)
        let scope = try await store.prepareSegmentedExpressionProcessingScope(sourceID: sourceID,
            extraction: extractionConfiguration, aggregation: aggregationConfiguration, segmentScalarBudget: 40)
        let batch = try await store.enqueueSegmentedProcessingBatch(scope, commandID: "segmented-test:" + sourceID,
            extraction: extractionConfiguration, aggregation: aggregationConfiguration)
        return (store, batch)
    }

    func testInvalidSegmentOutputRejectsBatchWithReasonAndNoAutoResend() async throws {
        let (store, batch) = try await queuedBatch()
        let extraction = RetrySegmentExtraction(.invalidEvidence), aggregation = RetrySegmentAggregation()
        let result = try await store.processSegmentedCognition(batchID: batch.id, extraction: extraction, aggregation: aggregation)
        XCTAssertNil(result.claimIDs)
        let claimIDs = try await store.segmentedCognitiveClaimIDs(batchID: batch.id)
        XCTAssertNil(claimIDs)
        let rejected = try await store.segmentedProcessingBatch(id: batch.id)
        XCTAssertEqual(rejected.state, .rejected)
        XCTAssertTrue(rejected.state.allowsExplicitRetry)
        let reason = try XCTUnwrap(rejected.error)
        XCTAssertTrue(reason.contains("第 1 段"), reason)
        XCTAssertTrue(reason.contains("逐字引用"), reason)
        let batches = try await store.segmentedProcessingBatches()
        let listed = batches.first { $0.id == batch.id }
        XCTAssertEqual(listed?.state, .rejected)
        XCTAssertEqual(listed?.error, reason)
        let extractionCalls = await extraction.calls, aggregationCalls = await aggregation.calls
        XCTAssertEqual(extractionCalls, 1)
        XCTAssertEqual(aggregationCalls, 0)
        _ = try await store.processSegmentedCognition(batchID: batch.id, extraction: extraction, aggregation: aggregation)
        let resent = await extraction.calls
        XCTAssertEqual(resent, 1)
    }

    func testWholeBatchRetryUsesNewCommandAndKeepsOldBatch() async throws {
        let (store, batch) = try await queuedBatch()
        _ = try await store.processSegmentedCognition(batchID: batch.id,
            extraction: RetrySegmentExtraction(.invalidEvidence), aggregation: RetrySegmentAggregation())
        let rejectedState = try await store.segmentedProcessingBatch(id: batch.id).state
        XCTAssertEqual(rejectedState, .rejected)
        let fresh = try await store.retryRejectedSegmentedBatch(id: batch.id, extraction: extractionConfiguration, aggregation: aggregationConfiguration)
        XCTAssertNotEqual(fresh.id, batch.id)
        XCTAssertEqual(fresh.commandID, "segmented-retry:" + batch.id + ":1")
        XCTAssertNotEqual(fresh.commandID, batch.commandID)
        XCTAssertEqual(fresh.state, .queued)
        let extraction = RetrySegmentExtraction(.valid), aggregation = RetrySegmentAggregation()
        let result = try await store.processSegmentedCognition(batchID: fresh.id, extraction: extraction, aggregation: aggregation)
        let ids = try XCTUnwrap(result.claimIDs)
        XCTAssertFalse(ids.isEmpty)
        let committed = try await store.segmentedCognitiveClaimIDs(batchID: fresh.id)
        XCTAssertEqual(committed ?? [], ids)
        let retainedState = try await store.segmentedProcessingBatch(id: batch.id).state
        XCTAssertEqual(retainedState, .rejected)
        let repeated = try await store.retryRejectedSegmentedBatch(id: batch.id, extraction: extractionConfiguration, aggregation: aggregationConfiguration)
        XCTAssertEqual(repeated.id, fresh.id)
        let extractionCalls = await extraction.calls
        XCTAssertEqual(extractionCalls, fresh.scope.plan.segments.count)
    }

    func testTransientFailureStaysUnknownWithoutAutomaticResend() async throws {
        let (store, batch) = try await queuedBatch()
        let extraction = RetrySegmentExtraction(.transient), aggregation = RetrySegmentAggregation()
        _ = try await store.processSegmentedCognition(batchID: batch.id, extraction: extraction, aggregation: aggregation)
        let failed = try await store.segmentedProcessingBatch(id: batch.id)
        XCTAssertEqual(failed.state, .unknown)
        XCTAssertFalse(failed.state.allowsExplicitRetry)
        let reason = try XCTUnwrap(failed.error)
        XCTAssertTrue(reason.contains("超时"), reason)
        do {
            _ = try await store.retryRejectedSegmentedBatch(id: batch.id, extraction: extractionConfiguration, aggregation: aggregationConfiguration)
            XCTFail("未知结果不能显式重试")
        } catch {}
        _ = try await store.processSegmentedCognition(batchID: batch.id, extraction: extraction, aggregation: aggregation)
        let calls = await extraction.calls
        XCTAssertEqual(calls, 1)
    }
}
