import XCTest
@testable import VoiceOSCore

private struct TypedOutcomeInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private struct TypedQuestionReply: DiscussionModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "fixture", promptVersion: "p1", schemaVersion: "s1", destination: .local)
    func reply(_ request: DiscussionModelRequest) async throws -> DiscussionModelResponse {
        .init(status: .completed, parts: [.init(kind: .aiSuggestion, text: "AI追问：哪些条件需要重新检查？")])
    }
}
private actor TypedQuestionOutcome: ConversationOutcomePort {
    let configuration = ModelConfiguration(provider: "typed_fixture", model: "fixture", promptVersion: "p2", schemaVersion: "s2", destination: .local)
    let typed: Bool
    let badAction: Bool
    var calls = 0
    init(typed: Bool = true, badAction: Bool = false) { self.typed = typed; self.badAction = badAction }
    func extract(_ request: ConversationOutcomeRequest) async throws -> ConversationOutcomeResponse {
        calls += 1
        let input = request.snapshot
        let evidence = input.input.userTurns.map { turn -> OutcomeSourceEvidence in
            let source = input.context.sources.first(where: { $0.sourceID == turn.sourceID })!
            return .init(reference: .init(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id), quote: String(source.text.prefix(80)))
        }
        let reply = input.replies.last!
        return .init(status: .completed, proposals: [
            .init(statement: "哪些反例可以限制猜想？", ownership: .userTentative, sourceEvidence: evidence, action: badAction ? .init(title: "哪些反例", kind: .task, quote: evidence[0].quote, autoSend: true) : nil, contentKind: typed ? .question : nil),
            .init(statement: reply.parts[0].text, ownership: .aiCandidate, sourceEvidence: [], replyEvidence: [.init(attemptID: reply.attemptID, partIndex: 0, quote: reply.parts[0].text)], contentKind: typed ? .question : nil)
        ], inputTokens: 10, outputTokens: 20)
    }
}
final class DiscussionQuestionTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func setup(long: Bool = false) async throws -> (VoiceOSStore, ConversationOutcomeSnapshot) {
        let s = try VoiceOSStore(root: root, inspector: TypedOutcomeInspector()); try await s.recover()
        let history = try await s.recordUserExpression("合成讨论起点：暂未验证的猜想。")
        let id = try await s.beginConversation(sourceIDs: [history])
        let count = long ? 3 : 1
        for index in 0..<count {
            let text = "合成个人疑问第\(index + 1)轮：哪些反例可以限制猜想？" + (long ? String(repeating: "背景", count: 1500) : "")
            let source = try await s.recordUserExpression(text)
            _ = try await s.appendConversationUserSource(conversationID: id, sourceID: source, expectedVersion: index + 1)
        }
        let input = try await s.prepareConversationInput(id: id, expectedVersion: count + 1, destination: .local, scalarBudget: 12000)
        _ = try await s.performConversationReply(input, using: TypedQuestionReply())
        try await s.endConversation(id: id, expectedVersion: count + 1)
        let snapshot = try await s.prepareReusableConversationOutcome(id: id, expectedVersion: count + 2, destination: .local, scalarBudget: 12000)
        return (s, snapshot)
    }
    func testTypedDiscussionQuestionsPersistWithPersonalAndAIProvenance() async throws {
        let (s, snapshot) = try await setup(), port = TypedQuestionOutcome()
        let ids = try await s.performConversationOutcome(snapshot, using: port)
        let questions = try await s.questions(), claims = try await s.candidateClaims(), actions = try await s.actions(), origins = try await s.conversationOutcomeOrigins()
        XCTAssertEqual(questions.count, 2); XCTAssertEqual(Set(questions.map(\.seed.claimID)), Set(ids))
        XCTAssertEqual(Set(questions.map(\.seed.ownership)), ["user_tentative", "ai_candidate"])
        XCTAssertTrue(claims.allSatisfy { $0.contentKind == .question && $0.reviewState == "pending" && $0.evidenceState == "unverified" })
        XCTAssertEqual(Set(origins.map(\.referenceKind)), ["source_citation", "context_anchor"]); XCTAssertTrue(actions.isEmpty)
        let package = root.appendingPathComponent("package"), restoredRoot = root.appendingPathComponent("restored")
        try await s.exportPackage(to: package)
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: TypedOutcomeInspector())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: TypedOutcomeInspector()); try await restored.recover()
        let restoredQuestions = try await restored.questions(); XCTAssertEqual(Set(restoredQuestions.map(\.id)), Set(questions.map(\.id))); XCTAssertTrue(restoredQuestions.allSatisfy { $0.validity == "frozen" })
    }
    func testLegacyOutcomeRemainsUnclassifiedAndUpgradeCannotReextractDiscussion() async throws {
        let (s, snapshot) = try await setup(), legacy = TypedQuestionOutcome(typed: false), upgraded = TypedQuestionOutcome()
        _ = try await s.performConversationOutcome(snapshot, using: legacy)
        let claims = try await s.candidateClaims(), questions = try await s.questions()
        XCTAssertTrue(claims.allSatisfy { $0.contentKind == nil }); XCTAssertTrue(questions.isEmpty)
        do { _ = try await s.performConversationOutcome(snapshot, using: upgraded); XCTFail("reextract after schema change") } catch {}
        let calls = await upgraded.calls; XCTAssertEqual(calls, 0)
    }
    func testQuestionActionMixRejectsEntireOutcomeWithoutPartialQuestionOrAction() async throws {
        let (s, snapshot) = try await setup()
        do { _ = try await s.performConversationOutcome(snapshot, using: TypedQuestionOutcome(badAction: true)); XCTFail("mixed question action") } catch {}
        let questions = try await s.questions(), claims = try await s.candidateClaims(), actions = try await s.actions(), receipts = try await s.conversationOutcomes(conversationID: snapshot.input.conversationID)
        XCTAssertTrue(questions.isEmpty); XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(receipts.first?.state, "rejected"); XCTAssertEqual(receipts.first?.usage?["input_tokens"], 10)
    }
    func testLongSelectedDiscussionReferencesUseTheirPinnedBoundedBudget() async throws {
        let (s, snapshot) = try await setup(long: true)
        _ = try await s.performConversationOutcome(snapshot, using: TypedQuestionOutcome())
        let questions = try await s.questions(), personal = try XCTUnwrap(questions.first(where: { $0.seed.ownership == "user_tentative" }))
        XCTAssertEqual(personal.seed.context.scalarBudget, 12000); XCTAssertGreaterThan(personal.seed.context.sources.reduce(0, { $0 + $1.text.unicodeScalars.count }), 8000)
        XCTAssertEqual(personal.validity, "current")
        let transition = try await s.prepareStoredQuestionTransition(questionID: personal.id, expectedVersion: 1, to: .exploring, reason: "保留完整讨论依据继续研究")
        _ = try await s.transitionQuestion(questionID: personal.id, input: transition)
        let package = root.appendingPathComponent("long-package"); try await s.exportPackage(to: package)
    }
}
