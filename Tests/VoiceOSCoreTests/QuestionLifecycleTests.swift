import XCTest
@testable import VoiceOSCore

private struct QuestionInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text only") }
}
private struct QuestionFixturePort: ModelPort {
    let configuration = ModelConfiguration(provider: "question_fixture", model: "synthetic", promptVersion: "p1", schemaVersion: "s1", destination: .local)
    let ownership: CandidateOwnership
    let contentKind: CognitiveContentKind?
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        let source = request.context.sources[0]
        return .init(status: .completed, claims: [.init(statement: "哪些反例可以限制猜想？", ownership: ownership, references: [.init(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)], contentKind: contentKind)])
    }
}
final class QuestionLifecycleTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func fixture(ownership: CandidateOwnership = .userTentative, contentKind: CognitiveContentKind? = nil, checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = { _ in }) async throws -> (VoiceOSStore, String, OutcomeSourceEvidence) {
        let s = try VoiceOSStore(root: root, inspector: QuestionInspector(), checkpoint: checkpoint); try await s.recover()
        let id = try await s.recordUserExpression("我想知道：哪些反例可以限制猜想？")
        let context = try await s.prepareLocalTranscriptContext(sourceIDs: [id])
        let contextID = try await s.persistLocalContext(context)
        let ids = try await s.generateClaims(contextID: contextID, using: QuestionFixturePort(ownership: ownership, contentKind: contentKind))
        let source = context.sources[0]
        return (s, ids[0], .init(reference: .init(sourceID: id, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id), quote: source.text))
    }
    func evidence(_ s: VoiceOSStore, text: String) async throws -> OutcomeSourceEvidence {
        let id = try await s.recordUserExpression(text), context = try await s.prepareLocalTranscriptContext(sourceIDs: [id]), source = context.sources[0]
        return .init(reference: .init(sourceID: id, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id), quote: text)
    }
    func testPreparationIsReadOnlyAndPreservesUnendorsedOwnership() async throws {
        let (s, claim, quote) = try await fixture(), first = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 0, original: quote), second = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 0, original: quote)
        XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(first.contentDigest, second.contentDigest)
        XCTAssertEqual(first.ownership, "user_tentative"); try await s.validateQuestionSeed(first)
        let claims = try await s.candidateClaims(), actions = try await s.actions(), attempts = try await s.modelAttempts(sourceID: quote.reference.sourceID)
        XCTAssertEqual(claims.count, 1); XCTAssertEqual(claims[0].reviewState, "pending"); XCTAssertTrue(actions.isEmpty); XCTAssertEqual(attempts.count, 1)
    }
    func testTypedCognitionSurvivesPackageAndQuestionSeed() async throws {
        let (s, claim, quote) = try await fixture(contentKind: .question)
        let seed = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 0, original: quote)
        XCTAssertEqual(seed.contentKind, .question)
        let package = root.appendingPathComponent("typed-package"), restoredRoot = root.appendingPathComponent("restored")
        try await s.exportPackage(to: package)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at: package).version, 24)
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: QuestionInspector())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: QuestionInspector()); try await restored.recover()
        let claims = try await restored.candidateClaims(includeFrozen: true)
        XCTAssertEqual(claims.first?.contentKind, .question); XCTAssertEqual(claims.first?.id, claim)
        let integrity = try await restored.integrityCheck(); XCTAssertTrue(integrity)
        _ = try await s.reviewClaim(claimID: claim, expectedVersion: 0, action: .correct, statement: "更正：这只是记录，不再是问题。", note: "类型不能沿用旧文本")
        let corrected = try await s.candidateClaims(); XCTAssertNil(corrected.first?.contentKind)
    }
    func testLegacyKindAbsentEncodingAndSchema22Upgrade() async throws {
        let (_, _, quote) = try await fixture()
        let legacy = ClaimProposal(statement: "旧未分类内容？", ownership: .userTentative, references: [quote.reference])
        let bytes = try JSONEncoder().encode(legacy), json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(json["contentKind"]); XCTAssertNil(try JSONDecoder().decode(ClaimProposal.self, from: bytes).contentKind)
        let dbURL = root.appendingPathComponent("old22.sqlite")
        do { let db = try Database(dbURL); try db.execute("DROP TABLE question_revisions"); try db.execute("DROP TABLE questions"); try db.execute("ALTER TABLE claims DROP COLUMN content_kind"); try db.execute("PRAGMA user_version=22") }
        let upgraded = try Database(dbURL)
        XCTAssertEqual(try upgraded.query("PRAGMA user_version").first?["user_version"], "31")
        XCTAssertTrue(try upgraded.query("PRAGMA table_info(claims)").contains(where: { $0["name"] == "content_kind" }))
    }
    func testAIQuestionCandidateStaysAIAndFakeQuoteFails() async throws {
        let (s, claim, quote) = try await fixture(ownership: .aiCandidate)
        let seed = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 0, original: quote)
        XCTAssertEqual(seed.ownership, "ai_candidate")
        do { _ = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 0, original: .init(reference: quote.reference, quote: "不存在的提问")); XCTFail("fake quote") } catch {}
    }
    func testReviewChangeAndPolicyEpochInvalidateSeed() async throws {
        let (s, claim, quote) = try await fixture(), seed = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 0, original: quote)
        _ = try await s.reviewClaim(claimID: claim, expectedVersion: 0, action: .endorse)
        do { try await s.validateQuestionSeed(seed); XCTFail("review change") } catch {}
        let fresh = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 1, original: quote)
        _ = try await s.setSourceLocalOnly(sourceID: quote.reference.sourceID, expectedVersion: 1, localOnly: false)
        _ = try await s.setSourceLocalOnly(sourceID: quote.reference.sourceID, expectedVersion: 2, localOnly: true)
        do { try await s.validateQuestionSeed(fresh); XCTFail("policy epoch") } catch {}
    }
    func testResolvedRequiresEvidenceClosedIsDistinctAndReopenExplicit() async throws {
        let (s, claim, quote) = try await fixture(), seed = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 0, original: quote)
        do { _ = try await s.prepareQuestionTransition(seed: seed, expectedVersion: 1, from: .open, to: .resolved, reason: "猜测已有答案"); XCTFail("no answer evidence") } catch {}
        do { _ = try await s.prepareQuestionTransition(seed: seed, expectedVersion: 1, from: .open, to: .resolved, reason: "原问题不是答案", resolution: quote); XCTFail("question reused as answer") } catch {}
        do { _ = try await s.prepareQuestionTransition(seed: seed, expectedVersion: 1, from: .open, to: .resolved, reason: "截短原问题仍不是答案", resolution: .init(reference: quote.reference, quote: "哪些反例可以限制猜想？")); XCTFail("partial question reused as answer") } catch {}
        let closed = try await s.prepareQuestionTransition(seed: seed, expectedVersion: 1, from: .open, to: .closed, reason: "暂时不追踪")
        XCTAssertNil(closed.resolution); XCTAssertEqual(closed.to, .closed)
        _ = try await s.prepareQuestionTransition(seed: seed, expectedVersion: 2, from: .closed, to: .open, reason: "我决定重新研究")
        do { _ = try await s.prepareQuestionTransition(seed: seed, expectedVersion: 2, from: .closed, to: .resolved, reason: "直接复活解决"); XCTFail("invalid reopening") } catch {}
        let answer = try await evidence(s, text: "我找到了反例，这个问题已有答案；答案仍待检验。")
        let solved = try await s.prepareQuestionTransition(seed: seed, expectedVersion: 1, from: .open, to: .resolved, reason: "用户登记答案", resolution: answer)
        try await s.validateQuestionTransition(solved)
        _ = try await s.correctTranscript(sourceID: answer.reference.sourceID, expectedVersionID: answer.reference.transcriptVersionID, text: "更正：我还没有找到答案。")
        do { try await s.validateQuestionTransition(solved); XCTFail("changed answer") } catch {}
    }
}
