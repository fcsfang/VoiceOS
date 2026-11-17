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
        XCTAssertTrue(first.allSatisfy { $0.input.current.sources.allSatisfy(\.text.isEmpty) }, "读取返回摘要，不带逐字稿")
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
        let prepared: (sourceID: String, before: (json: String, digest: String?)) = try await {
            let store = try await makeStore()
            let sourceID = try await cloudSource(store)
            _ = try await store.processRecordingFollowup(sourceID: sourceID, using: DigestFollowupPort())
            let db = await store.db
            let before = try storedFollowup(db, sourceID)
            try db.execute("ALTER TABLE sources DROP COLUMN followup_digest")
            try db.execute("PRAGMA user_version=64")
            return (sourceID, before)
        }()
        let sourceID = prepared.sourceID, before = prepared.before

        let migrated: Database? = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try migrated?.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
        let rows = try XCTUnwrap(migrated).query("SELECT followup_json,followup_digest FROM sources WHERE id=?", [sourceID])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["followup_json"], before.json)
        let migratedDigest = try XCTUnwrap(row["followup_digest"])
        XCTAssertEqual(migratedDigest, VoiceOSStore.relevanceHash(Data(before.json.utf8)))
        _ = migrated
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

    private func storedDigest(_ db: Database, _ sourceID: String) throws -> FollowupReceiptDigest? {
        guard let raw = try db.query("SELECT followup_receipt_digest FROM sources WHERE id=?", [sourceID]).first?["followup_receipt_digest"] else { return nil }
        return try JSONDecoder().decode(FollowupReceiptDigest.self, from: Data(raw.utf8))
    }

    func testLaunchReadUsesTheReceiptDigestWithoutDecodingTheBody() async throws {
        let sourceID: String = try await {
            let store = try await makeStore()
            let id = try await cloudSource(store)
            _ = try await store.processRecordingFollowup(sourceID: id, using: DigestFollowupPort())
            let db = await store.db
            let document = try XCTUnwrap(try storedDigest(db, id))
            XCTAssertEqual(document.version, FollowupReceiptDigest.currentVersion)
            XCTAssertEqual(document.receipts.map(\.state), ["completed"])
            XCTAssertEqual(document.receipts.first?.input.current.sources.first?.text, "", "摘要不携带逐字稿")
            XCTAssertTrue(try storedFollowup(db, id).json.contains("继续练英语讲解"), "正文仍保留逐字稿")
            try db.execute("UPDATE sources SET followup_json='{malformed' WHERE id=?", [id])
            return id
        }()
        let reopened = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await reopened.recover()
        let receipts = try await reopened.recordingFollowups()
        XCTAssertEqual(receipts.filter { $0.sourceID == sourceID }.map(\.state), ["completed"], "摘要命中时正文损坏也不参与解码")
        let db = await reopened.db
        XCTAssertEqual(try storedFollowup(db, sourceID).json, "{malformed", "读取不得改写真身")
    }

    func testVersionMismatchFallsBackToTheBodyAndRewritesTheDigest() async throws {
        let sourceID: String = try await {
            let store = try await makeStore()
            let id = try await cloudSource(store)
            _ = try await store.processRecordingFollowup(sourceID: id, using: DigestFollowupPort())
            let db = await store.db
            let stale = FollowupReceiptDigest(version: FollowupReceiptDigest.currentVersion + 1, receipts: [])
            try db.execute("UPDATE sources SET followup_receipt_digest=? WHERE id=?", [String(decoding: try JSONEncoder().encode(stale), as: UTF8.self), id])
            return id
        }()
        let reopened = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await reopened.recover()
        let receipts = try await reopened.recordingFollowups()
        XCTAssertEqual(receipts.filter { $0.sourceID == sourceID }.map(\.state), ["completed"])
        let db = await reopened.db
        let rewritten = try XCTUnwrap(try storedDigest(db, sourceID))
        XCTAssertEqual(rewritten.version, FollowupReceiptDigest.currentVersion)
        XCTAssertEqual(rewritten.receipts.map(\.state), ["completed"], "自愈后摘要与原文一致")
    }

    func testMissingReceiptDigestIsRebuiltFromTheBody() async throws {
        let sourceID: String = try await {
            let store = try await makeStore()
            let id = try await cloudSource(store)
            _ = try await store.processRecordingFollowup(sourceID: id, using: DigestFollowupPort())
            let db = await store.db
            try db.execute("UPDATE sources SET followup_receipt_digest=NULL WHERE id=?", [id])
            return id
        }()
        let reopened = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await reopened.recover()
        _ = try await reopened.recordingFollowups()
        let db = await reopened.db
        let rebuilt = try XCTUnwrap(try storedDigest(db, sourceID))
        XCTAssertEqual(rebuilt.version, FollowupReceiptDigest.currentVersion)
        XCTAssertEqual(rebuilt.receipts.map(\.state), ["completed"])
        XCTAssertEqual(rebuilt.receipts.first?.input.current.sources.first?.text, "", "补写的是摘要，不是原文")
    }

    func testEveryRetryStepRewritesTheReceiptDigest() async throws {
        let store = try await makeStore()
        let sourceID = try await cloudSource(store)
        let db = await store.db
        _ = try await store.enqueueRecordingFollowup(sourceID: sourceID)
        XCTAssertEqual(try storedDigest(db, sourceID)?.receipts.map(\.state), ["queued"])
        do { _ = try await store.processRecordingFollowup(sourceID: sourceID, using: FailingDigestFollowupPort()) } catch { }
        let failed = try XCTUnwrap(try storedDigest(db, sourceID)?.receipts.last)
        XCTAssertEqual(failed.state, "failed")
        XCTAssertNotNil(failed.error)
        XCTAssertNotNil(failed.retryAt)
        let failedID = failed.id
        var receipts = try await store.recordingFollowups()
        let index = try XCTUnwrap(receipts.firstIndex { $0.id == failedID })
        receipts[index].retryAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
        try db.execute("UPDATE sources SET followup_json=?,followup_digest=NULL WHERE id=?", [String(decoding: try JSONEncoder().encode(receipts.filter { $0.sourceID == sourceID }), as: UTF8.self), sourceID])
        let retried = try await store.processRecordingFollowup(sourceID: sourceID, using: DigestFollowupPort())
        XCTAssertEqual(retried.id, failedID)
        let completed = try XCTUnwrap(try storedDigest(db, sourceID)?.receipts.last)
        XCTAssertEqual(completed.id, failedID)
        XCTAssertEqual(completed.state, "completed")
        XCTAssertNil(completed.retryAt)
    }

    func testMigration67BackfillsReceiptDigestAndReplaysSafely() async throws {
        let sourceID: String = try await {
            let store = try await makeStore()
            let id = try await cloudSource(store)
            _ = try await store.processRecordingFollowup(sourceID: id, using: DigestFollowupPort())
            let db = await store.db
            try db.execute("ALTER TABLE sources DROP COLUMN followup_receipt_digest")
            try db.execute("PRAGMA user_version=66")
            return id
        }()
        let url = root.appendingPathComponent("voiceos.sqlite")
        do {
            let migrated = try Database(url)
            XCTAssertEqual(try migrated.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
            let row = try XCTUnwrap(try migrated.query("SELECT followup_json,followup_digest,followup_receipt_digest FROM sources WHERE id=?", [sourceID]).first)
            let body = try XCTUnwrap(row["followup_json"])
            XCTAssertEqual(row["followup_digest"], VoiceOSStore.relevanceHash(Data(body.utf8)))
            let document = try JSONDecoder().decode(FollowupReceiptDigest.self, from: Data(try XCTUnwrap(row["followup_receipt_digest"]).utf8))
            XCTAssertEqual(document.version, FollowupReceiptDigest.currentVersion)
            XCTAssertEqual(document.receipts.map(\.state), ["completed"])
            try migrated.execute("PRAGMA user_version=66")
        }
        let retried = try Database(url)
        XCTAssertEqual(try retried.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
        XCTAssertNotNil(try retried.query("SELECT followup_receipt_digest FROM sources WHERE id=?", [sourceID]).first?["followup_receipt_digest"])
        let reopened = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await reopened.recover()
        let receipts = try await reopened.recordingFollowups()
        XCTAssertEqual(receipts.filter { $0.sourceID == sourceID }.map(\.state), ["completed"])
    }

    private func assertDigestMatchesBody(_ db: Database, _ sourceID: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try storedFollowup(db, sourceID)
        XCTAssertEqual(try XCTUnwrap(value.digest), VoiceOSStore.relevanceHash(Data(value.json.utf8)), file: file, line: line)
        let document = try XCTUnwrap(try storedDigest(db, sourceID), file: file, line: line)
        XCTAssertEqual(document.version, FollowupReceiptDigest.currentVersion, file: file, line: line)
        let bodyReceipts = try JSONDecoder().decode([RecordingFollowupReceipt].self, from: Data(value.json.utf8))
        XCTAssertEqual(document.receipts.map(\.id), bodyReceipts.map(\.id), file: file, line: line)
        XCTAssertEqual(document.receipts.map(\.state), bodyReceipts.map(\.state), file: file, line: line)
    }
}
