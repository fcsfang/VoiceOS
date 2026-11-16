import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class SomedayClarifyChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-someday-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore(_ directory: URL? = nil) async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: directory ?? root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addAction(_ store: VoiceOSStore, title: String, kind: ActionKind) async throws -> ActionRecord {
        let source = try await store.recordUserExpression("需要核对的内容。")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: title, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: kind, quote: quote))
        ], commandID: "someday-claims-" + UUID().uuidString)
        let claimID = try XCTUnwrap(claimIDs.first)
        let candidates = try await store.actions()
        return try XCTUnwrap(candidates.first { $0.claimID == claimID })
    }

    private func action(_ store: VoiceOSStore, _ id: String) async throws -> ActionRecord {
        let actions = try await store.actions(includeHistory: true)
        return try XCTUnwrap(actions.first { $0.id == id })
    }

    func testMigrationAddsSomedayToAnOldVersionDatabase() async throws {
        let store = try await openStore()
        let seeded = try await addAction(store, title: "以后也许再学的一门课", kind: .opportunity)
        let db = await store.db
        try db.execute("PRAGMA foreign_keys=OFF")
        try db.transaction {
            try db.execute("""
            CREATE TABLE actions_62 (
              id TEXT PRIMARY KEY, claim_id TEXT NOT NULL REFERENCES claims(id), claim_review_version INTEGER NOT NULL CHECK(claim_review_version>=0),
              title TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('task','opportunity','ai_suggestion')),
              intent_actor TEXT NOT NULL CHECK(intent_actor IN ('user','ai')), note TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('open','completed','dismissed')), validity TEXT NOT NULL CHECK(validity IN ('current','frozen')),
              version INTEGER NOT NULL DEFAULT 1 CHECK(version>=1), command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL, created_at TEXT NOT NULL,
              auto_send INTEGER NOT NULL DEFAULT 0 CHECK(auto_send IN (0,1)), intent_json TEXT,
              parent_id TEXT REFERENCES actions(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
              CHECK((kind='ai_suggestion' AND intent_actor='ai') OR (kind!='ai_suggestion' AND intent_actor='user')),
              CHECK(state!='completed' OR kind IN ('task','opportunity'))
            )
            """)
            try db.execute("""
            INSERT INTO actions_62(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,version,command_id,input_fingerprint,created_at,auto_send,intent_json,parent_id)
            SELECT id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,version,command_id,input_fingerprint,created_at,auto_send,intent_json,parent_id FROM actions
            """)
            try db.execute("DROP TABLE actions")
            try db.execute("ALTER TABLE actions_62 RENAME TO actions")
            try db.execute("""
            CREATE TABLE action_revisions_62 (
              id TEXT PRIMARY KEY, action_id TEXT NOT NULL REFERENCES actions(id), version INTEGER NOT NULL CHECK(version>1), from_version INTEGER NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('open','completed','dismissed')), note TEXT NOT NULL, actor TEXT NOT NULL CHECK(actor IN ('user','external')),
              command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(action_id,version)
            )
            """)
            try db.execute("INSERT INTO action_revisions_62(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) SELECT id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at FROM action_revisions")
            try db.execute("DROP TABLE action_revisions")
            try db.execute("ALTER TABLE action_revisions_62 RENAME TO action_revisions")
            try db.execute("PRAGMA user_version=62")
        }
        try db.execute("PRAGMA foreign_keys=ON")
        XCTAssertThrowsError(try db.execute("UPDATE actions SET state='someday' WHERE id=?", [seeded.id]),
                             "62 的 CHECK 不应接受 someday")

        let migrated = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try migrated.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
        XCTAssertEqual(try migrated.query("SELECT state FROM actions WHERE id=?", [seeded.id]).first?["state"], "open")
        XCTAssertEqual(try migrated.query("SELECT count(*) AS n FROM sqlite_master WHERE type='trigger' AND name='search_dirty_actions'").first?["n"], "1")
        try VoiceOSStore.validateStoredActions(migrated)
        try migrated.execute("UPDATE actions SET state='someday' WHERE id=?", [seeded.id])
        XCTAssertEqual(try migrated.query("SELECT state FROM actions WHERE id=?", [seeded.id]).first?["state"], "someday")
    }

    func testTransitionsAcceptSomedayThroughTheLedger() async throws {
        let store = try await openStore()
        let seeded = try await addAction(store, title: "以后也许再做的事", kind: .opportunity)
        let v2 = try await store.setActionState(actionID: seeded.id, expectedVersion: seeded.version, state: .someday, note: "留到以后", commandID: "state-someday")
        var record = try await action(store, seeded.id)
        XCTAssertEqual(record.state, "someday")
        XCTAssertEqual(v2, 2)
        try VoiceOSStore.validateStoredActions(await store.db)

        let v3 = try await store.setActionState(actionID: seeded.id, expectedVersion: v2, state: .open, note: "重新成为目标", commandID: "state-open")
        record = try await action(store, seeded.id)
        XCTAssertEqual(record.state, "open")

        let v4 = try await store.completeOutcome(actionID: seeded.id, expectedVersion: v3, commandID: "state-complete")
        record = try await action(store, seeded.id)
        XCTAssertEqual(record.state, "completed")
        XCTAssertEqual(v4, 4)

        _ = try await store.setActionState(actionID: seeded.id, expectedVersion: v4, state: .dismissed, note: "放下", commandID: "state-dismissed")
        record = try await action(store, seeded.id)
        XCTAssertEqual(record.state, "dismissed")
        let history = try await store.actionHistory(actionID: seeded.id)
        XCTAssertEqual(history.map(\.state), ["open", "someday", "open", "completed", "dismissed"])
        try VoiceOSStore.validateStoredActions(await store.db)
    }

    func testSomedayRejectsTasks() async throws {
        let store = try await openStore()
        let seeded = try await addAction(store, title: "明确待办", kind: .task)
        do {
            _ = try await store.setActionState(actionID: seeded.id, expectedVersion: seeded.version, state: .someday)
            XCTFail("待办不能留到将来也许")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "待办不能留到将来也许；请完成或不再跟进")
        }
    }

    func testClarifyReceiptsAreIdempotentPerCommand() async throws {
        let store = try await openStore()
        let somedayGoal = try await addAction(store, title: "留到以后的目标", kind: .opportunity)
        let command = VoiceOSStore.clarifyCommandID(actionID: somedayGoal.id, exit: .someday, version: somedayGoal.version)
        let first = try await store.setActionState(actionID: somedayGoal.id, expectedVersion: somedayGoal.version, state: .someday, note: "逐个澄清：留到以后", commandID: command)
        let second = try await store.setActionState(actionID: somedayGoal.id, expectedVersion: somedayGoal.version, state: .someday, note: "逐个澄清：留到以后", commandID: command)
        XCTAssertEqual(second, first)
        let db = await store.db
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_revisions WHERE command_id=?", [command]).first?["n"], "1")
        do {
            _ = try await store.setActionState(actionID: somedayGoal.id, expectedVersion: somedayGoal.version, state: .dismissed, note: "逐个澄清：留到以后", commandID: command)
            XCTFail("同一澄清命令不能更换出口")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "同一行动状态命令不能更换内容")
        }

        let completedGoal = try await addAction(store, title: "已经达成的目标", kind: .opportunity)
        let completeCommand = VoiceOSStore.clarifyCommandID(actionID: completedGoal.id, exit: .complete, version: completedGoal.version)
        let v1 = try await store.completeOutcome(actionID: completedGoal.id, expectedVersion: completedGoal.version, commandID: completeCommand)
        let v2 = try await store.completeOutcome(actionID: completedGoal.id, expectedVersion: completedGoal.version, commandID: completeCommand)
        XCTAssertEqual(v2, v1)
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_revisions WHERE command_id=?", [completeCommand]).first?["n"], "1")
        try VoiceOSStore.validateStoredActions(db)
    }

    func testSomedayReviewQueryUsesSixtyDaysAndRevisit() async throws {
        let store = try await openStore()
        let seeded = try await addAction(store, title: "放一放的目标", kind: .opportunity)
        let v2 = try await store.setActionState(actionID: seeded.id, expectedVersion: seeded.version, state: .someday, note: "留到以后")
        var rows = try await store.somedayReviewCandidates()
        XCTAssertFalse(rows.contains { $0.id == seeded.id }, "刚留到以后的目标不应立刻出现在回看里")

        let db = await store.db
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90 * 86400))
        try db.execute("UPDATE actions SET created_at=? WHERE id=?", [old, seeded.id])
        try db.execute("UPDATE action_revisions SET created_at=? WHERE action_id=?", [old, seeded.id])
        rows = try await store.somedayReviewCandidates()
        XCTAssertTrue(rows.contains { $0.id == seeded.id }, "超过 60 天未回看的 someday 目标应出现在回看里")

        let v3 = try await store.revisitSomeday(actionID: seeded.id, expectedVersion: v2, commandID: "review-once")
        XCTAssertEqual(v3, v2 + 1)
        rows = try await store.somedayReviewCandidates()
        XCTAssertFalse(rows.contains { $0.id == seeded.id }, "回看后应从回看列表移除")
        let history = try await store.actionHistory(actionID: seeded.id)
        XCTAssertEqual(history.last?.state, "someday")
        XCTAssertEqual(history.last?.note, "回看")
        try VoiceOSStore.validateStoredActions(db)

        let again = try await store.revisitSomeday(actionID: seeded.id, expectedVersion: v2, commandID: "review-once")
        XCTAssertEqual(again, v3)
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_revisions WHERE command_id=?", ["revisit:review-once"]).first?["n"], "1")
    }
}
