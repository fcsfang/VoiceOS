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

    private func attachCompletedExpression(_ store: VoiceOSStore, sourceIDs: [String], id: String) async throws {
        let records = try await store.sources()
        let members = try sourceIDs.map { sourceID -> (SourceRecord, String, Int) in
            let record = try XCTUnwrap(records.first { $0.id == sourceID })
            return (record, try XCTUnwrap(record.transcriptVersionID), record.policyVersion)
        }
        let expression = RecordingExpression(id: id, sourceIDs: sourceIDs, title: "连续表达", summary: "同一连续表达的完整分段", reason: "按录音顺序承接同一表达", responseIDs: [], versions: Dictionary(uniqueKeysWithValues: members.map { ($0.0.id, $0.1) }), policies: Dictionary(uniqueKeysWithValues: members.map { ($0.0.id, $0.2) }), state: "completed", previousActionIDs: [])
        let db = await store.db
        for member in members {
            var presentation = member.0.presentation ?? RecordingPresentation()
            presentation.expression = expression
            try db.execute("UPDATE sources SET presentation_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(presentation), as: UTF8.self), member.0.id])
        }
    }

    private func seedExternal(_ store: VoiceOSStore, text: String) async throws -> String {
        let id = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        let db = await store.db
        try db.execute("UPDATE sources SET origin='external',speaker='external' WHERE id=?", [id])
        return id
    }

    func testMultiMemberExpressionUnchangedSkipsPreparation() async throws {
        let store = try await openStore()
        let firstID = try await seed(store, text: String(repeating: "第一段连续表达需要完整保留。", count: 40))
        let secondID = try await seed(store, text: String(repeating: "第二段连续表达需要完整保留。", count: 40))
        try await attachCompletedExpression(store, sourceIDs: [firstID, secondID], id: "scan-multi")
        let first = try await store.enqueueKnowledgeReview(sourceID: firstID)
        let preparedOnce = await store.knowledgeReviewPreparations
        XCTAssertEqual(preparedOnce, 1)
        let second = try await store.enqueueKnowledgeReview(sourceID: firstID)
        XCTAssertEqual(second.id, first.id)
        let preparedTwice = await store.knowledgeReviewPreparations
        XCTAssertEqual(preparedTwice, preparedOnce)
        _ = try await store.enqueueKnowledgeReview(sourceID: secondID)
        let preparedMember = await store.knowledgeReviewPreparations
        _ = try await store.enqueueKnowledgeReview(sourceID: secondID)
        let preparedMemberTwice = await store.knowledgeReviewPreparations
        XCTAssertEqual(preparedMemberTwice, preparedMember)
        let reviewed = try await store.knowledgeReviews(sourceID: firstID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "current")
    }

    func testMultiMemberTranscriptChangeFallsBackAndFreezes() async throws {
        let store = try await openStore()
        let firstID = try await seed(store, text: String(repeating: "连续表达首段需要完整保留。", count: 40))
        let secondID = try await seed(store, text: String(repeating: "连续表达次段需要完整保留。", count: 40))
        try await attachCompletedExpression(store, sourceIDs: [firstID, secondID], id: "scan-transcript")
        let first = try await store.enqueueKnowledgeReview(sourceID: firstID)
        let before = await store.knowledgeReviewPreparations
        let records = try await store.sources()
        let member = try XCTUnwrap(records.first { $0.id == secondID })
        _ = try await store.correctTranscript(sourceID: secondID, expectedVersionID: try XCTUnwrap(member.transcriptVersionID), text: "更正后的连续表达次段需要完整保留。")
        let reviewed = try await store.knowledgeReviews(sourceID: firstID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "frozen")
        let after = await store.knowledgeReviewPreparations
        XCTAssertEqual(after, before + 1)
    }

    func testMultiMemberPolicyChangeFallsBackAndFreezes() async throws {
        let store = try await openStore()
        let firstID = try await seed(store, text: String(repeating: "连续表达首段授权核对。", count: 40))
        let secondID = try await seed(store, text: String(repeating: "连续表达次段授权核对。", count: 40))
        try await attachCompletedExpression(store, sourceIDs: [firstID, secondID], id: "scan-policy")
        let first = try await store.enqueueKnowledgeReview(sourceID: firstID)
        let before = await store.knowledgeReviewPreparations
        let policy = try await store.sourcePolicy(sourceID: secondID)
        _ = try await store.setSourceLocalOnly(sourceID: secondID, expectedVersion: policy.version, localOnly: true)
        let reviewed = try await store.knowledgeReviews(sourceID: firstID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "frozen")
        let after = await store.knowledgeReviewPreparations
        XCTAssertEqual(after, before + 1)
    }

    func testMultiMemberMembershipChangeFallsBackAndFreezes() async throws {
        let store = try await openStore()
        let firstID = try await seed(store, text: String(repeating: "连续表达首段成员核对。", count: 40))
        let secondID = try await seed(store, text: String(repeating: "连续表达次段成员核对。", count: 40))
        try await attachCompletedExpression(store, sourceIDs: [firstID, secondID], id: "scan-membership")
        let first = try await store.enqueueKnowledgeReview(sourceID: firstID)
        let before = await store.knowledgeReviewPreparations
        try await attachCompletedExpression(store, sourceIDs: [firstID], id: "scan-single")
        let reviewed = try await store.knowledgeReviews(sourceID: firstID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "frozen")
        let after = await store.knowledgeReviewPreparations
        XCTAssertEqual(after, before + 1)
    }

    func testRecordingContextUnchangedSkipsPreparation() async throws {
        let store = try await openStore()
        let personalID = try await seed(store, text: String(repeating: "双轨个人原话需要完整保留。", count: 40))
        let externalID = try await seedExternal(store, text: "节目组认为智能体可以完全自主。")
        try await store.attachRecordingContext(personalSourceID: personalID, externalSourceID: externalID, sessionID: "scan-pairing")
        let first = try await store.enqueueKnowledgeReview(sourceID: personalID)
        let preparedOnce = await store.knowledgeReviewPreparations
        XCTAssertEqual(preparedOnce, 1)
        let second = try await store.enqueueKnowledgeReview(sourceID: personalID)
        XCTAssertEqual(second.id, first.id)
        let preparedTwice = await store.knowledgeReviewPreparations
        XCTAssertEqual(preparedTwice, preparedOnce)
    }

    func testRecordingContextChangeFallsBackAndFreezes() async throws {
        let store = try await openStore()
        let personalID = try await seed(store, text: String(repeating: "双轨偏移前的个人原话。", count: 40))
        let externalID = try await seedExternal(store, text: "节目组会发布一份报告。")
        try await store.attachRecordingContext(personalSourceID: personalID, externalSourceID: externalID, sessionID: "scan-pairing-change")
        let first = try await store.enqueueKnowledgeReview(sourceID: personalID)
        let before = await store.knowledgeReviewPreparations
        try await store.attachRecordingContext(personalSourceID: personalID, externalSourceID: externalID, sessionID: "scan-pairing-change", offsetMS: 250)
        let reviewed = try await store.knowledgeReviews(sourceID: personalID)
        XCTAssertEqual(reviewed.first { $0.id == first.id }?.validity, "frozen")
        let after = await store.knowledgeReviewPreparations
        XCTAssertEqual(after, before + 1)
    }

    func testNewestUnusableReviewDoesNotHideMatchingOlderReview() async throws {
        let store = try await openStore()
        let sourceID = try await seed(store, text: String(repeating: "排序回退原话需要完整保留。", count: 40))
        let older = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        let db = await store.db
        let stored = try XCTUnwrap(try db.query("SELECT input_json FROM knowledge_reviews WHERE id=?", [older.id]).first)
        let inputJSON = try XCTUnwrap(stored["input_json"])
        try db.execute("UPDATE knowledge_reviews SET created_at='2000-01-01T00:00:00Z' WHERE id=?", [older.id])
        let newerID = UUID().uuidString
        try db.execute("INSERT INTO knowledge_reviews(id,source_id,input_digest,input_json,state,response_ids_json,created_at) VALUES(?,?,?,?,'failed','[]','2999-01-01T00:00:00Z')", [newerID, sourceID, "stale-digest", inputJSON])
        let before = await store.knowledgeReviewPreparations
        let result = try await store.enqueueKnowledgeReview(sourceID: sourceID)
        XCTAssertEqual(result.id, older.id)
        let after = await store.knowledgeReviewPreparations
        XCTAssertEqual(after, before + 1)
    }
}
