import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private let scanConfiguration = ModelConfiguration(provider: "fixture", model: "scan", promptVersion: "v1", schemaVersion: "v1", destination: .local)

private actor ScanModel: ModelPort {
    let configuration = scanConfiguration
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        let source = request.context.sources[0]
        let reference = ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        return ModelResponse(status: .completed, claims: [ClaimProposal(statement: String(source.text.prefix(80)), ownership: .userTentative, references: [reference])])
    }
}

final class KnowledgeReviewScanChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-knowledge-scan-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func seed(_ store: VoiceOSStore, text: String) async throws -> String {
        let id = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        _ = try await store.continueSourceUnderstanding(sourceID: id, using: ScanModel())
        return id
    }

    func testUnchangedSingleSourceReviewSkipsPreparation() async throws {
        let store = try await openStore()
        let sourceID = try await seed(store, text: String(repeating: "这是用于知识核查的完整个人原话。", count: 40))
        let first = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        XCTAssertEqual(first.state, "queued")
        let preparedOnce = await store.knowledgeReviewPreparations
        XCTAssertEqual(preparedOnce, 1)
        let reviewed = try await store.knowledgeReviews(sourceID: sourceID)
        XCTAssertEqual(reviewed.map(\.id), [first.id])
        XCTAssertEqual(reviewed.first?.validity, "current")
        let second = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        XCTAssertEqual(second.id, first.id)
        let preparedTwice = await store.knowledgeReviewPreparations
        XCTAssertEqual(preparedTwice, preparedOnce)
    }

    func testTranscriptCorrectionRebuildsAndFreezes() async throws {
        let store = try await openStore()
        let text = String(repeating: "原始原话需要完整保留。", count: 40)
        let sourceID = try await seed(store, text: text)
        let first = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        let before = await store.knowledgeReviewPreparations
        let current = try await store.sources()
        let version = try XCTUnwrap(current.first { $0.id == sourceID }?.transcriptVersionID)
        _ = try await store.correctTranscript(sourceID: sourceID, expectedVersionID: version, text: text + "更正后的原话。")
        let reviewed = try await store.knowledgeReviews(sourceID: sourceID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "frozen")
        let after = await store.knowledgeReviewPreparations
        XCTAssertEqual(after, before + 1)
    }

    func testPolicyChangeRebuildsAndFreezes() async throws {
        let store = try await openStore()
        let sourceID = try await seed(store, text: String(repeating: "授权变化前的完整原话。", count: 40))
        let first = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        let before = await store.knowledgeReviewPreparations
        let policy = try await store.sourcePolicy(sourceID: sourceID)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: policy.version, localOnly: true)
        let reviewed = try await store.knowledgeReviews(sourceID: sourceID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "frozen")
        let after = await store.knowledgeReviewPreparations
        XCTAssertEqual(after, before + 1)
    }

    func testClaimReviewVersionRebuildsAndCreatesCurrentReview() async throws {
        let store = try await openStore()
        let sourceID = try await seed(store, text: String(repeating: "认可版本变化前的完整原话。", count: 40))
        let first = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        let before = await store.knowledgeReviewPreparations
        let claims = try await store.latestCandidateClaims(for: sourceID)
        let claim = try XCTUnwrap(claims.first)
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: claim.reviewVersion, action: .endorse)
        let reviewed = try await store.knowledgeReviews(sourceID: sourceID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "frozen")
        let afterValidation = await store.knowledgeReviewPreparations
        XCTAssertEqual(afterValidation, before + 1)
        let second = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.state, "queued")
        let afterEnqueue = await store.knowledgeReviewPreparations
        XCTAssertEqual(afterEnqueue, afterValidation + 1)
    }

    func testContinuousExpressionSourceFallsBackToFullValidation() async throws {
        let store = try await openStore()
        let sourceID = try await seed(store, text: String(repeating: "连续表达分段前的完整原话。", count: 40))
        let first = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        let before = await store.knowledgeReviewPreparations
        let records = try await store.sources()
        let record = try XCTUnwrap(records.first { $0.id == sourceID })
        let version = try XCTUnwrap(record.transcriptVersionID)
        let expression = RecordingExpression(id: "scan-expression", sourceIDs: [sourceID, "missing-member"], title: "连续表达", summary: "等待第二段", reason: "同一表达的两段", responseIDs: [], versions: [sourceID: version], policies: [sourceID: record.policyVersion], state: "completed", previousActionIDs: [])
        var presentation = record.presentation ?? RecordingPresentation()
        presentation.expression = expression
        let db = await store.db
        try db.execute("UPDATE sources SET presentation_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(presentation), as: UTF8.self), sourceID])
        let reviewed = try await store.knowledgeReviews(sourceID: sourceID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "current")
        let after = await store.knowledgeReviewPreparations
        XCTAssertEqual(after, before + 1)
    }

    func testPendingSingleSourceExpressionFallsBackAndFreezes() async throws {
        let store = try await openStore()
        let sourceID = try await seed(store, text: String(repeating: "待完成表达前的完整原话。", count: 40))
        let first = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        let before = await store.knowledgeReviewPreparations
        let records = try await store.sources()
        let record = try XCTUnwrap(records.first { $0.id == sourceID })
        let version = try XCTUnwrap(record.transcriptVersionID)
        let expression = RecordingExpression(id: "pending-expression", sourceIDs: [sourceID], title: "待完成表达", summary: "仍在理解", reason: "单段表达尚未完成", responseIDs: [], versions: [sourceID: version], policies: [sourceID: record.policyVersion], state: "pending", previousActionIDs: [])
        var presentation = record.presentation ?? RecordingPresentation()
        presentation.expression = expression
        let db = await store.db
        try db.execute("UPDATE sources SET presentation_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(presentation), as: UTF8.self), sourceID])
        let reviewed = try await store.knowledgeReviews(sourceID: sourceID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "frozen")
        let after = await store.knowledgeReviewPreparations
        XCTAssertEqual(after, before + 1)
    }

    func testManySourceScanSkipsPreparationAndReportsCost() async throws {
        let store = try await openStore()
        let body = String(repeating: "这段长原话用于测量知识核查扫描的重建成本，内容保持完整并包含可检索的公开知识线索。", count: 80)
        var sourceIDs: [String] = []
        for index in 0..<60 {
            sourceIDs.append(try await seed(store, text: "材料\(index)：" + body))
        }
        for id in sourceIDs {
            _ = try await store.enqueueKnowledgeReview(sourceID: id)
        }
        let observed = try await store.knowledgeReviews()
        XCTAssertEqual(observed.count, 60)
        _ = try await store.knowledgeReviews()

        var slowTimes: [Double] = [], fastTimes: [Double] = []
        var slowPreparations = 0, fastPreparations = 0
        for _ in 0..<5 {
            await store.setKnowledgeReviewScanFastPathEnabled(false)
            let slowBefore = await store.knowledgeReviewPreparations
            let slowStart = Date()
            let slowReviews = try await store.knowledgeReviews()
            slowTimes.append(Date().timeIntervalSince(slowStart))
            slowPreparations = await store.knowledgeReviewPreparations - slowBefore
            XCTAssertEqual(slowReviews.count, 60)

            await store.setKnowledgeReviewScanFastPathEnabled(true)
            let fastBefore = await store.knowledgeReviewPreparations
            let fastStart = Date()
            let fastReviews = try await store.knowledgeReviews()
            fastTimes.append(Date().timeIntervalSince(fastStart))
            fastPreparations = await store.knowledgeReviewPreparations - fastBefore
            XCTAssertEqual(fastReviews.count, 60)
        }
        XCTAssertEqual(slowPreparations, 60)
        XCTAssertEqual(fastPreparations, 0)
        let slowMedian = slowTimes.sorted()[2], fastMedian = fastTimes.sorted()[2]
        print(String(format: "knowledge scan 60 reviews: before median %.1f ms range %.1f-%.1f (%d preparations); after median %.1f ms range %.1f-%.1f (%d preparations)",
                     slowMedian * 1000, slowTimes.min()! * 1000, slowTimes.max()! * 1000, slowPreparations,
                     fastMedian * 1000, fastTimes.min()! * 1000, fastTimes.max()! * 1000, fastPreparations))
    }
}
