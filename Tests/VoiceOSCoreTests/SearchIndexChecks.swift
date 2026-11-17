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

    private func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    private func insertSource(_ db: Database, name: String, transcript: String? = nil, createdAt: String = "2026-11-14T00:00:00Z") throws -> String {
        let id = UUID().uuidString
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?, 'external_text','unknown','external','saved',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, "asset:" + id, "version:" + id, name, createdAt, TimeZone.current.identifier, "assets/" + id])
        if let transcript {
            let assetID = UUID().uuidString, jobID = UUID().uuidString, transcriptID = UUID().uuidString, versionID = UUID().uuidString
            try db.execute("INSERT INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,?,'0','original')", [assetID, id, "assets/" + id, "0"])
            try db.execute("INSERT INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','fixture','completed')", [jobID, id, "version:" + id])
            try db.execute("INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at) VALUES(?,?,?,?,?,'verbatim',?,'zh_CN','fixture',?)", [transcriptID, id, assetID, "version:" + id, jobID, transcript, createdAt])
            try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,'[]','original','system',?)", [versionID, transcriptID, transcript, createdAt])
            try db.execute("UPDATE transcripts SET current_version_id=? WHERE id=?", [versionID, transcriptID])
        }
        return id
    }

    private func insertClaim(_ db: Database, statement: String, createdAt: String = "2026-11-14T00:00:00Z") throws -> String {
        let id = UUID().uuidString, contextID = UUID().uuidString, attemptID = UUID().uuidString
        try db.execute("INSERT INTO contexts(id,command_id,snapshot_json,digest,state,created_at) VALUES(?,?,?,?, 'current',?)", [contextID, "context:" + contextID, "{}", contextID, createdAt])
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at) VALUES(?,?,?,?,?,?, 'completed',?)", [attemptID, contextID, "fixture", "fixture", "v1", "v1", createdAt])
        try db.execute("INSERT INTO claims(id,attempt_id,ordinal,statement,ownership,evidence_state,validity,refs_json,created_at) VALUES(?,?,0,?, 'external','unverified','current','[]',?)", [id, attemptID, statement, createdAt])
        return id
    }

    private func insertAction(_ db: Database, claimID: String, title: String, note: String, createdAt: String = "2026-11-14T00:00:00Z") throws -> String {
        let id = UUID().uuidString
        try db.execute("""
        INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,command_id,input_fingerprint,created_at)
        VALUES(?,?,0,?,'task','user',?,'open','current',?,?,?)
        """, [id, claimID, title, note, "action:" + id, id, createdAt])
        return id
    }

    private func dirtyFlag(_ db: Database) throws -> Bool {
        try db.query("SELECT value FROM search_index_meta WHERE key='dirty'").first?["value"] == "1"
    }

    private func clearDirtyFlag(_ db: Database) throws {
        try db.execute("DELETE FROM search_index_meta WHERE key='dirty'")
    }

    private func writeCount(_ db: Database) throws -> String? {
        try db.query("SELECT total_changes() AS changes").first?["changes"]
    }

    func testMigrationCreatesSearchIndex() async throws {
        let store = try await openStore()
        let db = await store.db
        XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
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
        XCTAssertTrue(chinese.allSatisfy { !$0.title.contains(" ") && !$0.snippet.contains("复 盘") })

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
        let emptyTotal = try await store.searchAll(query: "", perKindLimit: 20).total(for: .claim)
        XCTAssertEqual(emptyTotal, 0)
    }

    func testQueryWithoutMatchesReturnsNoHits() async throws {
        let store = try await openStore()
        let db = await store.db
        _ = try insertClaim(db, statement: "项目复盘的关键结论")
        try await store.rebuildSearchIndex()
        let hits = try await store.search(query: "不存在的词条")
        XCTAssertTrue(hits.isEmpty)
    }

    func testFingerprintChangeRebuildsIndexOnFirstQuery() async throws {
        let store = try await openStore()
        let db = await store.db
        let first = try insertClaim(db, statement: "第一阶段实验记录")
        try await store.rebuildSearchIndex()
        let added = try insertClaim(db, statement: "量子纠缠实验记录")

        let addedHits = try await store.search(query: "量子纠缠")
        XCTAssertEqual(addedHits.map(\.refID), [added])
        let firstHits = try await store.search(query: "第一阶段")
        XCTAssertEqual(firstHits.map(\.refID), [first])
        XCTAssertNil(try db.query("SELECT value FROM search_index_meta WHERE key='rebuild_pending'").first?["value"])
    }

    func testTwoCharacterChineseQueryKeepsRelevanceOrder() async throws {
        let store = try await openStore()
        let db = await store.db
        let old = try insertClaim(db, statement: "复盘", createdAt: "2020-01-01T00:00:00Z")
        let recent = try insertClaim(db, statement: "复盘", createdAt: now())
        try await store.rebuildSearchIndex()

        let hits = try await store.search(query: "复盘")
        XCTAssertEqual(hits.map(\.refID), [recent, old])
        XCTAssertTrue(hits.allSatisfy { $0.snippet.contains("复盘") })
    }

    func testMixedShortTokenFiltersTrigramMatches() async throws {
        let store = try await openStore()
        let db = await store.db
        let both = try insertClaim(db, statement: "项目复盘 roadmap")
        _ = try insertClaim(db, statement: "项目复盘 记录")
        _ = try insertClaim(db, statement: "roadmap only")
        try await store.rebuildSearchIndex()

        let hits = try await store.search(query: "复 roadmap")
        XCTAssertEqual(hits.map(\.refID), [both])
    }

    func testSingleCharacterQueryFallsBackWithTitleFirst() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db, statement: "会")
        let action = try insertAction(db, claimID: claim, title: "周报", note: "会上讨论过预算")
        try await store.rebuildSearchIndex()

        let hits = try await store.search(query: "会")
        XCTAssertEqual(Array(hits.prefix(2)).map(\.refID), [claim, action])
    }

    func testPerKindLimitCapsEachKindAndReportsTotals() async throws {
        let store = try await openStore()
        let db = await store.db
        let parent = try insertClaim(db, statement: "复盘 母记录")
        for index in 0..<3 { _ = try insertClaim(db, statement: "复盘 结论 \(index)") }
        for index in 0..<2 { _ = try insertAction(db, claimID: parent, title: "复盘 行动 \(index)", note: "复盘") }
        try await store.rebuildSearchIndex()

        let result = try await store.searchAll(query: "复盘", perKindLimit: 1)
        XCTAssertEqual(result.total(for: .claim), 4)
        XCTAssertEqual(result.hits(for: .claim).count, 1)
        XCTAssertEqual(result.total(for: .action), 2)
        XCTAssertEqual(result.hits(for: .action).count, 1)
        XCTAssertEqual(result.total(for: .material), 0)
        XCTAssertTrue(result.hits(for: .claim).allSatisfy { $0.kind == .claim })
        XCTAssertTrue(result.hits(for: .action).allSatisfy { $0.kind == .action })
        let limitedCount = try await store.search(query: "复盘", limit: 2).count
        XCTAssertEqual(limitedCount, 2)
    }

    func testInPlaceActionEditShowsUpOnNextQuery() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db, statement: "整理材料")
        let action = try insertAction(db, claimID: claim, title: "整理材料", note: "旧备注")
        try await store.rebuildSearchIndex()

        try db.execute("UPDATE actions SET note='新的驻留词汇' WHERE id=?", [action])
        XCTAssertTrue(try dirtyFlag(db))
        let fresh = try await store.search(query: "驻留词汇")
        XCTAssertEqual(fresh.map(\.refID), [action])
        XCTAssertFalse(try dirtyFlag(db))
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

    func testNarrowedTriggersIgnoreNonSearchWrites() async throws {
        let store = try await openStore()
        let db = await store.db
        let material = try insertSource(db, name: "触发器材料")
        let claim = try insertClaim(db, statement: "触发器结论")
        let action = try insertAction(db, claimID: claim, title: "触发器行动", note: "触发器备注")
        try await store.rebuildSearchIndex()
        XCTAssertFalse(try dirtyFlag(db))

        try db.execute("UPDATE sources SET followup_json='{}',presentation_json='{}',policy_version=2 WHERE id=?", [material])
        XCTAssertFalse(try dirtyFlag(db), "跟进回执、呈现 JSON 与策略切换不应置脏")

        try db.execute("UPDATE actions SET nature='goal',state='completed' WHERE id=?", [action])
        XCTAssertFalse(try dirtyFlag(db), "行动状态与性质不在索引列")

        try db.execute("UPDATE sources SET name='触发器材料改名' WHERE id=?", [material])
        XCTAssertTrue(try dirtyFlag(db))
        try clearDirtyFlag(db)

        try db.execute("UPDATE actions SET note='触发器备注更新' WHERE id=?", [action])
        XCTAssertTrue(try dirtyFlag(db))
        try clearDirtyFlag(db)

        try db.execute("UPDATE claims SET statement='触发器结论更新' WHERE id=?", [claim])
        XCTAssertTrue(try dirtyFlag(db))
    }

    func testNarrowedTriggersTrackTranscriptColumns() async throws {
        let store = try await openStore()
        let db = await store.db
        let material = try insertSource(db, name: "转写材料", transcript: "原始转写内容")
        try await store.rebuildSearchIndex()
        try clearDirtyFlag(db)

        let versionID = try db.query("SELECT id FROM transcript_versions WHERE transcript_id IN (SELECT id FROM transcripts WHERE source_id=?)", [material]).first!["id"]!
        try db.execute("UPDATE transcripts SET current_version_id=? WHERE source_id=?", [versionID, material])
        XCTAssertTrue(try dirtyFlag(db))
        try clearDirtyFlag(db)

        try db.execute("UPDATE transcripts SET locale='en_US' WHERE source_id=?", [material])
        XCTAssertFalse(try dirtyFlag(db), "转写表的非索引列不应置脏")
    }

    func testQuotedTokenDoesNotThrow() async throws {
        let store = try await openStore()
        let db = await store.db
        _ = try insertClaim(db, statement: "复盘")
        try await store.rebuildSearchIndex()
        let hits = try await store.search(query: "\"复盘 ")
        XCTAssertTrue(hits.isEmpty)
    }

    func testDirtyEmptyIndexRebuildsOnFirstSearch() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db, statement: "首次查询即命中的结论")
        try db.execute("INSERT OR REPLACE INTO search_index_meta(key, value) VALUES('dirty', '1')")
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS count FROM search_index").first?["count"], "0")

        let hits = try await store.search(query: "即命中")
        XCTAssertEqual(hits.map(\.refID), [claim])
        XCTAssertFalse(try dirtyFlag(db))
    }

    func testDirtyEmptyIndexRebuildsOnFirstSearchAll() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db, statement: "汇报要点整理")
        let action = try insertAction(db, claimID: claim, title: "整理汇报要点", note: "汇报")
        try db.execute("INSERT OR REPLACE INTO search_index_meta(key, value) VALUES('dirty', '1')")

        let result = try await store.searchAll(query: "汇报", perKindLimit: 10)
        XCTAssertEqual(result.hits(for: .claim).map(\.refID), [claim])
        XCTAssertEqual(result.hits(for: .action).map(\.refID), [action])
        XCTAssertFalse(try dirtyFlag(db))
    }

    func testSecondQueryDoesNotRebuildAgain() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db, statement: "重复查询不重建索引")
        try db.execute("INSERT OR REPLACE INTO search_index_meta(key, value) VALUES('dirty', '1')")

        let first = try await store.search(query: "不重建")
        XCTAssertEqual(first.map(\.refID), [claim])
        let writes = try writeCount(db)
        let second = try await store.search(query: "不重建")
        XCTAssertEqual(second.map(\.refID), first.map(\.refID))
        XCTAssertEqual(try writeCount(db), writes)
        XCTAssertNil(try db.query("SELECT value FROM search_index_meta WHERE key='rebuild_pending'").first?["value"])
    }

    func testCleanIndexQueryWritesNothing() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db, statement: "正常索引查询")
        try await store.rebuildSearchIndex()
        let writes = try writeCount(db)

        let hits = try await store.search(query: "正常索引")
        XCTAssertEqual(hits.map(\.refID), [claim])
        XCTAssertEqual(try writeCount(db), writes)
        XCTAssertFalse(try dirtyFlag(db))
        XCTAssertNil(try db.query("SELECT value FROM search_index_meta WHERE key='rebuild_pending'").first?["value"])
    }

    func testRebuildFailureSurfacesToCaller() async throws {
        let store = try await openStore()
        let db = await store.db
        _ = try insertClaim(db, statement: "索引表缺失时查询报错")
        try db.execute("DROP TABLE search_index")

        var thrown: Error?
        do { _ = try await store.search(query: "索引表缺失") } catch { thrown = error }
        XCTAssertNotNil(thrown as? VoiceOSError)
    }
}
