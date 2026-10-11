import XCTest
@testable import VoiceOSCore

final class QuestionStoreTests: XCTestCase {
    var fixture: QuestionLifecycleTests!
    override func setUpWithError() throws { fixture = QuestionLifecycleTests(); try fixture.setUpWithError() }
    override func tearDownWithError() throws { try fixture.tearDownWithError() }
    func firstQuestion(_ store: VoiceOSStore) async throws -> QuestionRecord {
        let items = try await store.questions()
        return try XCTUnwrap(items.first)
    }
    func testAtomicRegistrationAndEndorsementPreserveQuestionIdentity() async throws {
        let (s, claim, quote) = try await fixture.fixture(contentKind: .question)
        let original = try await firstQuestion(s)
        XCTAssertEqual(original.seed.claimID, claim); XCTAssertEqual(original.status, .open)
        let seed = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 0, original: quote)
        let duplicateID = try await s.registerQuestion(seed); XCTAssertEqual(duplicateID, original.id)
        _ = try await s.reviewClaim(claimID: claim, expectedVersion: 0, action: .endorse)
        let endorsed = try await firstQuestion(s)
        XCTAssertEqual(endorsed.id, original.id); XCTAssertEqual(endorsed.validity, "current")
        let transition = try await s.prepareStoredQuestionTransition(questionID: original.id, expectedVersion: 1, to: .exploring, reason: "我决定继续研究")
        XCTAssertEqual(transition.seed.claimReviewVersion, 1)
        _ = try await s.transitionQuestion(questionID: original.id, input: transition)
        let claimNow = try await s.candidateClaims().first
        XCTAssertEqual(claimNow?.reviewState, "endorsed"); XCTAssertEqual(claimNow?.evidenceState, "unverified")
    }
    func testResolveReplayConflictReopenAndAnswerCorrectionFreeze() async throws {
        let (s, _, _) = try await fixture.fixture(contentKind: .question)
        let question = try await firstQuestion(s)
        let answer = try await fixture.evidence(s, text: "我找到反例，已登记答案；这不代表客观验证。")
        let resolution = try await s.prepareStoredQuestionTransition(questionID: question.id, expectedVersion: 1, to: .resolved, reason: "我报告解决", resolution: answer)
        let stale = try await s.prepareStoredQuestionTransition(questionID: question.id, expectedVersion: 1, to: .closed, reason: "旧预览")
        let next = try await s.transitionQuestion(questionID: question.id, input: resolution, commandID: "resolve-once")
        XCTAssertEqual(next, 2)
        let replay = try await s.transitionQuestion(questionID: question.id, input: resolution, commandID: "resolve-once"); XCTAssertEqual(replay, 2)
        do { _ = try await s.transitionQuestion(questionID: question.id, input: stale); XCTFail("stale writer") } catch {}
        do { _ = try await s.transitionQuestion(questionID: question.id, input: stale, commandID: "resolve-once"); XCTFail("changed command") } catch {}
        let reopen = try await s.prepareStoredQuestionTransition(questionID: question.id, expectedVersion: 2, to: .open, reason: "我发现答案需要重新研究")
        _ = try await s.transitionQuestion(questionID: question.id, input: reopen)
        let histories = try await s.questionHistory(questionID: question.id); XCTAssertEqual(histories.count, 2)
        _ = try await s.correctTranscript(sourceID: answer.reference.sourceID, expectedVersionID: answer.reference.transcriptVersionID, text: "更正：此前反例错误。")
        let frozen = try await s.questions().first; XCTAssertEqual(frozen?.validity, "frozen"); XCTAssertEqual(frozen?.status, .open)
    }
    func testLegacyNotClassifiedAndAIIdentityPreserved() async throws {
        let (s, claim, quote) = try await fixture.fixture()
        let legacyQuestions = try await s.questions(); XCTAssertTrue(legacyQuestions.isEmpty)
        let seed = try await s.prepareQuestionSeed(claimID: claim, expectedReviewVersion: 0, original: quote)
        do { _ = try await s.registerQuestion(seed); XCTFail("legacy question guessed") } catch {}
        try fixture.tearDownWithError(); try fixture.setUpWithError()
        let (aiStore, _, _) = try await fixture.fixture(ownership: .aiCandidate, contentKind: .question)
        let ai = try await aiStore.questions().first; XCTAssertEqual(ai?.seed.ownership, "ai_candidate")
    }
    func testCorrectionAndPolicyEpochFreezeExistingIdentity() async throws {
        let (s, claim, quote) = try await fixture.fixture(contentKind: .question)
        let question = try await firstQuestion(s)
        let pending = try await s.prepareStoredQuestionTransition(questionID: question.id, expectedVersion: 1, to: .closed, reason: "我停止追踪")
        _ = try await s.setSourceLocalOnly(sourceID: quote.reference.sourceID, expectedVersion: 1, localOnly: false)
        _ = try await s.setSourceLocalOnly(sourceID: quote.reference.sourceID, expectedVersion: 2, localOnly: true)
        do { _ = try await s.transitionQuestion(questionID: question.id, input: pending); XCTFail("late revoked preview") } catch {}
        let frozen = try await s.questions().first; XCTAssertEqual(frozen?.validity, "frozen")
        // Separate fixture verifies content correction, rather than relying on revoked provenance.
        try fixture.tearDownWithError(); try fixture.setUpWithError()
        let (s2, claim2, _) = try await fixture.fixture(contentKind: .question)
        _ = try await s2.reviewClaim(claimID: claim2, expectedVersion: 0, action: .correct, statement: "更正后的其他疑问", note: "原分类不再沿用")
        let corrected = try await s2.questions().first; XCTAssertEqual(corrected?.validity, "frozen")
        XCTAssertFalse(claim.isEmpty)
    }
    func testPackageRoundTripRetainsStatusButFreezesAuthorityAndTamperRejected() async throws {
        let (s, _, _) = try await fixture.fixture(contentKind: .question)
        let q = try await firstQuestion(s)
        let input = try await s.prepareStoredQuestionTransition(questionID: q.id, expectedVersion: 1, to: .closed, reason: "明确停止追踪")
        _ = try await s.transitionQuestion(questionID: q.id, input: input, commandID: "close")
        let package = fixture.root.appendingPathComponent("package"), restoredRoot = fixture.root.appendingPathComponent("restored")
        try await s.exportPackage(to: package)
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: QuestionInspectorForStore())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: QuestionInspectorForStore()); try await restored.recover()
        let record = try await restored.questions().first
        XCTAssertEqual(record?.id, q.id); XCTAssertEqual(record?.version, 2); XCTAssertEqual(record?.status, .closed); XCTAssertEqual(record?.validity, "frozen")
        // Independent SQL tampering with a coherent SQLite file must fail semantic recovery.
        let db = try Database(restoredRoot.appendingPathComponent("voiceos.sqlite")); try db.execute("UPDATE questions SET status='resolved'")
        do { _ = try await restored.questions(); XCTFail("unbacked state") } catch {}
    }
    func testSchema23UpgradeDoesNotBackfillLegacyQuestionIdentity() async throws {
        let file = fixture.root.appendingPathComponent("legacy23.sqlite")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        do {
            let db = try Database(file)
            try db.execute("DROP TABLE question_revisions"); try db.execute("DROP TABLE questions"); try db.execute("PRAGMA user_version=23")
        }
        let db = try Database(file)
        XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], "24")
        XCTAssertTrue(try db.query("SELECT * FROM questions").isEmpty)
        XCTAssertTrue(try db.query("PRAGMA foreign_key_check").isEmpty)
    }
    func testRehashedPortableQuestionStateTamperIsRejected() async throws {
        let (store, _, _) = try await fixture.fixture(contentKind: .question)
        let package = fixture.root.appendingPathComponent("tampered-package")
        try await store.exportPackage(to: package)
        let file = package.appendingPathComponent("questions.jsonl")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        row["status"] = "resolved"
        try (JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])).write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any])
        var files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        let index = try XCTUnwrap(files.firstIndex(where: { $0["path"] as? String == "questions.jsonl" }))
        let hash = try DurableFiles.hash(file); files[index]["bytes"] = hash.0; files[index]["sha256"] = hash.1
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let destination = fixture.root.appendingPathComponent("tampered-restored")
        do { try await VoiceOSStore.restorePackage(from: package, to: destination, inspector: QuestionInspectorForStore()); XCTFail("state without revision accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testTransitionRollbackAndCommittedCrashReplay() async throws {
        for checkpoint in [SaveCheckpoint.questionUncommitted, .questionCommitted] {
            try fixture.tearDownWithError(); try fixture.setUpWithError()
            let latch = QuestionFaultLatch(checkpoint)
            let (s, _, _) = try await fixture.fixture(contentKind: .question, checkpoint: { try latch.trigger($0) }), q = try await firstQuestion(s)
            let input = try await s.prepareStoredQuestionTransition(questionID: q.id, expectedVersion: 1, to: .closed, reason: "停止")
            do { _ = try await s.transitionQuestion(questionID: q.id, input: input, commandID: "same-command"); XCTFail("fault") } catch {}
            let after = try await s.questions().first
            XCTAssertEqual(after?.version, checkpoint == .questionCommitted ? 2 : 1)
            _ = try await s.transitionQuestion(questionID: q.id, input: input, commandID: "same-command")
            let history = try await s.questionHistory(questionID: q.id); XCTAssertEqual(history.count, 1)
        }
    }
}
private struct QuestionInspectorForStore: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text only") }
}

private final class QuestionFaultLatch: @unchecked Sendable {
    let point: SaveCheckpoint
    private let lock = NSLock()
    private var fired = false
    init(_ point: SaveCheckpoint) { self.point = point }
    func trigger(_ value: SaveCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        if value == point && !fired { fired = true; throw VoiceOSError("simulated interruption") }
    }
}
