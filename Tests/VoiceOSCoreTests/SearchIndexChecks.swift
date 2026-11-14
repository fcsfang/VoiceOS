import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class SearchIndexChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-search-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func insertSource(_ db: Database, name: String, transcript: String? = nil) throws -> String {
        let id = UUID().uuidString, now = "2026-11-14T00:00:00Z"
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?, 'external_text','unknown','external','saved',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, "asset:" + id, "version:" + id, name, now, TimeZone.current.identifier, "assets/" + id])
        if let transcript {
            let assetID = UUID().uuidString, jobID = UUID().uuidString, transcriptID = UUID().uuidString, versionID = UUID().uuidString
            try db.execute("INSERT INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,?,'0','original')", [assetID, id, "assets/" + id, "0"])
            try db.execute("INSERT INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','fixture','completed')", [jobID, id, "version:" + id])
            try db.execute("INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at) VALUES(?,?,?,?,?,'verbatim',?,'zh_CN','fixture',?)", [transcriptID, id, assetID, "version:" + id, jobID, transcript, now])
            try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,'[]','original','system',?)", [versionID, transcriptID, transcript, now])
            try db.execute("UPDATE transcripts SET current_version_id=? WHERE id=?", [versionID, transcriptID])
        }
        return id
    }

    private func insertClaim(_ db: Database, statement: String) throws -> String {
        let id = UUID().uuidString, contextID = UUID().uuidString, attemptID = UUID().uuidString
        try db.execute("INSERT INTO contexts(id,command_id,snapshot_json,digest,state,created_at) VALUES(?,?,?,?, 'current',?)", [contextID, "context:" + contextID, "{}", contextID, "2026-11-14T00:00:00Z"])
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at) VALUES(?,?,?,?,?,?, 'completed',?)", [attemptID, contextID, "fixture", "fixture", "v1", "v1", "2026-11-14T00:00:00Z"])
        try db.execute("INSERT INTO claims(id,attempt_id,ordinal,statement,ownership,evidence_state,validity,refs_json,created_at) VALUES(?,?,0,?, 'external','unverified','current','[]',?)", [id, attemptID, statement, "2026-11-14T00:00:00Z"])
        return id
    }

    private func insertAction(_ db: Database, claimID: String, title: String, note: String) throws -> String {
        let id = UUID().uuidString
        try db.execute("""
        INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,command_id,input_fingerprint,created_at)
        VALUES(?,?,0,?,'task','user',?,'open','current',?,?,?)
        """, [id, claimID, title, note, "action:" + id, id, "2026-11-14T00:00:00Z"])
        return id
    }

    func testMigrationCreatesSearchIndex() async throws {
        let store = try await openStore()
        let db = await store.db
        XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], "60")
        for table in ["search_index", "search_index_meta"] {
            XCTAssertEqual(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table]).count, 1)
        }
    }

    func testChineseAndEnglishHits() async throws {
        let store = try await openStore()
        let db = await store.db
        let material = try insertSource(db, name: "季度规划会议", transcript: "会议材料整理与下次复盘会的时间安排")
        let titled = try insertSource(db, name: "无转写的材料")
        let claim = try insertClaim(db, statement: "项目复盘的关键结论")
        let action = try insertAction(db, claimID: claim, title: "Review the quarterly roadmap", note: "Ask the team about roadmap priorities")
        try await store.rebuildSearchIndex()

        let chinese = try await store.search(query: "复盘会")
        XCTAssertEqual(chinese.first(where: { $0.kind == .material })?.refID, material)
        XCTAssertTrue(chinese.contains(where: { $0.snippet.contains("复盘会") }))

        let titleOnly = try await store.search(query: "无转写")
        XCTAssertEqual(titleOnly.map(\.refID), [titled])
        XCTAssertTrue(titleOnly.first?.snippet.contains("无转写") == true)

        let claims = try await store.search(query: "关键结论")
        XCTAssertEqual(claims.map(\.refID), [claim])
        XCTAssertEqual(claims.first?.title, "项目复盘的关键结论")

        let english = try await store.search(query: "roadmap")
        XCTAssertEqual(english.map(\.refID), [action])
        XCTAssertEqual(english.first?.kind, SearchHit.Kind.action)
    }

    func testRebuildDropsDeletedContent() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db, statement: "旧内容的独特措辞")
        try await store.rebuildSearchIndex()
        let before = try await store.search(query: "独特措辞")
        XCTAssertEqual(before.map(\.refID), [claim])
        try db.execute("DELETE FROM claims WHERE id=?", [claim])
        try await store.rebuildSearchIndex()
        let after = try await store.search(query: "独特措辞")
        XCTAssertTrue(after.isEmpty)
    }

    func testEmptyQueryReturnsNoHits() async throws {
        let store = try await openStore()
        let db = await store.db
        _ = try insertClaim(db, statement: "项目复盘的关键结论")
        try await store.rebuildSearchIndex()
        let empty = try await store.search(query: "")
        let blank = try await store.search(query: " \n ")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(blank.isEmpty)
    }

    func testQueryWithoutMatchesReturnsNoHits() async throws {
        let store = try await openStore()
        let db = await store.db
        _ = try insertClaim(db, statement: "项目复盘的关键结论")
        try await store.rebuildSearchIndex()
        let hits = try await store.search(query: "不存在的词条")
        XCTAssertTrue(hits.isEmpty)
    }

    func testFingerprintChangeRebuildsIndex() async throws {
        let store = try await openStore()
        let db = await store.db
        let first = try insertClaim(db, statement: "第一阶段实验记录")
        try await store.rebuildSearchIndex()
        let added = try insertClaim(db, statement: "量子纠缠实验记录")
        let addedHits = try await store.search(query: "量子纠缠")
        XCTAssertEqual(addedHits.map(\.refID), [added])
        let firstHits = try await store.search(query: "第一阶段")
        XCTAssertEqual(firstHits.map(\.refID), [first])
    }

    func testShortChineseQueryFallsBackToSubstring() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db, statement: "项目复盘的关键结论")
        try await store.rebuildSearchIndex()
        let hits = try await store.search(query: "复盘")
        XCTAssertEqual(hits.map(\.refID), [claim])
        XCTAssertTrue(hits.first?.snippet.contains("复盘") == true)
    }

    func testInPlaceActionEditRefreshesIndex() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db, statement: "整理材料")
        let action = try insertAction(db, claimID: claim, title: "整理材料", note: "旧备注")
        try await store.rebuildSearchIndex()
        try db.execute("UPDATE actions SET note='新的驻留词汇' WHERE id=?", [action])
        let hits = try await store.search(query: "驻留词汇")
        XCTAssertEqual(hits.map(\.refID), [action])
    }

    func testTrashedMaterialLeavesIndex() async throws {
        let store = try await openStore()
        let db = await store.db
        let material = try insertSource(db, name: "回收站材料", transcript: "独特回收站词汇")
        try await store.rebuildSearchIndex()
        let before = try await store.search(query: "独特回收站词汇")
        XCTAssertFalse(before.isEmpty)
        try db.execute("UPDATE sources SET state='trashed' WHERE id=?", [material])
        let after = try await store.search(query: "独特回收站词汇")
        XCTAssertTrue(after.isEmpty)
    }
}
