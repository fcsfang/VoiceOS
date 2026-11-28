import XCTest
import AVFoundation
@testable import VoiceOSCore
import VoiceOSPlatform

private struct SilentSpeech: SpeechPort {
    let backendIdentity = "Qwen3-ASR-empty-fixture"
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        SpeechText(text: " \n ")
    }
}

private struct SpeakingSpeech: SpeechPort {
    let backendIdentity = "Qwen3-ASR-empty-fixture"
    let text: String
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        SpeechText(text: text)
    }
}

extension CoreFlowTests {
    private func openStoreForEmptyTranscriptChecks() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func dictation(_ store: VoiceOSStore) async throws -> String {
        let intent = try await store.beginDictation()
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12000)!
        buffer.frameLength = 12000
        for i in 0..<12000 { buffer.floatChannelData![0][i] = 0.01 * sin(Float(i) * 0.1) }
        do { let file = try AVAudioFile(forWriting: intent.stagingURL, settings: format.settings); try file.write(from: buffer) }
        try await store.sealDictation(sourceID: intent.sourceID)
        return intent.sourceID
    }
    private func sourceRecord(_ store: VoiceOSStore, id: String) async throws -> SourceRecord {
        let sources = try await store.sources()
        return try XCTUnwrap(sources.first { $0.id == id })
    }

    func testEmptyTranscriptMarksJobForReview() async throws {
        let store = try await openStoreForEmptyTranscriptChecks()
        let id = try await dictation(store)
        try await store.processTranscriptions(using: SilentSpeech())
        let record = try await sourceRecord(store, id: id)
        XCTAssertEqual(record.jobState, "blocked")
        XCTAssertEqual(record.error, SourceRecord.emptyTranscriptJobError)
        XCTAssertNil(record.transcript)
        XCTAssertTrue(record.needsEmptyTranscriptionReview)
    }

    func testNonEmptyTranscriptStaysCompleted() async throws {
        let store = try await openStoreForEmptyTranscriptChecks()
        let id = try await dictation(store)
        let text = "我认为检索质量比记忆容量更值得研究。"
        try await store.processTranscriptions(using: SpeakingSpeech(text: text))
        let record = try await sourceRecord(store, id: id)
        XCTAssertEqual(record.jobState, "completed")
        XCTAssertEqual(record.transcript, text)
        XCTAssertNil(record.error)
        XCTAssertFalse(record.needsEmptyTranscriptionReview)
    }

    func testBlockedEmptyTranscriptRetriesThroughExistingChannel() async throws {
        let store = try await openStoreForEmptyTranscriptChecks()
        let id = try await dictation(store)
        try await store.processTranscriptions(using: SilentSpeech())
        try await store.retryTranscription(sourceID: id)
        let other = try await dictation(store)
        let text = "重新转写得到的文字。"
        try await store.processTranscriptions(using: SpeakingSpeech(text: text), sourceIDs: [])
        let stillQueued = try await sourceRecord(store, id: id)
        XCTAssertEqual(stillQueued.jobState, "queued")
        try await store.processTranscriptions(using: SpeakingSpeech(text: text), sourceIDs: [id, id])
        let record = try await sourceRecord(store, id: id)
        let unrelated = try await sourceRecord(store, id: other)
        XCTAssertEqual(record.jobState, "completed")
        XCTAssertEqual(record.transcript, text)
        XCTAssertFalse(record.needsEmptyTranscriptionReview)
        XCTAssertEqual(unrelated.jobState, "queued")
        XCTAssertNil(unrelated.transcript)

        let db = await store.db
        try db.execute("""
            INSERT INTO jobs(id,source_id,input_version_id,stage,config,state)
            VALUES('obsolete-queued-job',?,?,'transcription','fixture','queued')
            """, [id, UUID().uuidString])
        let eligible = try await store.queuedTranscriptionSourceIDs()
        XCTAssertEqual(eligible, [other])
        let currentRows = try await store.sourceRecords(ids: [id])
        XCTAssertEqual(currentRows.count, 1)
        XCTAssertEqual(currentRows.first?.jobState, "completed")
        try await store.processTranscriptions(using: SpeakingSpeech(text: text))
        let remaining = try await store.queuedTranscriptionSourceIDs()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testHistoricalCompletedEmptyTranscriptIsIdentifiedAndReplaced() async throws {
        let store = try await openStoreForEmptyTranscriptChecks()
        let id = try await dictation(store)
        try await store.processTranscriptions(using: SpeakingSpeech(text: "第一版文字。"))
        let db = await store.db
        try db.execute("UPDATE transcript_versions SET text='',spans_json='[]' WHERE id=(SELECT current_version_id FROM transcripts WHERE source_id=?)", [id])
        let historical = try await sourceRecord(store, id: id)
        XCTAssertEqual(historical.jobState, "completed")
        XCTAssertTrue(historical.needsEmptyTranscriptionReview)
        try await store.retryTranscription(sourceID: id)
        let text = "重新转写恢复的文字。"
        try await store.processTranscriptions(using: SpeakingSpeech(text: text))
        let record = try await sourceRecord(store, id: id)
        XCTAssertEqual(record.jobState, "completed")
        XCTAssertEqual(record.transcript, text)
        XCTAssertFalse(record.needsEmptyTranscriptionReview)
        let history = try await store.transcriptHistory(sourceID: id)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.text, text)
        XCTAssertTrue(history.first?.isCurrent == true)
    }
}
