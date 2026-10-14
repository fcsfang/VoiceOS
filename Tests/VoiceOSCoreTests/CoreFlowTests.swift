import XCTest
import AVFoundation
@testable import VoiceOSCore
import VoiceOSPlatform

// Simulated model/reminder ports exercise the user flows without cloud calls or personal data.
private let flowConfiguration = ModelConfiguration(provider: "fixture", model: "flow", promptVersion: "v1", schemaVersion: "v1", destination: .local)

private actor FlowModel: ModelPort {
    let configuration = flowConfiguration
    let createsTask: Bool
    var calls = 0
    init(createsTask: Bool = false) { self.createsTask = createsTask }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1
        let source = request.context.sources[0]
        let reference = ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        let action = createsTask ? ExtractedAction(title: source.text, kind: .task, quote: source.text, autoSend: true) : nil
        return ModelResponse(status: .completed, claims: [ClaimProposal(statement: source.text, ownership: .userTentative, references: [reference], action: action)])
    }
}
private struct FlowSpeech: SpeechPort {
    let backendIdentity = "Qwen3-ASR-flow-fixture"
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText { SpeechText(text: "我认为检索质量比记忆容量更值得研究。") }
}
private struct FlowAssociation: ExpressionAssociationPort {
    let configuration = flowConfiguration
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse { .init(proposals: []) }
}
private actor FlowReminders: RemindersPort {
    var items: [ReminderSnapshot] = []
    var contexts: [String] = []
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        items.filter { $0.marker == marker || $0.id == externalID }
    }
    func create(calendarID: String, title: String, marker: String, context: String) async throws {
        items.append(.init(id: UUID().uuidString, title: title, completed: false, marker: marker))
        contexts.append(context)
    }
    func complete() { items = items.map { .init(id: $0.id, title: $0.title, completed: true, marker: $0.marker) } }
}
private struct FlowEnglish: EnglishPracticeModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "english", promptVersion: "english-practice-v1", schemaVersion: "english-feedback-v1", destination: .cloud)
    let response: EnglishPracticeResponse
    func generate(_ request: EnglishPracticeRequest) async throws -> EnglishPracticeResponse { response }
}

