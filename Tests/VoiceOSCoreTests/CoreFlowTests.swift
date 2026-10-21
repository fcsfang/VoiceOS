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
private actor FlowPanorama: PanoramaModelPort {
    var generations=0
    var reviews=0
    var repairs=0
    var receivedRejection=false
    func generate(_ input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt) {
        generations += 1
        let questions=input.sources.prefix(2).enumerated().map { index, value in
            PanoramaQuestion(id: "q"+String(index), regionID: "r", title: "如何核对检索理解？", summary: "保留待核对问题", evidence: [.init(sourceID: value.id, transcriptVersionID: value.transcript.transcriptVersionID, start: 5, end: 6, quote: value.transcript.text, claimIDs: input.claims.filter { $0.references.contains { $0.sourceID == value.id } }.map(\.id))])
        }
        let represented=Set(questions.flatMap(\.evidence).flatMap(\.claimIDs))
        let proposal=PanoramaProposal(regions: [.init(id: "r", title: "检索研究", summary: "跨材料的探索")], questions: questions,
            relations: [.init(id: "e", from: "q0", to: "q1", label: "补充检索条件", explanation: "AI 候选，需核对双方条件", fromEvidence: questions[0].evidence, toEvidence: questions[1].evidence)],
            unrepresentedSources: input.sources.dropFirst(2).map { .init(id: $0.id, reason: "本轮未归入具体问题，仍可打开全文") },
            unrepresentedClaims: input.claims.filter { !represented.contains($0.id) }.map { .init(id: $0.id, reason: "保留在认识入口") })
        return (proposal, .init(responseID: "generation", model: "fixture", createdAt: "2026-10-21T00:00:00Z"))
    }
    func verify(_ proposal: PanoramaProposal, input: PanoramaInput, priorRejection: PanoramaRejection?) async throws -> (PanoramaReview, PanoramaReceipt) {
        reviews += 1
        if let priorRejection { receivedRejection = priorRejection.review.questions.contains { !$0.accepted } && priorRejection.proposal.questions.first?.summary == "保留待核对问题" }
        return (.init(questions: proposal.questions.map { .init(id: $0.id, accepted: reviews > 1, reason: reviews > 1 ? "合成依据对应" : "问题归纳需要保留否定条件") }, relations: proposal.relations.map { .init(id: $0.id, accepted: true, reason: "合成双侧依据对应") }, coverageAccepted: true, reason: "全量输入与未表达项均核对"), .init(responseID: "verification-"+String(reviews), model: "fixture", createdAt: "2026-10-21T00:00:01Z"))
    }
    func repair(_ proposal: PanoramaProposal, input: PanoramaInput, review: PanoramaReview) async throws -> (PanoramaProposal, PanoramaReceipt) {
        repairs += 1
        let questions=proposal.questions.map { PanoramaQuestion(id: $0.id, regionID: $0.regionID, title: $0.title, summary: $0.summary+"，保留否定条件", evidence: $0.evidence) }
        return (.init(regions: proposal.regions, questions: questions, relations: proposal.relations, unrepresentedSources: proposal.unrepresentedSources, unrepresentedClaims: proposal.unrepresentedClaims), .init(responseID: "repair", model: "fixture", createdAt: "2026-10-21T00:00:01Z"))
    }
}
private struct FlowPanoramaFailureTransport: ModelHTTPTransport {
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://fixture.invalid/private?key=fixture-secret")!])
    }
}
private actor FlowCompleteDiscussion: DiscussionModelPort, ConversationOutcomePort {
    let configuration=flowConfiguration
    var snapshots: [DiscussionSnapshot]=[]
    func reply(_ request: DiscussionModelRequest) async throws -> DiscussionModelResponse {
        snapshots.append(request.snapshot)
        return .init(status: .completed, parts: [.init(kind: .aiSuggestion, text: "这是合成的待核对分析。")])
    }
    func extract(_ request: ConversationOutcomeRequest) async throws -> ConversationOutcomeResponse {
        let source=request.snapshot.context.sources.last!
        let reference=ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id)
        return .init(status:.completed,proposals:[.init(statement:"这是合成的成果候选。",ownership:.aiCandidate,sourceEvidence:[.init(reference:reference,quote:source.text)])])
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
private struct FlowRelevance: RelevanceModelPort {
    let configuration = flowConfiguration
    func select(_ request: RelevanceModelRequest) async throws -> RelevanceModelResponse {
        .init(status: .completed, selection: .init(snapshotID: request.snapshot.id, queryID: request.snapshot.queryID, candidateIDs: request.snapshot.candidates.map(\.id)))
    }
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

private actor FlowFollowupTransport: ModelHTTPTransport {
    let replies: [ModelHTTPReply]
    let cancelAt: Int?
    var requests: [Data] = []
    init(_ replies: [ModelHTTPReply], cancelAt: Int? = nil) { self.replies = replies; self.cancelAt = cancelAt }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        let index = requests.count
        requests.append(request.httpBody ?? Data())
        guard index < replies.count else { throw VoiceOSError("Unexpected follow-up send") }
        if requests.count == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
        return replies[index]
    }
}
private actor FlowFollowup: RecordingFollowupPort {
    var calls = 0
    var remainingFailures = 0
    var duringGeneration: (@Sendable () async throws -> Void)?
    init(failures: Int = 0, duringGeneration: (@Sendable () async throws -> Void)? = nil) { self.remainingFailures = failures; self.duringGeneration = duringGeneration }
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration {
        calls += 1
        if remainingFailures > 0 { remainingFailures -= 1; throw URLError(.timedOut) }
        if let duringGeneration { self.duringGeneration = nil; try await duringGeneration() }
        let text = input.current.sources[0].text
        let old = input.thoughts.first { $0.statement.contains("容量越大") }
        let updates: [ThoughtUpdate] = old.map { [.init(claimID: $0.id, currentQuote: text, historicalQuote: $0.evidence[0].quote, relation: "qualifies", understanding: "检索质量需要与容量分别考虑", reason: "新表达限定此前的容量判断")] } ?? []
        let plans = input.goals.map { goal in
            let title = input.tasks.contains(where: { $0.state == "completed" }) ? "再录一次三分钟英语讲解，应用上次表达反馈" : "录制一次三分钟英语讲解"
            let task = input.tasks.first { $0.state == "open" && $0.goalID == goal.id }
            let step = GoalStep(title: task?.title ?? title, condition: "有安静环境时进行，不设硬性截止日期", existingTaskID: task?.id ?? "")
            return GoalPlan(goalID: goal.id, summary: goal.title, adjustment: "依据已完成步骤和当前表达选择下一步", phases: [.init(title: "表达与复练", steps: [step])], nextStep: step)
        }
        let improved = text.contains("The agent has")
        let oldPractice = input.practices.first { $0.text.contains("Today I explain") }
        let comparison: [PracticeComparison] = oldPractice.map { [.init(priorSourceID: $0.sourceID, priorQuote: $0.text, currentQuote: text, change: improved ? "improved" : "repeated", explanation: "比较同一技术主题的主谓一致表达")] } ?? []
        let english = PracticeFollowup(isPractice: true, evidenceQuote: text, suggestions: [.init(original: text, suggested: "The agent has a memory. It helps us find facts.", explanation: "注意单数主语的动词形式", possibleTranscriptIssue: false)], comparisons: comparison, nextExercise: "再用一分钟解释检索质量，练习 has 和 helps")
        return .init(result: .init(thoughtUpdates: updates, goalPlans: plans, english: english), responseIDs: ["fixture-generation", "fixture-review"])
    }
}
private extension VoiceOSStore {
    func markFlowGoal(_ id: String) throws {
        try db.execute("UPDATE actions SET intent_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(ActionIntentMetadata(intentType: "goal", followupState: "pending", uncertain: false)), as: UTF8.self), id])
    }
    func interruptFlowFollowup(_ id: String) throws {
        var receipts = try recordingFollowups()
        let index = receipts.firstIndex { $0.id == id }!
        receipts[index].state = "running"
        try db.execute("UPDATE sources SET followup_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(receipts.filter { $0.sourceID == receipts[index].sourceID }), as: UTF8.self), receipts[index].sourceID])
        try recoverRecordingFollowups()
    }
    func expireFlowFollowupRetry(_ id: String) throws {
        var receipts = try recordingFollowups()
        let index = receipts.firstIndex { $0.id == id }!
        receipts[index].retryAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
        try db.execute("UPDATE sources SET followup_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(receipts.filter { $0.sourceID == receipts[index].sourceID }), as: UTF8.self), receipts[index].sourceID])
    }
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
        let queuedHistory = try await store.prepareExpressionProcessingIntent(sourceID: next.sourceID, cognition: model.configuration, association: association.configuration)
        let queuedHistoryID = try await store.enqueueExpressionProcessingIntent(queuedHistory, cognition: model.configuration, association: association.configuration).id
        let segmentedHistory = try await store.prepareSegmentedExpressionProcessingScope(sourceID: next.sourceID, extraction: model.configuration, aggregation: model.configuration, segmentScalarBudget: 20)
        let segmentedHistoryID = try await store.enqueueSegmentedProcessingBatch(segmentedHistory, extraction: model.configuration, aggregation: model.configuration).id
        let historicalHits = try await store.retrieve("检索", using: NativeRetrieval())
        let oldHit = try XCTUnwrap(historicalHits.hits.first { $0.document.sourceID == next.sourceID })
        let otherHit = try XCTUnwrap(historicalHits.hits.first { $0.document.sourceID == intent.sourceID })
        let relevanceHistory = try await store.prepareRelevanceSnapshot(query: "检索", queryID: UUID(), candidates: [oldHit])
        _ = try await store.performRelevanceSelection(relevanceHistory, using: FlowRelevance())
        let associationHistory = try await store.prepareExpressionAssociation(currentSourceID: next.sourceID, candidates: [otherHit])
        _ = try await store.reserveExpressionAssociation(associationHistory, configuration: association.configuration)
        let candidateHistory = try await store.prepareExpressionAssociation(currentSourceID: historicalQuestion, candidates: [oldHit])
        _ = try await store.reserveExpressionAssociation(candidateHistory, configuration: association.configuration)
        let questionRef = ClaimReference(sourceID: next.sourceID, transcriptVersionID: localUnreviewed.sources[0].transcriptVersionID, spanID: localUnreviewed.sources[0].spans[0].id)
        let questionClaims = try await store.importOrganizedClaims(context: localUnreviewed, proposals: [.init(statement: "检索该怎样验证？", ownership: .userTentative, references: [questionRef], contentKind: .question)], commandID: "historical-question")
        let questionSeed = try await store.prepareQuestionSeed(claimID: questionClaims[0], expectedReviewVersion: 0, original: .init(reference: questionRef, quote: transcript))
        let historicalQuestionID = try await store.registerQuestion(questionSeed)
        let answerQuestionContext = try await store.prepareLocalTranscriptContext(sourceIDs: [historicalQuestion])
        let answerQuestionRef = ClaimReference(sourceID: historicalQuestion, transcriptVersionID: answerQuestionContext.sources[0].transcriptVersionID, spanID: answerQuestionContext.sources[0].spans[0].id)
        let answerQuestionClaims = try await store.importOrganizedClaims(context: answerQuestionContext, proposals: [.init(statement: "答案是否仍有效？", ownership: .userTentative, references: [answerQuestionRef], contentKind: .question)], commandID: "historical-answer-question")
        let answerQuestionSeed = try await store.prepareQuestionSeed(claimID: answerQuestionClaims[0], expectedReviewVersion: 0, original: .init(reference: answerQuestionRef, quote: answerQuestionContext.sources[0].text))
        let answerQuestionID = try await store.registerQuestion(answerQuestionSeed)
        let answerTransition = try await store.prepareStoredQuestionTransition(questionID: answerQuestionID, expectedVersion: 1, to: .resolved, reason: "合成答案已记录", resolution: .init(reference: questionRef, quote: transcript))
        _ = try await store.transitionQuestion(questionID: answerQuestionID, input: answerTransition)


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
        let correctedDatabase = await store.db
        for validate in [VoiceOSStore.validateStoredRelevance, VoiceOSStore.validateStoredConversations,
                         VoiceOSStore.validateStoredExpressionAssociations, VoiceOSStore.validateStoredQuestions,
                         VoiceOSStore.validateStoredProcessingIntents, VoiceOSStore.validateStoredSegmentedProcessingBatches] {
            do { try validate(correctedDatabase) } catch { XCTFail("AI 更正后的历史校验失败：\(error.localizedDescription)") }
        }
        let blockedHistory = try await store.runExpressionProcessingIntent(id: queuedHistoryID, retrieval: NativeRetrieval(), cognitionPort: model, associationPort: association)
        XCTAssertEqual(blockedHistory.state, .blocked)
        let blockedBatch = try await store.segmentedProcessingBatch(id: segmentedHistoryID)
        XCTAssertEqual(blockedBatch.state, .blocked)
        let changedAnswer = try await store.questions().first { $0.id == answerQuestionID }
        XCTAssertEqual(changedAnswer?.validity, "frozen")
        XCTAssertEqual(changedAnswer?.canReopen, true)
        let reopenAnswer = try await store.prepareStoredQuestionTransition(questionID: answerQuestionID, expectedVersion: 2, to: .open, reason: "答案更正后重新核对")
        _ = try await store.transitionQuestion(questionID: answerQuestionID, input: reopenAnswer)
        let reopenedAnswer = try await store.questions().first { $0.id == answerQuestionID }
        XCTAssertEqual(reopenedAnswer?.validity, "current")
        do { try await store.validateExpressionProcessingIntent(queuedHistory, cognition: model.configuration, association: association.configuration); XCTFail("历史处理意图不能发送") } catch {}
        do { try await store.validateSegmentedExpressionProcessingScope(segmentedHistory, extraction: model.configuration, aggregation: model.configuration); XCTFail("历史分段范围不能发送") } catch {}
        do { try await store.validateRelevanceSnapshot(relevanceHistory, currentQueryID: relevanceHistory.queryID); XCTFail("历史摘录不能发送") } catch {}
        do { try await store.validateQuestionSeed(questionSeed); XCTFail("历史提问不能充当当前依据") } catch {}
        do { try await store.validateExpressionAssociation(associationHistory); XCTFail("历史关联原话不能发送") } catch {}
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
        let restoredQueue = try await contextStore.runExpressionProcessingIntent(id: queuedHistoryID, retrieval: NativeRetrieval(), cognitionPort: model, associationPort: association)
        XCTAssertEqual(restoredQueue.state, .frozen)
        let restoredBatch = try await contextStore.segmentedProcessingBatch(id: segmentedHistoryID)
        XCTAssertEqual(restoredBatch.state, .frozen)
        let restoredQuestion = try await contextStore.questions().first { $0.id == historicalQuestionID }
        XCTAssertEqual(restoredQuestion?.validity, "frozen")
        do { try await contextStore.validateExpressionAssociation(candidateHistory); XCTFail("更正前的关联候选不得发送") } catch {}
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
        let reportConversation=try await grouped.beginConversation(sourceIDs:[members[0]])
        let reportQuestion=try await grouped.recordUserExpression("这份方案报告还有哪些待核对的问题？")
        _ = try await grouped.appendConversationUserSource(conversationID:reportConversation,sourceID:reportQuestion,expectedVersion:1)
        let reportInput=try await grouped.prepareConversationInput(id:reportConversation,expectedVersion:2,destination:.local)
        let reportReply=try await grouped.performConversationReply(reportInput,using:FlowCompleteDiscussion())
        try await grouped.endConversation(id:reportConversation,expectedVersion:2)
        let reportOutcome=try await grouped.prepareConversationOutcome(id:reportConversation,expectedVersion:3,destination:.local)
        let reportOutcomeClaims=try await grouped.performConversationOutcome(reportOutcome,using:FlowCompleteDiscussion())
        let independentSource=try await grouped.recordUserExpression("独立讨论如何核对既有成果。")
        let reusedConversation=try await grouped.beginConversation(sourceIDs:[independentSource])
        _ = try await grouped.appendConversationUserSource(conversationID:reusedConversation,sourceID:reportQuestion,expectedVersion:1)
        try await grouped.endConversation(id:reusedConversation,expectedVersion:2)
        let reusedOutcome=try await grouped.prepareReusableConversationOutcome(id:reusedConversation,expectedVersion:3,destination:.local)
        XCTAssertEqual(reusedOutcome.reusePlan?.priorResults.flatMap(\.claimIDs),reportOutcomeClaims)
        let reusedClaims=try await grouped.performConversationOutcome(reusedOutcome,using:FlowCompleteDiscussion())
        let late=try await grouped.recordUserExpression("补充刚才那份方案报告：不要采用方案A了，改成方案B，仍然只要一份对比准确性和速度的报告。背景笔记已经整理完了。也取消给同事发送方案A，不用发送。")
        _ = try await grouped.setSourceLocalOnly(sourceID:late,expectedVersion:1,localOnly:false)
        try await grouped.registerAutomaticRecording(sourceID:late,inbox:"synthetic-inbox",recordedAt:"2026-10-16T02:05:00Z")
        let extended=try await grouped.connectRecordingExpressions(using:grouping)
        let whole=try XCTUnwrap(extended.first { $0.id == report.id })
        XCTAssertEqual(whole.sourceIDs,report.sourceIDs+[late])
        let frozenReportConversation=try await grouped.conversation(id:reportConversation)
        let frozenReportReplies=try await grouped.discussionAttempts(conversationID:reportConversation)
        XCTAssertEqual(frozenReportConversation.validity,"frozen")
        XCTAssertEqual(frozenReportReplies.first { $0.id == reportReply }?.validity,"frozen")
        let frozenReusedOutcome=try await grouped.conversationOutcomes(conversationID:reusedConversation)
        let frozenReusedClaims=try await grouped.candidateClaims(includeFrozen:true)
        XCTAssertEqual(frozenReusedOutcome.first?.validity,"frozen")
        XCTAssertEqual(frozenReusedClaims.first { reusedClaims.contains($0.id) }?.validity,"frozen")
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
        let restoredReportReplies=try await groupRestored.discussionAttempts(conversationID:reportConversation)
        XCTAssertEqual(restoredReportReplies.first { $0.id == reportReply }?.validity,"frozen")
        XCTAssertEqual(restoredReportReplies.first { $0.id == reportReply }?.parts.first?.text,"这是合成的待核对分析。")
        let restoredReusedOutcome=try await groupRestored.conversationOutcomes(conversationID:reusedConversation)
        XCTAssertEqual(restoredReusedOutcome.first?.validity,"frozen")
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

        var corpus: [String]=[]
        for index in 0..<4 {
            let source=try await store.recordUserExpression(String(repeating: "合成检索资料需要完整保留。", count: 240)+String(index))
            _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
            corpus.append(source)
        }
        let full=try await store.prepareLocalTranscriptContext(sourceIDs: corpus, scalarBudget: Int.max)
        _ = try await store.importOrganizedClaims(context: full, proposals: [], commandID: "complete-zero-claims")
        let panorama=FlowPanorama()
        let eligible=try await store.panoramaInput()
        XCTAssertEqual(Set(eligible.manifest.sourceIDs), Set(corpus))
        XCTAssertEqual(eligible.claims.count, 0)
        XCTAssertGreaterThan(eligible.sources.reduce(0) { $0+$1.transcript.text.unicodeScalars.count }, 12000)
        let largeSummary=String(repeating: "完整合成解释。", count: 16000)
        let largeProposal=PanoramaProposal(regions: [.init(id: "r", title: "检索研究", summary: largeSummary)], questions: [], relations: [], unrepresentedSources: eligible.sources.map { .init(id: $0.id, reason: "保留全文入口") }, unrepresentedClaims: [])
        let text=String(decoding: try JSONEncoder().encode(largeProposal), as: UTF8.self)
        let envelope=try JSONSerialization.data(withJSONObject: ["id":"large-panorama", "status":"completed", "usage":["input_tokens":120, "output_tokens":100], "output":[["type":"message", "role":"assistant", "status":"completed", "content":[["type":"output_text", "text":text]]]]])
        XCTAssertGreaterThan(envelope.count, 262144)
        XCTAssertThrowsError(try ResponsesEnvelope.parse(envelope))
        let largePort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([.init(status: 200, body: envelope)]))
        let (decoded, receipt)=try await largePort.generate(eligible)
        XCTAssertEqual(decoded.regions.first?.summary, largeSummary)
        XCTAssertEqual(receipt.responseID, "large-panorama")
        XCTAssertEqual(receipt.inputTokens, 120)
        XCTAssertEqual(receipt.outputTokens, 100)
        let invalid=try JSONSerialization.data(withJSONObject: ["status":"completed", "output":[["type":"unsupported"]]])
        let rejectedPort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([.init(status: 200, body: invalid)]))
        do { try await store.generatePanorama(using: rejectedPort); XCTFail("无效响应不能发布") } catch {}
        let rejected=try await store.panoramaState()
        XCTAssertEqual(rejected.status, "failed")
        XCTAssertEqual(rejected.error, "响应包含不支持的输出项")
        XCTAssertNil(rejected.snapshot)
        let privateDetail="https://fixture.invalid/private?key=fixture-secret"
        let terminalFailures: [([String:Any],String)]=[
            (["status":"failed", "error":["code":"server_error", "message":privateDetail]], "响应未完成（status=failed；error.code=server_error）；未接纳部分结果"),
            (["status":"failed", "error":["code":privateDetail, "message":privateDetail]], "响应未完成（status=failed；error.code=unknown）；未接纳部分结果"),
            (["status":"completed"], "响应已完成但 output 缺失或格式无效（status=completed）"),
            (["status":"incomplete", "incomplete_details":["reason":"max_output_tokens"]], "响应未完成（status=incomplete；incomplete_details.reason=max_output_tokens）；未接纳部分结果"),
            (["status":"incomplete", "incomplete_details":["reason":privateDetail]], "响应未完成（status=incomplete；incomplete_details.reason=unknown）；未接纳部分结果"),
            (["status":privateDetail], "响应未完成（status=unknown）；未接纳部分结果")
        ]
        for (var response, expected) in terminalFailures {
            response["usage"]=["input_tokens":120,"output_tokens":100]
            let transport=FlowFollowupTransport([.init(status:200,body:try JSONSerialization.data(withJSONObject:response))])
            let port=try ResponsesPanoramaPort(baseURL:URL(string:"https://api.openai.com/v1")!,apiKey:"fixture",model:"fixture",transport:transport)
            do { try await store.generatePanorama(using:port,retry:true); XCTFail("终态失败不能发布") }
            catch ModelPortFailure.rejected(let reason,let input,let output) {
                XCTAssertEqual(reason,expected)
                XCTAssertEqual(input,120); XCTAssertEqual(output,100)
            }
            let failure=try await store.panoramaState()
            XCTAssertEqual(failure.status,"failed")
            XCTAssertEqual(failure.error,expected)
            XCTAssertFalse(failure.error?.contains("fixture-secret") ?? true)
            XCTAssertNil(failure.snapshot)
            let requests=await transport.requests
            XCTAssertEqual(requests.count,1)
        }
        let timedOutPort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowPanoramaFailureTransport())
        do { try await store.generatePanorama(using: timedOutPort, retry: true); XCTFail("网络失败不能发布") } catch {}
        let timedOut=try await store.panoramaState()
        XCTAssertEqual(timedOut.status, "failed")
        XCTAssertEqual(timedOut.error, "全景网络请求失败（错误码 -1001）；材料保留，请明确重试")
        XCTAssertNil(timedOut.snapshot)
        try await store.generatePanorama(using: panorama, retry: true)
        try await store.generatePanorama(using: panorama)
        let state=try await store.panoramaState(), snapshot=try XCTUnwrap(state.snapshot)
        XCTAssertEqual(snapshot.coverage.submittedSourceIDs.count, 4)
        XCTAssertEqual(snapshot.coverage.representedSourceIDs.count, 2)
        XCTAssertEqual(snapshot.coverage.unrepresentedSources.count, 2)
        let generationCount=await panorama.generations, reviewCount=await panorama.reviews, repairCount=await panorama.repairs
        XCTAssertEqual(generationCount, 1); XCTAssertEqual(reviewCount, 2); XCTAssertEqual(repairCount, 1)
        let receivedRejection=await panorama.receivedRejection
        XCTAssertTrue(receivedRejection)
        XCTAssertEqual(snapshot.proposal.questions.first?.evidence.first?.start, 0)
        XCTAssertEqual(snapshot.generation.responseID, "repair")
        let repeated=eligible.sources[0]
        let ambiguous=PanoramaEvidence(sourceID: repeated.id, transcriptVersionID: repeated.transcript.transcriptVersionID, start: -1, end: -1, quote: "合成检索资料需要完整保留。", claimIDs: [])
        let ambiguousProposal=PanoramaProposal(regions: snapshot.proposal.regions, questions: [.init(id: "ambiguous", regionID: "r", title: "重复原话", summary: "不能猜测位置", evidence: [ambiguous])], relations: [], unrepresentedSources: [], unrepresentedClaims: [])
        XCTAssertThrowsError(try VoiceOSStore.locatePanoramaQuotes(ambiguousProposal, input: eligible))
        let entry=try await store.beginPanoramaConversation(snapshotID: snapshot.id, selection: .relation("e"))
        XCTAssertTrue(entry.draft.contains("AI 全景候选"))
        let noTurns=try await store.conversationUserTurns(conversationID: entry.conversation.id)
        XCTAssertTrue(noTurns.isEmpty)
        try await store.endConversation(id: entry.conversation.id, expectedVersion: 1)
        let reopened=try await store.beginPanoramaConversation(snapshotID: snapshot.id, selection: .relation("e"))
        XCTAssertNotEqual(reopened.conversation.id, entry.conversation.id)
        XCTAssertEqual(reopened.conversation.state, "active")
        let conversation=try await store.beginConversation(sourceIDs: corpus)
        let discussion=FlowCompleteDiscussion()
        for ordinal in 1...2 {
            let turn=try await store.recordUserExpression("请核对合成资料第\(ordinal)轮。")
            _ = try await store.appendConversationUserSource(conversationID: conversation, sourceID: turn, expectedVersion: ordinal)
            let input=try await store.prepareConversationInput(id: conversation, expectedVersion: ordinal+1, destination: .local)
            _ = try await store.performConversationReply(input, using: discussion)
        }
        let sent=await discussion.snapshots
        XCTAssertEqual(sent[1].priorReplies.count, 1)
        XCTAssertEqual(sent[1].context.sources.count, 6)
        XCTAssertGreaterThan(sent[1].context.scalarBudget, 12000)
        try await store.endConversation(id: conversation, expectedVersion: 3)
        let outcome=try await store.prepareConversationOutcome(id: conversation, expectedVersion: 4, destination: .local)
        XCTAssertEqual(outcome.replies.count, 2)
        XCTAssertGreaterThan(outcome.context.scalarBudget, 12000)
        _ = try await store.setSourceLocalOnly(sourceID: corpus[0], expectedVersion: 2, localOnly: true)
        let invalidated=try await store.panoramaState()
        XCTAssertNil(invalidated.snapshot)
        do { _ = try await store.beginPanoramaConversation(snapshotID: snapshot.id, selection: .relation("e")); XCTFail("旧图不能继续讨论") } catch {}
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

    func testRecordingFollowupConnectsThoughtGoalAndRepeatedEnglishPractice() async throws {
        let store = try await openStore(), model = FlowModel(), reminders = FlowReminders()
        let fixture = FlowFollowup(duringGeneration: {
            let unrelated = try await store.recordUserExpression("同时新记一件事：家里的咖啡豆快用完了。")
            _ = try await store.setSourceLocalOnly(sourceID: unrelated, expectedVersion: 1, localOnly: false)
            _ = try await store.continueSourceUnderstanding(sourceID: unrelated, using: FlowModel())
        })
        let oldID = try await expression(store, text: "我原来认为记忆容量越大效果越好。", model: model)
        let oldContext = try await store.prepareLocalTranscriptContext(sourceIDs: [oldID])
        let oldSource = oldContext.sources[0]
        _ = try await store.importOrganizedClaims(context: oldContext, proposals: [.init(statement: oldSource.text, ownership: .userTentative, references: [.init(sourceID: oldID, transcriptVersionID: oldSource.transcriptVersionID, spanID: oldSource.spans[0].id)])], commandID: "flow-current-organization")
        let goalSource = try await expression(store, text: "我希望一个月内能用英语清楚讲解 Agent 的记忆机制。", model: model)
        let goalClaims = try await store.latestCandidateClaims(for: goalSource)
        let goalClaim = try XCTUnwrap(goalClaims.first)
        let goalID = try await store.createAction(claimID: goalClaim.id, expectedClaimReviewVersion: goalClaim.reviewVersion, title: "用英语清楚讲解 Agent 记忆机制", kind: .opportunity)
        try await store.markFlowGoal(goalID)
        let priorID = try await expression(store, text: "Today I explain agent memory. The agent have a memory. It help us find facts.", model: model)
        let oldPractice = try await store.prepareEnglishPractice(currentSourceID: priorID, destination: .cloud)
        let priorSource = oldPractice.context.sources[0]
        let suggestion = EnglishSuggestionProposal(kind: .grammar, original: .init(reference: .init(sourceID: priorID, transcriptVersionID: priorSource.transcriptVersionID, spanID: priorSource.spans[0].id), quote: "The agent have a memory."), suggestedText: "The agent has a memory.", explanation: "单数主语使用 has")
        _ = try await store.performEnglishFeedback(oldPractice, using: FlowEnglish(response: .init(suggestions: [suggestion], comparisons: [])))
        let retainedPracticeClaims = try await store.latestCandidateClaims(for: priorID)
        XCTAssertFalse(retainedPracticeClaims.isEmpty)
        let currentID = try await expression(store, text: "读完论文后，我现在认为检索质量比单纯增大容量更重要。今天练习英文讲解：Today I explain agent memory. The agent have a memory. It helps us find facts.", model: model)
        let port: any RecordingFollowupPort
        if let configuration = ProcessInfo.processInfo.environment["VOICEOS_FOLLOWUP_LIVE_CONFIG"] { port = try LocalTextModel.loadSuite(from: URL(fileURLWithPath: configuration)).followup }
        else { port = fixture }
        let queued = try await store.enqueueRecordingFollowup(sourceID: currentID)
        let queuedAgain = try await store.enqueueRecordingFollowup(sourceID: currentID)
        XCTAssertEqual(queued.id, queuedAgain.id)
        try await store.interruptFlowFollowup(queued.id)
        let resumed = try await store.pendingRecordingFollowups()
        XCTAssertEqual(resumed.map(\.id), [queued.id])
        let first = try await store.processRecordingFollowup(sourceID: currentID, using: port)
        XCTAssertEqual(first.id, queued.id)
        let pending = try await store.pendingRecordingFollowups()
        XCTAssertTrue(pending.isEmpty)
        let result = try XCTUnwrap(first.result)
        let oldClaimIDs = Set(try await store.latestCandidateClaims(for: oldID).map(\.id))
        XCTAssertTrue(result.thoughtUpdates.contains { oldClaimIDs.contains($0.claimID) })
        XCTAssertTrue(result.english.isPractice)
        XCTAssertTrue(result.english.comparisons.contains { $0.priorSourceID == priorID })
        XCTAssertEqual(result.goalPlans.map(\.goalID), [goalID])
        XCTAssertEqual(first.responseIDs.count, 2)
        XCTAssertEqual(first.input.thoughts.filter { $0.evidence.contains(where: { $0.reference.sourceID == oldID }) }.count, 1)
        if let path = ProcessInfo.processInfo.environment["VOICEOS_FOLLOWUP_DEMO_EXPORT"] {
            try await store.exportPackage(to: URL(fileURLWithPath: path), includeMedia: true)
        }
        let replay = try await store.processRecordingFollowup(sourceID: currentID, using: port)
        let replayQueue = try await store.enqueueRecordingFollowup(sourceID: currentID)
        XCTAssertEqual(replayQueue.id, replay.id)
        let plan = try XCTUnwrap(result.goalPlans.first)
        let taskID = try await store.activateGoalStep(receiptID: first.id, goalID: goalID, step: plan.nextStep)
        let sameTask = try await store.activateGoalStep(receiptID: first.id, goalID: goalID, step: plan.nextStep)
        XCTAssertEqual(taskID, sameTask)
        let tasks = try await store.actions(), task = try XCTUnwrap(tasks.first { $0.id == taskID })
        XCTAssertEqual(task.intent?.goalID, goalID)
        _ = try await store.setReminderAccess(calendarID: "fixture", title: "VoiceOS", enabled: true, expectedVersion: 0)
        try await store.sendTaskToReminders(actionID: taskID, expectedVersion: task.version, calendarID: "fixture", using: reminders, expectedAccessVersion: 1)
        let linked = try await store.processRecordingFollowup(sourceID: currentID, using: fixture)
        XCTAssertEqual(linked.result?.goalPlans.first?.nextStep.existingTaskID, taskID)
        await reminders.complete()
        try await store.refreshAuthorizedReminders(expectedAccessVersion: 1, using: reminders)
        let linkedValidity = try await store.recordingFollowupValidity(linked)
        XCTAssertTrue(linkedValidity.sourceCurrent)
        XCTAssertTrue(linkedValidity.thoughtClaimIDs.isSuperset(of: oldClaimIDs))
        XCTAssertTrue(linkedValidity.english)
        XCTAssertFalse(linkedValidity.goalIsCurrent(goalID))
        let targeted = try await store.enqueueActionFollowups(actionIDs: [taskID])
        XCTAssertEqual(targeted.map(\.sourceID), [goalSource])
        XCTAssertTrue(targeted.first?.input.tasks.contains { $0.id == taskID && $0.state == "completed" } == true)
        let goalAfterCompletion = try await store.processRecordingFollowup(sourceID: goalSource, using: fixture)
        let completedTaskRecords = try await store.actions(includeHistory: true)
        let completedTask = try XCTUnwrap(completedTaskRecords.first { $0.id == taskID })
        let feedbackSource = try await store.recordActionFeedback(actionID: taskID, expectedVersion: completedTask.version, kind: .outcome, text: "讲解时检索质量的例子还不够清楚，下次要补一个例子。")
        _ = try await store.setSourceLocalOnly(sourceID: feedbackSource, expectedVersion: 1, localOnly: false)
        let feedbackInput = try await store.prepareRecordingFollowup(sourceID: feedbackSource)
        XCTAssertEqual(feedbackInput.feedbackActionID, taskID)
        XCTAssertTrue(feedbackInput.tasks.contains { $0.id == taskID && $0.feedback.contains("讲解时检索质量的例子还不够清楚，下次要补一个例子。") })
        let afterFeedback = try await store.recordingFollowupValidity(goalAfterCompletion)
        XCTAssertFalse(afterFeedback.goalIsCurrent(goalID))
        let feedbackFollowup = try await store.processRecordingFollowup(sourceID: feedbackSource, using: fixture)
        XCTAssertEqual(feedbackFollowup.input.feedbackActionID, taskID)
        XCTAssertTrue(feedbackFollowup.result?.goalPlans.contains { $0.goalID == goalID } == true)
        do { _ = try await store.activateGoalStep(receiptID: linked.id, goalID: goalID, step: linked.result!.goalPlans[0].nextStep); XCTFail("Completed steps must not be reactivated") } catch { }
        let nextID = try await expression(store, text: "我已完成第一次英文讲解练习。Today I explain agent memory. The agent has a memory. It helps us find facts.", model: model)
        let next = try await store.processRecordingFollowup(sourceID: nextID, using: port)
        let nextResult = try XCTUnwrap(next.result)
        XCTAssertTrue(next.input.practices.contains { $0.sourceID == currentID && $0.feedback.contains("has") })
        XCTAssertTrue(nextResult.english.comparisons.contains { $0.priorSourceID == currentID || $0.priorSourceID == priorID })
        XCTAssertTrue(nextResult.goalPlans.allSatisfy { $0.nextStep.existingTaskID != taskID })
        let retryingPort = FlowFollowup(failures: 1)
        do { _ = try await store.processRecordingFollowup(sourceID: nextID, using: retryingPort, retry: true); XCTFail("A timeout must leave a retryable receipt") } catch { }
        let afterFailure = try await store.recordingFollowups()
        let failed = try XCTUnwrap(afterFailure.last { $0.sourceID == nextID })
        XCTAssertEqual(failed.state, "failed")
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertNotNil(failed.retryAt)
        let waitingForRetry = try await store.pendingRecordingFollowups()
        XCTAssertTrue(waitingForRetry.isEmpty)
        try await store.expireFlowFollowupRetry(failed.id)
        let readyForRetry = try await store.pendingRecordingFollowups()
        XCTAssertEqual(readyForRetry.map(\.id), [failed.id])
        let retried = try await store.processRecordingFollowup(sourceID: nextID, using: retryingPort)
        XCTAssertEqual(retried.id, failed.id)
        XCTAssertEqual(retried.state, "completed")
        XCTAssertNil(retried.retryAt)
        let nativeInput = try await store.prepareRecordingFollowup(sourceID: currentID)
        let nativeResult = try await FlowFollowup().generate(nativeInput).result
        func completed(_ id: String, _ value: Any) throws -> ModelHTTPReply {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["id": id, "status": "completed",
                "output": [["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text]]]]], options: [.sortedKeys]))
        }
        func nativePort(_ transport: FlowFollowupTransport) throws -> ResponsesRecordingFollowupPort {
            try ResponsesRecordingFollowupPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture-model", transport: transport)
        }
        let selection: [String: Any] = ["thoughtIDs": nativeInput.thoughts.map(\.id), "goalIDs": nativeInput.goals.map(\.id),
            "taskIDs": nativeInput.tasks.map(\.id), "practiceSourceIDs": nativeInput.practices.map(\.sourceID)]
        let wrongSelection = try completed("rejected-selection", ["thoughts": [], "goals": [], "tasks": [], "practices": []])
        let validSelection = try completed("accepted-selection", selection)
        let resultObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(nativeResult)) as? [String: Any])
        var incompleteResult = resultObject; incompleteResult.removeValue(forKey: "english")
        let wrongResult = try completed("rejected-result", incompleteResult)
        let validResult = try completed("accepted-result", resultObject)
        let recoveringTransport = FlowFollowupTransport([wrongSelection, validSelection, wrongResult, validResult])
        let native = try await store.processRecordingFollowup(sourceID: currentID, using: nativePort(recoveringTransport), retry: true)
        XCTAssertEqual(native.responseIDs, ["accepted-selection", "accepted-result"])
        XCTAssertEqual(native.rejectedResponses?.map(\.rawResponse), [wrongSelection.body, wrongResult.body])
        XCTAssertEqual(native.rejectedResponses?.map(\.stage), [.selectHistory, .generateFollowup])
        XCTAssertEqual(native.rejectedResponses?.map(\.wireAttempt), [1, 1])
        XCTAssertEqual(native.rejectedResponses?.map(\.responseID), ["rejected-selection", "rejected-result"])
        XCTAssertEqual(native.rejectedResponses?.first?.path, "$.goalIDs")
        XCTAssertEqual(native.rejectedResponses?.last?.path, "$.english")
        let nativeRequests = await recoveringTransport.requests
        XCTAssertEqual(nativeRequests.count, 4)
        for data in nativeRequests {
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let instructions = try XCTUnwrap(request["instructions"] as? String)
            let format = try XCTUnwrap((request["text"] as? [String: Any])?["format"] as? [String: Any])
            let exactSchema = String(decoding: try JSONSerialization.data(withJSONObject: format["schema"]!, options: [.sortedKeys]), as: UTF8.self)
            XCTAssertTrue(instructions.contains(exactSchema))
            XCTAssertEqual((request["reasoning"] as? [String: String])?["effort"], "high")
            XCTAssertEqual(request["truncation"] as? String, "disabled")
            let messages = try XCTUnwrap(request["input"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.first?["content"] as? String)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
            let current = ((payload["recording"] as? [String: Any])?["current"] ?? payload["current"]) as? [String: Any]
            let sources = current?["sources"] as? [[String: Any]]
            XCTAssertEqual(sources?.first?["text"] as? String, nativeInput.current.sources[0].text)
        }
        var invalidSemantic = resultObject
        var invalidEnglish = try XCTUnwrap(invalidSemantic["english"] as? [String: Any])
        invalidEnglish["evidenceQuote"] = "A quotation absent from this recording."
        invalidSemantic["english"] = invalidEnglish
        let semanticReply = try completed("rejected-semantic", invalidSemantic)
        let semanticTransport = FlowFollowupTransport([wrongSelection, validSelection, semanticReply])
        do {
            _ = try await store.processRecordingFollowup(sourceID: currentID, using: nativePort(semanticTransport), retry: true)
            XCTFail("Semantic rejection must remain terminal")
        } catch let failure as RecordingFollowupGenerationFailure {
            XCTAssertEqual(failure.responseIDs, ["accepted-selection"])
            XCTAssertEqual(failure.rejectedResponses.map(\.rawResponse), [wrongSelection.body, semanticReply.body])
        }
        let semanticSends = await semanticTransport.requests.count
        XCTAssertEqual(semanticSends, 3)
        let semanticReceipts = try await store.recordingFollowups()
        let semanticFailure = try XCTUnwrap(semanticReceipts.last { $0.sourceID == currentID })
        XCTAssertEqual(semanticFailure.responseIDs, ["accepted-selection"])
        XCTAssertNil(semanticFailure.retryAt)
        let budgetTransport = FlowFollowupTransport([.init(status: 503, body: Data()), wrongSelection, .init(status: 503, body: Data())])
        do {
            _ = try await store.processRecordingFollowup(sourceID: currentID, using: nativePort(budgetTransport), retry: true)
            XCTFail("All wire attempts must share one stage budget")
        } catch let failure as RecordingFollowupGenerationFailure {
            XCTAssertEqual((failure.underlying as? RecordingFollowupTransientError)?.status, 503)
            XCTAssertTrue(failure.responseIDs.isEmpty)
            XCTAssertEqual(failure.rejectedResponses.map(\.rawResponse), [wrongSelection.body])
            XCTAssertEqual(failure.rejectedResponses.first?.wireAttempt, 2)
        }
        let budgetSends = await budgetTransport.requests.count
        XCTAssertEqual(budgetSends, 3)
        let budgetReceipts = try await store.recordingFollowups()
        let budgetFailure = try XCTUnwrap(budgetReceipts.last { $0.sourceID == currentID })
        XCTAssertNotNil(budgetFailure.retryAt)
        let cancelledTransport = FlowFollowupTransport([wrongSelection], cancelAt: 1)
        let cancelledPort = try nativePort(cancelledTransport)
        let cancelled = Task {
            try await store.processRecordingFollowup(sourceID: currentID, using: cancelledPort, retry: true)
        }
        do { _ = try await cancelled.value; XCTFail("Cancellation must stop structural retries") }
        catch let failure as RecordingFollowupGenerationFailure {
            XCTAssertTrue(failure.underlying is CancellationError)
            XCTAssertEqual(failure.rejectedResponses.map(\.rawResponse), [wrongSelection.body])
        }
        let cancelledSends = await cancelledTransport.requests.count
        XCTAssertEqual(cancelledSends, 1)
        let cancelledReceipts = try await store.recordingFollowups()
        let cancelledReceipt = try XCTUnwrap(cancelledReceipts.last { $0.sourceID == currentID })
        XCTAssertNil(cancelledReceipt.retryAt)
        try await store.interruptFlowFollowup(cancelledReceipt.id)
        let resumedTransport = FlowFollowupTransport([wrongSelection, validSelection, validResult])
        let resumedNative = try await store.processRecordingFollowup(sourceID: currentID, using: nativePort(resumedTransport))
        XCTAssertEqual(resumedNative.id, cancelledReceipt.id)
        XCTAssertEqual(resumedNative.rejectedResponses?.map(\.rawResponse), [wrongSelection.body, wrongSelection.body])
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(native)) as? [String: Any])
        legacyObject.removeValue(forKey: "rejectedResponses")
        let legacy = try JSONDecoder().decode(RecordingFollowupReceipt.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        XCTAssertNil(legacy.rejectedResponses)
        let legacyEncoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(legacyEncoded["rejectedResponses"])
        let savedFollowups = try await store.recordingFollowups()
        let package = root.appendingPathComponent("followup-package"), restored = root.appendingPathComponent("followup-restored")
        try await store.exportPackage(to: package, includeMedia: true)
        try await VoiceOSStore.restorePackage(from: package, to: restored, inspector: NativeMediaInspector())
        let recovered = try VoiceOSStore(root: restored, inspector: NativeMediaInspector()); try await recovered.recover()
        let retained = try await recovered.recordingFollowups()
        XCTAssertEqual(retained.map(\.id), savedFollowups.map(\.id))
        XCTAssertEqual(retained.last?.responseIDs, savedFollowups.last?.responseIDs)
        let restoredNative = try XCTUnwrap(retained.first { $0.id == native.id })
        XCTAssertEqual(restoredNative.rejectedResponses?.map(\.rawResponse), [wrongSelection.body, wrongResult.body])
        XCTAssertEqual(restoredNative.responseIDs, ["accepted-selection", "accepted-result"])
        let restoredSemantic = try XCTUnwrap(retained.first { $0.id == semanticFailure.id })
        XCTAssertEqual(restoredSemantic.rejectedResponses?.last?.rawResponse, semanticReply.body)
        XCTAssertEqual(restoredSemantic.responseIDs, ["accepted-selection"])
        let restoredResumed = try XCTUnwrap(retained.first { $0.id == resumedNative.id })
        XCTAssertEqual(restoredResumed.rejectedResponses?.map(\.rawResponse), [wrongSelection.body, wrongSelection.body])
        let sourceRecords = try await store.sources()
        let currentSource = try XCTUnwrap(sourceRecords.first { $0.id == currentID })
        _ = try await store.correctTranscript(sourceID: currentID, expectedVersionID: currentSource.transcriptVersionID!, text: "更正：此前并非练习原话。")
        do { try await store.validateRecordingFollowup(first); XCTFail("Old followup must stop after a correction") } catch { }
        let invalidated = try await store.recordingFollowupValidity(first)
        XCTAssertFalse(invalidated.sourceCurrent)
        let history = try await store.recordingFollowups()
        XCTAssertEqual(history.first?.result?.thoughtUpdates.first?.currentQuote, first.result?.thoughtUpdates.first?.currentQuote)
        let isolated = try VoiceOSStore(root: root.appendingPathComponent("practice-boundaries"), inspector: NativeMediaInspector())
        try await isolated.recover()
        let privateQuote = "Today I explain my private orchid-albatross mnemonic."
        let practiceA = try await expression(isolated, text: privateQuote, model: model)
        _ = try await isolated.processRecordingFollowup(sourceID: practiceA, using: fixture)
        let practiceB = try await expression(isolated, text: "Today I explain a public design. The agent has a memory.", model: model)
        let practiceBResult = try await isolated.processRecordingFollowup(sourceID: practiceB, using: fixture)
        XCTAssertEqual(practiceBResult.result?.english.comparisons.first?.priorSourceID, practiceA)
        let legacyID = try await expression(isolated, text: "The agent have a public design.", model: model)
        let legacyInput = try await isolated.prepareEnglishPractice(currentSourceID: legacyID, priorSourceIDs: [practiceA], destination: .cloud)
        let legacyCurrent = legacyInput.context.sources[0], legacyPrior = legacyInput.context.sources[1]
        let legacyCurrentQuote = OutcomeSourceEvidence(reference: .init(sourceID: legacyID, transcriptVersionID: legacyCurrent.transcriptVersionID, spanID: legacyCurrent.spans[0].id), quote: legacyCurrent.text)
        let legacyPriorQuote = OutcomeSourceEvidence(reference: .init(sourceID: practiceA, transcriptVersionID: legacyPrior.transcriptVersionID, spanID: legacyPrior.spans[0].id), quote: privateQuote)
        _ = try await isolated.performEnglishFeedback(legacyInput, using: FlowEnglish(response: .init(suggestions: [.init(kind: .grammar, original: legacyCurrentQuote, suggestedText: "The agent has a public design.", explanation: "单数主语使用 has")], comparisons: [.init(kind: .similarIssue, currentSuggestionIndex: 0, current: legacyCurrentQuote, prior: legacyPriorQuote, explanation: "比较旧练习")])) )
        let practiceC = try await expression(isolated, text: "Today I explain the next example.", model: model)
        let beforeRevocation = try await isolated.prepareRecordingFollowup(sourceID: practiceC)
        let legacyHistory = try XCTUnwrap(beforeRevocation.practices.first { $0.sourceID == legacyID })
        XCTAssertTrue(try JSONDecoder().decode(EnglishPracticeResponse.self, from: Data(legacyHistory.feedback.utf8)).comparisons.isEmpty)
        _ = try await isolated.setSourceLocalOnly(sourceID: practiceA, expectedVersion: 2, localOnly: true)
        let afterRevocation = try await isolated.prepareRecordingFollowup(sourceID: practiceC)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(afterRevocation), as: UTF8.self).contains(privateQuote))
        let ownPractice = try XCTUnwrap(afterRevocation.practices.first { $0.sourceID == practiceB })
        let ownFeedback = try JSONDecoder().decode(PracticeFollowup.self, from: Data(ownPractice.feedback.utf8))
        XCTAssertFalse(ownFeedback.suggestions.isEmpty)
        XCTAssertTrue(ownFeedback.comparisons.isEmpty)
        _ = try await isolated.setSourceLocalOnly(sourceID: practiceA, expectedVersion: 3, localOnly: false)
        let practiceRecords = try await isolated.sources(), originalPractice = try XCTUnwrap(practiceRecords.first { $0.id == practiceA })
        _ = try await isolated.correctTranscript(sourceID: practiceA, expectedVersionID: originalPractice.transcriptVersionID!, text: "Corrected practice without the private mnemonic.")
        let afterCorrection = try await isolated.prepareRecordingFollowup(sourceID: practiceC)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(afterCorrection), as: UTF8.self).contains(privateQuote))
        XCTAssertTrue(afterCorrection.practices.contains { $0.sourceID == practiceB && $0.feedback.contains("has") })
        let originalPracticeFile = try await isolated.playableURL(sourceID: practiceB)
        try Data("modified disposable practice".utf8).write(to: originalPracticeFile)
        do { _ = try await isolated.playableURL(sourceID: practiceB); XCTFail("Modified original must be quarantined") } catch { }
        let afterQuarantine = try await isolated.prepareRecordingFollowup(sourceID: practiceC)
        XCTAssertFalse(afterQuarantine.practices.contains { $0.sourceID == practiceB })
        for title in ["掌握英语技术讲解", "练习英语工作汇报"] {
            let source = try await expression(isolated, text: title, model: model)
            let claims = try await isolated.latestCandidateClaims(for: source), claim = try XCTUnwrap(claims.first)
            let goal = try await isolated.createAction(claimID: claim.id, expectedClaimReviewVersion: claim.reviewVersion, title: title, kind: .opportunity)
            try await isolated.markFlowGoal(goal)
        }
        let sameTitlePlans = try await isolated.processRecordingFollowup(sourceID: practiceC, using: fixture)
        let separatePlans = try XCTUnwrap(sameTitlePlans.result?.goalPlans)
        XCTAssertEqual(separatePlans.count, 2)
        XCTAssertEqual(separatePlans[0].nextStep.title, separatePlans[1].nextStep.title)
        let firstGoalTask = try await isolated.activateGoalStep(receiptID: sameTitlePlans.id, goalID: separatePlans[0].goalID, step: separatePlans[0].nextStep)
        let secondGoalTask = try await isolated.activateGoalStep(receiptID: sameTitlePlans.id, goalID: separatePlans[1].goalID, step: separatePlans[1].nextStep)
        XCTAssertNotEqual(firstGoalTask, secondGoalTask)
        let separateTasks = try await isolated.actions(includeHistory: true)
        XCTAssertEqual(separateTasks.first { $0.id == firstGoalTask }?.intent?.goalID, separatePlans[0].goalID)
        XCTAssertEqual(separateTasks.first { $0.id == secondGoalTask }?.intent?.goalID, separatePlans[1].goalID)

    }
}
