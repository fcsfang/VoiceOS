import XCTest
import Foundation
import AVFoundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class RecordingCaptureTests: XCTestCase {
    var base:URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:base.path) { try FileManager.default.removeItem(at:base) } }
    func store(_ name:String = "root",checkpoint:@escaping @Sendable (SaveCheckpoint) throws -> Void = {_ in}) async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root:base.appendingPathComponent(name),inspector:NativeMediaInspector(),checkpoint:checkpoint); try await s.recover(); return s
    }
    func audio(_ intent:RecordingIntent) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:24000,channels:1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:12000)); buffer.frameLength = 12000
        for i in 0..<12000 { buffer.floatChannelData![0][i] = 0.01 * sin(Float(i)*0.1) }
        let file = try AVAudioFile(forWriting:intent.stagingURL,settings:format.settings)
        try file.write(from:buffer) // Synthetic tone; no device or permission request.
    }
    func testIntentPrecedesBytesAndCannotStartTwoRecordings() async throws {
        let s = try await store(), intent = try await s.beginDictation(commandID:"start")
        let same = try await s.beginDictation(commandID:"start"); XCTAssertEqual(same.sourceID,intent.sourceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath:intent.stagingURL.path))
        let sources = try await s.sources(); XCTAssertEqual(sources[0].state,"receiving"); XCTAssertEqual(sources[0].bytes,0); XCTAssertTrue(sources[0].localOnly)
        do { _ = try await s.beginDictation(); XCTFail() } catch {}
        do { try await s.exportPackage(to:base.appendingPathComponent("active")); XCTFail() } catch {}
    }
    func testStoppedSyntheticCAFSealsOnceThenQueuesLocalSpeech() async throws {
        let s = try await store(), intent = try await s.beginDictation(); try audio(intent)
        try await s.sealDictation(sourceID:intent.sourceID); try await s.sealDictation(sourceID:intent.sourceID)
        let rows = try await s.sources(); XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0].id,intent.sourceID)
        XCTAssertEqual(rows[0].state,"saved"); XCTAssertEqual(rows[0].jobState,"queued"); XCTAssertEqual(rows[0].origin,"user"); XCTAssertEqual(rows[0].speaker,"user"); XCTAssertTrue(rows[0].localOnly)
        XCTAssertEqual(try XCTUnwrap(rows[0].duration),0.5,accuracy:0.01)
        XCTAssertFalse(FileManager.default.fileExists(atPath:intent.stagingURL.path))
        let original = try await s.playableURL(sourceID:intent.sourceID); XCTAssertTrue(FileManager.default.fileExists(atPath:original.path))
        let attempts = try await s.modelAttempts(sourceID:intent.sourceID); XCTAssertTrue(attempts.isEmpty)
    }
    func testStartupNeverPromotesUnsealedBytesAndAllowsExplicitFragmentRecovery() async throws {
        var intent:RecordingIntent!
        do { let s = try await store(); intent = try await s.beginDictation(); try audio(intent) }
        let s = try await store(), before = try await s.sources()
        XCTAssertEqual(before[0].state,"interrupted"); XCTAssertNil(before[0].jobState); XCTAssertEqual(before[0].bytes,0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:intent.stagingURL.path))
        try await s.sealDictation(sourceID:intent.sourceID)
        let after = try await s.sources(); XCTAssertEqual(after[0].state,"saved")
    }
    func testEmptyAndMalformedDraftNeverReportsSaved() async throws {
        let s = try await store(), intent = try await s.beginDictation()
        try Data().write(to:intent.stagingURL)
        do { try await s.sealDictation(sourceID:intent.sourceID); XCTFail() } catch {}
        try Data("not audio".utf8).write(to:intent.stagingURL)
        do { try await s.sealDictation(sourceID:intent.sourceID); XCTFail() } catch {}
        try await s.interruptDictation(sourceID:intent.sourceID)
        let rows = try await s.sources(); XCTAssertEqual(rows[0].state,"interrupted"); XCTAssertNil(rows[0].jobState)
        XCTAssertTrue(FileManager.default.fileExists(atPath:intent.stagingURL.path))
    }
    func testSealedWindowRecoversOriginalIdentityWithoutDuplicateJob() async throws {
        var id = ""
        do {
            let s = try await store(checkpoint:{ if $0 == .sealed { throw VoiceOSError("synthetic interruption") } })
            let intent = try await s.beginDictation(); id = intent.sourceID; try audio(intent)
            do { try await s.sealDictation(sourceID:id); XCTFail() } catch {}
        }
        let s = try await store(), rows = try await s.sources(); XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0].id,id); XCTAssertEqual(rows[0].state,"saved"); XCTAssertEqual(rows[0].jobState,"queued")
        try await s.recover(); let again = try await s.sources(); XCTAssertEqual(again.count,1)
    }
    func testSavedRecordingPortableRoundtripPreservesUserOriginAndMedia() async throws {
        let s = try await store(), intent = try await s.beginDictation(); try audio(intent); try await s.sealDictation(sourceID:intent.sourceID)
        let package = base.appendingPathComponent("package"), target = base.appendingPathComponent("restored")
        try await s.exportPackage(to:package,includeMedia:true); XCTAssertEqual(try VoiceOSStore.packageSummary(at:package).version,17)
        try await VoiceOSStore.restorePackage(from:package,to:target,inspector:NativeMediaInspector())
        let restored = try await store("restored"), rows = try await restored.sources(); XCTAssertEqual(rows[0].origin,"user"); XCTAssertTrue(rows[0].localOnly); XCTAssertEqual(rows[0].state,"saved"); XCTAssertEqual(rows[0].jobState,"blocked")
        _ = try await restored.playableURL(sourceID:intent.sourceID)
    }
    func testInterruptedReservationRoundtripDoesNotInventAnOriginal() async throws {
        let s = try await store(), intent = try await s.beginDictation(); try await s.interruptDictation(sourceID:intent.sourceID)
        let package = base.appendingPathComponent("package"), target = base.appendingPathComponent("restored")
        try await s.exportPackage(to:package,includeMedia:true)
        try await VoiceOSStore.restorePackage(from:package,to:target,inspector:NativeMediaInspector())
        let restored = try await store("restored"), rows = try await restored.sources()
        XCTAssertEqual(rows[0].state,"interrupted"); XCTAssertNil(rows[0].jobState); XCTAssertEqual(rows[0].bytes,0)
        do { _ = try await restored.playableURL(sourceID:intent.sourceID); XCTFail() } catch {}
    }
    func testMediaExportDoesNotSilentlyOmitUnsealedCapturedBytes() async throws {
        let s = try await store(), intent = try await s.beginDictation(); try audio(intent); try await s.interruptDictation(sourceID:intent.sourceID)
        let full = base.appendingPathComponent("full")
        do { try await s.exportPackage(to:full,includeMedia:true); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:full.path))
        let metadata = base.appendingPathComponent("metadata"), target = base.appendingPathComponent("restored")
        try await s.exportPackage(to:metadata)
        try await VoiceOSStore.restorePackage(from:metadata,to:target,inspector:NativeMediaInspector())
        let r = try await store("restored"), rows = try await r.sources(); XCTAssertTrue(rows[0].error?.contains("暂存片段未随包迁移") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:intent.stagingURL.path))
    }
    @MainActor
    func testInvalidTimedLimitFailsBeforePermissionOrDeviceCreation() throws {
        let recorder = NativeDictation(), file = base.appendingPathComponent("not-created.caf")
        for seconds in [0.0,-1.0,Double.infinity,Double.nan,61.0] {
            XCTAssertThrowsError(try recorder.start(at:file,maximumDuration:seconds) { _ in XCTFail("invalid duration must not begin capture") })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
}
