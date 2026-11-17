import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class RecordingPresentationFailureChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-presentation-failure-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func sourceWithVersion(_ store: VoiceOSStore) async throws -> (id: String, key: String, version: String) {
        let id = try await store.recordUserExpression("这段原话用于核对失败留存。")
        let record = try await store.sources().first { $0.id == id }
        let version = try XCTUnwrap(record?.transcriptVersionID)
        let policy = try XCTUnwrap(record?.policyVersion)
        return (id, id + ":" + version + ":" + String(policy), version)
    }

    func testFailureSurvivesRestartAndClearsAfterSuccess() async throws {
        let (id, key): (String, String) = try await {
            let first = try await openStore()
            let source = try await sourceWithVersion(first)
            try await first.recordTranscriptionReviewFailure(sourceID: source.id, reason: "网络中断，可重试")
            return (source.id, source.key)
        }()
        let reopened = try await openStore()
        let stored = try await reopened.sources().first { $0.id == id }
        XCTAssertEqual(stored?.transcriptionReviewFailure?.reason, "网络中断，可重试")
        let storedMap = try await reopened.storedTranscriptionReviewFailures()
        XCTAssertEqual(storedMap[key], "网络中断，可重试")
        try await reopened.clearTranscriptionReviewFailure(sourceID: id)
        let remaining = try await reopened.storedTranscriptionReviewFailures()
        XCTAssertTrue(remaining.isEmpty)
        let reread = try await reopened.sources().first { $0.id == id }
        XCTAssertNil(reread?.transcriptionReviewFailure)
    }

    func testFailureRetiresWhenTranscriptVersionChanges() async throws {
        let store = try await openStore()
        let (id, _, version) = try await sourceWithVersion(store)
        try await store.recordTranscriptionReviewFailure(sourceID: id, reason: "模型未返回有效结果")
        let recorded = try await store.sources().first { $0.id == id }
        let text = try XCTUnwrap(recorded?.transcript)
        _ = try await store.correctTranscript(sourceID: id, expectedVersionID: version, text: text + "更正后的原话。")
        let updated = try await store.sources().first { $0.id == id }
        XCTAssertNil(updated?.transcriptionReviewFailure)
        let remaining = try await store.storedTranscriptionReviewFailures()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLegacyPresentationWithoutFailureFieldStillDecodes() throws {
        let legacy = Data(#"{"archived":false,"responseIDs":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(RecordingPresentation.self, from: legacy)
        XCTAssertNil(decoded.transcriptionReviewFailure)
    }
}
