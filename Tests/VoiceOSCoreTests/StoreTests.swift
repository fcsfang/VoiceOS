import XCTest
import Foundation
@testable import VoiceOSCore

private struct Inspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo {
        guard try Data(contentsOf: url).starts(with: Data("fixture:".utf8)) else { throw VoiceOSError("invalid fixture") }
        return MediaInfo(duration: 1, kind: "audio")
    }
}
private struct Speech: SpeechPort {
    let text: String
    func transcribe(_ url: URL, locale: String) async throws -> String { text }
}
private struct FailedSpeech: SpeechPort {
    func transcribe(_ url: URL, locale: String) async throws -> String { throw VoiceOSError("backend unavailable") }
}
final class StoreTests: XCTestCase {
    private var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceOS-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func fixture(_ text: String = "fixture:independent test") throws -> URL {
        let url = base.appendingPathComponent("input.wav")
        try Data(text.utf8).write(to: url)
        return url
    }
    private func store() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: base.appendingPathComponent("store"), inspector: Inspector())
        try await store.recover()
        return store
    }
    func testSameCommandIsIdempotentButNewCommandKeepsDistinctEvent() async throws {
        let store = try await store(); let input = try fixture()
        let a = try await store.importFile(input, commandID: "one")
        let replay = try await store.importFile(input, commandID: "one")
        let b = try await store.importFile(input, commandID: "two")
        XCTAssertEqual(a, replay); XCTAssertNotEqual(a, b)
        let rows = try await store.sources()
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows.allSatisfy { $0.state == "saved" && $0.jobState == "queued" })
        let integrity = try await store.integrityCheck(); XCTAssertTrue(integrity)
    }
    func testCommandContentChangeRejected() async throws {
        let store = try await store(); let input = try fixture()
        _ = try await store.importFile(input, commandID: "one")
        try Data("fixture:changed".utf8).write(to: input)
        do { _ = try await store.importFile(input, commandID: "one"); XCTFail("must reject changed command") } catch {}
        let rows = try await store.sources(); XCTAssertEqual(rows.count, 1)
    }
    func testOwnedOriginalSurvivesInputRemoval() async throws {
        let store = try await store(); let input = try fixture(); let original = try Data(contentsOf: input)
        let id = try await store.importFile(input)
        try FileManager.default.removeItem(at: input)
        let saved = try await store.playableURL(sourceID: id)
        XCTAssertEqual(try Data(contentsOf: saved), original)
    }
    func testCorruptionBlocksProcessingAndHidesTranscript() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "retained"))
        let url = try await store.playableURL(sourceID: id)
        try Data("broken".utf8).write(to: url)
        do { _ = try await store.playableURL(sourceID: id); XCTFail("must quarantine") } catch {}
        let row = try await store.sources().first!
        XCTAssertEqual(row.state, "quarantined"); XCTAssertEqual(row.jobState, "blocked"); XCTAssertNil(row.transcript)
    }
    func testEmptyTranscriptIsCompletedNotInventedSpeech() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: ""))
        let row = try await store.sources().first!
        XCTAssertEqual(row.jobState, "completed"); XCTAssertEqual(row.transcript, "")
        try await store.processTranscriptions(using: Speech(text: "must not replace"))
        let again = try await store.sources().first!; XCTAssertEqual(again.transcript, "")
    }
    func testFailedTranscriptionRequiresExplicitRetry() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: FailedSpeech())
        let failed = try await store.sources().first!; XCTAssertEqual(failed.jobState, "failed")
        try await store.retryTranscription(sourceID: id)
        try await store.processTranscriptions(using: Speech(text: "恢复的文字"))
        let row = try await store.sources().first!; XCTAssertEqual(row.transcript, "恢复的文字"); XCTAssertEqual(row.jobState, "completed")
    }
    func testInvalidMediaNeverQueuesJob() async throws {
        let store = try await store()
        do { _ = try await store.importFile(fixture("not a fixture")); XCTFail("must fail validation") } catch {}
        let row = try await store.sources().first!; XCTAssertEqual(row.state, "interrupted"); XCTAssertNil(row.jobState)
    }
    func testSecondStoreCannotOwnSameRoot() async throws {
        let first = try await store()
        do { _ = try VoiceOSStore(root: base.appendingPathComponent("store"), inspector: Inspector()); XCTFail("must reject another writer") } catch {}
        let integrity = try await first.integrityCheck(); XCTAssertTrue(integrity)
    }
    func testStructuredRestoreRetainsIdentityTextButDoesNotPretendMediaExists() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "原始逐字稿"))
        let package = base.appendingPathComponent("structured")
        try await store.exportPackage(to: package)
        let target = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let row = try await restored.sources().first!
        XCTAssertEqual(row.id, id); XCTAssertEqual(row.state, "reference_only"); XCTAssertEqual(row.transcript, "原始逐字稿")
        do { _ = try await restored.playableURL(sourceID: id); XCTFail("missing media must not play") } catch {}
    }
    func testMediaRestorePreservesBytesAndPausesPendingWork() async throws {
        let store = try await store(); let input = try fixture(); let bytes = try Data(contentsOf: input)
        let id = try await store.importFile(input)
        let package = base.appendingPathComponent("full")
        try await store.exportPackage(to: package, includeMedia: true)
        let target = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let row = try await restored.sources().first!
        XCTAssertEqual(row.id, id); XCTAssertEqual(row.state, "saved"); XCTAssertEqual(row.jobState, "blocked")
        let url = try await restored.playableURL(sourceID: id); XCTAssertEqual(try Data(contentsOf: url), bytes)
        try await restored.processTranscriptions(using: Speech(text: "must stay paused"))
        let unchanged = try await restored.sources().first!; XCTAssertNil(unchanged.transcript)
    }
    func testDamagedPackageRejectedBeforeDestinationExists() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let package = base.appendingPathComponent("full"); try await store.exportPackage(to: package, includeMedia: true)
        try Data("corrupted".utf8).write(to: package.appendingPathComponent("sources.jsonl"))
        let target = base.appendingPathComponent("restored")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("must reject damage") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testRestoreRefusesExistingDestination() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let package = base.appendingPathComponent("full"); try await store.exportPackage(to: package, includeMedia: true)
        let target = base.appendingPathComponent("store")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("must not overwrite") } catch {}
        let rows = try await store.sources(); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].state, "saved")
    }
    func testManifestTraversalRejected() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let package = base.appendingPathComponent("full"); try await store.exportPackage(to: package)
        let manifest = package.appendingPathComponent("manifest.json")
        var content = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        var files = content["files"] as! [[String: Any]]; files[0]["path"] = "../input.wav"; content["files"] = files
        try JSONSerialization.data(withJSONObject: content).write(to: manifest)
        let target = base.appendingPathComponent("restored")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("must reject traversal") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testPackageSymlinkRejected() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let package = base.appendingPathComponent("full"); try await store.exportPackage(to: package)
        let file = package.appendingPathComponent("sources.jsonl"); let outside = base.appendingPathComponent("outside.jsonl")
        try FileManager.default.moveItem(at: file, to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do { try await VoiceOSStore.restorePackage(from: package, to: base.appendingPathComponent("restored"), inspector: Inspector()); XCTFail("must reject symlink") } catch {}
    }

    func testUnicodeAndEmbeddedNullRoundTrip() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let expected = "中文🙂\0之后仍保留"
        try await store.processTranscriptions(using: Speech(text: expected))
        let row = try await store.sources().first!; XCTAssertEqual(row.transcript, expected)
        let package = base.appendingPathComponent("structured"); try await store.exportPackage(to: package)
        let target = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let restoredRow = try await restored.sources().first!; XCTAssertEqual(restoredRow.transcript, expected)
    }

}
