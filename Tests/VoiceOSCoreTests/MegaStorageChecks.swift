import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class MegaStorageChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-mega-storage-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func insertSource(_ db: Database, id: String = UUID().uuidString) throws -> String {
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?,?,'unknown','external','saved',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, "asset:" + id, "version:" + id, "合成资料", "external_text", "2026-11-14T00:00:00Z", TimeZone.current.identifier, "assets/" + id])
        return id
    }

    private func insertClaim(_ db: Database, id: String = UUID().uuidString) throws -> String {
        let contextID = UUID().uuidString, attemptID = UUID().uuidString
        try db.execute("INSERT INTO contexts(id,command_id,snapshot_json,digest,state,created_at) VALUES(?,?,?,?, 'current',?)",
                       [contextID, "context:" + contextID, "{}", contextID, "2026-11-14T00:00:00Z"])
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at) VALUES(?,?,?,?,?,?, 'completed',?)",
                       [attemptID, contextID, "fixture", "fixture", "v1", "v1", "2026-11-14T00:00:00Z"])
        try db.execute("INSERT INTO claims(id,attempt_id,ordinal,statement,ownership,evidence_state,validity,refs_json,created_at) VALUES(?,?,0,?, 'external','unverified','current','[]',?)",
                       [id, attemptID, "合成观点", "2026-11-14T00:00:00Z"])
        return id
    }

    private func insertAction(_ db: Database, claimID: String) throws -> String {
        let id = UUID().uuidString
        try db.execute("""
        INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,command_id,input_fingerprint,created_at)
        VALUES(?,?,0,?,'task','user','','open','current',?,?,?)
        """, [id, claimID, "合成行动", "action:" + id, id, "2026-11-14T00:00:00Z"])
        return id
    }

    func testMigrationAddsMegaTables() async throws {
        let store = try await openStore()
        let db = await store.db
        XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], "62")
        for table in ["action_subtasks", "action_estimates", "source_chapters", "capture_templates"] {
            XCTAssertEqual(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table]).count, 1)
        }
        XCTAssertEqual(try db.query("SELECT name FROM sqlite_master WHERE type='index' AND name='action_subtask_action'").count, 1)
    }

    func testSubtaskAddTrimOrderAndPersistence() async throws {
        let store = try await openStore()
        let db = await store.db
        let action = try insertAction(db, claimID: try insertClaim(db))
        let other = try insertAction(db, claimID: try insertClaim(db))
        let first = try await store.addSubtask(actionID: action, title: "  第一步  ")
        XCTAssertEqual(first.title, "第一步")
        XCTAssertEqual(first.ordinal, 0)
        XCTAssertFalse(first.done)
        XCTAssertNil(first.completedAt)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: first.createdAt))
        _ = try await store.addSubtask(actionID: action, title: "第二步")
        _ = try await store.addSubtask(actionID: action, title: "第三步")
        let listed = try await store.subtasks(actionID: action)
        XCTAssertEqual(listed.map(\.title), ["第一步", "第二步", "第三步"])
        XCTAssertEqual(listed.map(\.ordinal), [0, 1, 2])
        let otherFirst = try await store.addSubtask(actionID: other, title: "另一条行动的子任务")
        XCTAssertEqual(otherFirst.ordinal, 0)
        let otherList = try await store.subtasks(actionID: other)
        XCTAssertEqual(otherList.count, 1)
        let database = try Database(root.appendingPathComponent("voiceos.sqlite"))
        let persisted = try database.query("SELECT title FROM action_subtasks WHERE action_id=? ORDER BY ordinal", [action])
        XCTAssertEqual(persisted.compactMap { $0["title"] }, ["第一步", "第二步", "第三步"])
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM action_subtasks").first?["n"], "4")
    }

    func testSubtaskDoneSetsAndClearsCompletedAt() async throws {
        let store = try await openStore()
        let db = await store.db
        let action = try insertAction(db, claimID: try insertClaim(db))
        let subtask = try await store.addSubtask(actionID: action, title: "写初稿")
        let done = try await store.setSubtaskDone(id: subtask.id, done: true)
        XCTAssertTrue(done.done)
        let completedAt = try XCTUnwrap(done.completedAt)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: completedAt))
        let readBack = try await store.subtasks(actionID: action)
        XCTAssertEqual(readBack.first?.done, true)
        XCTAssertEqual(readBack.first?.completedAt, completedAt)
        let repeated = try await store.setSubtaskDone(id: subtask.id, done: true)
        XCTAssertEqual(repeated.completedAt, completedAt)
        let undone = try await store.setSubtaskDone(id: subtask.id, done: false)
        XCTAssertFalse(undone.done)
        XCTAssertNil(undone.completedAt)
        let afterUndo = try await store.subtasks(actionID: action)
        XCTAssertNil(afterUndo.first?.completedAt)
        do {
            _ = try await store.setSubtaskDone(id: UUID().uuidString, done: true)
            XCTFail("不存在的子任务不能更新")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "子任务不存在")
        }
    }

    func testSubtaskValidationAndDelete() async throws {
        let store = try await openStore()
        let db = await store.db
        let action = try insertAction(db, claimID: try insertClaim(db))
        do {
            _ = try await store.addSubtask(actionID: action, title: " \n ")
            XCTFail("空标题必须被拒绝")
        } catch {}
        do {
            _ = try await store.addSubtask(actionID: action, title: String(repeating: "长", count: 201))
            XCTFail("超长子任务必须被拒绝")
        } catch {}
        let boundary = try await store.addSubtask(actionID: action, title: String(repeating: "长", count: 200))
        XCTAssertEqual(boundary.title.unicodeScalars.count, 200)
        do {
            _ = try await store.addSubtask(actionID: UUID().uuidString, title: "孤儿子任务")
            XCTFail("行动不存在时不能添加子任务")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "行动不存在")
        }
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_subtasks").first?["n"], "1")
        try await store.deleteSubtask(id: boundary.id)
        let empty = try await store.subtasks(actionID: action)
        XCTAssertTrue(empty.isEmpty)
        try await store.deleteSubtask(id: boundary.id)
        try await store.deleteSubtask(id: UUID().uuidString)
    }

    func testActionEstimateConstraintsAndClear() async throws {
        let store = try await openStore()
        let db = await store.db
        let claim = try insertClaim(db)
        let first = try insertAction(db, claimID: claim)
        let second = try insertAction(db, claimID: claim)
        let third = try insertAction(db, claimID: claim)
        let initial = try await store.actionEstimates()
        XCTAssertTrue(initial.isEmpty)
        try await store.setActionEstimate(actionID: first, minutes: 15)
        try await store.setActionEstimate(actionID: second, minutes: 30)
        try await store.setActionEstimate(actionID: third, minutes: 60)
        let estimates = try await store.actionEstimates()
        XCTAssertEqual(estimates, [first: 15, second: 30, third: 60])
        try await store.setActionEstimate(actionID: first, minutes: 60)
        let updated = try await store.actionEstimates()
        XCTAssertEqual(updated, [first: 60, second: 30, third: 60])
        XCTAssertEqual(try db.query("SELECT * FROM action_estimates WHERE action_id=?", [first]).count, 1)
        for minutes in [0, 14, 45, 90] {
            do {
                try await store.setActionEstimate(actionID: second, minutes: minutes)
                XCTFail("非法时长必须被拒绝：\(minutes)")
            } catch {}
        }
        let unchanged = try await store.actionEstimates()
        XCTAssertEqual(unchanged[second], 30)
        do {
            try await store.setActionEstimate(actionID: UUID().uuidString, minutes: 15)
            XCTFail("行动不存在时不能写时长")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "行动不存在")
        }
        try await store.clearActionEstimate(actionID: second)
        let cleared = try await store.actionEstimates()
        XCTAssertEqual(cleared, [first: 60, third: 60])
        try await store.clearActionEstimate(actionID: second)
        let database = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM action_estimates").first?["n"], "2")
    }

    func testReplaceChaptersSortsAndRenumbers() async throws {
        let store = try await openStore()
        let db = await store.db
        let source = try insertSource(db)
        let empty = try await store.chapters(sourceID: source)
        XCTAssertTrue(empty.isEmpty)
        try await store.replaceChapters(sourceID: source, entries: [("第二节", 30000), ("开场", 0), ("第一节", 10000)])
        let sorted = try await store.chapters(sourceID: source)
        XCTAssertEqual(sorted.map(\.title), ["开场", "第一节", "第二节"])
        XCTAssertEqual(sorted.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(sorted.map(\.startMS), [0, 10000, 30000])
        XCTAssertTrue(sorted.allSatisfy { $0.sourceID == source })
        try await store.replaceChapters(sourceID: source, entries: [("  重开  ", 5000), ("补记", 5000)])
        let replaced = try await store.chapters(sourceID: source)
        XCTAssertEqual(replaced.map(\.title), ["重开", "补记"])
        XCTAssertEqual(replaced.map(\.ordinal), [0, 1])
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM source_chapters WHERE source_id=?", [source]).first?["n"], "2")
        try await store.replaceChapters(sourceID: source, entries: [])
        let cleared = try await store.chapters(sourceID: source)
        XCTAssertTrue(cleared.isEmpty)
        do {
            try await store.replaceChapters(sourceID: UUID().uuidString, entries: [("开场", 0)])
            XCTFail("来源不存在时不能写章节")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "来源不存在")
        }
    }

    func testReplaceChaptersRejectsInvalidAndKeepsPrevious() async throws {
        let store = try await openStore()
        let db = await store.db
        let source = try insertSource(db)
        try await store.replaceChapters(sourceID: source, entries: [("保留", 0)])
        do {
            try await store.replaceChapters(sourceID: source, entries: [("", 0)])
            XCTFail("空标题必须被拒绝")
        } catch {}
        do {
            try await store.replaceChapters(sourceID: source, entries: [("越界", -1)])
            XCTFail("负起点必须被拒绝")
        } catch {}
        do {
            try await store.replaceChapters(sourceID: source, entries: [("合法", 0), (String(repeating: "长", count: 201), 1000)])
            XCTFail("超长标题必须被拒绝")
        } catch {}
        let kept = try await store.chapters(sourceID: source)
        XCTAssertEqual(kept.map(\.title), ["保留"])
        XCTAssertEqual(kept.map(\.ordinal), [0])
    }

    func testCaptureTemplatesUniqueNameAndDelete() async throws {
        let store = try await openStore()
        let db = await store.db
        let initial = try await store.captureTemplates()
        XCTAssertTrue(initial.isEmpty)
        let morning = try await store.saveCaptureTemplate(name: "  晨间  ", body: "今天想先完成一件小事。")
        XCTAssertEqual(morning.name, "晨间")
        XCTAssertEqual(morning.body, "今天想先完成一件小事。")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: morning.createdAt))
        _ = try await store.saveCaptureTemplate(name: "复盘", body: "本周做得好的三件事。")
        let listed = try await store.captureTemplates()
        XCTAssertEqual(listed.map(\.name), ["晨间", "复盘"])
        do {
            _ = try await store.saveCaptureTemplate(name: "晨间", body: "另一段正文")
            XCTFail("重名模板必须被拒绝")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "模板名称已存在")
        }
        do {
            _ = try await store.saveCaptureTemplate(name: "  晨间  ", body: "另一段正文")
            XCTFail("去空白后重名也必须被拒绝")
        } catch {}
        do {
            _ = try await store.saveCaptureTemplate(name: "  ", body: "正文")
            XCTFail("空名称必须被拒绝")
        } catch {}
        do {
            _ = try await store.saveCaptureTemplate(name: String(repeating: "名", count: 41), body: "正文")
            XCTFail("超长名称必须被拒绝")
        } catch {}
        let boundary = try await store.saveCaptureTemplate(name: String(repeating: "名", count: 40), body: "正文")
        XCTAssertEqual(boundary.name.unicodeScalars.count, 40)
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM capture_templates").first?["n"], "3")
        try await store.deleteCaptureTemplate(id: morning.id)
        let remaining = try await store.captureTemplates()
        XCTAssertEqual(remaining.map(\.name), ["复盘", boundary.name])
        try await store.deleteCaptureTemplate(id: morning.id)
        let stable = try await store.captureTemplates()
        XCTAssertEqual(stable.count, 2)
    }
}
