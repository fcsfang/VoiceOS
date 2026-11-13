import XCTest
import VoiceOSPlatform
@testable import VoiceOSCore

private actor ScriptedKnowledgeTransport: ModelHTTPTransport {
    let failures: Int
    let code: URLError.Code
    private(set) var calls = 0
    init(failures: Int, code: URLError.Code) { self.failures = failures; self.code = code }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        calls += 1
        if calls <= failures { throw URLError(code) }
        let envelope: [String: Any] = ["id": "response-\(calls)", "status": "completed", "output": [
            ["type": "message", "role": "assistant", "status": "completed",
             "content": [["type": "output_text", "text": #"{"candidates":[]}"#]]]]]
        return .init(status: 200, body: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]))
    }
}

private actor RecordedDelays {
    private(set) var values: [Duration] = []
    func record(_ value: Duration) { values.append(value) }
}

private actor ConformanceFollowup: RecordingFollowupPort {
    let alwaysInvalid: Bool
    private(set) var calls = 0
    init(alwaysInvalid: Bool = false) { self.alwaysInvalid = alwaysInvalid }
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration {
        calls += 1
        let empty = PracticeFollowup(isPractice: false, evidenceQuote: "", suggestions: [], comparisons: [], nextExercise: "")
        if alwaysInvalid || calls == 1 {
            let invalid = PracticeFollowup(isPractice: true, evidenceQuote: "", suggestions: [], comparisons: [], nextExercise: "继续练习")
            return .init(result: .init(thoughtUpdates: [], goalPlans: [], english: invalid), responseIDs: ["fixture-\(calls)"])
        }
        return .init(result: .init(thoughtUpdates: [], goalPlans: [], english: empty), responseIDs: ["fixture-\(calls)"])
    }
}

private struct PolicyFlipFollowup: RecordingFollowupPort {
    let store: VoiceOSStore
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration {
        let sourceID = input.current.sources[0].sourceID
        let policy = try await store.sourcePolicy(sourceID: sourceID)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: policy.version, localOnly: !policy.localOnly)
        let empty = PracticeFollowup(isPractice: false, evidenceQuote: "", suggestions: [], comparisons: [], nextExercise: "")
        return .init(result: .init(thoughtUpdates: [], goalPlans: [], english: empty), responseIDs: ["fixture"])
    }
}

private extension VoiceOSStore {
    func expireFollowupRetry(_ id: String) throws {
        var receipts = try recordingFollowups()
        let index = receipts.firstIndex { $0.id == id }!
        receipts[index].retryAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
        try db.execute("UPDATE sources SET followup_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(receipts.filter { $0.sourceID == receipts[index].sourceID }), as: UTF8.self), receipts[index].sourceID])
    }
}

final class RetryResilienceChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-retry-resilience-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func cloudSource(_ store: VoiceOSStore) async throws -> String {
        let id = try await store.recordUserExpression("我要继续练习英语讲解。")
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        return id
    }
    private func knowledgeInput(_ text: String) -> KnowledgeReviewInput {
        let source = ContextTranscript(sourceID: "source", sourceVersionID: "source-v1", transcriptVersionID: "transcript-v1",
                                       origin: "user", speaker: "user", localOnly: false, text: text, spans: [])
        return KnowledgeReviewInput(sourceID: "source", transcriptVersionID: "transcript-v1", policyVersion: 1,
                                    context: LocalTranscriptContext(sources: [source], scalarBudget: max(1, text.unicodeScalars.count), contentDigest: "digest"),
                                    claimReviewVersions: ["claim": 1], inputDigest: "digest")
    }

    func testKnowledgePortRetriesTransientURLErrorWithSameBackoff() async throws {
        let delays = RecordedDelays()
        let transport = ScriptedKnowledgeTransport(failures: 2, code: .secureConnectionFailed)
        let port = try ResponsesKnowledgeReviewPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture-key", model: "fixture-model",
            transport: transport, retryDelay: { await delays.record($0) })
        let selection = try await port.identify(knowledgeInput("我认为检索质量比记忆容量更值得研究。"))
        XCTAssertTrue(selection.candidates.isEmpty)
        XCTAssertEqual(selection.responseID, "response-3")
        let calls = await transport.calls
        XCTAssertEqual(calls, 3)
        let recorded = await delays.values
        XCTAssertEqual(recorded, [.seconds(5), .seconds(15)])
    }

    func testKnowledgePortPropagatesNonTransientURLErrorImmediately() async throws {
        let delays = RecordedDelays()
        let transport = ScriptedKnowledgeTransport(failures: 10, code: .badServerResponse)
        let port = try ResponsesKnowledgeReviewPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture-key", model: "fixture-model",
            transport: transport, retryDelay: { await delays.record($0) })
        do {
            _ = try await port.identify(knowledgeInput("没有需要核查的判断。"))
            XCTFail("A non-transient URLError must propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
        let recorded = await delays.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testConformanceFailureSchedulesOneRetryThenCompletes() async throws {
        let store = try await makeStore()
        let sourceID = try await cloudSource(store)
        let port = ConformanceFollowup()
        do {
            _ = try await store.processRecordingFollowup(sourceID: sourceID, using: port)
            XCTFail("A non-verbatim quote must fail validation")
        } catch { }
        let receipts = try await store.recordingFollowups()
        let failed = try XCTUnwrap(receipts.last { $0.sourceID == sourceID })
        XCTAssertEqual(failed.state, "failed")
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertTrue(failed.error?.contains("跟进结果引用不是连续原话") == true)
        let retryAt = try XCTUnwrap(failed.retryAt)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: retryAt), "The scheduler must parse the stored retry time")
        let waiting = try await store.pendingRecordingFollowups()
        XCTAssertTrue(waiting.isEmpty)
        try await store.expireFollowupRetry(failed.id)
        let ready = try await store.pendingRecordingFollowups()
        XCTAssertEqual(ready.map(\.id), [failed.id])
        let completed = try await store.processRecordingFollowup(sourceID: sourceID, using: port, retry: true)
        XCTAssertEqual(completed.id, failed.id)
        XCTAssertEqual(completed.state, "completed")
        XCTAssertEqual(completed.retryCount, 1)
        XCTAssertNil(completed.retryAt)
        let calls = await port.calls
        XCTAssertEqual(calls, 2)
    }

    func testPersistentConformanceFailureDoesNotScheduleASecondRetry() async throws {
        let store = try await makeStore()
        let sourceID = try await cloudSource(store)
        let port = ConformanceFollowup(alwaysInvalid: true)
        do { _ = try await store.processRecordingFollowup(sourceID: sourceID, using: port); XCTFail("The invalid result must fail") } catch { }
        var receipts = try await store.recordingFollowups()
        let first = try XCTUnwrap(receipts.last { $0.sourceID == sourceID })
        XCTAssertEqual(first.retryCount, 1)
        try await store.expireFollowupRetry(first.id)
        do { _ = try await store.processRecordingFollowup(sourceID: sourceID, using: port, retry: true); XCTFail("The invalid result must fail again") } catch { }
        receipts = try await store.recordingFollowups()
        let second = try XCTUnwrap(receipts.last { $0.sourceID == sourceID })
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.state, "failed")
        XCTAssertEqual(second.retryCount, 1)
        XCTAssertNil(second.retryAt)
        let calls = await port.calls
        XCTAssertEqual(calls, 2)
    }

    func testConformanceRetryHelpers() {
        let failure = RecordingFollowupConformanceFailure(underlying: VoiceOSError("引用不符"))
        XCTAssertTrue(VoiceOSStore.conformanceRetryScheduled(afterFailure: failure, retryCount: nil))
        XCTAssertFalse(VoiceOSStore.conformanceRetryScheduled(afterFailure: failure, retryCount: 1))
        XCTAssertFalse(VoiceOSStore.conformanceRetryScheduled(afterFailure: VoiceOSError("引用不符"), retryCount: nil))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let at = VoiceOSStore.conformanceRetryAt(now: now)
        XCTAssertEqual(ISO8601DateFormatter().date(from: at), now.addingTimeInterval(60))
    }

    func testSourceValidityFailureDoesNotScheduleRetry() async throws {
        let store = try await makeStore()
        let sourceID = try await cloudSource(store)
        let port = PolicyFlipFollowup(store: store)
        do {
            _ = try await store.processRecordingFollowup(sourceID: sourceID, using: port)
            XCTFail("An authorization change must fail the receipt")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("录音原话或授权已变化"))
        }
        let receipts = try await store.recordingFollowups()
        let failed = try XCTUnwrap(receipts.last { $0.sourceID == sourceID })
        XCTAssertEqual(failed.state, "failed")
        XCTAssertNil(failed.retryCount)
        XCTAssertNil(failed.retryAt)
    }
}
