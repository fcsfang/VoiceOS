import XCTest
@testable import VoiceOSCore

private struct QuestionAssociationRetrieval: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.map { .init(documentID: $0.id, score: 1, method: "exact") }
    }
}
private actor QuestionAssociationPort: ExpressionAssociationPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "fixture", promptVersion: "p1", schemaVersion: "s1", destination: .local)
    var calls = 0
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        calls += 1
        let current = request.snapshot.current.sources[0], hit = request.snapshot.candidates[0]
        let evidence = OutcomeSourceEvidence(reference: .init(sourceID: current.sourceID, transcriptVersionID: current.transcriptVersionID, spanID: current.spans[0].id), quote: current.text)
        return .init(proposals: [.init(candidateID: hit.id, current: evidence, historicalQuote: hit.document.text, relation: .sameQuestion, reason: "合成关系提案，不能推断解决状态。")])
    }
}
final class QuestionAssociationTests: XCTestCase {
    var fixture: QuestionLifecycleTests!
    override func setUpWithError() throws { fixture = QuestionLifecycleTests(); try fixture.setUpWithError() }
    override func tearDownWithError() throws { try fixture.tearDownWithError() }
    private func association(_ store: VoiceOSStore, sourceID: String) async throws -> (String, QuestionAssociationPort) {
        let current = try await store.recordUserExpression("合成新表达：我再次比较反例和猜想的限制。")
        let hits = try await store.retrieve("反例", using: QuestionAssociationRetrieval()).hits.filter { $0.document.sourceID == sourceID }
        let snapshot = try await store.prepareExpressionAssociation(currentSourceID: current, candidates: hits), port = QuestionAssociationPort()
        _ = try await store.performExpressionAssociation(snapshot, using: port)
        return (current, port)
    }
    func testCitationQuestionVersionsChangeWithoutRegeneratingAssociation() async throws {
        let (s, _, quote) = try await fixture.fixture(contentKind: .question), (current, port) = try await association(s, sourceID: quote.reference.sourceID)
        let first = try await s.expressionAssociationFeedback(currentSourceID: current)
        let question = try XCTUnwrap(first.first?.historicalQuestions.first)
        XCTAssertEqual(question.status, .open); XCTAssertEqual(question.version, 1)
        let closed = try await s.prepareStoredQuestionTransition(questionID: question.id, expectedVersion: 1, to: .closed, reason: "明确停止")
        _ = try await s.transitionQuestion(questionID: question.id, input: closed)
        let after = try await s.expressionAssociationFeedback(currentSourceID: current)
        XCTAssertEqual(after.first?.id, first.first?.id); XCTAssertEqual(after.first?.historicalQuestions.first?.status, .closed)
        XCTAssertEqual(after.first?.historicalQuestions.first?.version, 2)
        let calls = await port.calls; XCTAssertEqual(calls, 1)
        let attempts = try await s.expressionAssociationAttempts(); XCTAssertEqual(attempts.count, 1)
        let actions = try await s.actions(); XCTAssertTrue(actions.isEmpty)
    }
    func testAIQuestionIdentityAndUnclassifiedHistoryNotInferred() async throws {
        let (s, _, quote) = try await fixture.fixture(ownership: .aiCandidate, contentKind: .question), (current, _) = try await association(s, sourceID: quote.reference.sourceID)
        let ai = try await s.expressionAssociationFeedback(currentSourceID: current)
        XCTAssertEqual(ai.first?.historicalQuestions.first?.seed.ownership, "ai_candidate")
        try fixture.tearDownWithError(); try fixture.setUpWithError()
        let (legacy, _, oldQuote) = try await fixture.fixture(), (newID, _) = try await association(legacy, sourceID: oldQuote.reference.sourceID)
        let unclassified = try await legacy.expressionAssociationFeedback(currentSourceID: newID)
        XCTAssertEqual(unclassified.count, 1); XCTAssertTrue(unclassified[0].historicalQuestions.isEmpty)
    }
    func testChangedAnswerFreezesQuestionContextWhileAssociationRemainsAnAIProposal() async throws {
        let (s, _, quote) = try await fixture.fixture(contentKind: .question), (current, _) = try await association(s, sourceID: quote.reference.sourceID)
        let initial = try await s.expressionAssociationFeedback(currentSourceID: current), question = try XCTUnwrap(initial.first?.historicalQuestions.first)
        let answer = try await fixture.evidence(s, text: "合成回答：明确答案依据，尚未验证。")
        let input = try await s.prepareStoredQuestionTransition(questionID: question.id, expectedVersion: 1, to: .resolved, reason: "登记答案", resolution: answer)
        _ = try await s.transitionQuestion(questionID: question.id, input: input)
        _ = try await s.correctTranscript(sourceID: answer.reference.sourceID, expectedVersionID: answer.reference.transcriptVersionID, text: "更正答案失效")
        let after = try await s.expressionAssociationFeedback(currentSourceID: current)
        XCTAssertEqual(after.count, 1); XCTAssertEqual(after[0].historicalQuestions[0].validity, "frozen"); XCTAssertEqual(after[0].historicalQuestions[0].status, .resolved)
        XCTAssertEqual(after[0].proposal.relation, .sameQuestion)
    }
    func testPauseAndIgnoreNeverCloseQuestionOrRepeatAttempt() async throws {
        let (s, _, quote) = try await fixture.fixture(contentKind: .question), (current, port) = try await association(s, sourceID: quote.reference.sourceID)
        let items = try await s.expressionAssociationFeedback(currentSourceID: current), item = try XCTUnwrap(items.first)
        try await s.setCognitiveFeedbackMode(.paused, expectedVersion: 0)
        let paused = try await s.expressionAssociationFeedback(currentSourceID: current); XCTAssertTrue(paused.isEmpty)
        try await s.setCognitiveFeedbackMode(.normal, expectedVersion: 1)
        try await s.ignoreExpressionAssociation(attemptID: item.attemptID, candidateID: item.proposal.candidateID, relation: item.proposal.relation)
        let ignored = try await s.expressionAssociationFeedback(currentSourceID: current); XCTAssertTrue(ignored.isEmpty)
        let questions = try await s.questions(); XCTAssertEqual(questions[0].status, .open); XCTAssertEqual(questions[0].version, 1)
        let calls = await port.calls; XCTAssertEqual(calls, 1)
    }
}