final class CoreFlowTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-flow-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func expression(_ store: VoiceOSStore, text: String, model: FlowModel) async throws -> String {
        let id = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        _ = try await store.continueSourceUnderstanding(sourceID: id, using: model)
        return id
    }

    func testExpressionCreatesKnowledgeTaskAndOutcome() async throws {
        let store = try await openStore(), model = FlowModel(createsTask: true), reminders = FlowReminders()
        let sourceID = try await expression(store, text: "我会查阅相关论文。", model: model)
        let claims = try await store.candidateClaims(), actions = try await store.actions()
        let action = try XCTUnwrap(actions.first)
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
        let completedActions = try await store.actions(includeHistory: true), completed = try XCTUnwrap(completedActions.first)
        XCTAssertEqual(completed.state, "completed")
        let feedbackID = try await store.recordActionFeedback(actionID: action.id, expectedVersion: completed.version, kind: .outcome, text: "阅读后发现检索质量确实影响结果。")
        let feedback = try await store.actionFeedback(actionID: action.id)
        XCTAssertEqual(feedback.first?.sourceID, feedbackID)
        XCTAssertEqual(feedback.first?.actionID, action.id)
    }

    func testRecordingRunsTranscriptionUnderstandingAndAssociation() async throws {
        let store = try await openStore(), model = FlowModel(createsTask: true), association = FlowAssociation()
        let intent = try await store.beginProcessingDictation(cognition: model.configuration, association: association.configuration)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12000)!
        buffer.frameLength = 12000
        for i in 0..<12000 { buffer.floatChannelData![0][i] = 0.01 * sin(Float(i) * 0.1) }
        do { let file = try AVAudioFile(forWriting: intent.stagingURL, settings: format.settings); try file.write(from: buffer) }
        try await store.sealDictation(sourceID: intent.sourceID)
        try await store.processTranscriptions(using: FlowSpeech())
        try await store.reconcileRecordingProcessingRequests(cognition: model.configuration, association: association.configuration)
        let queues = try await store.processingIntents(), queue = try XCTUnwrap(queues.first)
        let result = try await store.runExpressionProcessingIntent(id: queue.id, retrieval: NativeRetrieval(), cognitionPort: model, associationPort: association)
        let sources = try await store.sources(), claims = try await store.candidateClaims()
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(sources.first?.transcript, "我认为检索质量比记忆容量更值得研究。")
        XCTAssertEqual(claims.first?.references.first?.sourceID, intent.sourceID)
        let actions = try await store.actions(), action = try XCTUnwrap(actions.first)
        _ = try await store.recordActionFeedback(actionID: action.id, expectedVersion: action.version, kind: .reflection,
                                                text: "这是口述后核对的实际收获。", recordingSourceID: intent.sourceID)
        let feedback = try await store.actionFeedback(actionID: action.id)
        XCTAssertEqual(feedback.first?.recordingSourceID, intent.sourceID)
        // The full organizer saves knowledge and follow-ups separately in the same recording flow.
        let base = root.appendingPathComponent("organized"), folder = base.appendingPathComponent("recording")
        let policy = try await store.sourcePolicy(sourceID: intent.sourceID)
        _ = try await store.setSourceLocalOnly(sourceID: intent.sourceID, expectedVersion: policy.version, localOnly: false)
        _ = try await store.writeOrganizingInput(sourceID: intent.sourceID, to: folder)
        let source = try XCTUnwrap(sources.first)
        let reference: [String: Any] = ["recording": "recording", "quote": source.transcript!, "citation_status": "located", "span_ids": [source.spans[0].id]]
        let items: [[String: Any]] = [
            ["id": "K1", "title": "检索质量比记忆容量更值得研究", "intent_type": "claim", "uncertain": false, "followup_state": "knowledge", "notes": "口述观点", "references": [reference]],
            ["id": "T1", "title": "研究检索质量", "intent_type": "task", "uncertain": false, "followup_state": "pending", "notes": "需跟进", "references": [reference]]
        ]
        var payload: [String: Any] = ["source_folders": [folder.path], "all_audio_complete": true, "all_windows_checked": true, "items": items]
        try JSONSerialization.data(withJSONObject: payload).write(to: base.appendingPathComponent("完整任务清单.json"))
        do { _ = try await store.ingestOrganizedPodcast(at: base, requireAPIReview: true); XCTFail("初稿不能进入自动同步流程") }
        catch { XCTAssertTrue(error.localizedDescription.contains("意图核对尚未完成")) }
        payload["api_review_completed"] = true
        try JSONSerialization.data(withJSONObject: payload).write(to: base.appendingPathComponent("完整任务清单.json"))
        let count = try await store.ingestOrganizedPodcast(at: base, requireAPIReview: true)
        XCTAssertEqual(count, 2)
        let organized = try await store.latestCandidateClaims(for: intent.sourceID), organizedIDs = Set(organized.map(\.id))
        let savedActions = try await store.actions(includeHistory: true)
        let followups = savedActions.filter { organizedIDs.contains($0.claimID) }
        XCTAssertEqual(organized.count, 2)
        XCTAssertEqual(followups.count, 1)
        XCTAssertEqual(followups.first?.intent?.intentType, "task")
        _ = try await store.ingestOrganizedPodcast(at: base)
        let repeated = try await store.actions(includeHistory: true)
        XCTAssertEqual(repeated.count, savedActions.count)
    }

    func testIdeaFindsHistoryWithoutCreatingTask() async throws {
        let store = try await openStore(), model = FlowModel()
        let oldID = try await expression(store, text: "记忆系统需要关注检索质量。", model: model)
        let previous = try await store.retrieve("检索质量", using: NativeRetrieval())
        XCTAssertEqual(previous.hits.first?.document.sourceID, oldID)
        _ = try await expression(store, text: "今天又想到检索质量和容量的关系。", model: model)
        do { try await store.validateRetrievalResult(previous); XCTFail("新表达出现后应重新查找历史") } catch {}
        let current = try await store.retrieve("检索质量", using: NativeRetrieval()), actions = try await store.actions()
        XCTAssertEqual(current.matchingSources, 2)
        XCTAssertTrue(actions.isEmpty)
        let claims = try await store.latestCandidateClaims(for: oldID), claim = try XCTUnwrap(claims.first)
        let opportunityID = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: claim.reviewVersion, title: "【问题】检索质量如何改善", kind: .opportunity)
        let taskID = try await store.confirmOpportunityAsTask(actionID: opportunityID, expectedVersion: 1, title: "研究检索质量的改进方法")
        let history = try await store.actions(includeHistory: true)
        XCTAssertEqual(history.first(where: { $0.id == opportunityID })?.state, "dismissed")
        XCTAssertEqual(history.first(where: { $0.id == taskID })?.kind, "task")
        XCTAssertEqual(history.first(where: { $0.id == taskID })?.intent?.uncertain, false)
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
