import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class ActionNatureChecks: XCTestCase {
    private static let taggedTitles: [(title: String, nature: String)] = [
        ("【录音中活动】继续讲解第二节", "narration"),
        ("【录音中活动】这样理解对吗？", "narration"),
        ("【问题】要不要学木工", "question"),
        ("这件事该怎么验证？", "question"),
        ("【长期目标】每周复盘工作", "goal"),
        ("整理书架", "unknown"),
    ]
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-nature-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore(_ directory: URL? = nil) async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: directory ?? root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addAction(_ store: VoiceOSStore, title: String, kind: ActionKind, contentKind: CognitiveContentKind? = nil) async throws -> ActionRecord {
        let source = try await store.recordUserExpression("需要核对的内容。")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: title, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: kind, quote: quote), contentKind: contentKind)
        ], commandID: "nature-claims-" + UUID().uuidString)
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    private func action(_ store: VoiceOSStore, _ id: String) async throws -> ActionRecord {
        let actions = try await store.actions(includeHistory: true)
        return try XCTUnwrap(actions.first { $0.id == id })
    }

    func testMigration64BackfillsNatureFromTitleTags() async throws {
        let store = try await openStore()
        var seeded: [(title: String, id: String, nature: String)] = []
        for entry in Self.taggedTitles {
            let record = try await addAction(store, title: entry.title, kind: .opportunity)
            seeded.append((title: entry.title, id: record.id, nature: entry.nature))
        }
        let db = await store.db
        try db.execute("PRAGMA foreign_keys=OFF")
        try db.transaction {
            try db.execute("""
            CREATE TABLE actions_63 (
              id TEXT PRIMARY KEY, claim_id TEXT NOT NULL REFERENCES claims(id), claim_review_version INTEGER NOT NULL CHECK(claim_review_version>=0),
              title TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('task','opportunity','ai_suggestion')),
              intent_actor TEXT NOT NULL CHECK(intent_actor IN ('user','ai')), note TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('open','completed','dismissed','someday')), validity TEXT NOT NULL CHECK(validity IN ('current','frozen')),
              version INTEGER NOT NULL DEFAULT 1 CHECK(version>=1), command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL, created_at TEXT NOT NULL,
              auto_send INTEGER NOT NULL DEFAULT 0 CHECK(auto_send IN (0,1)), intent_json TEXT,
              parent_id TEXT REFERENCES actions(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
              CHECK((kind='ai_suggestion' AND intent_actor='ai') OR (kind!='ai_suggestion' AND intent_actor='user')),
              CHECK(state!='completed' OR kind IN ('task','opportunity')),
              CHECK(state!='someday' OR kind!='task')
            )
            """)
            try db.execute("""
            INSERT INTO actions_63(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,version,command_id,input_fingerprint,created_at,auto_send,intent_json,parent_id)
            SELECT id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,version,command_id,input_fingerprint,created_at,auto_send,intent_json,parent_id FROM actions
            """)
            try db.execute("DROP TABLE actions")
            try db.execute("ALTER TABLE actions_63 RENAME TO actions")
            try db.execute("CREATE TRIGGER search_dirty_actions AFTER UPDATE ON actions BEGIN INSERT INTO search_index_meta(key, value) VALUES('dirty', '1') ON CONFLICT(key) DO UPDATE SET value=excluded.value; END")
            try db.execute("PRAGMA user_version=63")
        }
        try db.execute("PRAGMA foreign_keys=ON")

        let migrated = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try migrated.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
        for entry in seeded {
            XCTAssertEqual(try migrated.query("SELECT nature FROM actions WHERE id=?", [entry.id]).first?["nature"], entry.nature, entry.title)
        }
        let counts = try migrated.query("SELECT nature,count(*) AS n FROM actions GROUP BY nature")
        let byNature = Dictionary(uniqueKeysWithValues: counts.map { ($0["nature"]!, $0["n"]!) })
        XCTAssertEqual(byNature["narration"], "2")
        XCTAssertEqual(byNature["question"], "2")
        XCTAssertEqual(byNature["goal"], "1")
        XCTAssertEqual(byNature["unknown"], "1")
        XCTAssertThrowsError(try migrated.execute("UPDATE actions SET nature='bogus' WHERE id=?", [seeded[0].id]))
        try VoiceOSStore.validateStoredActions(migrated)
    }

    func testSetActionNatureIsIdempotentThroughTheRevisionLedger() async throws {
        let store = try await openStore()
        let seeded = try await addAction(store, title: "要不要学木工", kind: .opportunity)
        XCTAssertEqual(seeded.nature, "unknown")

        let v2 = try await store.setActionNature(id: seeded.id, expectedVersion: seeded.version, nature: .goal, commandID: "nature-goal")
        XCTAssertEqual(v2, 2)
        let afterGoal = try await action(store, seeded.id)
        XCTAssertEqual(afterGoal.nature, "goal")
        let replay = try await store.setActionNature(id: seeded.id, expectedVersion: seeded.version, nature: .goal, commandID: "nature-goal")
        XCTAssertEqual(replay, 2)
        let db = await store.db
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_revisions WHERE command_id='nature:nature-goal'").first?["n"], "1")

        do {
            _ = try await store.setActionNature(id: seeded.id, expectedVersion: seeded.version, nature: .question, commandID: "nature-goal")
            XCTFail("同一命令不能更换归类")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "同一次归类不能更换行动或归类")
        }
        do {
            _ = try await store.setActionNature(id: seeded.id, expectedVersion: v2, nature: .goal, commandID: "nature-same")
            XCTFail("归类没有变化时不能新增修订")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "行动归类没有变化")
        }
        do {
            _ = try await store.setActionNature(id: seeded.id, expectedVersion: 1, nature: .question, commandID: "nature-stale")
            XCTFail("旧版本不能归类")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "行动版本已变化，请重新核对")
        }

        let v3 = try await store.setActionNature(id: seeded.id, expectedVersion: v2, nature: .question, commandID: "nature-question")
        XCTAssertEqual(v3, 3)
        let history = try await store.actionHistory(actionID: seeded.id)
        XCTAssertEqual(history.map(\.note), ["需要核对的内容。", "归类：目标", "归类：问题"])
        let afterQuestion = try await action(store, seeded.id)
        XCTAssertEqual(afterQuestion.nature, "question")
        try VoiceOSStore.validateStoredActions(db)
    }

    func testEndpointsScopeByNatureAndKind() async throws {
        let store = try await openStore()
        let question = try await addAction(store, title: "要不要学木工", kind: .opportunity)
        let goal = try await addAction(store, title: "发布新版本", kind: .opportunity)
        let narration = try await addAction(store, title: "继续讲解第二节", kind: .opportunity)
        let unknown = try await addAction(store, title: "整理书架", kind: .opportunity)
        let goalTask = try await addAction(store, title: "写好发布说明", kind: .task)
        _ = try await store.setActionNature(id: question.id, expectedVersion: question.version, nature: .question, commandID: "scope-question")
        _ = try await store.setActionNature(id: goal.id, expectedVersion: goal.version, nature: .goal, commandID: "scope-goal")
        _ = try await store.setActionNature(id: narration.id, expectedVersion: narration.version, nature: .narration, commandID: "scope-narration")
        _ = try await store.setActionNature(id: goalTask.id, expectedVersion: goalTask.version, nature: .goal, commandID: "scope-task-goal")

        let questions = try await store.openQuestions()
        let goals = try await store.openGoals()
        let untriaged = try await store.untriagedSuggestions()
        let stalled = try await store.stalledOutcomes()
        let visible = try await store.actions()
        XCTAssertEqual(Set(questions.map(\.id)), [question.id])
        XCTAssertEqual(Set(goals.map(\.id)), [goal.id])
        XCTAssertEqual(Set(untriaged.map(\.id)), [unknown.id])
        XCTAssertEqual(Set(stalled.map(\.id)), [goal.id])
        XCTAssertEqual(visible.first { $0.id == narration.id }?.nature, "narration")

        _ = try await store.completeOutcome(actionID: goal.id, expectedVersion: goal.version + 1, commandID: "scope-complete")
        let goalsAfter = try await store.openGoals()
        let stalledAfter = try await store.stalledOutcomes()
        XCTAssertTrue(goalsAfter.isEmpty)
        XCTAssertTrue(stalledAfter.isEmpty)
        let db = await store.db
        try VoiceOSStore.validateStoredActions(db)
    }

    func testDeriveAndExtractionWriteNature() async throws {
        XCTAssertEqual(ActionNature.derive(title: "无所谓", contentKind: .question), .question)
        XCTAssertEqual(ActionNature.derive(title: "【问题】要不要学", contentKind: .statement), .question)
        XCTAssertEqual(ActionNature.derive(title: "【长期目标】每周复盘", contentKind: nil), .goal)
        XCTAssertEqual(ActionNature.derive(title: "【录音中活动】继续讲解", contentKind: nil), .narration)
        XCTAssertEqual(ActionNature.derive(title: "【待核对】某句", contentKind: nil), .unknown)
        XCTAssertEqual(ActionNature.derive(title: "整理书架", contentKind: nil), .unknown)

        let store = try await openStore()
        let question = try await addAction(store, title: "【问题】该怎样验证", kind: .opportunity)
        let goal = try await addAction(store, title: "【长期目标】三个月跑完半马", kind: .opportunity)
        let narration = try await addAction(store, title: "【录音中活动】继续讲解第二节", kind: .opportunity)
        let task = try await addAction(store, title: "整理书架", kind: .task)
        XCTAssertEqual(question.nature, "question")
        XCTAssertEqual(goal.nature, "goal")
        XCTAssertEqual(narration.nature, "narration")
        XCTAssertEqual(task.nature, "unknown")
    }

    func testPackageRoundTripPreservesNatureAndLegacyPackagesDefaultUnknown() async throws {
        let store = try await openStore()
        let goal = try await addAction(store, title: "发布新版本", kind: .opportunity)
        let question = try await addAction(store, title: "要不要学木工", kind: .opportunity)
        _ = try await store.setActionNature(id: goal.id, expectedVersion: goal.version, nature: .goal, commandID: "package-goal")
        _ = try await store.setActionNature(id: question.id, expectedVersion: question.version, nature: .question, commandID: "package-question")
        let package = base.appendingPathComponent("package")
        try await store.exportPackage(to: package, includeMedia: true)

        let restoredRoot = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
        let restored = try await openStore(restoredRoot)
        let restoredGoal = try await action(restored, goal.id)
        let restoredQuestion = try await action(restored, question.id)
        XCTAssertEqual(restoredGoal.nature, "goal")
        XCTAssertEqual(restoredQuestion.nature, "question")

        try removeNatureFromPackage(package)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["version"] as? Int, 51)
        let legacyRoot = base.appendingPathComponent("legacy")
        try await VoiceOSStore.restorePackage(from: package, to: legacyRoot, inspector: NativeMediaInspector())
        let legacy = try await openStore(legacyRoot)
        let legacyGoal = try await action(legacy, goal.id)
        let legacyQuestion = try await action(legacy, question.id)
        XCTAssertEqual(legacyGoal.nature, "unknown")
        XCTAssertEqual(legacyQuestion.nature, "unknown")
        let legacyDB = await legacy.db
        try VoiceOSStore.validateStoredActions(legacyDB)
    }

    private func removeNatureFromPackage(_ package: URL) throws {
        let actionsFile = package.appendingPathComponent("actions.jsonl")
        let lines = try Data(contentsOf: actionsFile).split(separator: 0x0A)
        var data = Data()
        for line in lines {
            guard var row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { XCTFail("行动行格式错误"); return }
            row.removeValue(forKey: "nature")
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: actionsFile)
        let (bytes, hash) = try DurableFiles.hash(actionsFile)
        let manifestURL = package.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              var files = manifest["files"] as? [[String: Any]] else { XCTFail("迁移清单格式错误"); return }
        for index in files.indices where files[index]["path"] as? String == "actions.jsonl" {
            files[index]["bytes"] = bytes
            files[index]["sha256"] = hash
        }
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
    }
}
