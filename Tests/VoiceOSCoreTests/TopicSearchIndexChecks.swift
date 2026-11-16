import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class TopicSearchIndexChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-topic-search-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func insertSource(_ db: Database, name: String) throws -> String {
        let id = UUID().uuidString, now = "2026-11-14T00:00:00Z"
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?, 'external_text','unknown','external','saved',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, "asset:" + id, "version:" + id, name, now, TimeZone.current.identifier, "assets/" + id])
        return id
    }

    private func insertTopic(_ db: Database, title: String, sourceID: String) throws -> String {
        let id = UUID().uuidString, now = "2026-11-14T00:00:00Z"
        try db.execute("INSERT INTO reflection_questions(id,title,title_source_id,created_at,updated_at) VALUES(?,?,?,?,?)", [id, title, sourceID, now, now])
        return id
    }

    func testTopicTitleIsSearchable() async throws {
        let store = try await openStore()
        let db = await store.db
        let source = try insertSource(db, name: "习惯记录")
        let topic = try insertTopic(db, title: "与父母沟通的节奏", sourceID: source)
        try await store.rebuildSearchIndex()

        let hits = try await store.search(query: "沟通的节奏")
        XCTAssertEqual(hits.map(\.refID), [topic])
        XCTAssertEqual(hits.first?.kind, SearchHit.Kind.topic)
        XCTAssertEqual(hits.first?.title, "与父母沟通的节奏")
    }

    func testTwoCharacterTopicQueryUsesIndex() async throws {
        let store = try await openStore()
        let db = await store.db
        let source = try insertSource(db, name: "习惯记录")
        let topic = try insertTopic(db, title: "与父母沟通的节奏", sourceID: source)
        try await store.rebuildSearchIndex()

        let hits = try await store.search(query: "沟通")
        XCTAssertEqual(hits.map(\.refID), [topic])
        XCTAssertEqual(hits.first?.kind, .topic)
        XCTAssertEqual(try await store.searchAll(query: "沟通", perKindLimit: 20).total(for: .topic), 1)
    }

    func testTopicRenameRefreshesIndex() async throws {
        let store = try await openStore()
        let db = await store.db
        let source = try insertSource(db, name: "习惯记录")
        let topic = try insertTopic(db, title: "与父母沟通的节奏", sourceID: source)
        try await store.rebuildSearchIndex()
        _ = try await store.search(query: "沟通的节奏")

        try db.execute("UPDATE reflection_questions SET title='与同事沟通的边界',updated_at='2026-11-15T00:00:00Z' WHERE id=?", [topic])
        let stale = try await store.search(query: "沟通的边界")
        XCTAssertTrue(stale.isEmpty)
        try await store.waitForPendingSearchRebuild()

        let renamed = try await store.search(query: "沟通的边界")
        XCTAssertEqual(renamed.map(\.refID), [topic])
        XCTAssertEqual(renamed.first?.title, "与同事沟通的边界")
        let old = try await store.search(query: "沟通的节奏")
        XCTAssertTrue(old.isEmpty)
    }

    func testDeletedTopicLeavesIndex() async throws {
        let store = try await openStore()
        let db = await store.db
        let source = try insertSource(db, name: "习惯记录")
        let topic = try insertTopic(db, title: "与父母沟通的节奏", sourceID: source)
        try await store.rebuildSearchIndex()
        try db.execute("DELETE FROM reflection_questions WHERE id=?", [topic])

        let stale = try await store.search(query: "沟通的节奏")
        XCTAssertFalse(stale.isEmpty)
        try await store.waitForPendingSearchRebuild()
        let hits = try await store.search(query: "沟通的节奏")
        XCTAssertTrue(hits.isEmpty)
    }
}
