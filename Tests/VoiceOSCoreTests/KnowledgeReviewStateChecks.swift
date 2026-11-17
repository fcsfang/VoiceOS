import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private let stateConfiguration = ModelConfiguration(provider: "fixture", model: "knowledge-state", promptVersion: "v1", schemaVersion: "v1", destination: .local)

private actor StateUnderstandingModel: ModelPort {
    let configuration = stateConfiguration
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        let source = request.context.sources[0]
        let reference = ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        return ModelResponse(status: .completed, claims: [ClaimProposal(statement: String(source.text.prefix(80)), ownership: .userTentative, references: [reference])])
    }
}

private struct StateKnowledgePort: KnowledgeReviewPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "knowledge-state", promptVersion: "knowledge-review-v1", schemaVersion: "knowledge-review-v1", destination: .local)
    let quotes: [String]
    func identify(_ input: KnowledgeReviewInput) async throws -> KnowledgeReviewSelection {
        .init(candidates: quotes.enumerated().map { index, quote in
            KnowledgeReviewCandidate(id: "issue-\(index)", quote: quote, reason: "可核查的知识判断")
        }, responseID: "identify-receipt")
    }
    func check(_ candidate: KnowledgeReviewCandidate, input: KnowledgeReviewInput) async throws -> KnowledgeReviewCheck {
        .init(issue: KnowledgeReviewIssue(id: candidate.id, quote: candidate.quote, kind: .factualError, explanation: "与公开资料不一致", betterUnderstanding: "更准确的理解", boundary: "仅在该条件下成立", counterexample: "", references: [AssistantReference(url: "https://example.com/reference", title: "公开参考")], responseIDs: ["review-receipt"]), responseIDs: ["review-receipt"])
    }
}

final class KnowledgeReviewStateChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-knowledge-state-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func completedReview(_ store: VoiceOSStore) async throws -> KnowledgeReviewRecord {
        let text = "SQLite integrity_check 会检查索引与表记录的一致性。SQLite quick_check 不能证明业务逻辑正确。" + String(repeating: "这段原话用于核对知识核查状态是否持久。", count: 40)
        let sourceID = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        _ = try await store.continueSourceUnderstanding(sourceID: sourceID, using: StateUnderstandingModel())
        let record = try await store.processKnowledgeReview(sourceID: sourceID, using: StateKnowledgePort(quotes: ["SQLite integrity_check 会检查索引与表记录的一致性。", "SQLite quick_check 不能证明业务逻辑正确。"]))
        XCTAssertEqual(record.state, "completed")
        XCTAssertEqual(record.issues.count, 2)
        guard record.issues.count == 2 else { throw VoiceOSError("知识核查夹具未产生两条问题") }
        return record
    }

    func testIssueStatesRoundTripPersistAndCount() async throws {
        var sourceID = "", reviewID = "", rejectedIssue = "", seenIssue = ""
        do {
            let store = try await openStore()
            let record = try await completedReview(store)
            sourceID = record.sourceID; reviewID = record.id
            rejectedIssue = record.issues[0].id; seenIssue = record.issues[1].id
            try await store.setKnowledgeReviewIssueState(reviewID: reviewID, issueID: rejectedIssue, state: .accepted)
            try await store.setKnowledgeReviewIssueState(reviewID: reviewID, issueID: seenIssue, state: .seen)

            let reviewsAfterWrite = try await store.knowledgeReviews(sourceID: sourceID)
            let readBack = try XCTUnwrap(reviewsAfterWrite.first { $0.id == reviewID })
            XCTAssertEqual(readBack.issueState(rejectedIssue), .accepted)
            XCTAssertEqual(readBack.issueState(seenIssue), .seen)
            XCTAssertNil(readBack.issueState("not-an-issue"))
            XCTAssertEqual(readBack.issueCounts(of: readBack.issues), KnowledgeReviewIssueCounts(pending: 0, seen: 1, accepted: 1, rejected: 0))
            XCTAssertEqual(readBack.openIssues(from: readBack.issues).map(\.id), [seenIssue])
            XCTAssertEqual(readBack.settledIssues(from: readBack.issues).map(\.id), [rejectedIssue])

            try await store.setKnowledgeReviewIssueState(reviewID: reviewID, issueID: rejectedIssue, state: .rejected)
            let reviewsAfterOverwrite = try await store.knowledgeReviews(sourceID: sourceID)
            let overwritten = try XCTUnwrap(reviewsAfterOverwrite.first { $0.id == reviewID })
            XCTAssertEqual(overwritten.issueState(rejectedIssue), .rejected)
            XCTAssertEqual(overwritten.issueCounts(of: overwritten.issues), KnowledgeReviewIssueCounts(pending: 0, seen: 1, accepted: 0, rejected: 1))
            let db = await store.db
            XCTAssertEqual(try db.query("SELECT count(*) AS n FROM knowledge_review_states").first?["n"], "2", "覆盖状态不新增行")
        }

        let reopened = try await openStore()
        let reviewsAfterReopen = try await reopened.knowledgeReviews(sourceID: sourceID)
        let persisted = try XCTUnwrap(reviewsAfterReopen.first { $0.id == reviewID })
        XCTAssertEqual(persisted.issueState(rejectedIssue), .rejected)
        XCTAssertEqual(persisted.issueState(seenIssue), .seen)
    }

    func testStateWriteRejectsUnknownReviewAndUnknownIssue() async throws {
        let store = try await openStore()
        let record = try await completedReview(store)
        do {
            try await store.setKnowledgeReviewIssueState(reviewID: UUID().uuidString, issueID: record.issues[0].id, state: .seen)
            XCTFail("未知核查不能写入状态")
        } catch { XCTAssertTrue(error is VoiceOSError) }
        do {
            try await store.setKnowledgeReviewIssueState(reviewID: record.id, issueID: "not-an-issue", state: .seen)
            XCTFail("不属于该核查的问题不能写入状态")
        } catch { XCTAssertTrue(error is VoiceOSError) }
        let db = await store.db
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM knowledge_review_states").first?["n"], "0")
    }

    func testMigration68CreatesStateTableAndRetriesSafely() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("voiceos.sqlite")
        do {
            let db = try Database(url)
            XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
            XCTAssertEqual(try db.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='knowledge_review_states'").first?["n"], "1")
            try db.execute("DROP TABLE knowledge_review_states")
            try db.execute("PRAGMA user_version=67")
        }
        do {
            let migrated = try Database(url)
            XCTAssertEqual(try migrated.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
            XCTAssertEqual(try migrated.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='knowledge_review_states'").first?["n"], "1")
            // Simulate a retry that created the table before bumping the version.
            try migrated.execute("PRAGMA user_version=67")
        }
        let retried = try Database(url)
        XCTAssertEqual(try retried.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
        XCTAssertEqual(try retried.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='knowledge_review_states'").first?["n"], "1")
    }
}
