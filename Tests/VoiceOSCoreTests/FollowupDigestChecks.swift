import XCTest
import VoiceOSPlatform
@testable import VoiceOSCore

private struct DigestFollowupPort: RecordingFollowupPort {
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration {
        let empty = PracticeFollowup(isPractice: false, evidenceQuote: "", suggestions: [], comparisons: [], nextExercise: "")
        return .init(result: .init(thoughtUpdates: [], goalPlans: [], english: empty), responseIDs: ["digest-fixture"])
    }
}

private struct FailingDigestFollowupPort: RecordingFollowupPort {
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration { throw URLError(.timedOut) }
}

final class FollowupDigestChecks: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-followup-digest-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func cloudSource(_ store: VoiceOSStore) async throws -> String {
        let id = try await store.recordUserExpression("继续练英语讲解。")
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        return id
    }
    private func storedFollowup(_ db: Database, _ sourceID: String) throws -> (json: String, digest: String?) {
        let row = try XCTUnwrap(try db.query("SELECT followup_json,followup_digest FROM sources WHERE id=?", [sourceID]).first)
        return (try XCTUnwrap(row["followup_json"]), row["followup_digest"])
    }

    func testDigestHitReusesCachedReceiptsWithoutReadingTheBody() async throws {
        let store = try await makeStore()
        let sourceID = try await cloudSource(store)
        _ = try await store.processRecordingFollowup(sourceID: sourceID, using: DigestFollowupPort())
        let first = try await store.recordingFollowups()
        XCTAssertEqual(first.map(\.state), ["completed"])
        let db = await store.db
        let before = try storedFollowup(db, sourceID)
        XCTAssertEqual(try XCTUnwrap(before.digest), VoiceOSStore.relevanceHash(Data(before.json.utf8)))

        var rewritten = try XCTUnwrap(first.first)
        rewritten.state = "failed"
        let staleBody = String(decoding: try JSONEncoder().encode([rewritten]), as: UTF8.self)
        XCTAssertNotEqual(staleBody, before.json)
        try db.execute("UPDATE sources SET followup_json=? WHERE id=?", [staleBody, sourceID])

        let hit = try await store.recordingFollowups()
        XCTAssertEqual(hit.map(\.state), ["completed"], "摘要命中时正文不参与读取")
        let after = try storedFollowup(db, sourceID)
        XCTAssertEqual(after.json, staleBody)
        XCTAssertEqual(after.digest, before.digest)
    }

    func testMissingDigestIsBackfilledAndAContentChangeIsRecomputed() async throws {
        let store = try await makeStore()
        let sourceID = try await cloudSource(store)
        _ = try await store.processRecordingFollowup(sourceID: sourceID, using: DigestFollowupPort())
        let db = await store.db
        try db.execute("UPDATE sources SET followup_digest=NULL WHERE id=?", [sourceID])

        let backfilled = try await store.recordingFollowups()
        XCTAssertEqual(backfilled.map(\.state), ["completed"])
        let afterBackfill = try storedFollowup(db, sourceID)
        XCTAssertEqual(try XCTUnwrap(afterBackfill.digest), VoiceOSStore.relevanceHash(Data(afterBackfill.json.utf8)))

        var changed = try XCTUnwrap(backfilled.first)
        changed.state = "failed"
        let changedBody = String(decoding: try JSONEncoder().encode([changed]), as: UTF8.self)
        try db.execute("UPDATE sources SET followup_json=?,followup_digest=NULL WHERE id=?", [changedBody, sourceID])

        let recomputed = try await store.recordingFollowups()
        XCTAssertEqual(recomputed.map(\.state), ["failed"])
        let afterChange = try storedFollowup(db, sourceID)
        XCTAssertEqual(try XCTUnwrap(afterChange.digest), VoiceOSStore.relevanceHash(Data(changedBody.utf8)))
    }

    func testMigration65BackfillsLegacyRowsAndFirstReadUsesTheStoredDigest() async throws {
        let store = try await makeStore()
        let sourceID = try await cloudSource(store)
        _ = try await store.processRecordingFollowup(sourceID: sourceID, using: DigestFollowupPort())
        let db = await store.db
        let before = try storedFollowup(db, sourceID)
        try db.execute("ALTER TABLE sources DROP COLUMN followup_digest")
        try db.execute("PRAGMA user_version=64")

        let migrated = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try migrated.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
        let rows = try migrated.query("SELECT followup_json,followup_digest FROM sources WHERE id=?", [sourceID])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["followup_json"], before.json)
        let migratedDigest = try XCTUnwrap(row["followup_digest"])
        XCTAssertEqual(migratedDigest, VoiceOSStore.relevanceHash(Data(before.json.utf8)))

        let reopened = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await reopened.recover()
        let receipts = try await reopened.recordingFollowups()
        XCTAssertEqual(receipts.map(\.state), ["completed"])
        let reopenedDB = await reopened.db
        XCTAssertEqual(try storedFollowup(reopenedDB, sourceID).digest, migratedDigest, "首次读取应使用迁移回填的摘要")
    }

    func testEveryFollowupSaveWritesTheDigest() async throws {
        let store = try await makeStore()
        let sourceID = try await cloudSource(store)
        let db = await store.db
        _ = try await store.enqueueRecordingFollowup(sourceID: sourceID)
        try assertDigestMatchesBody(db, sourceID)
        do { _ = try await store.processRecordingFollowup(sourceID: sourceID, using: FailingDigestFollowupPort()) } catch { }
        try assertDigestMatchesBody(db, sourceID)
        let completed = try await store.processRecordingFollowup(sourceID: sourceID, using: DigestFollowupPort(), retry: true)
        XCTAssertEqual(completed.state, "completed")
        try assertDigestMatchesBody(db, sourceID)
    }

    private func assertDigestMatchesBody(_ db: Database, _ sourceID: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try storedFollowup(db, sourceID)
        XCTAssertEqual(try XCTUnwrap(value.digest), VoiceOSStore.relevanceHash(Data(value.json.utf8)), file: file, line: line)
    }
}
