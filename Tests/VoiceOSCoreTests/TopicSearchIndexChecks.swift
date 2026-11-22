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

    func testTopicSearchIndexScenarios() async throws {
        struct Scenario {
            let name: String
            let mutate: (Database, String) throws -> Void
            let query: String
            let expectedTitle: String?
            let extra: ((VoiceOSStore, String) async throws -> Void)?
        }
        let scenarios: [Scenario] = [
            Scenario(name: "标题可搜索", mutate: { _, _ in }, query: "沟通的节奏",
                     expectedTitle: "与父母沟通的节奏", extra: { store, _ in
                let hits = try await store.search(query: "沟通的节奏")
                XCTAssertEqual(hits.first?.kind, SearchHit.Kind.topic)
            }),
            Scenario(name: "两字查询走索引", mutate: { _, _ in }, query: "沟通",
                     expectedTitle: "与父母沟通的节奏", extra: { store, _ in
                let hits = try await store.search(query: "沟通")
                XCTAssertEqual(hits.first?.kind, .topic)
                let topicTotal = try await store.searchAll(query: "沟通", perKindLimit: 20).total(for: .topic)
                XCTAssertEqual(topicTotal, 1)
            }),
            Scenario(name: "改名刷新索引", mutate: { db, topic in
                try db.execute("UPDATE reflection_questions SET title='与同事沟通的边界',updated_at='2026-11-15T00:00:00Z' WHERE id=?", [topic])
            }, query: "沟通的边界", expectedTitle: "与同事沟通的边界", extra: { store, _ in
                let old = try await store.search(query: "沟通的节奏")
                XCTAssertTrue(old.isEmpty)
            }),
            Scenario(name: "删除移出索引", mutate: { db, topic in
                try db.execute("DELETE FROM reflection_questions WHERE id=?", [topic])
            }, query: "沟通的节奏", expectedTitle: nil, extra: nil),
        ]
        for testCase in scenarios {
            try? FileManager.default.removeItem(at: root)
            let store = try await openStore()
            let db = await store.db
            let source = try insertSource(db, name: "习惯记录")
            let topic = try insertTopic(db, title: "与父母沟通的节奏", sourceID: source)
            try await store.rebuildSearchIndex()
            try testCase.mutate(db, topic)

            let hits = try await store.search(query: testCase.query)
            if let expectedTitle = testCase.expectedTitle {
                XCTAssertEqual(hits.map(\.refID), [topic], testCase.name)
                XCTAssertEqual(hits.first?.title, expectedTitle, testCase.name)
            } else {
                XCTAssertTrue(hits.isEmpty, testCase.name)
            }
            try await testCase.extra?(store, topic)
        }
    }
}
