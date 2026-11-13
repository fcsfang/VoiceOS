import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor ReviewReminders: RemindersPort {
    var items: [ReminderSnapshot] = []
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        items.filter { $0.marker == marker || (externalID != nil && $0.id == externalID) }
    }
    func create(calendarID: String, title: String, marker: String, context: String) async throws {
        items.append(.init(id: UUID().uuidString, title: title, completed: false, marker: marker))
    }
}

final class ActionReviewResolutionChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-action-review-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func seedSource(_ store: VoiceOSStore, text: String = "这些待办需要核对。") async throws -> String {
        let id = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        try await store.registerAutomaticRecording(sourceID: id, inbox: "fixture", recordedAt: "2026-11-01T00:00:00Z")
        return id
    }

    private func sourceText(_ store: VoiceOSStore, _ sourceID: String) async throws -> String {
        let records = try await store.sources()
        return try XCTUnwrap(records.first { $0.id == sourceID }?.transcript)
    }

    private func addAction(_ store: VoiceOSStore, sourceID: String, title: String,
                           kind: ActionKind, commandID: String = UUID().uuidString) async throws -> ActionRecord {
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: title, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: kind, quote: quote))
        ], commandID: commandID)
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    private func freeze(_ store: VoiceOSStore, actionID: String) async throws {
        let database = await store.db
        try database.execute("UPDATE actions SET validity='frozen' WHERE id=?", [actionID])
    }

    private func attachExpression(_ store: VoiceOSStore, sourceIDs: [String], id: String,
                                  previous: [String], decisions: [RecordingExpressionActionDecision]?,
                                  taskReviewPending: Bool) async throws {
        let records = try await store.sources().filter { sourceIDs.contains($0.id) }
        let versions = try Dictionary(uniqueKeysWithValues: records.map { record -> (String, String) in
            (record.id, try XCTUnwrap(record.transcriptVersionID))
        })
        let policies = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.policyVersion) })
        var expression = RecordingExpression(id: id, sourceIDs: sourceIDs, title: "完整表达", summary: "摘要",
                                             reason: "依据", responseIDs: [],
                                             versions: versions, policies: policies, state: "completed",
                                             previousActionIDs: previous)
        expression.actionReviewDecisions = decisions
        expression.taskReviewPending = taskReviewPending
        expression.actionReviewResponseIDs = decisions == nil ? nil : ["review-1", "review-2"]
        let database = await store.db
        for record in records {
            var presentation = record.presentation ?? RecordingPresentation()
            presentation.expression = expression
            try database.execute("UPDATE sources SET presentation_json=? WHERE id=?",
                                 [String(decoding: try JSONEncoder().encode(presentation), as: UTF8.self), record.id])
        }
    }

    private func action(_ store: VoiceOSStore, _ id: String) async throws -> ActionRecord {
        let actions = try await store.actions(includeHistory: true)
        return try XCTUnwrap(actions.first { $0.id == id })
    }

    private func ledger(_ store: VoiceOSStore, _ expressionID: String) async throws -> ActionReviewLedger {
        let snapshot = try await store.workspaceSnapshot()
        return try XCTUnwrap(snapshot.actionReviewLedgers[expressionID])
    }

    private struct PairFixture {
        let expressionID: String
        let sourceID: String
        let oldID: String
        let newID: String
        let ledger: ActionReviewLedger
    }

    private func makePair(_ store: VoiceOSStore, oldKind: ActionKind = .opportunity,
                          newKind: ActionKind = .task, linkOld: Bool = false) async throws -> PairFixture {
        let sourceID = try await seedSource(store)
        let old = try await addAction(store, sourceID: sourceID, title: "旧记录", kind: oldKind,
                                      commandID: "old-" + UUID().uuidString)
        if linkOld {
            let reminders = ReviewReminders()
            let access = try await store.setReminderAccess(calendarID: "review-calendar", title: "VoiceOS",
                                                           enabled: true, expectedVersion: 0)
            try await store.sendTaskToReminders(actionID: old.id, expectedVersion: old.version,
                                                calendarID: access.calendarID, using: reminders,
                                                expectedAccessVersion: access.version)
        }
        try await freeze(store, actionID: old.id)
        let new = try await addAction(store, sourceID: sourceID, title: "这次识别", kind: newKind,
                                      commandID: "new-" + UUID().uuidString)
        let text = try await sourceText(store, sourceID)
        let expressionID = "expression-" + UUID().uuidString
        let decisions = [RecordingExpressionActionDecision(oldID: old.id, newID: "", relation: "uncertain",
                                                          sourceID: sourceID, quote: text, possibleNewIDs: [new.id])]
        try await attachExpression(store, sourceIDs: [sourceID], id: expressionID, previous: [old.id],
                                   decisions: decisions, taskReviewPending: true)
        let current = try await ledger(store, expressionID)
        return PairFixture(expressionID: expressionID, sourceID: sourceID, oldID: old.id, newID: new.id, ledger: current)
    }

    func testDifferentClearsAllFourGates() async throws {
        let store = try await openStore()
        let fixture = try await makePair(store)
        let snapshot = try await store.workspaceSnapshot()
        let current = try XCTUnwrap(snapshot.actionReviewLedgers[fixture.expressionID])
        XCTAssertTrue(current.requiresReview(actionID: fixture.oldID))
        XCTAssertTrue(current.requiresReview(actionID: fixture.newID))
        XCTAssertEqual(current.unresolvedPairs.count, 1)

        let newAction = try await action(store, fixture.newID)
        XCTAssertEqual(WorkspaceActionPause.reason(for: newAction, sources: snapshot.sources, claims: snapshot.claims,
                                                    currentClaimsBySource: snapshot.currentClaimsBySource,
                                                    actions: snapshot.actions,
                                                    ledgers: snapshot.actionReviewLedgers), .recordingActionReview)
        XCTAssertTrue(PausedActionBatch.plan(snapshot: snapshot).reviewOnlyActionIDs.contains(fixture.newID))
        let allowedBefore = try await store.reminderSourceAllowed(newAction)
        XCTAssertFalse(allowedBefore)
        do {
            _ = try await store.enqueueAssistantExecution(actionID: fixture.newID, expectedVersion: newAction.version)
            XCTFail("AI 委托必须在行动关系核对前暂停")
        } catch {}

        let database = await store.db
        let storedBefore = try database.query("SELECT presentation_json FROM sources WHERE id=?", [fixture.sourceID]).first?["presentation_json"]
        let receipt = try await store.resolveActionReview(
            expressionID: fixture.expressionID,
            judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .different),
            expectedDecisionsDigest: fixture.ledger.decisionsDigest, commandID: "different-once")
        XCTAssertNil(receipt.survivorActionID)
        let storedAfter = try database.query("SELECT presentation_json FROM sources WHERE id=?", [fixture.sourceID]).first?["presentation_json"]
        XCTAssertEqual(storedAfter, storedBefore)

        let after = try await store.workspaceSnapshot()
        let refreshed = try XCTUnwrap(after.actionReviewLedgers[fixture.expressionID])
        XCTAssertFalse(refreshed.requiresReview(actionID: fixture.oldID))
        XCTAssertFalse(refreshed.requiresReview(actionID: fixture.newID))
        let newAfter = try await action(store, fixture.newID)
        XCTAssertNil(WorkspaceActionPause.reason(for: newAfter, sources: after.sources, claims: after.claims,
                                                 currentClaimsBySource: after.currentClaimsBySource,
                                                 actions: after.actions, ledgers: after.actionReviewLedgers))
        XCTAssertFalse(PausedActionBatch.plan(snapshot: after).reviewOnlyActionIDs.contains(fixture.newID))
        let allowedAfter = try await store.reminderSourceAllowed(newAfter)
        XCTAssertTrue(allowedAfter)
        _ = try await store.enqueueAssistantExecution(actionID: fixture.newID, expectedVersion: newAfter.version)
    }

    func testSameAdoptsOldIdentityAndKeepsReminderLink() async throws {
        let store = try await openStore()
        let fixture = try await makePair(store, oldKind: .task, newKind: .opportunity, linkOld: true)
        let oldBefore = try await action(store, fixture.oldID)
        let newBefore = try await action(store, fixture.newID)

        let receipt = try await store.resolveActionReview(
            expressionID: fixture.expressionID,
            judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .same),
            expectedDecisionsDigest: fixture.ledger.decisionsDigest, commandID: "same-once")
        XCTAssertEqual(receipt.survivorActionID, fixture.oldID)
        XCTAssertEqual(receipt.dismissedActionID, fixture.newID)

        let oldAfter = try await action(store, fixture.oldID)
        XCTAssertEqual(oldAfter.title, "这次识别")
        XCTAssertEqual(oldAfter.claimID, newBefore.claimID)
        XCTAssertEqual(oldAfter.kind, "task")
        XCTAssertEqual(oldAfter.state, "open")
        XCTAssertEqual(oldAfter.validity, "current")
        XCTAssertEqual(oldAfter.version, oldBefore.version)
        let newAfter = try await action(store, fixture.newID)
        XCTAssertEqual(newAfter.state, "dismissed")
        XCTAssertEqual(newAfter.validity, "frozen")

        let links = try await store.reminderLinks()
        let link = try XCTUnwrap(links.first { $0.actionID == fixture.oldID })
        XCTAssertEqual(link.state, "linked")
        let database = await store.db
        XCTAssertEqual(try database.query("SELECT desired_title FROM reminder_links WHERE action_id=?", [fixture.oldID]).first?["desired_title"], "这次识别")
        try VoiceOSStore.validateStoredActions(database)
        try VoiceOSStore.validateStoredExpressionActionReviews(database)
        try VoiceOSStore.validateStoredReminders(database)

        let recovered = try await ledger(store, fixture.expressionID)
        XCTAssertFalse(recovered.requiresReview(actionID: fixture.oldID))
        XCTAssertFalse(recovered.requiresReview(actionID: fixture.newID))
    }

    func testSameMergesFrozenOpportunityIntoCurrentTask() async throws {
        let store = try await openStore()
        let fixture = try await makePair(store)
        let receipt = try await store.resolveActionReview(
            expressionID: fixture.expressionID,
            judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .same),
            expectedDecisionsDigest: fixture.ledger.decisionsDigest, commandID: "same-opportunity")
        XCTAssertEqual(receipt.survivorActionID, fixture.oldID)
        let survivor = try await action(store, fixture.oldID)
        XCTAssertEqual(survivor.kind, "task")
        XCTAssertEqual(survivor.validity, "current")
        XCTAssertEqual(survivor.title, "这次识别")
        let database = await store.db
        try VoiceOSStore.validateStoredActions(database)
        try VoiceOSStore.validateStoredExpressionActionReviews(database)
    }

    func testLegacyAffirmationIsBoundToStoredUnderstanding() async throws {
        let store = try await openStore()
        let sourceID = try await seedSource(store, text: "旧协议需要核对。")
        let task = try await addAction(store, sourceID: sourceID, title: "整理这件事", kind: .task)
        let expressionID = "legacy-" + UUID().uuidString
        try await attachExpression(store, sourceIDs: [sourceID], id: expressionID, previous: [task.id],
                                   decisions: nil, taskReviewPending: true)
        let database = await store.db
        let before = try database.query("SELECT presentation_json FROM sources WHERE id=?", [sourceID]).first?["presentation_json"]
        let initial = try await ledger(store, expressionID)
        XCTAssertTrue(initial.canAcknowledge)
        XCTAssertTrue(initial.requiresReview(actionID: task.id))
        let allowedBefore = try await store.reminderSourceAllowed(task)
        XCTAssertFalse(allowedBefore)
        do {
            _ = try await store.enqueueAssistantExecution(actionID: task.id, expectedVersion: task.version)
            XCTFail("旧协议待核对时 AI 委托必须暂停")
        } catch {}

        _ = try await store.resolveActionReview(expressionID: expressionID, judgment: .acknowledgeExpression,
                                                expectedDecisionsDigest: initial.decisionsDigest, commandID: "acknowledge-once")
        let after = try database.query("SELECT presentation_json FROM sources WHERE id=?", [sourceID]).first?["presentation_json"]
        XCTAssertEqual(after, before)
        let acknowledged = try await ledger(store, expressionID)
        XCTAssertTrue(acknowledged.isAcknowledged)
        XCTAssertFalse(acknowledged.requiresReview(actionID: task.id))
        let allowedAfter = try await store.reminderSourceAllowed(task)
        XCTAssertTrue(allowedAfter)
        _ = try await store.enqueueAssistantExecution(actionID: task.id, expectedVersion: task.version)

        let candidate = try await addAction(store, sourceID: sourceID, title: "另一次识别", kind: .task)
        let text = try await sourceText(store, sourceID)
        try await attachExpression(store, sourceIDs: [sourceID], id: expressionID, previous: [task.id],
                                   decisions: [.init(oldID: task.id, newID: "", relation: "uncertain",
                                                     sourceID: sourceID, quote: text, possibleNewIDs: [candidate.id])],
                                   taskReviewPending: true)
        let reunderstood = try await ledger(store, expressionID)
        XCTAssertNotEqual(reunderstood.decisionsDigest, initial.decisionsDigest)
        XCTAssertFalse(reunderstood.isAcknowledged)
        XCTAssertTrue(reunderstood.requiresReview(actionID: task.id))
        let databaseAfter = await store.db
        try VoiceOSStore.validateStoredExpressionActionReviews(databaseAfter)
        try VoiceOSStore.validateStoredActionReviewResolutions(databaseAfter)
    }

    func testMultipleCandidatesRequireEachJudgment() async throws {
        let store = try await openStore()
        let sourceID = try await seedSource(store)
        let old = try await addAction(store, sourceID: sourceID, title: "旧任务", kind: .task)
        try await freeze(store, actionID: old.id)
        let first = try await addAction(store, sourceID: sourceID, title: "候选一", kind: .task)
        let second = try await addAction(store, sourceID: sourceID, title: "候选二", kind: .task)
        let text = try await sourceText(store, sourceID)
        let expressionID = "multi-" + UUID().uuidString
        try await attachExpression(store, sourceIDs: [sourceID], id: expressionID, previous: [old.id],
                                   decisions: [.init(oldID: old.id, newID: "", relation: "uncertain",
                                                     sourceID: sourceID, quote: text,
                                                     possibleNewIDs: [first.id, second.id])],
                                   taskReviewPending: true)
        let initial = try await ledger(store, expressionID)
        XCTAssertEqual(initial.unresolvedPairs.count, 2)

        _ = try await store.resolveActionReview(
            expressionID: expressionID,
            judgment: .pair(oldActionID: old.id, newActionID: first.id, relation: .different),
            expectedDecisionsDigest: initial.decisionsDigest, commandID: "first-candidate")
        let partial = try await ledger(store, expressionID)
        XCTAssertTrue(partial.requiresReview(actionID: old.id))
        XCTAssertFalse(partial.requiresReview(actionID: first.id))
        XCTAssertTrue(partial.requiresReview(actionID: second.id))
        let partialSnapshot = try await store.workspaceSnapshot()
        XCTAssertEqual(Set(PausedActionBatch.plan(snapshot: partialSnapshot).reviewOnlyActionIDs),
                       Set([old.id, second.id]))

        _ = try await store.resolveActionReview(
            expressionID: expressionID,
            judgment: .pair(oldActionID: old.id, newActionID: second.id, relation: .different),
            expectedDecisionsDigest: partial.decisionsDigest, commandID: "second-candidate")
        let final = try await ledger(store, expressionID)
        XCTAssertFalse(final.requiresReview(actionID: old.id))
        XCTAssertFalse(final.requiresReview(actionID: first.id))
        XCTAssertFalse(final.requiresReview(actionID: second.id))
        let finalSnapshot = try await store.workspaceSnapshot()
        XCTAssertTrue(PausedActionBatch.plan(snapshot: finalSnapshot).reviewOnlyActionIDs.isEmpty)
    }

    func testResolutionIsIdempotentAndRollsBackOnFailure() async throws {
        let store = try await openStore()
        let fixture = try await makePair(store)
        let first = try await store.resolveActionReview(
            expressionID: fixture.expressionID,
            judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .different),
            expectedDecisionsDigest: fixture.ledger.decisionsDigest, commandID: "same-command")
        let replay = try await store.resolveActionReview(
            expressionID: fixture.expressionID,
            judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .different),
            expectedDecisionsDigest: fixture.ledger.decisionsDigest, commandID: "same-command")
        XCTAssertEqual(replay, first)
        let contentReplay = try await store.resolveActionReview(
            expressionID: fixture.expressionID,
            judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .different),
            expectedDecisionsDigest: fixture.ledger.decisionsDigest, commandID: "other-command")
        XCTAssertEqual(contentReplay.id, first.id)
        do {
            _ = try await store.resolveActionReview(
                expressionID: fixture.expressionID,
                judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .same),
                expectedDecisionsDigest: fixture.ledger.decisionsDigest, commandID: "conflicting-command")
            XCTFail("同一行动关系不能改判")
        } catch {}

        let rollback = try await makePair(store)
        let database = await store.db
        try database.execute("CREATE TRIGGER action_review_fail BEFORE UPDATE ON actions BEGIN SELECT RAISE(ABORT,'injected'); END")
        do {
            _ = try await store.resolveActionReview(
                expressionID: rollback.expressionID,
                judgment: .pair(oldActionID: rollback.oldID, newActionID: rollback.newID, relation: .same),
                expectedDecisionsDigest: rollback.ledger.decisionsDigest, commandID: "rollback-command")
            XCTFail("注入的写入失败必须回滚整次核对")
        } catch {}
        try database.execute("DROP TRIGGER action_review_fail")
        let resolutions = try await store.actionReviewResolutions()
        XCTAssertFalse(resolutions.contains { $0.expressionID == rollback.expressionID })
        let rollbackOld = try await action(store, rollback.oldID)
        XCTAssertEqual(rollbackOld.title, "旧记录")
        XCTAssertEqual(rollbackOld.validity, "frozen")
        let rollbackNew = try await action(store, rollback.newID)
        XCTAssertEqual(rollbackNew.state, "open")
        XCTAssertEqual(rollbackNew.validity, "current")
    }

    func testSameIsRefusedWhenTheCandidateIsNoLongerCurrent() async throws {
        let store = try await openStore()
        let fixture = try await makePair(store)
        let newAction = try await action(store, fixture.newID)
        _ = try await store.setActionState(actionID: newAction.id, expectedVersion: newAction.version,
                                           state: .completed, commandID: "complete-candidate")
        let current = try await ledger(store, fixture.expressionID)
        let pair = try XCTUnwrap(current.unresolvedPairs.first)
        XCTAssertFalse(pair.isMergeable)
        XCTAssertNotNil(pair.mergeBlockedReason)
        do {
            _ = try await store.resolveActionReview(
                expressionID: fixture.expressionID,
                judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .same),
                expectedDecisionsDigest: current.decisionsDigest, commandID: "same-completed")
            XCTFail("已完成的新记录不能作为同一件事接回")
        } catch {}
        _ = try await store.resolveActionReview(
            expressionID: fixture.expressionID,
            judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .different),
            expectedDecisionsDigest: current.decisionsDigest, commandID: "different-completed")
        let cleared = try await ledger(store, fixture.expressionID)
        XCTAssertFalse(cleared.requiresReview(actionID: fixture.newID))
    }

    func testMixedLegacyAndPairRequiresPairJudgmentBeforeAffirmation() async throws {
        let store = try await openStore()
        let sourceID = try await seedSource(store)
        let old = try await addAction(store, sourceID: sourceID, title: "旧任务", kind: .task)
        try await freeze(store, actionID: old.id)
        let candidate = try await addAction(store, sourceID: sourceID, title: "候选", kind: .task)
        let noCandidates = try await addAction(store, sourceID: sourceID, title: "无候选旧任务", kind: .opportunity)
        try await freeze(store, actionID: noCandidates.id)
        let text = try await sourceText(store, sourceID)
        let expressionID = "mixed-" + UUID().uuidString
        try await attachExpression(store, sourceIDs: [sourceID], id: expressionID,
                                   previous: [old.id, noCandidates.id],
                                   decisions: [
                                    .init(oldID: old.id, newID: "", relation: "uncertain",
                                          sourceID: sourceID, quote: text, possibleNewIDs: [candidate.id]),
                                    .init(oldID: noCandidates.id, newID: "", relation: "uncertain",
                                          sourceID: sourceID, quote: text)
                                   ], taskReviewPending: true)
        let initial = try await ledger(store, expressionID)
        XCTAssertFalse(initial.canAcknowledge)
        XCTAssertTrue(initial.requiresReview(actionID: noCandidates.id))
        _ = try await store.resolveActionReview(
            expressionID: expressionID,
            judgment: .pair(oldActionID: old.id, newActionID: candidate.id, relation: .different),
            expectedDecisionsDigest: initial.decisionsDigest, commandID: "mixed-pair")
        let pairCleared = try await ledger(store, expressionID)
        XCTAssertTrue(pairCleared.canAcknowledge)
        XCTAssertTrue(pairCleared.requiresReview(actionID: noCandidates.id))
        _ = try await store.resolveActionReview(expressionID: expressionID, judgment: .acknowledgeExpression,
                                                expectedDecisionsDigest: pairCleared.decisionsDigest,
                                                commandID: "mixed-acknowledge")
        let cleared = try await ledger(store, expressionID)
        XCTAssertFalse(cleared.requiresReview(actionID: old.id))
        XCTAssertFalse(cleared.requiresReview(actionID: candidate.id))
        XCTAssertFalse(cleared.requiresReview(actionID: noCandidates.id))
    }

    func testStaleDigestSurvivesRecoveryAndExportAndTamperingFailsValidation() async throws {
        let store = try await openStore()
        let fixture = try await makePair(store)
        _ = try await store.resolveActionReview(
            expressionID: fixture.expressionID,
            judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .different),
            expectedDecisionsDigest: fixture.ledger.decisionsDigest, commandID: "first-generation")

        let text = try await sourceText(store, fixture.sourceID)
        try await attachExpression(store, sourceIDs: [fixture.sourceID], id: fixture.expressionID,
                                   previous: [fixture.oldID],
                                   decisions: [.init(oldID: fixture.oldID, newID: "", relation: "uncertain",
                                                     sourceID: fixture.sourceID, quote: "另行理解：" + text,
                                                     possibleNewIDs: [fixture.newID])],
                                   taskReviewPending: true)
        let reunderstood = try await ledger(store, fixture.expressionID)
        XCTAssertTrue(reunderstood.requiresReview(actionID: fixture.newID))
        _ = try await store.resolveActionReview(
            expressionID: fixture.expressionID,
            judgment: .pair(oldActionID: fixture.oldID, newActionID: fixture.newID, relation: .different),
            expectedDecisionsDigest: reunderstood.decisionsDigest, commandID: "second-generation")
        let currentResolutions = try await store.actionReviewResolutions()
        XCTAssertEqual(currentResolutions.filter { $0.expressionID == fixture.expressionID }.count, 2)

        let storeDatabase = await store.db
        try VoiceOSStore.validateStoredExpressionActionReviews(storeDatabase)
        try VoiceOSStore.validateStoredActionReviewResolutions(storeDatabase)
        let recovered = try await ledger(store, fixture.expressionID)
        XCTAssertFalse(recovered.requiresReview(actionID: fixture.newID))

        let package = root.appendingPathComponent("review-package")
        try await store.exportPackage(to: package, includeMedia: true)
        let restoredRoot = root.appendingPathComponent("review-restored")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: NativeMediaInspector())
        try await restored.recover()
        let restoredResolutions = try await restored.actionReviewResolutions()
        XCTAssertEqual(restoredResolutions.filter { $0.expressionID == fixture.expressionID }.count, 2)
        let restoredLedger = try await ledger(restored, fixture.expressionID)
        XCTAssertFalse(restoredLedger.requiresReview(actionID: fixture.newID))

        let database = await restored.db
        let tampered = try XCTUnwrap(restoredResolutions.first?.id)
        try database.execute("UPDATE action_review_resolutions SET input_fingerprint='tampered' WHERE id=?", [tampered])
        XCTAssertThrowsError(try VoiceOSStore.validateStoredActionReviewResolutions(database))
    }
}
