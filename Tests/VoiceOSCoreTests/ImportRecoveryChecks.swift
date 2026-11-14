import XCTest
import AVFoundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class ImportRecoveryChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-import-recovery-" + UUID().uuidString) }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func writeAudio(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        buffer.frameLength = 2400
        for index in 0..<2400 { buffer.floatChannelData![0][index] = 0.01 * sin(Float(index) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func insertSource(_ db: Database, commandID: String, input: URL, state: String, staging: Bool) throws -> String {
        let (bytes, hash) = try DurableFiles.hash(input)
        let extensionName = input.pathExtension.lowercased()
        let id = UUID().uuidString, asset = UUID().uuidString
        let relative = "assets/\(asset).\(extensionName)"
        let fingerprint = "\(hash):\(bytes):\(extensionName):\(input.lastPathComponent)"
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,origin,speaker,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [id, commandID, fingerprint, asset, UUID().uuidString, input.lastPathComponent, "unknown", "external", "unknown", state, ISO8601DateFormatter().string(from: Date()), TimeZone.current.identifier, String(bytes), hash, relative])
        if staging {
            let stagingURL = root.appendingPathComponent("staging/\(asset).part.\(extensionName)")
            try FileManager.default.copyItem(at: input, to: stagingURL)
        }
        return id
    }

    func testInterruptedImportResumesSameCommand() async throws {
        let store = try await openStore()
        let input = root.appendingPathComponent("retry.caf")
        try writeAudio(input)
        let db = await store.db
        let id = try insertSource(db, commandID: "retry-command", input: input, state: "interrupted", staging: false)
        let stale = try await store.importedSourceID(commandID: "retry-command")
        XCTAssertNil(stale)
        let imported = try await store.importFile(input, commandID: "retry-command")
        XCTAssertEqual(imported, id)
        let resolved = try await store.importedSourceID(commandID: "retry-command")
        XCTAssertEqual(resolved, id)
        let sources = try await store.sources()
        let source = try XCTUnwrap(sources.first { $0.id == id })
        XCTAssertEqual(source.state, "saved")
        XCTAssertNil(source.error)
        XCTAssertEqual(try db.query("SELECT state FROM jobs WHERE source_id=?", [id]).first?["state"], "queued")
    }

    func testSealedImportResumesFromStagedCopy() async throws {
        let store = try await openStore()
        let input = root.appendingPathComponent("sealed-import.caf")
        try writeAudio(input)
        let db = await store.db
        let id = try insertSource(db, commandID: "sealed-import-command", input: input, state: "sealed", staging: true)
        let stale = try await store.importedSourceID(commandID: "sealed-import-command")
        XCTAssertNil(stale)
        let imported = try await store.importFile(input, commandID: "sealed-import-command")
        XCTAssertEqual(imported, id)
        let sources = try await store.sources()
        let source = try XCTUnwrap(sources.first { $0.id == id })
        XCTAssertEqual(source.state, "saved")
        XCTAssertNil(source.error)
        XCTAssertEqual(try db.query("SELECT state FROM jobs WHERE source_id=?", [id]).first?["state"], "queued")
    }

    func testRecoverQuarantinesSavedSourceWithMissingOriginal() async throws {
        let id: String
        do {
            let store = try await openStore()
            let input = root.appendingPathComponent("missing.caf")
            try writeAudio(input)
            id = try await store.importFile(input, commandID: "missing-command")
            let sources = try await store.sources()
            let relative = try XCTUnwrap(sources.first { $0.id == id }?.relativePath)
            try FileManager.default.removeItem(at: root.appendingPathComponent(relative))
        }
        let reopened = try await openStore()
        let sources = try await reopened.sources()
        let source = try XCTUnwrap(sources.first { $0.id == id })
        XCTAssertEqual(source.state, "quarantined")
        XCTAssertEqual(source.error, "受管原件缺失")
    }

    func testRecoverRecordsErrorWithoutQuarantineOnSizeMismatch() async throws {
        let id: String
        let relative: String
        do {
            let store = try await openStore()
            let input = root.appendingPathComponent("mismatch.caf")
            try writeAudio(input)
            id = try await store.importFile(input, commandID: "mismatch-command")
            let sources = try await store.sources()
            relative = try XCTUnwrap(sources.first { $0.id == id }?.relativePath)
        }
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(relative))
        _ = try handle.seekToEnd(); try handle.write(contentsOf: Data([0x00])); try handle.synchronize(); try handle.close()
        let reopened = try await openStore()
        let sources = try await reopened.sources()
        let source = try XCTUnwrap(sources.first { $0.id == id })
        XCTAssertEqual(source.state, "saved")
        XCTAssertEqual(source.error, "原件核对失败，可在处理情况页重试")
    }

    func testReverifySourceClearsErrorOnlyAfterFullCheck() async throws {
        let store = try await openStore()
        let input = root.appendingPathComponent("reverify.caf")
        try writeAudio(input)
        let id = try await store.importFile(input, commandID: "reverify-command")
        let db = await store.db
        let row = try XCTUnwrap(try db.query("SELECT expected_hash FROM sources WHERE id=?", [id]).first)
        try db.execute("UPDATE sources SET expected_hash=?,error=? WHERE id=?", [String(repeating: "0", count: 64), "原件核对失败，可在处理情况页重试", id])
        let failed = try await store.reverifySource(id: id)
        XCTAssertFalse(failed)
        XCTAssertEqual(try db.query("SELECT state FROM sources WHERE id=?", [id]).first?["state"], "saved")
        XCTAssertEqual(try db.query("SELECT error FROM sources WHERE id=?", [id]).first?["error"], "原件核对失败，可在处理情况页重试")
        try db.execute("UPDATE sources SET expected_hash=? WHERE id=?", [row["expected_hash"]!, id])
        let verified = try await store.reverifySource(id: id)
        XCTAssertTrue(verified)
        XCTAssertNil(try db.query("SELECT error FROM sources WHERE id=?", [id]).first?["error"])
    }

    func testSealedDictationContinuesAndInterrupts() async throws {
        let store = try await openStore()
        let continuation = try await store.beginDictation(commandID: "sealed-dictation")
        try writeAudio(continuation.stagingURL)
        let db = await store.db
        let sealedHash = try DurableFiles.hash(continuation.stagingURL)
        try db.execute("UPDATE sources SET state='sealed',expected_bytes=?,expected_hash=?,duration=?,kind='audio' WHERE id=?",
                       [String(sealedHash.0), sealedHash.1, "1.0", continuation.sourceID])
        try await store.sealDictation(sourceID: continuation.sourceID)
        let sources = try await store.sources()
        let saved = try XCTUnwrap(sources.first { $0.id == continuation.sourceID })
        XCTAssertEqual(saved.state, "saved")
        XCTAssertNil(saved.error)
        XCTAssertEqual(try db.query("SELECT state FROM jobs WHERE source_id=?", [continuation.sourceID]).first?["state"], "queued")

        let interrupted = try await store.beginDictation(commandID: "interrupt-sealed")
        try writeAudio(interrupted.stagingURL)
        let interruptedHash = try DurableFiles.hash(interrupted.stagingURL)
        try db.execute("UPDATE sources SET state='sealed',expected_bytes=?,expected_hash=?,duration=?,kind='audio' WHERE id=?",
                       [String(interruptedHash.0), interruptedHash.1, "1.0", interrupted.sourceID])
        try await store.interruptDictation(sourceID: interrupted.sourceID)
        let row = try XCTUnwrap(try db.query("SELECT state,error FROM sources WHERE id=?", [interrupted.sourceID]).first)
        XCTAssertEqual(row["state"], "interrupted")
        XCTAssertEqual(row["error"], "录制未正常封存，片段保留待核对；未显示保存成功")
    }
}
