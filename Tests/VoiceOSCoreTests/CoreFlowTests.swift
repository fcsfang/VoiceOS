import XCTest
import CryptoKit
import AVFoundation
@testable import VoiceOSCore
import VoiceOSPlatform

// Simulated model/reminder ports exercise the user flows without cloud calls or personal data.
private let flowConfiguration = ModelConfiguration(provider: "fixture", model: "flow", promptVersion: "v1", schemaVersion: "v1", destination: .local)

private actor FlowModel: ModelPort {
    let configuration: ModelConfiguration
    let createsTask: Bool
    var calls = 0
    init(createsTask: Bool = false, destination: ModelDestination = .local) {
        self.createsTask = createsTask
        configuration = .init(provider: "fixture", model: "flow", promptVersion: "v1", schemaVersion: "v1", destination: destination)
    }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1
        let source = request.context.sources[0]
        let reference = ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        let action = createsTask ? ExtractedAction(title: source.text, kind: .task, quote: source.text, autoSend: true) : nil
        if source.origin == "external" { XCTAssertTrue(source.text.hasSuffix("末尾观点也必须完整保留。")) }
        return ModelResponse(status: .completed, claims: [ClaimProposal(statement: source.origin == "external" ? "作者认为检索需要评估。" : source.text, ownership: source.origin == "external" ? .external : .userTentative, references: [reference], action: action)])
    }
}
private struct FlowSpeech: SpeechPort {
    let backendIdentity = "Qwen3-ASR-flow-fixture"
    var text = "我认为检索质量比记忆容量更值得研究。"
    var timed = false
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        SpeechText(text: text, spans: timed ? [.init(textStart: 0, textEnd: text.unicodeScalars.count, startMS: 0, endMS: 500)] : nil)
    }
}
private struct FlowRecordingExpressions: RecordingExpressionPort, RecordingExpressionActionPort {
    func group(_ input:RecordingExpressionInput) async throws -> ([RecordingExpressionProposal],[String]) {
        let incoming=Set(input.newSourceIDs)
        let report=input.context.sources.filter { !$0.text.contains("咖啡豆") }
        let coffee=input.context.sources.filter { $0.text.contains("咖啡豆") }
        let groups=[report,coffee].filter { !$0.isEmpty && !$0.allSatisfy { !incoming.contains($0.sourceID) } }.map { members in
            RecordingExpressionProposal(existingID:input.existing.first { old in members.contains { old.sourceIDs.contains($0.sourceID) } }?.id ?? "",sourceIDs:members.map(\.sourceID),title:members[0].text.contains("咖啡豆") ? "买咖啡豆" : "方案报告",summary:"完整表达的整理",reason:"明确的接续或独立话语",evidence:members.map { .init(sourceID:$0.sourceID,quote:$0.text) })
        }
        return (groups,["expression-first","expression-independent"])
    }
    func reconcile(_ input:RecordingExpressionActionInput) async throws -> ([RecordingExpressionActionDecision],[String]) {
        let latest=input.context.sources.last(where: { $0.origin == "user" && $0.speaker == "user" })!
        if input.transcriptionCorrection == true {
            let decisions=input.oldActions.map { old in
                let next=input.newActions.first { $0.title == old.title && $0.kind == old.kind }
                return RecordingExpressionActionDecision(oldID:old.id,newID:next?.id ?? "",relation:next == nil ? (old.state == "completed" ? "history" : "uncertain") : "same",sourceID:latest.sourceID,quote:latest.text)
            }
            return (decisions,["correction-first","correction-independent"])
        }
        let decisions=input.oldActions.map { old in
            let next=input.newActions.first { $0.title.contains(old.title.contains("背景") ? "背景" : "报告") && !old.title.contains("发送") }
            return RecordingExpressionActionDecision(oldID:old.id,newID:next?.id ?? "",relation:next == nil ? "withdraw" : "same",sourceID:latest.sourceID,quote:latest.text)
        }
        return (decisions,["actions-first","actions-independent"])
    }
}
private struct FlowRecordingTitles: RecordingTitlePort {
    func generate(_ input: RecordingTitleInput) async throws -> ([RecordingTitleProposal], [String]) {
        (input.context.sources.map { .init(sourceID: $0.sourceID, title: "检索质量与记忆容量", summary: "讨论检索质量与容量的关系。", quotes: [$0.text]) }, ["title-result"])
    }
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

private extension VoiceOSStore {
    func dbValidateFlowActions() throws { try Self.validateStoredActions(db) }
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
        let titleCount = try await store.generateRecordingTitles(using: FlowRecordingTitles())
        let reusedTitles = try await store.generateRecordingTitles(using: FlowRecordingTitles())
        XCTAssertEqual(titleCount, 1)
        XCTAssertEqual(reusedTitles, 0)
        try await store.renameRecording(sourceID: intent.sourceID, title: "我的检索研究")
        let renamed = try await store.sources().first { $0.id == intent.sourceID }
        XCTAssertEqual(renamed?.displayTitle, "我的检索研究")
        XCTAssertEqual(renamed?.name, sources.first?.name)
        _ = try await store.writeOrganizingInput(sourceID: intent.sourceID, to: folder)
        let source = try XCTUnwrap(sources.first)
        let reference: [String: Any] = ["recording": "recording", "quote": source.transcript!, "citation_status": "located", "span_ids": [source.spans[0].id]]
        let items: [[String: Any]] = [
            ["id": "K1", "title": "检索质量比记忆容量更值得研究", "intent_type": "claim", "uncertain": false, "followup_state": "knowledge", "notes": "口述观点", "references": [reference]],
            ["id": "T1", "title": "研究检索质量", "intent_type": "task", "uncertain": false, "followup_state": "pending", "notes": "需跟进", "references": [reference]]
        ]
        var payload: [String: Any] = ["source_folders": [folder.path], "all_audio_complete": true, "all_windows_checked": true, "items": items]
        try JSONSerialization.data(withJSONObject: payload).write(to: base.appendingPathComponent("完整任务清单.json"))
        do { _ = try await store.ingestOrganizedPodcast(at: base); XCTFail("默认导入也不能接入未核对初稿") }
        catch { XCTAssertTrue(error.localizedDescription.contains("意图核对尚未完成")) }
        payload["api_review_completed"] = true
        payload["continuations_checked"] = true
        try JSONSerialization.data(withJSONObject: payload).write(to: base.appendingPathComponent("完整任务清单.json"))
        do { _ = try await store.ingestOrganizedPodcast(at: base, requireAPIReview: true); XCTFail("独立质量核对完成前不能接入") }
        catch { XCTAssertTrue(error.localizedDescription.contains("意图核对或全文转写校正")) }
        payload["independent_semantic_review_completed"] = true
        payload["audio_review_completed"] = true
        var checkedTranscript = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Qwen完整逐字稿.json"))) as? [String: Any])
        checkedTranscript["transcription_review"] = ["completed": true, "changed": false, "response_id": "flow-audio-review",
            "context_review_version": 2, "scope": "complete_expression_knowledge_and_intent", "full_text_independent_passes": 2,
            "response_ids": ["flow-audio-first", "flow-audio-second", "flow-audio-review"]]
        try JSONSerialization.data(withJSONObject: checkedTranscript).write(to: folder.appendingPathComponent("Qwen核对逐字稿.json"))
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
        // A later recording repeats an old task, reports a result, and adds a distinct next step.
        let targetAction = try XCTUnwrap(followups.first), reminders = FlowReminders()
        _ = try await store.setReminderAccess(calendarID: "fixture", title: "VoiceOS", enabled: true, expectedVersion: 0)
        try await store.refreshAuthorizedReminders(expectedAccessVersion: 1, using: reminders)
        let reminderCount = await reminders.items.count
        let next = try await store.beginDictation()
        buffer.floatChannelData![0][0] = 0.02
        do { let file = try AVAudioFile(forWriting: next.stagingURL, settings: format.settings); try file.write(from: buffer) }
        try await store.sealDictation(sourceID: next.sourceID)
        let transcript = "我还要研究检索质量。我已经比较了两种检索方法，发现重拍不一定能提高相关性。下一步另做一次容量对比实验。"
        try await store.processTranscriptions(using: FlowSpeech(text: transcript, timed: true), sourceIDs: [next.sourceID])
        let nextPolicy = try await store.sourcePolicy(sourceID: next.sourceID)
        _ = try await store.setSourceLocalOnly(sourceID: next.sourceID, expectedVersion: nextPolicy.version, localOnly: false)
        let nextBase = root.appendingPathComponent("next-organized"), nextFolder = nextBase.appendingPathComponent("next-recording")
        _ = try await store.writeOrganizingInput(sourceID: next.sourceID, to: nextFolder)
        let unreviewedSource = try await store.sources().first { $0.id == next.sourceID }
        XCTAssertEqual(unreviewedSource?.needsTranscriptionReview, true)
        let historicalDiscussion = try await store.beginConversation(sourceIDs: [next.sourceID])
        let historicalQuestion = try await store.recordUserExpression("请保留校正前的讨论依据。")
        _ = try await store.appendConversationUserSource(conversationID: historicalDiscussion, sourceID: historicalQuestion, expectedVersion: 1)
        let localUnreviewed = try await store.prepareLocalTranscriptContext(sourceIDs: [next.sourceID])
        XCTAssertEqual(localUnreviewed.sources.first?.text, transcript)
        let blockedModel = FlowModel(destination: .cloud)
        do { _ = try await store.continueSourceUnderstanding(sourceID: next.sourceID, using: blockedModel); XCTFail("完整校正前不能云端理解") }
        catch { XCTAssertTrue(error.localizedDescription.contains("全文转写校正")) }
        let blockedCalls = await blockedModel.calls
        XCTAssertEqual(blockedCalls, 0)
        let blockedTitles = try await store.prepareRecordingTitles(sourceIDs: [next.sourceID])
        XCTAssertNil(blockedTitles)
        let historyFile = nextBase.appendingPathComponent("已有任务.json")
        _ = try await store.writeExistingTaskInput(to: historyFile, excludingSourceIDs: [next.sourceID])
        let history = try JSONDecoder().decode([ExistingRecordingTask].self, from: Data(contentsOf: historyFile))
        let target = try XCTUnwrap(history.first { $0.id == targetAction.id })
        let targetJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))
        let correctedTranscript = transcript.replacingOccurrences(of: "重拍", with: "重排")
        let correctedSpan = TranscriptSpan(id: unreviewedSource!.spans[0].id, textStart: 0, textEnd: correctedTranscript.unicodeScalars.count, startMS: 0, endMS: 500)
        func ref(_ quote: String) -> [String: Any] { ["recording": "next-recording", "quote": quote, "citation_status": "located", "span_ids": [correctedSpan.id]] }
        let nextItems: [[String: Any]] = [
            ["id": "R1", "title": "研究检索质量", "intent_type": "task", "uncertain": false, "followup_state": "pending", "notes": "", "references": [ref("我还要研究检索质量。")], "continuation": ["relation": "repeat", "target": targetJSON, "notes": "同一待办"]],
            ["id": "K2", "title": "重排不一定能提高相关性", "intent_type": "claim", "uncertain": false, "followup_state": "knowledge", "notes": "", "references": [ref("我已经比较了两种检索方法，发现重排不一定能提高相关性。")], "continuation": ["relation": "outcome", "target": targetJSON, "notes": "实际收获"]],
            ["id": "T2", "title": "做一次容量对比实验", "intent_type": "task", "uncertain": false, "followup_state": "pending", "notes": "", "references": [ref("下一步另做一次容量对比实验。")]]
        ]
        var nextChecked = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: nextFolder.appendingPathComponent("Qwen完整逐字稿.json"))) as? [String: Any])
        nextChecked["text"] = correctedTranscript
        nextChecked["spans"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([correctedSpan]))
        nextChecked["transcription_review"] = ["completed": true, "changed": true, "response_id": "flow-next-context-review", "context_review_version": 3,
            "scope": "complete_expression_knowledge_and_intent", "review_method": "direct_ai", "full_text_independent_passes": 1,
            "response_ids": ["flow-next-context-review"], "unresolved_issues": [],
            "corrections": [["span_id": correctedSpan.id, "before": "重拍", "after": "重排", "reason": "检索上下文的词语推断"]]]
        var incompleteReview = nextChecked
        var oldQuality = try XCTUnwrap(nextChecked["transcription_review"] as? [String: Any])
        oldQuality["context_review_version"] = 1
        incompleteReview["transcription_review"] = oldQuality
        try JSONSerialization.data(withJSONObject: incompleteReview).write(to: nextFolder.appendingPathComponent("Qwen核对逐字稿.json"))
        let originalVersion = try XCTUnwrap(unreviewedSource?.transcriptVersionID)
        do { _ = try await store.applyTranscriptQualityResult(sourceID: next.sourceID, expectedVersionID: originalVersion, from: nextFolder); XCTFail("旧局部校正回执不能通过全文质量核查") }
        catch { XCTAssertTrue(error.localizedDescription.contains("转写校正期间")) }
        try FileManager.default.removeItem(at: nextFolder.appendingPathComponent("Qwen核对逐字稿.json"))
        var correctedManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: nextFolder.appendingPathComponent("source.json"))) as? [String: Any])
        correctedManifest["transcription_input_sha256"] = SHA256.hash(data: Data(transcript.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: correctedManifest).write(to: nextFolder.appendingPathComponent("source.json"))
        try JSONSerialization.data(withJSONObject: nextChecked).write(to: nextFolder.appendingPathComponent("Qwen完整逐字稿.json"))
        _ = try await store.applyTranscriptQualityResult(sourceID: next.sourceID, expectedVersionID: originalVersion, from: nextFolder)
        let reviewedSource = try await store.sources().first { $0.id == next.sourceID }
        XCTAssertEqual(reviewedSource?.needsTranscriptionReview, false)
        XCTAssertEqual(reviewedSource?.transcript, correctedTranscript)
        let reviewedTitles = try await store.prepareRecordingTitles(sourceIDs: [next.sourceID])
        XCTAssertNotNil(reviewedTitles)
        let nextPayload: [String: Any] = ["source_folders": [nextFolder.path], "all_audio_complete": true, "all_windows_checked": true, "api_review_completed": true, "continuations_checked": true, "independent_semantic_review_completed": true, "audio_review_completed": true, "items": nextItems]
        try JSONSerialization.data(withJSONObject: nextPayload).write(to: nextBase.appendingPathComponent("完整任务清单.json"))
        _ = try await store.ingestOrganizedPodcast(at: nextBase, allowReminderWrites: true, requireAPIReview: true)
        try await store.refreshAuthorizedReminders(expectedAccessVersion: 1, using: reminders)
        let after = try await store.actions(includeHistory: true), linked = try await store.actionFeedback(actionID: targetAction.id)
        XCTAssertEqual(after.count, repeated.count + 1)
        XCTAssertEqual(after.first { $0.id == targetAction.id }?.state, "open")
        XCTAssertEqual(Set(linked.map(\.relation)), ["repeat", "outcome"])
        XCTAssertTrue(linked.allSatisfy { $0.recordingSourceID == next.sourceID && correctedTranscript.contains($0.text) })
        let afterReminders = await reminders.items.count
        XCTAssertEqual(afterReminders, reminderCount + 1)
        _ = try await store.ingestOrganizedPodcast(at: nextBase, allowReminderWrites: true, requireAPIReview: true)
        try await store.recover()
        let retained = try await store.actionFeedback(actionID: targetAction.id)
        XCTAssertEqual(retained.count, 2)
        let revised = try await store.sources().first { $0.id == next.sourceID }
        XCTAssertEqual(revised?.transcriptionReview?.correction_count, 1)
        XCTAssertNil(revised?.transcriptionReview?.corrections)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextFolder.appendingPathComponent("Qwen核对逐字稿.json").path))
        let canonical = try JSONSerialization.jsonObject(with: Data(contentsOf: nextFolder.appendingPathComponent("Qwen完整逐字稿.json"))) as? [String: Any]
        XCTAssertEqual(canonical?["text"] as? String, correctedTranscript)
        let revisedContext = try await store.prepareLocalTranscriptContext(sourceIDs: [next.sourceID])
        XCTAssertNil(revisedContext.sources.first?.transcriptionReview?.corrections)
        let contextPackage = root.appendingPathComponent("context-correction-package"), contextRestore = root.appendingPathComponent("context-correction-restore")
        try await store.exportPackage(to: contextPackage, includeMedia: true)
        try await VoiceOSStore.restorePackage(from: contextPackage, to: contextRestore, inspector: NativeMediaInspector())
        let contextStore = try VoiceOSStore(root: contextRestore, inspector: NativeMediaInspector())
        try await contextStore.recover()
        let historicalSession = try await contextStore.conversation(id: historicalDiscussion)
        XCTAssertEqual(historicalSession.validity, "frozen")
        let historicalSources = try await contextStore.conversationHistorySources(conversationID: historicalDiscussion)
        XCTAssertEqual(historicalSources.first?.text, transcript)
        let historicalTurns = try await contextStore.conversationUserTurns(conversationID: historicalDiscussion)
        XCTAssertEqual(historicalTurns.first?.text, "请保留校正前的讨论依据。")
        do { _ = try await contextStore.prepareConversationInput(id: historicalDiscussion, expectedVersion: 2, destination: .local); XCTFail("冻结历史不能重新进入模型输入") } catch {}
        let restoredContextSource = try await contextStore.sources().first { $0.id == next.sourceID }
        XCTAssertEqual(restoredContextSource?.transcriptionReview?.correction_count, 1)
        XCTAssertNil(restoredContextSource?.transcriptionReview?.corrections)
        let beforeCorrection = try await store.transcriptHistory(sourceID: next.sourceID)
        _ = try await store.correctTranscript(sourceID: next.sourceID, expectedVersionID: beforeCorrection[0].id, text: correctedTranscript + "补充：需要继续验证。")
        let stale = try await store.actionFeedback(actionID: targetAction.id)
        XCTAssertTrue(stale.allSatisfy { $0.sourceState == "frozen" })
        let audioHistory = try await store.transcriptHistory(sourceID: next.sourceID)
        XCTAssertEqual(audioHistory.count, 2)
        XCTAssertTrue(audioHistory.contains { $0.reason == "ai_corrected" && $0.text == correctedTranscript })
        XCTAssertEqual(audioHistory.last?.text, correctedTranscript)
        try await store.recover()
        let package = root.appendingPathComponent("audio-reviewed-package"), restoredRoot = root.appendingPathComponent("audio-reviewed-restore")
        try await store.exportPackage(to: package, includeMedia: true)
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: NativeMediaInspector())
        try await restored.recover()
        let restoredRecording = try await restored.sources().first { $0.id == intent.sourceID }
        XCTAssertEqual(restoredRecording?.displayTitle, "我的检索研究")
        XCTAssertEqual(restoredRecording?.presentation?.automatic?.title, "检索质量与记忆容量")
        try await store.renameRecording(sourceID: intent.sourceID, title: nil)
        _ = try await store.correctTranscript(sourceID: intent.sourceID, expectedVersionID: source.transcriptVersionID!, text: "更正：我想研究检索质量。")
        let corrected = try await store.sources().first { $0.id == intent.sourceID }
        XCTAssertNil(corrected?.contentTitle)
        let regenerated = try await store.generateRecordingTitles(using: FlowRecordingTitles(), sourceIDs: [intent.sourceID])
        XCTAssertEqual(regenerated, 1)
        let legacy=try VoiceOSStore(root:root.appendingPathComponent("legacy-intake"),inspector:NativeMediaInspector())
        try await legacy.recover()
        let oldAudio=try await store.playableURL(sourceID:intent.sourceID)
        let oldID=try await legacy.importPersonalAudio(oldAudio,commandID:"automatic-recording:legacy-fixture:0")
        _ = try await legacy.setSourceLocalOnly(sourceID:oldID,expectedVersion:1,localOnly:false)
        try await legacy.processTranscriptions(using:FlowSpeech(),sourceIDs:[oldID])
        let legacyContext=try await legacy.prepareLocalTranscriptContext(sourceIDs:[oldID],scalarBudget:10000)
        _ = try await legacy.importOrganizedClaims(context:legacyContext,proposals:[],commandID:"legacy-complete")
        try await legacy.enrollPreviouslyImportedAutomaticRecordings()
        let enrolled=try await legacy.sources().first { $0.id == oldID }
        XCTAssertNotNil(enrolled?.presentation?.automaticInput)
        try await legacy.enrollPreviouslyImportedAutomaticRecordings()
        let reenrolled=try await legacy.sources().first { $0.id == oldID }
        XCTAssertEqual(enrolled?.presentation?.automaticInput?.discoveredAt,reenrolled?.presentation?.automaticInput?.discoveredAt)
        let legacyInput=try await legacy.prepareRecordingExpressions()
        XCTAssertEqual(legacyInput?.newSourceIDs,[oldID])
        let legacyGroups=try await legacy.connectRecordingExpressions(using:FlowRecordingExpressions())
        let legacyGroup=try XCTUnwrap(legacyGroups.first)
        let reusedLegacy=try await legacy.completeUnchangedSingleRecording(legacyGroup)
        XCTAssertTrue(reusedLegacy)
        let completedLegacy=try await legacy.recordingExpressions()
        XCTAssertEqual(completedLegacy.first?.state,"completed")
        _ = try await legacy.setSourceLocalOnly(sourceID:oldID,expectedVersion:2,localOnly:true)
        let revokedLegacy=try await legacy.prepareRecordingExpressions()
        XCTAssertNil(revokedLegacy)
        let groupedRoot=root.appendingPathComponent("automatic-expressions")
        let grouped=try VoiceOSStore(root:groupedRoot,inspector:NativeMediaInspector())
        try await grouped.recover()
        let texts=["我要整理方案A对比报告，还要整理背景笔记，另外给同事发送方案A。先说报告背景。", "接着刚才那份报告，补充要比较准确性和速度，不要拆成两份报告。", "另外单独记一件事情，周末买咖啡豆。这和刚才的报告无关。"]
        var members:[String]=[]
        for (index,text) in texts.enumerated() {
            let id=try await grouped.recordUserExpression(text)
            _ = try await grouped.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
            try await grouped.registerAutomaticRecording(sourceID:id,inbox:index == 1 ? "phone-sync" : "synthetic-inbox",recordedAt:"2026-10-16T02:0\(index):00Z")
            members.append(id)
        }
        let fixture=FlowRecordingExpressions()
        let grouping:any RecordingExpressionPort = fixture
        let actionPort:any RecordingExpressionActionPort = fixture
        let connected=try await grouped.connectRecordingExpressions(using:grouping)
        XCTAssertEqual(connected.count,2)
        let report=try XCTUnwrap(connected.first { $0.sourceIDs.contains(members[0]) })
        XCTAssertEqual(report.sourceIDs,Array(members.prefix(2)))
        XCTAssertFalse(report.sourceIDs.contains(members[2]))
        let context=try await grouped.prepareLocalTranscriptContext(sourceIDs:report.sourceIDs,scalarBudget:10000)
        let refs=context.sources.map { ClaimReference(sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID,spanID:$0.spans[0].id) }
        _ = try await grouped.importOrganizedClaims(context:context,proposals:[
            .init(statement:"整理方案A对比报告",ownership:.userTentative,references:refs,action:.init(title:"整理方案A对比报告",kind:.task,quote:texts[0])),
            .init(statement:"整理背景笔记",ownership:.userTentative,references:refs,action:.init(title:"整理背景笔记",kind:.task,quote:texts[0])),
            .init(statement:"给同事发送方案A",ownership:.userTentative,references:refs,action:.init(title:"给同事发送方案A",kind:.task,quote:texts[0]))
        ],commandID:"initial-expression")
        try await grouped.finishRecordingExpression(report,using:actionPort)
        let originalActions=try await grouped.actions()
        let completed=try XCTUnwrap(originalActions.first { $0.title.contains("背景") })
        _ = try await grouped.setActionState(actionID:completed.id,expectedVersion:completed.version,state:.completed)
        _ = try await grouped.recordActionFeedback(actionID:completed.id,expectedVersion:completed.version+1,kind:.reflection,text:"笔记已实际整理，真实完成记录不能被补录抹去。")
        let groupedReminders=FlowReminders()
        let access=try await grouped.setReminderAccess(calendarID:"expression-calendar",title:"VoiceOS",enabled:true,expectedVersion:0)
        for task in originalActions where task.id != completed.id {
            try await grouped.sendTaskToReminders(actionID:task.id,expectedVersion:task.version,calendarID:access.calendarID,using:groupedReminders,expectedAccessVersion:access.version)
        }
        let late=try await grouped.recordUserExpression("补充刚才那份方案报告：不要采用方案A了，改成方案B，仍然只要一份对比准确性和速度的报告。背景笔记已经整理完了。也取消给同事发送方案A，不用发送。")
        _ = try await grouped.setSourceLocalOnly(sourceID:late,expectedVersion:1,localOnly:false)
        try await grouped.registerAutomaticRecording(sourceID:late,inbox:"synthetic-inbox",recordedAt:"2026-10-16T02:05:00Z")
        let extended=try await grouped.connectRecordingExpressions(using:grouping)
        let whole=try XCTUnwrap(extended.first { $0.id == report.id })
        XCTAssertEqual(whole.sourceIDs,report.sourceIDs+[late])
        let wholeContext=try await grouped.prepareLocalTranscriptContext(sourceIDs:whole.sourceIDs,scalarBudget:10000)
        let wholeRefs=wholeContext.sources.map { ClaimReference(sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID,spanID:$0.spans[0].id) }
        _ = try await grouped.importOrganizedClaims(context:wholeContext,proposals:[
            .init(statement:"整理方案B对比报告",ownership:.userTentative,references:wholeRefs,action:.init(title:"整理方案B对比报告",kind:.task,quote:wholeContext.sources.last!.text)),
            .init(statement:"整理背景笔记",ownership:.userTentative,references:wholeRefs,action:.init(title:"整理背景笔记",kind:.task,quote:wholeContext.sources.last!.text))
        ],commandID:"whole-expression")
        try await grouped.finishRecordingExpression(whole,using:actionPort)
        let finalActions=try await grouped.actions(includeHistory:true)
        let current=finalActions.filter { $0.validity == "current" && $0.state != "dismissed" }
        XCTAssertEqual(current.count,2)
        XCTAssertEqual(current.first { $0.title.contains("报告") }?.id,originalActions.first { $0.title.contains("报告") }?.id)
        XCTAssertEqual(current.first { $0.id == completed.id }?.state,"completed")
        let actualFeedback=try await grouped.actionFeedback(actionID:completed.id)
        XCTAssertEqual(actualFeedback.count,1)
        XCTAssertEqual(finalActions.first { $0.id == originalActions.first { $0.title.contains("发送") }!.id }?.state,"dismissed")
        try await grouped.refreshAuthorizedReminders(expectedAccessVersion:access.version,using:groupedReminders)
        let remote=await groupedReminders.items
        XCTAssertEqual(remote.count,2)
        XCTAssertTrue(remote.contains { $0.title == "整理方案A对比报告" && !$0.completed })
        XCTAssertTrue(remote.contains { $0.title == "给同事发送方案A" && !$0.completed })
        try await grouped.dbValidateFlowActions()
        let groupPackage=root.appendingPathComponent("expression-package")
        try await grouped.exportPackage(to:groupPackage,includeMedia:true)
        let groupRestoredRoot=root.appendingPathComponent("expression-restored")
        try await VoiceOSStore.restorePackage(from:groupPackage,to:groupRestoredRoot,inspector:NativeMediaInspector())
        let groupRestored=try VoiceOSStore(root:groupRestoredRoot,inspector:NativeMediaInspector())
        try await groupRestored.recover()
        let restoredMembers=try await groupRestored.sources()
        XCTAssertEqual(restoredMembers.first { $0.id == members[0] }?.presentation?.expression?.sourceIDs,whole.sourceIDs)
        let restoredActions=try await groupRestored.actions(includeHistory:true)
        XCTAssertEqual(restoredActions.first { $0.id == completed.id }?.state,"completed")
        let dual=try VoiceOSStore(root:root.appendingPathComponent("dual-recording"),inspector:NativeMediaInspector())
        try await dual.recover()
        let personalText="嘉宾说应完全自主，我认为还需要可靠验证。我会做一次界面验证。"
        let programmeText="智能体可以完全自主。节目组会在明天发布报告。"
        let personalID=try await dual.importPersonalAudio(oldAudio,commandID:"dual-personal")
        let programmeID=try await dual.importFile(oldAudio,commandID:"dual-programme")
        for id in [personalID,programmeID] { _ = try await dual.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false) }
        try await dual.processTranscriptions(using:FlowSpeech(text:personalText,timed:true),sourceIDs:[personalID])
        try await dual.processTranscriptions(using:FlowSpeech(text:programmeText,timed:true),sourceIDs:[programmeID])
        func reviewDual(_ id:String) async throws {
            let currentRecords=try await dual.sources()
            let record=try XCTUnwrap(currentRecords.first { $0.id == id })
            let target=root.appendingPathComponent("dual-review/"+id+"/"+record.transcriptVersionID!)
            _ = try await dual.writeOrganizingInput(sourceID:id,to:target,reviewTranscriptOnly:true)
            var value=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:target.appendingPathComponent("Qwen完整逐字稿.json"))) as? [String:Any])
            value["transcription_review"]=["completed":true,"changed":false,"response_id":"dual-quality-"+id,"response_ids":["dual-quality-"+id],"context_review_version":3,"scope":"complete_expression_knowledge_and_intent","review_method":"direct_ai","full_text_independent_passes":1,"unresolved_issues":[]]
            try JSONSerialization.data(withJSONObject:value).write(to:target.appendingPathComponent("Qwen核对逐字稿.json"))
            _ = try await dual.applyTranscriptQualityResult(sourceID:id,expectedVersionID:record.transcriptVersionID!,from:target)
        }
        try await reviewDual(personalID);try await reviewDual(programmeID)
        try await dual.attachRecordingContext(personalSourceID:personalID,externalSourceID:programmeID,sessionID:"dual-session",offsetMS:250)
        try await dual.registerAutomaticRecording(sourceID:personalID,inbox:"synthetic-dual",recordedAt:"2026-10-17T02:00:00Z")
        let dualGroups=try await dual.connectRecordingExpressions(using:fixture)
        let dualGroup=try XCTUnwrap(dualGroups.first)
        XCTAssertEqual(dualGroup.sourceIDs,[personalID])
        XCTAssertEqual(Set(dualGroup.externalVersions?.keys.map { $0 } ?? []),[programmeID])
        let dualBase=root.appendingPathComponent("dual-organized"),dualFolder=dualBase.appendingPathComponent("personal")
        func writeDual(_ externalQuote:String) async throws {
            _ = try await dual.writeOrganizingInput(sourceID:personalID,to:dualFolder)
            let input=try JSONSerialization.jsonObject(with:Data(contentsOf:dualFolder.appendingPathComponent("外部上下文.json")))
            let personalRecords=try await dual.sources()
            let personal=try XCTUnwrap(personalRecords.first { $0.id == personalID })
            let ref:[String:Any]=["recording":"personal","quote":personalText,"citation_status":"located","span_ids":[personal.spans[0].id]]
            let list:[String:Any]=["source_folders":[dualFolder.path],"all_audio_complete":true,"all_windows_checked":true,"api_review_completed":true,"continuations_checked":true,"intent_review_completed":true,"transcription_review_completed":true,
                "items":[["id":"OWN1","title":"我认为自主执行还需要可靠验证","intent_type":"claim","uncertain":false,"followup_state":"knowledge","notes":"个人补充条件","references":[ref]],["id":"OWN2","title":"做一次界面验证","intent_type":"task","uncertain":false,"followup_state":"pending","notes":"","references":[ref]]],
                "recording_contexts":[input],"context_response_ids":["dual-first","dual-independent"],
                "context_links":[["taskID":"OWN1","personalSourceID":personalID,"personalQuote":"我认为还需要可靠验证。","externalSourceID":programmeID,"externalQuote":externalQuote,"externalStatement":externalQuote,"relation":"qualification","explanation":"个人明确补充验证条件；节目组的发布安排不属于本人任务。"]]]
            try JSONSerialization.data(withJSONObject:list,options:.sortedKeys).write(to:dualBase.appendingPathComponent("完整任务清单.json"))
        }
        try await writeDual("智能体可以完全自主。")
        let dualInput=try String(contentsOf:dualFolder.appendingPathComponent("外部上下文.json"),encoding:.utf8)
        XCTAssertTrue(dualInput.contains(programmeText))
        _ = try await dual.ingestOrganizedPodcast(at:dualBase,requireAPIReview:true)
        try await dual.finishRecordingExpression(dualGroup,using:fixture)
        let dualClaims=try await dual.candidateClaims(),dualActions=try await dual.actions()
        XCTAssertEqual(dualClaims.filter { $0.ownership == "external" }.count,1)
        XCTAssertEqual(dualActions.count,1)
        XCTAssertFalse(dualActions.contains { $0.title.contains("发布报告") })
        let dualLinks=try await dual.recordingContextLinks(sourceID:personalID)
        XCTAssertEqual(dualLinks.count,1)
        XCTAssertEqual(dualLinks.first?.pairing.offsetMS,250)
        let expanded=try await dual.recordingContextSourceIDs(sourceIDs:[personalID])
        let dualConversation=try await dual.beginConversation(sourceIDs:expanded)
        let dualQuestion=try await dual.recordUserExpression("我的补充条件与节目观点有什么区别？")
        _ = try await dual.setSourceLocalOnly(sourceID:dualQuestion,expectedVersion:1,localOnly:false)
        _ = try await dual.appendConversationUserSource(conversationID:dualConversation,sourceID:dualQuestion,expectedVersion:1)
        let dualDiscussion=try await dual.prepareConversationInput(id:dualConversation,expectedVersion:2,destination:.cloud)
        let dualDiscussionContext=try await dual.validateConversationInput(dualDiscussion)
        XCTAssertEqual(Set(dualDiscussionContext.sources.map(\.sourceID)),[personalID,programmeID,dualQuestion])
        let dualTask=try XCTUnwrap(dualActions.first)
        _ = try await dual.setActionState(actionID:dualTask.id,expectedVersion:dualTask.version,state:.completed)
        _ = try await dual.recordActionFeedback(actionID:dualTask.id,expectedVersion:dualTask.version+1,kind:.reflection,text:"实际执行过，结果仍需具体核对。")
        let dualPackage=root.appendingPathComponent("dual-package")
        try await dual.exportPackage(to:dualPackage,includeMedia:true)
        let dualRestoredRoot=root.appendingPathComponent("dual-restored")
        try await VoiceOSStore.restorePackage(from:dualPackage,to:dualRestoredRoot,inspector:NativeMediaInspector())
        let dualRestored=try VoiceOSStore(root:dualRestoredRoot,inspector:NativeMediaInspector())
        try await dualRestored.recover()
        let dualRestoredRecords=try await dualRestored.sources()
        XCTAssertEqual(dualRestoredRecords.first { $0.id == personalID }?.presentation?.recordingContext?.externalSourceID,programmeID)
        XCTAssertEqual(dualRestoredRecords.first { $0.id == programmeID }?.origin,"external")
        let programmeRecords=try await dual.sources()
        let programmeBefore=try XCTUnwrap(programmeRecords.first { $0.id == programmeID })
        _ = try await dual.correctTranscript(sourceID:programmeID,expectedVersionID:programmeBefore.transcriptVersionID!,text:"智能体不能完全自主。节目组会在明天发布报告。")
        do { _ = try await dual.recordingContextLinks(sourceID:personalID);XCTFail("旧双轨关联不能绕过节目更正") } catch {}
        let correctionMembers=try await dual.queueCorrectedRecordingUnderstanding(sourceID:programmeID,previousActionIDs:[dualTask.id])
        XCTAssertEqual(correctionMembers,[personalID])
        try await dual.refreshCorrectedRecordingContexts(sourceIDs:correctionMembers)
        let repairedGroups=try await dual.connectRecordingExpressions(using:fixture)
        let repairedGroup=try XCTUnwrap(repairedGroups.first)
        XCTAssertTrue(repairedGroup.previousActionIDs.contains(dualTask.id))
        try await writeDual("智能体不能完全自主。")
        _ = try await dual.ingestOrganizedPodcast(at:dualBase,requireAPIReview:true)
        try await dual.finishRecordingExpression(repairedGroup,using:fixture)
        let repairedActions=try await dual.actions(includeHistory:true)
        XCTAssertEqual(repairedActions.first { $0.id == dualTask.id }?.state,"completed")
        XCTAssertEqual(repairedActions.filter { $0.validity == "current" && $0.state != "dismissed" }.count,1)
        let repairedFeedback=try await dual.actionFeedback(actionID:dualTask.id)
        XCTAssertEqual(repairedFeedback.count,1)
        let repairedRecords=try await dual.sources()
        let repairedPersonal=try XCTUnwrap(repairedRecords.first { $0.id == personalID })
        XCTAssertNil(repairedPersonal.presentation?.correctedSourceIDs)
        XCTAssertNil(repairedPersonal.presentation?.correctedActionIDs)
        let programmePolicy=try await dual.sourcePolicy(sourceID:programmeID)
        _ = try await dual.setSourceLocalOnly(sourceID:programmeID,expectedVersion:programmePolicy.version,localOnly:true)
        do { _ = try await dual.recordingContextSourceIDs(sourceIDs:[personalID]);XCTFail("撤回节目许可后不能继续发送上下文") } catch {}
        let invalidatedClaims=try await dual.candidateClaims(includeFrozen:true)
        XCTAssertTrue(invalidatedClaims.allSatisfy { $0.validity != "current" })
        let revokedPolicy=try await dual.sourcePolicy(sourceID:programmeID)
        _ = try await dual.setSourceLocalOnly(sourceID:programmeID,expectedVersion:revokedPolicy.version,localOnly:false)
        let dualRestoredMembers=try await dual.queueRecordingUnderstanding(sourceID:programmeID,previousActionIDs:[dualTask.id])
        XCTAssertEqual(dualRestoredMembers,[personalID])
        try await dual.refreshCorrectedRecordingContexts(sourceIDs:dualRestoredMembers)
        let restoredGroups=try await dual.connectRecordingExpressions(using:fixture)
        let restoredGroup=try XCTUnwrap(restoredGroups.first)
        XCTAssertTrue(restoredGroup.previousActionIDs.contains(dualTask.id))
        let restoredActionReview=try await dual.prepareExpressionActionReview(restoredGroup)
        XCTAssertNotEqual(restoredActionReview.transcriptionCorrection,true)
        XCTAssertEqual(restoredActionReview.oldActions.first { $0.id == dualTask.id }?.state,"completed")

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
