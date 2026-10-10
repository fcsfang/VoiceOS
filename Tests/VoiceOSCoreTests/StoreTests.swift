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
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText { SpeechText(text: text) }
}
private struct FailedSpeech: SpeechPort {
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText { throw VoiceOSError("backend unavailable") }
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

    func testCorrectionPreservesOriginalAndRejectsStaleVersion() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "识别有误"))
        let original = try await store.sources().first!
        let version = try await store.correctTranscript(sourceID: id, expectedVersionID: original.transcriptVersionID!, text: "识别正确", commandID: "correction-one")
        let replay = try await store.correctTranscript(sourceID: id, expectedVersionID: original.transcriptVersionID!, text: "识别正确", commandID: "correction-one")
        XCTAssertEqual(version, replay)
        do { _ = try await store.correctTranscript(sourceID: id, expectedVersionID: original.transcriptVersionID!, text: "过期编辑"); XCTFail("must reject stale editor") } catch {}
        let current = try await store.sources().first!
        XCTAssertEqual(current.transcript, "识别正确"); XCTAssertEqual(current.transcriptVersionID, version)
        let history = try await store.transcriptHistory(sourceID: id)
        XCTAssertEqual(history.count, 2); XCTAssertEqual(history[1].text, "识别有误"); XCTAssertEqual(history[0].reason, "transcription_error")
        let oldTrusted = try await store.isCurrentTranscriptVersion(original.transcriptVersionID!); XCTAssertFalse(oldTrusted)
        let newTrusted = try await store.isCurrentTranscriptVersion(version); XCTAssertTrue(newTrusted)
        let package = base.appendingPathComponent("corrected-package"); try await store.exportPackage(to: package, includeMedia: true)
        let target = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let restoredHistory = try await restored.transcriptHistory(sourceID: id)
        XCTAssertEqual(restoredHistory.map(\.id), history.map(\.id)); XCTAssertEqual(restoredHistory.map(\.text), history.map(\.text))
    }
    func testInvalidTranscriptOffsetsAndTimesRejected() throws {
        XCTAssertThrowsError(try SpeechText(text: "🙂中", spans: [TranscriptSpan(textStart: 0, textEnd: 3)]).validate(duration: 1))
        XCTAssertThrowsError(try SpeechText(text: "🙂中", spans: [TranscriptSpan(textStart: 0, textEnd: 2, startMS: 0, endMS: 2000)]).validate(duration: 1))
        XCTAssertNoThrow(try SpeechText(text: "🙂中", spans: [TranscriptSpan(textStart: 0, textEnd: 2, startMS: 0, endMS: 800)]).validate(duration: 1))
    }

    func testRestoreRejectsMissingRevisionEvenWhenPackageHashesMatch() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "原稿"))
        let original = try await store.sources().first!
        _ = try await store.correctTranscript(sourceID: id, expectedVersionID: original.transcriptVersionID!, text: "更正稿")
        let package = base.appendingPathComponent("broken-history")
        try await store.exportPackage(to: package)
        let revisionFile = package.appendingPathComponent("transcript_revisions.jsonl")
        try Data().write(to: revisionFile)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
        var counts = manifest["counts"] as! [String: Int]; counts["transcript_revisions"] = 0; manifest["counts"] = counts
        var files = manifest["files"] as! [[String: Any]]
        let index = files.firstIndex { $0["path"] as? String == "transcript_revisions.jsonl" }!
        let digest = try DurableFiles.hash(revisionFile)
        files[index]["bytes"] = digest.0; files[index]["sha256"] = digest.1; manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let target = base.appendingPathComponent("must-not-restore")
        do {
            try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
            XCTFail("matching checksums must not conceal a missing correction receipt")
        } catch { XCTAssertTrue(error.localizedDescription.contains("版本链")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testLocalContextRetainsExternalIdentityAndRejectsStaleInput() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "外部材料中的观点🙂"))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        XCTAssertEqual(context.sources[0].origin, "external")
        XCTAssertEqual(context.sources[0].speaker, "unknown")
        XCTAssertTrue(context.sources[0].localOnly)
        XCTAssertEqual(context.sources[0].text, "外部材料中的观点🙂")
        try await store.validateLocalTranscriptContext(context)
        _ = try await store.correctTranscript(sourceID: id, expectedVersionID: context.sources[0].transcriptVersionID, text: "更正的材料")
        do { try await store.validateLocalTranscriptContext(context); XCTFail("old async input must fail revalidation") } catch {}
        let current = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        try await store.validateLocalTranscriptContext(current)
        XCTAssertNotEqual(current.contentDigest, context.contentDigest)
    }
    func testLocalContextRejectsPartialSelectionAndBudgetOverflow() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        do { _ = try await store.prepareLocalTranscriptContext(sourceIDs: [id]); XCTFail("untranscribed input must fail") } catch {}
        try await store.processTranscriptions(using: Speech(text: "🙂中"))
        let exact = try await store.prepareLocalTranscriptContext(sourceIDs: [id], scalarBudget: 2)
        XCTAssertEqual(exact.sources[0].text, "🙂中")
        for ids in [[id,id], [id,UUID().uuidString], []] {
            do { _ = try await store.prepareLocalTranscriptContext(sourceIDs: ids); XCTFail("selection must fail atomically") } catch {}
        }
        do { _ = try await store.prepareLocalTranscriptContext(sourceIDs: [id], scalarBudget: 1); XCTFail("do not silently truncate") } catch {}
    }
    func testLocalContextRejectsTamperedTextAndQuarantinedSource() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "原始材料"))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as! [String: Any]
        var sources = raw["sources"] as! [[String: Any]]; sources[0]["text"] = "篡改材料"; raw["sources"] = sources
        let tampered = try JSONDecoder().decode(LocalTranscriptContext.self, from: JSONSerialization.data(withJSONObject: raw))
        do { try await store.validateLocalTranscriptContext(tampered); XCTFail("must reject altered snapshot") } catch {}
        let file = try await store.playableURL(sourceID: id)
        try Data("damaged".utf8).write(to: file)
        do { try await store.validateLocalTranscriptContext(context); XCTFail("quarantine must block old input") } catch {}
        let row = try await store.sources().first!; XCTAssertEqual(row.state, "quarantined")
    }

}
