import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

// Simulated model/reminder ports exercise the user flows without cloud calls or personal data.
let flowConfiguration = ModelConfiguration(provider: "fixture", model: "flow", promptVersion: "v1", schemaVersion: "v1", destination: .local)

actor FlowModel: ModelPort {
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
actor FlowPanorama: PanoramaModelPort {
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
            relations: questions.count > 1 ? [.init(id: "e", from: "q0", to: "q1", label: "补充检索条件", explanation: "AI 候选，需核对双方条件", fromEvidence: questions[0].evidence, toEvidence: questions[1].evidence)] : [],
            unrepresentedSources: input.sources.dropFirst(2).map { .init(id: $0.id, reason: "本轮未归入具体问题，仍可打开全文") },
            unrepresentedClaims: input.claims.filter { !represented.contains($0.id) }.map { .init(id: $0.id, reason: "保留在认识入口") })
        return (proposal, .init(responseID: "generation-"+String(generations), model: "fixture", createdAt: "2026-10-21T00:00:00Z"))
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
struct FlowPanoramaFailureTransport: ModelHTTPTransport {
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://fixture.invalid/private?key=fixture-secret")!])
    }
}
actor FlowCompleteDiscussion: DiscussionModelPort, ConversationOutcomePort {
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
struct FlowSpeech: SpeechPort {
    let backendIdentity = "Qwen3-ASR-flow-fixture"
    var text = "我认为检索质量比记忆容量更值得研究。"
    var timed = false
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        SpeechText(text: text, spans: timed ? [.init(textStart: 0, textEnd: text.unicodeScalars.count, startMS: 0, endMS: 500)] : nil)
    }
}
struct FlowRecordingExpressions: RecordingExpressionPort, RecordingExpressionActionPort {
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
struct FlowRecordingTitles: RecordingTitlePort {
    func generate(_ input: RecordingTitleInput) async throws -> ([RecordingTitleProposal], [String]) {
        (input.context.sources.map { .init(sourceID: $0.sourceID, title: "检索质量与记忆容量", summary: "讨论检索质量与容量的关系。", quotes: [$0.text]) }, ["title-result"])
    }
}
struct FlowAssociation: ExpressionAssociationPort {
    let configuration = flowConfiguration
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse { .init(proposals: []) }
}
struct FlowRelevance: RelevanceModelPort {
    let configuration = flowConfiguration
    func select(_ request: RelevanceModelRequest) async throws -> RelevanceModelResponse {
        .init(status: .completed, selection: .init(snapshotID: request.snapshot.id, queryID: request.snapshot.queryID, candidateIDs: request.snapshot.candidates.map(\.id)))
    }
}
actor FlowReminders: RemindersPort {
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
struct FlowReviewedActions: RecordingExpressionActionPort {
    let decisions:[RecordingExpressionActionDecision]
    func reconcile(_ input:RecordingExpressionActionInput) async throws -> ([RecordingExpressionActionDecision],[String]) {
        (decisions,["scoped-draft","scoped-independent"])
    }
}
func verifyScopedExpressionActionReview(at root:URL) async throws {
    let storeRoot=root.appendingPathComponent("scoped-review"),package=root.appendingPathComponent("scoped-package")
    let clearID:String,retainedID:String,uncertainID:String,candidateID:String
    do {
        let store=try VoiceOSStore(root:storeRoot,inspector:NativeMediaInspector())
        try await store.recover()
        let first=try await store.recordUserExpression("整理报告，还要整改标签。报告的具体交付物仍有歧义。")
        _ = try await store.setSourceLocalOnly(sourceID:first,expectedVersion:1,localOnly:false)
        try await store.registerAutomaticRecording(sourceID:first,inbox:"fixture",recordedAt:"2026-10-20T01:00:00Z")
        let groups=try await store.connectRecordingExpressions(using:FlowRecordingExpressions())
        let initial=try XCTUnwrap(groups.first)
        let context=try await store.prepareLocalTranscriptContext(sourceIDs:[first])
        let refs=context.sources.map { ClaimReference(sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID,spanID:$0.spans[0].id) }
        _ = try await store.importOrganizedClaims(context:context,proposals:[
            .init(statement:"整理报告",ownership:.userTentative,references:refs,action:.init(title:"整理报告",kind:.task,quote:context.sources[0].text)),
            .init(statement:"整改标签",ownership:.userTentative,references:refs,action:.init(title:"整改标签",kind:.task,quote:context.sources[0].text)),
            .init(statement:"报告交付物待核对",ownership:.userTentative,references:refs,action:.init(title:"报告交付物待核对",kind:.opportunity,quote:context.sources[0].text))
        ],commandID:"scoped-before")
        try await store.finishRecordingExpression(initial,using:FlowReviewedActions(decisions:[]))
        let old=try await store.actions()
        let report=try XCTUnwrap(old.first { $0.title == "整理报告" }),label=try XCTUnwrap(old.first { $0.title == "整改标签" })
        let possible=try XCTUnwrap(old.first { $0.kind == "opportunity" })
        let reminders=FlowReminders()
        let access=try await store.setReminderAccess(calendarID:"scoped-calendar",title:"VoiceOS",enabled:true,expectedVersion:0)
        for task in [report,label] {
            try await store.sendTaskToReminders(actionID:task.id,expectedVersion:task.version,calendarID:access.calendarID,using:reminders,expectedAccessVersion:access.version)
        }
        let next=try await store.recordUserExpression("接着报告，报告仍需整理，标签的具体操作待核对。另确认购买备份盘。")
        _ = try await store.setSourceLocalOnly(sourceID:next,expectedVersion:1,localOnly:false)
        try await store.registerAutomaticRecording(sourceID:next,inbox:"fixture",recordedAt:"2026-10-20T01:01:00Z")
        let extended=try await store.connectRecordingExpressions(using:FlowRecordingExpressions())
        let expression=try XCTUnwrap(extended.first)
        let current=try await store.prepareLocalTranscriptContext(sourceIDs:expression.sourceIDs)
        let currentRefs=current.sources.map { ClaimReference(sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID,spanID:$0.spans[0].id) }
        let quote=try XCTUnwrap(current.sources.last).text
        _ = try await store.importOrganizedClaims(context:current,proposals:[
            .init(statement:"整理当前报告",ownership:.userTentative,references:currentRefs,action:.init(title:"整理当前报告",kind:.task,quote:quote)),
            .init(statement:"核对标签操作",ownership:.userTentative,references:currentRefs,action:.init(title:"核对标签操作",kind:.task,quote:quote)),
            .init(statement:"购买备份盘",ownership:.userTentative,references:currentRefs,action:.init(title:"购买备份盘",kind:.task,quote:quote))
        ],commandID:"scoped-after")
        let input=try await store.prepareExpressionActionReview(expression)
        let newReport=try XCTUnwrap(input.newActions.first { $0.title == "整理当前报告" })
        let newLabel=try XCTUnwrap(input.newActions.first { $0.title == "核对标签操作" })
        let clear=try XCTUnwrap(input.newActions.first { $0.title == "购买备份盘" })
        let reviewed:[RecordingExpressionActionDecision] = [
            .init(oldID:report.id,newID:newReport.id,relation:"same",sourceID:next,quote:quote,possibleNewIDs:[]),
            .init(oldID:label.id,newID:"",relation:"uncertain",sourceID:next,quote:quote,possibleNewIDs:[newLabel.id]),
            .init(oldID:possible.id,newID:"",relation:"uncertain",sourceID:next,quote:quote,possibleNewIDs:[newReport.id])
        ]
        try await store.finishRecordingExpression(expression,using:FlowReviewedActions(decisions:reviewed))
        let saved=try await store.recordingExpressions()
        let completed=try XCTUnwrap(saved.first)
        XCTAssertTrue(completed.requiresActionReview(actionID:report.id))
        XCTAssertTrue(completed.requiresActionReview(actionID:label.id))
        XCTAssertTrue(completed.requiresActionReview(actionID:newLabel.id))
        XCTAssertFalse(completed.requiresActionReview(actionID:clear.id))
        let currentActions=try await store.actions()
        let retained=try XCTUnwrap(currentActions.first { $0.id == report.id })
        let backup=try XCTUnwrap(currentActions.first { $0.id == clear.id })
        let candidate=try XCTUnwrap(currentActions.first { $0.id == newLabel.id })
        let allowed=try await store.reminderSourceAllowed(backup),blocked=try await store.reminderSourceAllowed(retained)
        XCTAssertTrue(allowed);XCTAssertFalse(blocked)
        try await store.sendTaskToReminders(actionID:retained.id,expectedVersion:retained.version,calendarID:access.calendarID,using:reminders,expectedAccessVersion:access.version)
        let retainedRemote=await reminders.items
        XCTAssertEqual(retainedRemote.count,2)
        XCTAssertTrue(retainedRemote.contains { $0.title == "整理报告" })
        do {
            try await store.sendTaskToReminders(actionID:candidate.id,expectedVersion:candidate.version,calendarID:access.calendarID,using:reminders,expectedAccessVersion:access.version)
            XCTFail("尚未关联且可能重复的新任务不得写入提醒事项")
        } catch {}
        try await store.sendTaskToReminders(actionID:backup.id,expectedVersion:backup.version,calendarID:access.calendarID,using:reminders,expectedAccessVersion:access.version)
        let links=try await store.reminderLinks(),remote=await reminders.items
        XCTAssertEqual(links.count,3);XCTAssertEqual(remote.count,3)
        XCTAssertTrue(links.contains { $0.actionID == label.id })
        var legacy=completed;legacy.actionReviewDecisions=nil
        XCTAssertTrue(legacy.requiresActionReview(actionID:clear.id))
        var missing=completed
        missing.actionReviewDecisions=reviewed.map { value in var value=value;if value.relation == "uncertain" { value.possibleNewIDs=nil };return value }
        XCTAssertTrue(missing.requiresActionReview(actionID:clear.id))
        try await store.exportPackage(to:package,includeMedia:true)
        clearID=clear.id;retainedID=report.id;uncertainID=label.id;candidateID=newLabel.id
    }
    let reopened=try VoiceOSStore(root:storeRoot,inspector:NativeMediaInspector())
    try await reopened.recover()
    let reopenedExpressions=try await reopened.recordingExpressions()
    XCTAssertFalse(try XCTUnwrap(reopenedExpressions.first).requiresActionReview(actionID:clearID))
    let restoredRoot=root.appendingPathComponent("scoped-restored")
    try await VoiceOSStore.restorePackage(from:package,to:restoredRoot,inspector:NativeMediaInspector())
    let restored=try VoiceOSStore(root:restoredRoot,inspector:NativeMediaInspector())
    try await restored.recover()
    let restoredExpressions=try await restored.recordingExpressions()
    let expression=try XCTUnwrap(restoredExpressions.first)
    XCTAssertEqual(expression.actionReviewDecisions?.count,3)
    XCTAssertFalse(expression.requiresActionReview(actionID:clearID))
    for id in [retainedID,uncertainID,candidateID] { XCTAssertTrue(expression.requiresActionReview(actionID:id)) }
}
struct FlowEnglish: EnglishPracticeModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "english", promptVersion: "english-practice-v1", schemaVersion: "english-feedback-v1", destination: .cloud)
    let response: EnglishPracticeResponse
    func generate(_ request: EnglishPracticeRequest) async throws -> EnglishPracticeResponse { response }
}

extension VoiceOSStore {
    func dbValidateFlowActions() throws { try Self.validateStoredActions(db) }
}

actor FlowFollowupTransport: ModelHTTPTransport {
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
actor FlowFollowup: RecordingFollowupPort {
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
extension VoiceOSStore {
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

class FlowTestCase: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-flow-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    func expression(_ store: VoiceOSStore, text: String, model: FlowModel) async throws -> String {
        let id = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        _ = try await store.continueSourceUnderstanding(sourceID: id, using: model)
        return id
    }
}
