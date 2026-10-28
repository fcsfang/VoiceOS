import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class CoreFlowTests: FlowTestCase {
    func testExpressionCreatesKnowledgeTaskAndOutcome() async throws {
        let model = FlowModel(createsTask: true), reminders = FlowReminders()
        let outcomeModel = FlowModel(), association = FlowAssociation()
        let action: ActionRecord, completed: ActionRecord, feedbackID: String
        do {
            let store = try await openStore()
            let sourceID = try await expression(store, text: "我会查阅相关论文。", model: model)
            let claims = try await store.candidateClaims(), actions = try await store.actions()
            action = try XCTUnwrap(actions.first)
            XCTAssertEqual(claims.first?.references.first?.sourceID, sourceID)
            XCTAssertEqual(claims.first?.ownership, "user_tentative")
            XCTAssertEqual(action.claimID, claims.first?.id)
            _ = try await store.setReminderAccess(calendarID: "fixture", title: "测试清单", enabled: true, expectedVersion: 0)
            try await store.sendTaskToReminders(actionID: action.id, expectedVersion: action.version, calendarID: "fixture", using: reminders, expectedAccessVersion: 1)
            let context = await reminders.contexts.first
            XCTAssertTrue(context?.contains("原话：我会查阅相关论文。") == true)
            let links = try await store.reminderLinks(), link = try XCTUnwrap(links.first)
            await reminders.complete()
            try await store.readReminder(linkID: link.id, calendarID: "fixture", using: reminders, expectedAccessVersion: 1)
            let completedActions = try await store.actions(includeHistory: true)
            completed = try XCTUnwrap(completedActions.first)
            XCTAssertEqual(completed.state, "completed")
            let needsResult = try await store.pendingOutcomeFollowups()
            XCTAssertTrue(needsResult.contains { $0.id == completed.id })
            feedbackID = try await store.recordActionFeedback(actionID: action.id, expectedVersion: completed.version, kind: .outcome, text: "阅读后发现检索质量确实影响结果。")
            let feedback = try await store.actionFeedback(actionID: action.id)
            XCTAssertEqual(feedback.first?.sourceID, feedbackID)
            XCTAssertEqual(feedback.first?.actionID, action.id)
            let savedOutcomes = try await store.recentActionOutcomes()
            XCTAssertEqual(savedOutcomes.map(\.sourceID), [feedbackID])
            let recordedResult = try await store.pendingOutcomeFollowups()
            XCTAssertFalse(recordedResult.contains { $0.id == completed.id })
            let reopenedVersion = try await store.setActionState(actionID: completed.id, expectedVersion: completed.version, state: .open)
            let nextCompletion = try await store.setActionState(actionID: completed.id, expectedVersion: reopenedVersion, state: .completed)
            let needsNewResult = try await store.pendingOutcomeFollowups()
            XCTAssertTrue(needsNewResult.contains { $0.id == completed.id && $0.version == nextCompletion })
            let historicalOutcomes = try await store.recentActionOutcomes()
            XCTAssertEqual(historicalOutcomes.first?.actionVersion, completed.version)
            try await store.enqueueActionFeedbackUnderstanding(cognition: outcomeModel.configuration, association: association.configuration)
            let localQueue = try await store.processingIntents()
            XCTAssertTrue(localQueue.isEmpty)
            _ = try await store.setSourceLocalOnly(sourceID: feedbackID, expectedVersion: 1, localOnly: false)
            try await store.enqueueActionFeedbackUnderstanding(cognition: outcomeModel.configuration, association: association.configuration)
        }
        let reopened = try await openStore()
        let queuedResults = try await reopened.processingIntents(), queuedResult = try XCTUnwrap(queuedResults.first)
        let processed = try await reopened.runExpressionProcessingIntent(id: queuedResult.id, retrieval: NativeRetrieval(), cognitionPort: outcomeModel, associationPort: association)
        XCTAssertEqual(processed.state, .completed)
        let outcomeThoughts = try await reopened.latestCandidateClaims(for: feedbackID)
        XCTAssertEqual(outcomeThoughts.first?.statement, "阅读后发现检索质量确实影响结果。")
        XCTAssertEqual(outcomeThoughts.first?.references.first?.sourceID, feedbackID)
        XCTAssertEqual(outcomeThoughts.first?.evidenceState, "unverified")
        let followups = try await reopened.pendingRecordingFollowups()
        XCTAssertEqual(followups.map(\.sourceID), [feedbackID])
        XCTAssertEqual(followups.first?.input.feedbackActionID, action.id)
        XCTAssertEqual(followups.first?.input.currentUnderstanding, outcomeThoughts.map(\.statement))
        let finalActions = try await reopened.actions(includeHistory: true)
        XCTAssertEqual(finalActions.count, 1)
        XCTAssertEqual(finalActions.first?.state, "completed")
        try await reopened.enqueueActionFeedbackUnderstanding(cognition: outcomeModel.configuration, association: association.configuration)
        let reusedQueues = try await reopened.processingIntents()
        XCTAssertEqual(reusedQueues.count, 1)
        let calls = await outcomeModel.calls; XCTAssertEqual(calls, 1)
        let package = root.appendingPathComponent("outcome-package"), restored = root.appendingPathComponent("outcome-restored")
        try await reopened.exportPackage(to: package, includeMedia: true)
        try await VoiceOSStore.restorePackage(from: package, to: restored, inspector: NativeMediaInspector())
        let recovered = try VoiceOSStore(root: restored, inspector: NativeMediaInspector()); try await recovered.recover()
        let recoveredTask = try await recovered.actions(includeHistory: true).first { $0.id == action.id }
        XCTAssertEqual(recoveredTask?.validity, "current")
        XCTAssertEqual(recoveredTask?.claimReviewVersion, 0)
        if let path = ProcessInfo.processInfo.environment["VOICEOS_OUTCOME_DEMO_PACKAGE"] {
            try await reopened.exportPackage(to: URL(fileURLWithPath: path), includeMedia: true)
        }

    }

    func testCorrectionPreservesHistoryAndRefreshesUnderstanding() async throws {
        let store = try await openStore(), model = FlowModel()
        let sourceID = try await expression(store, text: "我认为容量最重要。", model: model)
        let sources = try await store.sources(), original = try XCTUnwrap(sources.first?.transcriptVersionID)
        _ = try await store.correctTranscript(sourceID: sourceID, expectedVersionID: original, text: "我认为检索质量最重要。")
        _ = try await store.continueSourceUnderstanding(sourceID: sourceID, using: model)
        let history = try await store.transcriptHistory(sourceID: sourceID), current = try await store.latestCandidateClaims(for: sourceID)
        XCTAssertEqual(Set(history.map(\.text)), ["我认为容量最重要。", "我认为检索质量最重要。"])
        XCTAssertEqual(current.first?.statement, "我认为检索质量最重要。")
        let updated = try await store.sources(), version = try XCTUnwrap(updated.first?.transcriptVersionID)
        do { _ = try await store.correctTranscript(sourceID: sourceID, expectedVersionID: version, text: "我认为检索质量最重要。"); XCTFail("文字未变时应保持当前版本") }
        catch { XCTAssertEqual(error.localizedDescription, "文字未改变，无需保存更正") }
        let unchanged = try await store.transcriptHistory(sourceID: sourceID)
        XCTAssertEqual(unchanged.count, 2)
    }

    func testEnglishPracticeStoresFeedbackAgainstPriorPractice() async throws {
        let store = try await openStore()
        let oldID = try await store.recordUserExpression("The model have one layer.")
        let currentID = try await store.recordUserExpression("The model have two layers.")
        for id in [oldID, currentID] { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false) }
        let snapshot = try await store.prepareEnglishPractice(currentSourceID: currentID, priorSourceIDs: [oldID], destination: .cloud)
        let source = try XCTUnwrap(snapshot.context.sources.first { $0.sourceID == currentID })
        let reference = ClaimReference(sourceID: currentID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        let suggestion = EnglishSuggestionProposal(kind: .grammar, original: .init(reference: reference, quote: source.text), suggestedText: "The model has two layers.", explanation: "Use has with a singular subject.")
        let port = FlowEnglish(response: EnglishPracticeResponse(suggestions: [suggestion], comparisons: []))
        _ = try await store.performEnglishFeedback(snapshot, using: port)
        let feedback = try await store.englishFeedbackAttempts(), claims = try await store.candidateClaims()
        XCTAssertEqual(feedback.first?.state, "completed")
        XCTAssertEqual(feedback.first?.currentSourceID, currentID)
        XCTAssertEqual(feedback.first?.priorSourceIDs, [oldID])
        XCTAssertEqual(feedback.first?.result?.suggestions.first?.suggestedText, "The model has two layers.")
        XCTAssertTrue(claims.isEmpty)
    }

    func testReopenReusesSavedUnderstanding() async throws {
        let model = FlowModel()
        let sourceID: String
        do { let store = try await openStore(); sourceID = try await expression(store, text: "记忆系统要保留来源。", model: model) }
        let reopened = try await openStore()
        let result = try await reopened.continueSourceUnderstanding(sourceID: sourceID, using: model)
        let claims = try await reopened.candidateClaims(), calls = await model.calls
        XCTAssertTrue(result.reused)
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(calls, 1)
    }
}
