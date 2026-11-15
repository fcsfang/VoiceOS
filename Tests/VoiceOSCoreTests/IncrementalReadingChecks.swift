import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class IncrementalReadingChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-incremental-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func insertSource(_ store: VoiceOSStore, text: String, state: String = "saved", withTranscript: Bool = true) async throws -> (sourceID: String, assetID: String, jobID: String, transcriptID: String, versionID: String) {
        let db = await store.db
        let id = UUID().uuidString, assetID = UUID().uuidString, jobID = UUID().uuidString, transcriptID = UUID().uuidString, versionID = UUID().uuidString
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?, 'external_text','unknown','external',?,?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, assetID, "version:" + id, "合成资料", state, "2026-11-01T00:00:00Z", TimeZone.current.identifier, "assets/" + id])
        try db.execute("INSERT INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,?,'0','original')", [assetID, id, "assets/" + id, "0"])
        try db.execute("INSERT INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','fixture','completed')", [jobID, id, "version:" + id])
        guard withTranscript else { return (id, assetID, jobID, transcriptID, versionID) }
        let speech = SpeechText(text: text)
        try db.execute("INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at,current_version_id) VALUES(?,?,?,?,?,'verbatim',?,'zh_CN','fixture',?,?)", [transcriptID, id, assetID, "version:" + id, jobID, text, "2026-11-01T00:00:00Z", versionID])
        try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,?, 'original','system',?)", [versionID, transcriptID, text, String(decoding: try JSONEncoder().encode(speech.spans), as: UTF8.self), "2026-11-01T00:00:00Z"])
        try db.execute("UPDATE transcripts SET current_version_id=? WHERE id=?", [versionID, transcriptID])
        return (id, assetID, jobID, transcriptID, versionID)
    }

    private func addVersion(_ db: Database, transcriptID: String, text: String, number: Int) throws -> String {
        let versionID = UUID().uuidString
        let spans = String(decoding: try JSONEncoder().encode(SpeechText(text: text).spans), as: UTF8.self)
        try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,?,?,?, 'transcription_error','user',?)", [versionID, transcriptID, String(number), text, spans, "2026-11-02T00:00:00Z"])
        try db.execute("UPDATE transcripts SET current_version_id=? WHERE id=?", [versionID, transcriptID])
        return versionID
    }

    private func assertCovers(_ chunks: [ReadingChunk], scalars: Int, targetSize: Int) {
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertEqual(chunks.last?.end, scalars)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertLessThan(chunk.start, chunk.end)
            XCTAssertLessThanOrEqual(chunk.end - chunk.start, targetSize)
            if index > 0 { XCTAssertEqual(chunk.start, chunks[index - 1].end) }
        }
    }

    func testMigrationAddsIncrementalReading() async throws {
        let store = try await openStore()
        let db = await store.db
        XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], "61")
        XCTAssertEqual(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='incremental_reading'").count, 1)
    }

    func testSplitHardCutsLongText() {
        let chunks = ReadingChunks.split(text: String(repeating: "字", count: 25), spans: [TranscriptSpan(textStart: 0, textEnd: 25)], targetSize: 10)
        XCTAssertEqual(chunks.map { [$0.start, $0.end] }, [[0, 10], [10, 20], [20, 25]])
        assertCovers(chunks, scalars: 25, targetSize: 10)
    }

    func testSplitMergesShortPiecesWithinTarget() {
        let text = "甲乙\n丙丁戊\n己"
        let chunks = ReadingChunks.split(text: text, spans: [TranscriptSpan(textStart: 0, textEnd: text.unicodeScalars.count)], targetSize: 6)
        XCTAssertEqual(chunks.map { [$0.start, $0.end] }, [[0, 3], [3, 8]])
        assertCovers(chunks, scalars: 8, targetSize: 6)
    }

    func testSplitCoversFullTextWithoutOverlap() {
        let text = "abcdef\nghi"
        let spans = [TranscriptSpan(textStart: 0, textEnd: 4), TranscriptSpan(textStart: 4, textEnd: 7), TranscriptSpan(textStart: 7, textEnd: 11)]
        let chunks = ReadingChunks.split(text: text, spans: spans, targetSize: 5)
        XCTAssertEqual(chunks.map { [$0.start, $0.end] }, [[0, 4], [4, 7], [7, 11]])
        assertCovers(chunks, scalars: 11, targetSize: 5)
    }

    func testSplitEmptyTextHasNoChunks() {
        XCTAssertTrue(ReadingChunks.split(text: "", spans: [], targetSize: 10).isEmpty)
        let chunks = ReadingChunks.split(text: "abc", spans: [], targetSize: 100)
        XCTAssertEqual(chunks.map { [$0.start, $0.end] }, [[0, 3]])
    }

    func testStartValidatesRangeSourceAndTranscript() async throws {
        let store = try await openStore()
        let saved = try await insertSource(store, text: "合成文本")
        do {
            _ = try await store.startIncrementalReading(sourceID: saved.sourceID, chunkSize: 399)
            XCTFail("块大小低于下限时不能开始")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "按天读块大小需在 400 到 4000 字之间")
        }
        do {
            _ = try await store.startIncrementalReading(sourceID: saved.sourceID, chunkSize: 4001)
            XCTFail("块大小高于上限时不能开始")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "按天读块大小需在 400 到 4000 字之间")
        }
        do {
            _ = try await store.startIncrementalReading(sourceID: UUID().uuidString)
            XCTFail("来源不存在时不能开始")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "来源不存在")
        }
        let draft = try await insertSource(store, text: "草稿", state: "reference_only")
        do {
            _ = try await store.startIncrementalReading(sourceID: draft.sourceID)
            XCTFail("未保存的来源不能开始")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "此原件尚未可靠保存")
        }
        let bare = try await insertSource(store, text: "", withTranscript: false)
        do {
            _ = try await store.startIncrementalReading(sourceID: bare.sourceID)
            XCTFail("没有转写的来源不能开始")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "此来源没有转写")
        }
        let plan = try await store.startIncrementalReading(sourceID: saved.sourceID)
        XCTAssertEqual(plan.chunkSize, 1200)
        XCTAssertEqual(plan.currentChunk, 0)
        XCTAssertEqual(plan.transcriptVersionID, saved.versionID)
        let plans = try await store.incrementalPlans()
        XCTAssertEqual(plans.map(\.sourceID), [saved.sourceID])
    }

    func testSetClampsAndAdvanceStopsAtLastChunk() async throws {
        let store = try await openStore()
        let source = try await insertSource(store, text: String(repeating: "字", count: 900))
        let started = try await store.startIncrementalReading(sourceID: source.sourceID, chunkSize: 400)
        XCTAssertEqual(started.currentChunk, 0)
        let last = try await store.setIncrementalChunk(sourceID: source.sourceID, index: 99)
        XCTAssertEqual(last.currentChunk, 2)
        let first = try await store.setIncrementalChunk(sourceID: source.sourceID, index: -5)
        XCTAssertEqual(first.currentChunk, 0)
        let advanced = try await store.advanceIncrementalChunk(sourceID: source.sourceID)
        XCTAssertTrue(advanced)
        let middle = try await store.incrementalPlan(sourceID: source.sourceID)
        XCTAssertEqual(middle?.currentChunk, 1)
        let advancedAgain = try await store.advanceIncrementalChunk(sourceID: source.sourceID)
        XCTAssertTrue(advancedAgain)
        let stopped = try await store.advanceIncrementalChunk(sourceID: source.sourceID)
        XCTAssertFalse(stopped)
        let end = try await store.incrementalPlan(sourceID: source.sourceID)
        XCTAssertEqual(end?.currentChunk, 2)
    }

    func testTranscriptVersionChangeConvergesCursor() async throws {
        let store = try await openStore()
        let db = await store.db
        let source = try await insertSource(store, text: String(repeating: "字", count: 900))
        _ = try await store.startIncrementalReading(sourceID: source.sourceID, chunkSize: 400)
        _ = try await store.setIncrementalChunk(sourceID: source.sourceID, index: 2)
        let versionID = try addVersion(db, transcriptID: source.transcriptID, text: String(repeating: "短", count: 100), number: 2)
        let plan = try await store.incrementalPlan(sourceID: source.sourceID)
        XCTAssertEqual(plan?.transcriptVersionID, versionID)
        XCTAssertEqual(plan?.currentChunk, 0)
        let row = try XCTUnwrap(try db.query("SELECT current_chunk,transcript_version_id FROM incremental_reading WHERE source_id=?", [source.sourceID]).first)
        XCTAssertEqual(row["current_chunk"], "0")
        XCTAssertEqual(row["transcript_version_id"], versionID)
    }

    func testStopIsIdempotent() async throws {
        let store = try await openStore()
        let source = try await insertSource(store, text: "合成文本")
        _ = try await store.startIncrementalReading(sourceID: source.sourceID)
        try await store.stopIncrementalReading(sourceID: source.sourceID)
        let stopped = try await store.incrementalPlan(sourceID: source.sourceID)
        XCTAssertNil(stopped)
        try await store.stopIncrementalReading(sourceID: source.sourceID)
        let plans = try await store.incrementalPlans()
        XCTAssertTrue(plans.isEmpty)
    }
}
