import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class OutcomeModelChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-outcome-model-" + UUID().uuidString)
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
        ], commandID: "outcome-claims-" + UUID().uuidString)
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    private func action(_ store: VoiceOSStore, _ id: String) async throws -> ActionRecord {
        let actions = try await store.actions(includeHistory: true)
        return try XCTUnwrap(actions.first { $0.id == id })
    }

    func testSetActionStateCompletesTasksOnly() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "要不要换工作", kind: .opportunity)
        do {
            _ = try await store.setActionState(actionID: outcome.id, expectedVersion: outcome.version, state: .completed)
            XCTFail("问题与目标不能通过普通状态命令完成")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "探索意图与 AI 建议不能标成任务完成；问题与目标的完成请使用 completeOutcome")
        }
        let task = try await addAction(store, title: "写一页简历", kind: .task)
        let version = try await store.setActionState(actionID: task.id, expectedVersion: task.version, state: .completed)
        let completed = try await action(store, task.id)
        XCTAssertEqual(completed.state, "completed")
        XCTAssertEqual(completed.version, version)
        let database = await store.db
        try VoiceOSStore.validateStoredActions(database)
    }

    func testCompleteOutcomeCompletesAndIsIdempotent() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "把厨房整理好", kind: .opportunity)

        let version = try await store.completeOutcome(actionID: outcome.id, expectedVersion: outcome.version,
                                                      commandID: "complete-kitchen")
        XCTAssertEqual(version, outcome.version + 1)
        let completed = try await action(store, outcome.id)
        XCTAssertEqual(completed.state, "completed")
        XCTAssertEqual(completed.kind, "opportunity")
        XCTAssertEqual(completed.validity, "current")
        XCTAssertEqual(completed.version, version)
        let history = try await store.actionHistory(actionID: outcome.id)
        XCTAssertEqual(history.last?.state, "completed")
        XCTAssertEqual(history.last?.note, "目标达成")
        XCTAssertEqual(history.last?.actor, "user")
        let database = await store.db
        try VoiceOSStore.validateStoredActions(database)

        let repeated = try await store.completeOutcome(actionID: outcome.id, expectedVersion: outcome.version,
                                                       commandID: "complete-kitchen")
        XCTAssertEqual(repeated, version)
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM action_revisions WHERE command_id=?",
                                          ["complete-kitchen"]).first?["n"], "1")

        do {
            _ = try await store.completeOutcome(actionID: outcome.id, expectedVersion: version,
                                                commandID: "complete-kitchen")
            XCTFail("同一完成命令不能更换版本")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "同一完成目标命令不能更换内容")
        }
        do {
            _ = try await store.completeOutcome(actionID: outcome.id, expectedVersion: version)
            XCTFail("已完成的目标不能再次达成")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "只有未完成的问题与目标可以达成")
        }
        let task = try await addAction(store, title: "买收纳盒", kind: .task)
        do {
            _ = try await store.completeOutcome(actionID: task.id, expectedVersion: task.version)
            XCTFail("待办不经过完成目标命令")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "只有问题与目标可以达成")
        }
    }

    func testDismissedOutcomeLeavesActiveAndStalledLists() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "要不要学木工", kind: .opportunity)
        let version = try await store.setActionState(actionID: outcome.id, expectedVersion: outcome.version, state: .dismissed)
        let dismissed = try await action(store, outcome.id)
        XCTAssertEqual(dismissed.state, "dismissed")
        XCTAssertEqual(dismissed.version, version)
        let active = try await store.actions()
        XCTAssertTrue(active.isEmpty)
        let stalled = try await store.stalledOutcomes()
        XCTAssertTrue(stalled.isEmpty)
        let database = await store.db
        try VoiceOSStore.validateStoredActions(database)
    }

    func testAttachAndDetachNextActionTrackStalledState() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "发布新版本", kind: .opportunity)
        let task = try await addAction(store, title: "写好发布说明", kind: .task)
        let stalledBefore = try await store.stalledOutcomes()
        XCTAssertEqual(stalledBefore.map(\.id), [outcome.id])

        let attachedVersion = try await store.attachNextAction(outcomeID: outcome.id, actionID: task.id,
                                                               commandID: "attach-release-notes")
        var child = try await action(store, task.id)
        XCTAssertEqual(child.parentID, outcome.id)
        XCTAssertEqual(child.version, task.version + 1)
        XCTAssertEqual(attachedVersion, child.version)
        let attachHistory = try await store.actionHistory(actionID: task.id)
        XCTAssertEqual(attachHistory.last?.note, "添加下一步")
        let stalledAfterAttach = try await store.stalledOutcomes()
        XCTAssertTrue(stalledAfterAttach.isEmpty)
        let database = await store.db
        try VoiceOSStore.validateStoredActions(database)

        let repeatedAttach = try await store.attachNextAction(outcomeID: outcome.id, actionID: task.id,
                                                              commandID: "attach-release-notes")
        XCTAssertEqual(repeatedAttach, attachedVersion)
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM action_revisions WHERE command_id=?",
                                          ["attach:attach-release-notes"]).first?["n"], "1")

        let completedVersion = try await store.setActionState(actionID: task.id, expectedVersion: child.version,
                                                              state: .completed)
        child = try await action(store, task.id)
        XCTAssertEqual(child.version, completedVersion)
        let stalledAfterChildDone = try await store.stalledOutcomes()
        XCTAssertEqual(stalledAfterChildDone.map(\.id), [outcome.id])

        let detachedVersion = try await store.detachNextAction(actionID: task.id, expectedVersion: completedVersion,
                                                               commandID: "detach-release-notes")
        child = try await action(store, task.id)
        XCTAssertNil(child.parentID)
        XCTAssertEqual(child.version, detachedVersion)
        let detachHistory = try await store.actionHistory(actionID: task.id)
        XCTAssertEqual(detachHistory.last?.note, "摘除下一步")
        let stalledAfterDetach = try await store.stalledOutcomes()
        XCTAssertEqual(stalledAfterDetach.map(\.id), [outcome.id])
        try VoiceOSStore.validateStoredActions(database)

        let repeatedDetach = try await store.detachNextAction(actionID: task.id, expectedVersion: completedVersion,
                                                              commandID: "detach-release-notes")
        XCTAssertEqual(repeatedDetach, detachedVersion)
        do {
            _ = try await store.detachNextAction(actionID: task.id, expectedVersion: detachedVersion)
            XCTFail("没有目标的待办不能再次摘除")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "这条待办没有挂在目标下")
        }
    }

    func testAttachRejectsWrongRolesAndCycles() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "经营小花园", kind: .opportunity)
        let task = try await addAction(store, title: "买种子", kind: .task)
        let otherTask = try await addAction(store, title: "翻土", kind: .task)

        do {
            _ = try await store.attachNextAction(outcomeID: task.id, actionID: otherTask.id)
            XCTFail("待办不能作为目标的父项")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "下一步只能挂在问题与目标下")
        }
        do {
            _ = try await store.attachNextAction(outcomeID: outcome.id, actionID: UUID().uuidString)
            XCTFail("不存在的行动不能被挂上")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "行动不存在")
        }
        let secondOutcome = try await addAction(store, title: "要不要旅行", kind: .opportunity)
        do {
            _ = try await store.attachNextAction(outcomeID: outcome.id, actionID: secondOutcome.id)
            XCTFail("问题与目标不能作为下一步")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "只有待办可以作为下一步")
        }
        do {
            _ = try await store.attachNextAction(outcomeID: UUID().uuidString, actionID: task.id)
            XCTFail("不存在的目标不能挂下一步")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "目标不存在")
        }
        _ = try await store.attachNextAction(outcomeID: outcome.id, actionID: task.id, commandID: "attach-once")
        do {
            _ = try await store.attachNextAction(outcomeID: outcome.id, actionID: task.id, commandID: "attach-twice")
            XCTFail("已挂上的待办不能重复挂")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "这条待办已经挂在目标下")
        }

        let database = await store.db
        try database.execute("UPDATE actions SET parent_id=? WHERE id=?", [otherTask.id, outcome.id])
        do {
            _ = try await store.attachNextAction(outcomeID: outcome.id, actionID: otherTask.id, commandID: "attach-cycle")
            XCTFail("沿父链能走回自己的挂接必须被拒绝")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "下一步归属不能成环")
        }
        try database.execute("UPDATE actions SET parent_id=NULL WHERE id=?", [outcome.id])
    }

    func testStalledOutcomesCountOnlyOpenChildren() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "整理书架", kind: .opportunity)
        let child = try await addAction(store, title: "丢掉旧杂志", kind: .task)
        let dismissed = try await addAction(store, title: "给书编号", kind: .task)
        let childVersion = try await store.attachNextAction(outcomeID: outcome.id, actionID: child.id)
        let dismissedVersion = try await store.attachNextAction(outcomeID: outcome.id, actionID: dismissed.id)
        _ = try await store.setActionState(actionID: dismissed.id, expectedVersion: dismissedVersion, state: .dismissed)
        let withOpenChild = try await store.stalledOutcomes()
        XCTAssertTrue(withOpenChild.isEmpty)
        _ = try await store.setActionState(actionID: child.id, expectedVersion: childVersion, state: .completed)
        let afterChildrenClosed = try await store.stalledOutcomes()
        XCTAssertEqual(afterChildrenClosed.map(\.id), [outcome.id])

        let completed = try await addAction(store, title: "已收尾的目标", kind: .opportunity)
        _ = try await store.completeOutcome(actionID: completed.id, expectedVersion: completed.version)
        let frozen = try await addAction(store, title: "冻结的目标", kind: .opportunity)
        let database = await store.db
        try database.execute("UPDATE actions SET validity='frozen' WHERE id=?", [frozen.id])
        let stalled = try await store.stalledOutcomes()
        XCTAssertEqual(stalled.map(\.id), [outcome.id])
    }

    func testPackageRoundTripPreservesNextActionParent() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "完成迁移测试", kind: .opportunity)
        let task = try await addAction(store, title: "跑通往返", kind: .task)
        _ = try await store.attachNextAction(outcomeID: outcome.id, actionID: task.id, commandID: "attach-round-trip")
        let package = base.appendingPathComponent("package")
        try await store.exportPackage(to: package, includeMedia: true)
        let restoredRoot = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())

        let restored = try await openStore(restoredRoot)
        let restoredOutcome = try await action(restored, outcome.id)
        XCTAssertEqual(restoredOutcome.kind, "opportunity")
        XCTAssertNil(restoredOutcome.parentID)
        let restoredTask = try await action(restored, task.id)
        XCTAssertEqual(restoredTask.parentID, outcome.id)
        XCTAssertEqual(restoredTask.version, task.version + 1)
        let restoredStalled = try await restored.stalledOutcomes()
        XCTAssertTrue(restoredStalled.isEmpty)
        let restoredHistory = try await restored.actionHistory(actionID: task.id)
        XCTAssertEqual(restoredHistory.last?.note, "添加下一步")
        let database = await restored.db
        try VoiceOSStore.validateStoredActions(database)
    }

    func testRestoreRejectsBrokenNextActionLinks() async throws {
        let store = try await openStore()
        _ = try await addAction(store, title: "父项校验目标", kind: .opportunity)
        let task = try await addAction(store, title: "父项校验待办", kind: .task)
        let database = await store.db
        try database.execute("UPDATE actions SET parent_id=? WHERE id=?", [task.id, task.id])
        let package = base.appendingPathComponent("package-broken")
        try await store.exportPackage(to: package, includeMedia: true)
        let brokenRoot = base.appendingPathComponent("restored-broken")
        do {
            try await VoiceOSStore.restorePackage(from: package, to: brokenRoot, inspector: NativeMediaInspector())
            XCTFail("待办不能成为父项")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "迁移行动的下一步必须指向存在的问题与目标")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: brokenRoot.path))

        let cycleStore = try await openStore(base.appendingPathComponent("cycle"))
        let first = try await addAction(cycleStore, title: "环一", kind: .opportunity)
        let second = try await addAction(cycleStore, title: "环二", kind: .opportunity)
        let cycleDB = await cycleStore.db
        try cycleDB.execute("UPDATE actions SET parent_id=? WHERE id=?", [second.id, first.id])
        try cycleDB.execute("UPDATE actions SET parent_id=? WHERE id=?", [first.id, second.id])
        let cyclePackage = base.appendingPathComponent("package-cycle")
        try await cycleStore.exportPackage(to: cyclePackage, includeMedia: true)
        let cycleRoot = base.appendingPathComponent("restored-cycle")
        do {
            try await VoiceOSStore.restorePackage(from: cyclePackage, to: cycleRoot, inspector: NativeMediaInspector())
            XCTFail("成环的下一步归属必须被拒绝")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "迁移行动的下一步归属成环")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cycleRoot.path))
    }

    func testDeletingOutcomeLeavesNextActionUnattached() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "准备删除的目标", kind: .opportunity)
        let task = try await addAction(store, title: "留在原地的待办", kind: .task)
        _ = try await store.attachNextAction(outcomeID: outcome.id, actionID: task.id)
        let database = await store.db
        try database.execute("DELETE FROM actions WHERE id=?", [outcome.id])
        let surviving = try await action(store, task.id)
        XCTAssertEqual(surviving.kind, "task")
        XCTAssertNil(surviving.parentID)
    }

    func testUndoAndReminderSchedulingStayTaskOnly() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "让提醒调度只认待办", kind: .opportunity)
        let task = try await addAction(store, title: "被提醒的待办", kind: .task)
        _ = try await store.attachNextAction(outcomeID: outcome.id, actionID: task.id)

        let completedVersion = try await store.completeOutcome(actionID: outcome.id, expectedVersion: outcome.version)
        let undoneVersion = try await store.setActionState(actionID: outcome.id, expectedVersion: completedVersion, state: .open)
        let undone = try await action(store, outcome.id)
        XCTAssertEqual(undone.state, "open")
        XCTAssertEqual(undone.version, undoneVersion)
        let database = await store.db
        try VoiceOSStore.validateStoredActions(database)

        let proposal = try ReminderScheduleProposal(due: .dateOnly(localDate: "2026-11-20", timeZone: "Asia/Shanghai"),
                                                    authority: .userCommitment, rawExpression: "下周五",
                                                    anchorEventTime: Date(timeIntervalSince1970: 1_763_000_000))
        do {
            _ = try await store.recordActionSchedule(actionID: outcome.id, expectedActionVersion: undoneVersion,
                                                     expectedScheduleVersion: 0, proposal: proposal,
                                                     actor: .user, anchorTimeZone: "Asia/Shanghai")
            XCTFail("问题与目标不能排期")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "只有当前有效且未完成任务可以记录排期提案")
        }
        let taskVersion = try await action(store, task.id).version
        let intentID = try await store.recordActionSchedule(actionID: task.id, expectedActionVersion: taskVersion,
                                                            expectedScheduleVersion: 0, proposal: proposal,
                                                            actor: .user, anchorTimeZone: "Asia/Shanghai")
        let scheduled = try await store.actionScheduleIntents()
        XCTAssertEqual(scheduled.first { $0.id == intentID }?.eligibleForPlanning, true)

        _ = try await store.completeOutcome(actionID: outcome.id, expectedVersion: undoneVersion)
        let afterCompletion = try await store.actionScheduleIntents()
        XCTAssertEqual(afterCompletion.first { $0.id == intentID }?.eligibleForPlanning, true)
        try VoiceOSStore.validateStoredActions(database)
    }
}
