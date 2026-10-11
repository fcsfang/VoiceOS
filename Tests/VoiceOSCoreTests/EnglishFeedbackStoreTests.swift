import XCTest
@testable import VoiceOSCore

private struct EnglishStoreInspector: MediaInspector { func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") } }
private struct EnglishFakePort: EnglishPracticeModelPort {
    let configuration: ModelConfiguration
    let result: Result<EnglishPracticeResponse, ModelPortFailure>
    func generate(_ request: EnglishPracticeRequest) async throws -> EnglishPracticeResponse { try result.get() }
}
final class EnglishFeedbackStoreTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("english-store-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }
    func store(_ name: String = "root") async throws -> VoiceOSStore { let s = try VoiceOSStore(root: base.appendingPathComponent(name), inspector: EnglishStoreInspector()); try await s.recover(); return s }
    func setup(_ s: VoiceOSStore) async throws -> EnglishPracticeSnapshot {
        let old = try await s.recordUserExpression("Earlier practice: the model have one layer.")
        let current = try await s.recordUserExpression("The model have two layers.")
        for id in [old, current] { _ = try await s.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false) }
        return try await s.prepareEnglishPractice(currentSourceID: current, priorSourceIDs: [old], destination: .cloud)
    }
    func config() -> ModelConfiguration { .init(provider: "responses:test", model: "gpt-6.1-sol", promptVersion: "english-practice-v1", schemaVersion: "english-feedback-v1", destination: .cloud) }
    func response(_ snapshot: EnglishPracticeSnapshot) -> EnglishPracticeResponse {
        let source = snapshot.context.sources[0], ref = ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        let quote = OutcomeSourceEvidence(reference: ref, quote: source.text)
        return EnglishPracticeResponse(suggestions: [.init(kind: .grammar, original: quote, suggestedText: "The model has two layers.", explanation: "Use has with a singular subject.")], comparisons: [])
    }
    func testReserveCompleteAndReadBackKeepsIndependentRecord() async throws {
        let s = try await store(), snapshot = try await setup(s), id = try await s.reserveEnglishFeedback(snapshot, configuration: config())
        let replay = try await s.reserveEnglishFeedback(snapshot, configuration: config()); XCTAssertEqual(id, replay)
        try await s.completeEnglishFeedback(attemptID: id, response: response(snapshot))
        let rows = try await s.englishFeedbackAttempts(); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].state, "completed"); XCTAssertEqual(rows[0].result?.suggestions.count, 1)
        let claims = try await s.candidateClaims(), actions = try await s.actions(); XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty)
    }
    func testUnknownIsTerminalAndDoesNotReserveAgain() async throws {
        let s = try await store(), snapshot = try await setup(s), id = try await s.reserveEnglishFeedback(snapshot, configuration: config())
        try await s.markEnglishFeedbackUnknown(attemptID: id); let rows = try await s.englishFeedbackAttempts(); XCTAssertEqual(rows[0].state, "unknown")
        let replay = try await s.reserveEnglishFeedback(snapshot, configuration: config()), all = try await s.englishFeedbackAttempts(); XCTAssertEqual(id, replay); XCTAssertEqual(all.count, 1)
    }
    func testPerformMarksTransportFailureUnknownWithUsageAndNeverResends() async throws {
        let s = try await store(), snapshot = try await setup(s)
        let port = EnglishFakePort(configuration: config(), result: .failure(.rejected("TLS failed", inputTokens: 7, outputTokens: 0)))
        do { _ = try await s.performEnglishFeedback(snapshot, using: port); XCTFail("expected failure") } catch {}
        let rows = try await s.englishFeedbackAttempts(); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].state, "unknown"); XCTAssertEqual(rows[0].inputTokens, 7); XCTAssertEqual(rows[0].outputTokens, 0)
        let replay = try await s.performEnglishFeedback(snapshot, using: port); XCTAssertEqual(replay.state, "unknown")
        let finalRows = try await s.englishFeedbackAttempts(); XCTAssertEqual(finalRows.count, 1)
    }
    func testPackageRoundTripPreservesFeedbackButNotLiveAuthorization() async throws {
        let s = try await store(), snapshot = try await setup(s), id = try await s.reserveEnglishFeedback(snapshot, configuration: config()); try await s.completeEnglishFeedback(attemptID: id, response: response(snapshot))
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to: package); try await VoiceOSStore.restorePackage(from: package, to: base.appendingPathComponent("restored"), inspector: EnglishStoreInspector())
        let restored = try await store("restored"), rows = try await restored.englishFeedbackAttempts(), valid = try await restored.integrityCheck(); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].state, "completed"); XCTAssertTrue(valid)
    }
}
