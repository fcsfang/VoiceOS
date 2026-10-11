import XCTest
@testable import VoiceOSCore

private struct AssociationInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text only") }
}
private struct AssociationRetrieval: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.map { RetrievalMatch(documentID: $0.id, score: 1, method: "exact") }
    }
}
final class ExpressionAssociationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("association-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func fixture() async throws -> (VoiceOSStore, String, [RetrievalHit]) {
        let s = try VoiceOSStore(root: root, inspector: AssociationInspector()); try await s.recover()
        _ = try await s.recordUserExpression("旧问题：什么条件可以限制这个猜想？")
        _ = try await s.recordUserExpression("旧表达：还没有检验反例。")
        let current = try await s.recordUserExpression("这次表达：如果出现反例，我会修正猜想。🧠")
        let result = try await s.retrieve("表达", using: AssociationRetrieval())
        return (s, current, result.hits.filter { $0.document.sourceID != current })
    }
    func proposal(_ snapshot: ExpressionAssociationSnapshot) -> ExpressionAssociationProposal {
        let source = snapshot.current.sources[0], hit = snapshot.candidates[0]
        return .init(candidateID: hit.id, current: .init(reference: .init(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id), quote: source.text), historicalQuote: hit.document.text, relation: .qualification, reason: "AI提案：两次表达都在讨论猜想的限制条件。")
    }
    func testReadOnlyPreparationIsStableAndKeepsBothQuotes() async throws {
        let (s, current, hits) = try await fixture()
        let a = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits)
        let b = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits)
        XCTAssertNotEqual(a.id, b.id); XCTAssertEqual(a.contentDigest, b.contentDigest)
        try await s.validateExpressionAssociation(a)
        try VoiceOSStore.validateExpressionAssociationProposals([proposal(a)], snapshot: a)
        try VoiceOSStore.validateExpressionAssociationProposals([], snapshot: a)
        let models = try await s.modelAttempts(), claims = try await s.candidateClaims(), actions = try await s.actions()
        XCTAssertTrue(models.isEmpty); XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty)
    }
    func testCloudScopeSelfCandidateAndFullTextBudgetReject() async throws {
        let (s, current, hits) = try await fixture()
        do { _ = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits, destination: .cloud); XCTFail("private cloud") } catch {}
        do { _ = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits, scalarBudget: 5); XCTFail("must not truncate") } catch {}
        let all = try await s.retrieve("表达", using: AssociationRetrieval())
        do { _ = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: all.hits); XCTFail("self relation") } catch {}
        let empty = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: [])
        XCTAssertTrue(empty.candidates.isEmpty)
    }
    func testPolicyRegrantAndExcludedCandidateCorrectionInvalidateSnapshot() async throws {
        let (s, current, hits) = try await fixture()
        let before = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits)
        _ = try await s.setSourceLocalOnly(sourceID: current, expectedVersion: 1, localOnly: false)
        _ = try await s.setSourceLocalOnly(sourceID: current, expectedVersion: 2, localOnly: true)
        do { try await s.validateExpressionAssociation(before); XCTFail("policy epoch") } catch {}
        let fresh = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits)
        _ = try await s.correctTranscript(sourceID: hits[1].document.sourceID, expectedVersionID: hits[1].document.transcriptVersionID, text: "更正：此前表达有误。")
        do { try await s.validateExpressionAssociation(fresh); XCTFail("excluded input changed") } catch {}
    }
    func testPauseAndMalformedProposalsCannotBecomeFeedback() async throws {
        let (s, current, hits) = try await fixture()
        let a = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits), p = proposal(a)
        XCTAssertThrowsError(try VoiceOSStore.validateExpressionAssociationProposals([p, p], snapshot: a))
        let invalid = ExpressionAssociationProposal(candidateID: p.candidateID, current: p.current, historicalQuote: "不存在的旧句", relation: p.relation, reason: p.reason)
        XCTAssertThrowsError(try VoiceOSStore.validateExpressionAssociationProposals([invalid], snapshot: a))
        try await s.setCognitiveFeedbackMode(.paused, expectedVersion: 0)
        do { try await s.validateExpressionAssociation(a); XCTFail("paused late snapshot") } catch {}
        do { _ = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits); XCTFail("paused preparation") } catch {}
    }
    func testExplicitCloudTextPermissionsAllowSnapshotWithoutDispatch() async throws {
        let (s, current, _) = try await fixture()
        let sources = try await s.sources()
        for source in sources { _ = try await s.setSourceLocalOnly(sourceID: source.id, expectedVersion: source.policyVersion, localOnly: false) }
        let all = try await s.retrieve("表达", using: AssociationRetrieval())
        let snapshot = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: all.hits.filter { $0.document.sourceID != current }, destination: .cloud)
        try await s.validateExpressionAssociation(snapshot)
        try VoiceOSStore.validateExpressionAssociationProposals([proposal(snapshot)], snapshot: snapshot)
        let models = try await s.modelAttempts(); XCTAssertTrue(models.isEmpty)
    }
    func testReducedModeLimitsProposalCountAndPreferenceChangesInvalidateInput() async throws {
        let (s, current, hits) = try await fixture()
        let normal = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits)
        try await s.setCognitiveFeedbackMode(.reduced, expectedVersion: 0)
        do { try await s.validateExpressionAssociation(normal); XCTFail("preference changed") } catch {}
        let reduced = try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits), first = proposal(reduced)
        let second = ExpressionAssociationProposal(candidateID: hits[1].id, current: first.current, historicalQuote: hits[1].document.text, relation: .sameQuestion, reason: "AI提案：可能仍与旧问题相关，未确认解决状态。")
        try VoiceOSStore.validateExpressionAssociationProposals([first], snapshot: reduced)
        XCTAssertThrowsError(try VoiceOSStore.validateExpressionAssociationProposals([first, second], snapshot: reduced))
    }

}
