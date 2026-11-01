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
private struct FlowPanoramaFailureTransport: ModelHTTPTransport {
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://fixture.invalid/private?key=fixture-secret")!])
    }
}
private actor FlowCompleteDiscussion: DiscussionModelPort {
    let configuration=flowConfiguration
    var snapshots: [DiscussionSnapshot]=[]
    func reply(_ request: DiscussionModelRequest) async throws -> DiscussionModelResponse {
        snapshots.append(request.snapshot)
        return .init(status: .completed, parts: [.init(kind: .aiSuggestion, text: "这是合成的待核对分析。")])
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
private actor FlowTopics: TopicOrganizationPort {
    let questionID: String
    let unrelatedID: String
    let sharedSourceID: String?
    var calls = 0
    init(questionID:String,unrelatedID:String,sharedSourceID:String? = nil) { self.questionID=questionID;self.unrelatedID=unrelatedID;self.sharedSourceID=sharedSourceID }
    func organize(_ input:TopicOrganizationInput) async throws -> TopicOrganizationResult {
        calls += 1
        let all=input.context.sources.map(\.sourceID)
        let existing=input.topics.first { $0.title == "生活整理" }?.id ?? ""
        func section(_ id:String,_ title:String,personal:Bool) -> TopicReadingSection {
            let ids=personal ? all.filter { $0 != unrelatedID } : [unrelatedID]
            let source=input.context.sources.first { ids.contains($0.sourceID) }!
            return .init(id:id,title:title,summary:personal ? "先区分判断、尝试与实际证据，再继续验证。" : "保留整理书架的安排与实际记录。",
                claimIDs:input.knowledge.filter { personal ? !$0.sourceIDs.contains(unrelatedID) : $0.sourceIDs.contains(unrelatedID) }.map(\.id),
                actionIDs:input.tasks.filter { personal ? !$0.sourceIDs.contains(unrelatedID) : $0.sourceIDs.contains(unrelatedID) }.map(\.id),
                evidence:[.init(sourceID:source.sourceID,quote:source.text)])
        }
        return .init(briefing:"Agent 主题连接了早期判断、尝试和 AI 报告；一次尝试仍不足以证明原因。",highlightSourceIDs:[unrelatedID],topics:[
            .init(topicID:questionID,title:"怎样让 Agent 稳定完成真实任务？",summary:"已保存判断、尝试与报告，仍需用实际任务检验。",questions:["任务边界怎样影响完成质量？"],sourceIDs:all.filter { $0 != unrelatedID },sections:[section("agent-practice","用真实任务检验完成标准",personal:true)]),
            .init(topicID:existing,title:"生活整理",summary:"记录了整理书架的待办。",questions:[],sourceIDs:[unrelatedID] + (sharedSourceID.map { [$0] } ?? []),sections:[section("life-plan","整理书架的安排",personal:false)])
        ],responseID:"fixture-topics-\(calls)")
    }
}
private struct FlowDiscussion: DiscussionModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "discussion", promptVersion: "v1", schemaVersion: "v1", destination: .cloud)
    var responseText = "检索与实验设计都需要区分假设和测量结果；这是一条待验证的跨主题联系。"
    func reply(_ request: DiscussionModelRequest) async throws -> DiscussionModelResponse {
        let taskClaims = Set(request.snapshot.context.reflectionFocus?.tasks.compactMap(\.claimID) ?? [])
        let reference = request.snapshot.context.reflectionFocus?.thoughts.first { !taskClaims.contains($0.claimID) }?.evidence.first?.reference
        return .init(status: .completed, parts: [.init(kind: .aiSuggestion, text: responseText, references: reference.map { [$0] } ?? [])])
    }
}
private actor FlowAssistantTransport: ModelHTTPTransport {
    var assessments = 0
    var deliveries = 0
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["input"] as! [[String: Any]]
        let content = messages[0]["content"] as! String
        XCTAssertTrue(content.hasPrefix("当前执行时间："))
        let inputJSON = try XCTUnwrap(content.split(separator: "\n", maxSplits: 1).last)
        let input = try JSONDecoder().decode(AssistantTaskInput.self, from: Data(inputJSON.utf8))
        if body["text"] != nil {
            assessments += 1
            let delegated = input.title == "请帮我调研 Agent 记忆方案，并给出带来源的报告。" || !input.instruction.isEmpty
            let assessment = AssistantAssessment(explicitDelegation: delegated, supported: true, kind: .research, reason: delegated ? "明确委托调研" : "本人后续计划，没有委托助理")
            let text = String(decoding: try JSONEncoder().encode(assessment), as: UTF8.self)
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["status":"completed","output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]]]))
        }
        deliveries += 1
        XCTAssertEqual((body["tools"] as? [[String: String]])?.first?["type"], "web_search")
        XCTAssertEqual(body["tool_choice"] as? String, "required")
        XCTAssertEqual(body["truncation"] as? String, "disabled")
        return .init(status: 200, body: try Self.delivery())
    }
    static func delivery(search: Bool = true) throws -> Data {
        let report = "# Agent 记忆方案调研\n\n这是合成验证报告：容量与检索质量应分别评估，真实结论仍需实验。来源[1]"
        let annotation: [String: Any] = ["type":"url_citation","url":"https://example.com/agent-memory","title":"合成来源示例","start_index":report.unicodeScalars.count - 3,"end_index":report.unicodeScalars.count]
        var output: [[String: Any]] = []
        if search { output.append(["type":"web_search_call","status":"completed"]) }
        output.append(["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":report,"annotations":search ? [annotation] : []]]])
        return try JSONSerialization.data(withJSONObject: ["id":"synthetic-assistant-response","status":"completed","output":output])
    }
}
// Bounded synthetic requests verify recovery and cancellation of the assistant
// worker without any real model call or blocking the test's executor.
private actor FlowAssistantReliability: AssistantModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "assistant-reliability", promptVersion: "v1", schemaVersion: "v1", destination: .cloud)
    var remainingAssessmentFailures: Int
    let blockedActionID: String?
    var started = false
    var cancellationObserved = false
    var startWaiter: CheckedContinuation<Void, Never>?
    init(assessmentFailures: Int = 0, blockedActionID: String? = nil) {
        remainingAssessmentFailures = assessmentFailures; self.blockedActionID = blockedActionID
    }
    func assess(_ input: AssistantTaskInput) async throws -> AssistantAssessment {
        if remainingAssessmentFailures > 0 {
            remainingAssessmentFailures -= 1
            throw VoiceOSError("合成识别请求中断")
        }
        return .init(explicitDelegation: true, supported: true, kind: .draft, reason: "明确委托起草")
    }
    func execute(_ request: AssistantExecutionRequest) async throws -> AssistantExecutionResult {
        if request.input.actionID == blockedActionID {
            started = true; startWaiter?.resume(); startWaiter = nil
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { cancellationObserved = true; throw error }
        }
        return .init(title: request.input.title, markdown: "# 合成起草成果\n\n这是用于验证助理流程的完整草稿。", responseID: UUID().uuidString)
    }
    func waitForBlockedRequest() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
}
private actor FlowKnowledgeTransport: ModelHTTPTransport {
    var identifications = 0
    var researches = 0
    var reviews = 0
    var failCorrectQuery = true
    let expectedText: String
    init(expectedText: String) { self.expectedText = expectedText }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? String)
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        if format?["name"] as? String == "knowledge_candidates" {
            identifications += 1
            let input = try JSONDecoder().decode(KnowledgeReviewInput.self, from: Data(content.utf8))
            XCTAssertEqual(input.context.sources.first?.text, expectedText)
            let candidates = [
                KnowledgeReviewCandidate(id: "incorrect", quote: "SQLite quick_check 会完整检查所有索引与表记录的一致性。", reason: "公开知识断言", publicQuery: "SQLite quick_check index table consistency"),
                KnowledgeReviewCandidate(id: "correct", quote: "SQLite integrity_check 不能证明业务逻辑没有错误。", reason: "公开知识断言", publicQuery: "SQLite integrity_check application logic"),
                KnowledgeReviewCandidate(id: "uncertain", quote: "这个术语的转写还没听准。", reason: "原意尚未确认", transcriptionUncertain: true)
            ]
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidates))
            return try response(["candidates":encoded], id: "knowledge-identify")
        }
        if body["tools"] != nil {
            researches += 1
            XCTAssertFalse(content.contains("私人代号"))
            XCTAssertFalse(content.contains("quick_check 会完整"))
            if content.contains("application logic"), failCorrectQuery {
                failCorrectQuery = false
                throw VoiceOSError("合成知识检索中断")
            }
            let report = "# SQLite 官方说明\n\nquick_check不验证索引和表记录的一致性，数据库结构检查也不证明业务逻辑。[1]"
            let citation: [String: Any] = ["type":"url_citation","url":"https://www.sqlite.org/pragma.html","title":"SQLite PRAGMA","start_index":report.unicodeScalars.count-3,"end_index":report.unicodeScalars.count]
            return .init(status:200,body:try JSONSerialization.data(withJSONObject:["id":"knowledge-search-\(researches)","status":"completed","output":[["type":"web_search_call","status":"completed"],["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":report,"annotations":[citation]]]]]]))
        }
        reviews += 1
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String:String])
        let candidate = try JSONDecoder().decode(KnowledgeReviewCandidate.self, from: Data(payload["candidate"]!.utf8))
        return try response(["retain":candidate.id == "incorrect","kind":"factualError","explanation":"quick_check省略了索引与表记录的一致性检查。","betterUnderstanding":"需要核对这些关系时采用integrity_check。","boundary":"两种检查都不能证明业务逻辑正确。","counterexample":"结构有效的数据仍可能违反应用规则。","referenceURLs":["https://www.sqlite.org/pragma.html"]],id:"knowledge-review-\(reviews)")
    }
    private func response(_ object: [String: Any], id: String) throws -> ModelHTTPReply {
        let text = String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
        let envelope: [String: Any] = ["id":id,"status":"completed","output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]]]
        return .init(status:200,body:try JSONSerialization.data(withJSONObject:envelope))
    }
}
private actor FlowReminders: RemindersFieldsPort, RecordingExpressionRemindersPort {
    var items: [ReminderSnapshot] = []
    var contexts: [String] = []
    var expressionEdits = 0
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        items.filter { $0.marker == marker || $0.id == externalID }
    }
    func create(calendarID: String, title: String, marker: String, context: String) async throws {
        items.append(.init(id: UUID().uuidString, title: title, completed: false, marker: marker))
        contexts.append(context)
    }
    func create(calendarID: String, title: String, marker: String, context: String, fields: ReminderFields) async throws {
        items.append(.init(id: UUID().uuidString, title: title, completed: false, marker: marker, dueDate: fields.due, fields: fields))
        contexts.append(context)
    }
    func updateFields(calendarID: String, expected: ReminderSnapshot, desired: ReminderFields,
                      authorize: @Sendable () async throws -> Void) async throws {
        guard let index = items.firstIndex(of: expected) else { throw VoiceOSError("提醒已被修改") }
        try await authorize()
        items[index] = .init(id: expected.id, title: expected.title, completed: expected.completed, marker: expected.marker, dueDate: desired.due, fields: desired)
    }
    func changeFields(_ id: String, _ fields: ReminderFields) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            let old = items[i]; items[i] = .init(id: old.id, title: old.title, completed: old.completed, marker: old.marker, dueDate: fields.due, fields: fields)
        }
    }
    func reconcileExpression(_ edit:RecordingExpressionReminderEdit,authorize:@Sendable () async throws -> Void) async throws -> ReminderSnapshot {
        expressionEdits += 1
        guard let index=items.firstIndex(where: { $0.id == edit.externalID && $0.marker == edit.marker }) else { throw VoiceOSError("提醒身份不符") }
        let old=items[index]
        if old.completed { return old }
        guard old.title == edit.expectedTitle || old.title == edit.desiredTitle else { throw VoiceOSError("外部修改不能覆盖") }
        try await authorize()
        let fields=edit.withdraw ? ReminderFields() : old.fields
        items[index] = .init(id:old.id,title:edit.desiredTitle,completed:false,marker:old.marker,dueDate:edit.withdraw ? nil : old.dueDate,fields:fields)
        return items[index]
    }
    func complete() { items = items.map { .init(id: $0.id, title: $0.title, completed: true, marker: $0.marker) } }
}
private struct FlowReminderFields: ReminderFieldModelPort {
    func extract(_ input: ReminderFieldInput) async throws -> ([ReminderFieldProposal], [String]) {
        let proposals = input.tasks.map { task in
            let source = input.sources.first { task.sourceIDs.contains($0.id) }!
            let date = source.relativeDates["明天"] ?? ""
            let explicit = task.title.contains("汇报")
            return ReminderFieldProposal(taskID: task.id, dueDate: explicit ? date : "", dueTime: explicit ? "15:00" : "", dueSourceID: explicit ? source.id : "", dueQuote: explicit ? source.text : "",
                                         alertDate: explicit ? date : "", alertTime: explicit ? "15:00" : "", alertSourceID: explicit ? source.id : "", alertQuote: explicit ? source.text : "",
                                         priority: explicit ? 1 : 0, prioritySourceID: explicit ? source.id : "", priorityQuote: explicit ? source.text : "", reviewNote: explicit ? "" : "周末有时间再安排，不设硬性日期")
        }
        return (proposals, ["fields-result"])
    }
}
private struct FlowReviewedActions: RecordingExpressionActionPort {
    let decisions:[RecordingExpressionActionDecision]
    func reconcile(_ input:RecordingExpressionActionInput) async throws -> ([RecordingExpressionActionDecision],[String]) {
        (decisions,["scoped-draft","scoped-independent"])
    }
}
private func verifyScopedExpressionActionReview(at root:URL) async throws {
    let storeRoot=root.appendingPathComponent("scoped-review"),package=root.appendingPathComponent("scoped-package")
    let clearID:String,retainedID:String,uncertainID:String,candidateID:String,discussionID:String
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
        discussionID = try await store.beginConversation(sourceIDs: [first])
        let question = try await store.recordUserExpression("请核对报告需要保留哪些条件。")
        _ = try await store.appendConversationUserSource(conversationID: discussionID, sourceID: question, expectedVersion: 1)
        let discussionInput = try await store.prepareConversationInput(id: discussionID, expectedVersion: 2, destination: .local)
        _ = try await store.performConversationReply(discussionInput, using: FlowCompleteDiscussion())
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
        let frozenDiscussion = try await store.conversation(id: discussionID)
        XCTAssertEqual(frozenDiscussion.validity, "frozen")
        let frozenReplies = try await store.discussionAttempts(conversationID: discussionID)
        XCTAssertEqual(frozenReplies.first?.validity, "frozen")
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
        try await store.syncRecordingExpressionReminders(using:reminders)
        let edits=await reminders.expressionEdits,afterSync=await reminders.items
        XCTAssertEqual(edits,0)
        XCTAssertTrue(afterSync.contains { $0.title == "整理报告" })
        let pendingUpdates=try await store.recordingExpressions().first?.reminderUpdates
        XCTAssertTrue(pendingUpdates?.contains(report.id) == true)
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
    let recoveredDiscussion = try await reopened.conversation(id: discussionID)
    XCTAssertEqual(recoveredDiscussion.validity, "frozen")
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
private struct FlowEnglish: EnglishPracticeModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "english", promptVersion: "english-practice-v1", schemaVersion: "english-feedback-v1", destination: .cloud)
    let response: EnglishPracticeResponse
    func generate(_ request: EnglishPracticeRequest) async throws -> EnglishPracticeResponse { response }
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
    func dbValidateFlowActions() throws { try Self.validateStoredActions(db) }
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
    func corruptFlowFollowupPath() throws {
        guard let row = try db.query("SELECT id,followup_json FROM sources WHERE followup_json IS NOT NULL LIMIT 1").first,
              let raw = row["followup_json"], var receipts = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]],
              var receipt = receipts.first, var input = receipt["input"] as? [String: Any],
              var current = input["current"] as? [String: Any], var sources = current["sources"] as? [[String: Any]],
              !sources.isEmpty else { throw VoiceOSError("fixture follow-up JSON missing") }
        sources[0]["text"] = 42
        current["sources"] = sources
        input["current"] = current
        receipt["input"] = input
        receipts[0] = receipt
        try db.execute("UPDATE sources SET followup_json=? WHERE id=?", [String(decoding: try JSONSerialization.data(withJSONObject: receipts), as: UTF8.self), row["id"]!])
    }
    func dateFlowExpression(_ id: String, at date: Date) throws {
        try db.execute("UPDATE sources SET created_at=? WHERE id=?", [ISO8601DateFormatter().string(from: date), id])
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

    func testSpokenReminderFieldsCreateEditAndRespectExternalChanges() async throws {
        let store = try await openStore(), model = FlowModel(createsTask: true), reminders = FlowReminders()
        let explicitID = try await expression(store, text: "VoiceOS功能验证：明天下午三点提醒我向mentor汇报，这件事优先处理。", model: model)
        _ = try await expression(store, text: "VoiceOS功能验证：周末有时间再整理书架。", model: model)
        let port: any ReminderFieldModelPort
        if let configuration = ProcessInfo.processInfo.environment["VOICEOS_REMINDER_FIELDS_LIVE_CONFIG"] { port = try LocalTextModel.loadSuite(from: URL(fileURLWithPath: configuration)).reminderFields }
        else { port = FlowReminderFields() }
        let midnightQuote = "明天下午三点提醒我向mentor汇报，这件事优先处理。"
        let midnightSources = ["2026-10-17T03:59:59+08:00", "2026-10-17T04:00:00+08:00"].enumerated().map {
            ReminderFieldInput.Source(id: "night-\($0.offset)", text: midnightQuote, version: "v1", policyVersion: 1, expressedAt: $0.element, timeZone: "Asia/Shanghai")
        }
        let midnightTasks = midnightSources.map { ReminderFieldInput.Task(id: $0.id, version: 1, title: "向mentor汇报", quote: midnightQuote, sourceIDs: [$0.id], isSuggestedStep: false) }
        let midnightInput = ReminderFieldInput(tasks: midnightTasks, sources: midnightSources, processingAt: "2026-10-14T00:00:00.000Z")
        XCTAssertEqual(midnightSources[0].relativeDates["明天"], "2026-10-17")
        XCTAssertEqual(midnightSources[1].relativeDates["明天"], "2026-10-18")
        let (nightProposals, _) = try await port.extract(midnightInput)
        for task in midnightTasks {
            let proposal = try XCTUnwrap(nightProposals.first { $0.taskID == task.id })
            XCTAssertEqual(proposal.dueDate, midnightSources.first { $0.id == task.id }?.relativeDates["明天"])
            let resolved = try VoiceOSStore.resolveReminderFields(proposal, task: task, input: midnightInput)
            XCTAssertEqual(resolved.alerts.count, 1)
        }
        let wrongDate = ReminderFieldProposal(taskID: midnightTasks[0].id, dueDate: "2026-10-18", dueTime: "15:00", dueSourceID: midnightSources[0].id, dueQuote: midnightQuote, alertDate: "", alertTime: "", alertSourceID: "", alertQuote: "", priority: 0, prioritySourceID: "", priorityQuote: "", reviewNote: "")
        XCTAssertThrowsError(try VoiceOSStore.resolveReminderFields(wrongDate, task: midnightTasks[0], input: midnightInput))
        _ = try await store.setReminderAccess(calendarID: "fixture", title: "VoiceOS", enabled: true, expectedVersion: 0)
        try await store.refreshAuthorizedReminders(expectedAccessVersion: 1, using: reminders, requireReviewedFields: true)
        let awaitingFields = await reminders.items
        XCTAssertTrue(awaitingFields.isEmpty)
        try await store.extractReminderFields(using: port)
        let actions = try await store.actions()
        let task = try XCTUnwrap(actions.first { $0.title.contains("汇报") })
        let receipt = try XCTUnwrap(task.intent?.reminderFields), fields = try XCTUnwrap(receipt.desired)
        XCTAssertEqual(fields.priority, 1)
        XCTAssertEqual(fields.alerts.count, 1)
        guard case let .instant(utc, zone) = fields.due else { return XCTFail("Explicit time must be preserved") }
        XCTAssertEqual(fields.alerts, [utc]); XCTAssertEqual(zone, TimeZone.current.identifier)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        XCTAssertEqual(calendar.component(.hour, from: ReminderFields.date(utc)!), 15)
        let today = calendar.startOfDay(for: Date())
        let expectedDay = calendar.component(.hour, from: Date()) < 4 ? today : calendar.date(byAdding: .day, value: 1, to: today)!
        XCTAssertEqual(calendar.startOfDay(for: ReminderFields.date(utc)!), expectedDay)
        let flexible = try XCTUnwrap(actions.first { $0.title.contains("书架") }?.intent?.reminderFields)
        XCTAssertEqual(flexible.desired, ReminderFields()); XCTAssertFalse(flexible.reviewNote.isEmpty)
        XCTAssertEqual(receipt.responseIDs.count, 1); XCTAssertNotNil(receipt.sourceVersions[explicitID])
        if let path = ProcessInfo.processInfo.environment["VOICEOS_REMINDER_FIELDS_DEMO_PACKAGE"] {
            try await store.exportPackage(to: URL(fileURLWithPath: path), includeMedia: true)
        }
        try await store.refreshAuthorizedReminders(expectedAccessVersion: 1, using: reminders, requireReviewedFields: true)
        let count = await reminders.items.count; XCTAssertEqual(count, 2)
        let initialItems = await reminders.items
        let initial = try XCTUnwrap(initialItems.first { $0.title.contains("汇报") })
        XCTAssertEqual(initial.fields, fields)
        var edited = fields; edited.priority = 5; edited.alerts = []
        try await store.updateReminderFields(actionID: task.id, expectedVersion: 1, expected: initial, desired: edited, expectedAccessVersion: 1, using: reminders)
        let updatedItems = await reminders.items
        let updated = try XCTUnwrap(updatedItems.first { $0.id == initial.id })
        XCTAssertEqual(updated.fields, edited)
        var dateOnly = edited
        let formatter = DateFormatter(); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        dateOnly.due = .dateOnly(localDate: formatter.string(from: ReminderFields.date(utc)!), timeZone: nil)
        try await store.updateReminderFields(actionID: task.id, expectedVersion: 1, expected: updated, desired: dateOnly, expectedAccessVersion: 1, using: reminders)
        let dateOnlyItems = await reminders.items
        XCTAssertEqual(dateOnlyItems.first { $0.id == initial.id }?.fields, dateOnly)
        var manual = edited; manual.priority = 9
        await reminders.changeFields(initial.id, manual)
        try await store.refreshAuthorizedReminders(expectedAccessVersion: 1, using: reminders)
        let after = try await store.actions().first { $0.id == task.id }
        XCTAssertEqual(after?.intent?.reminderFields?.observed, manual)
        do {
            try await store.updateReminderFields(actionID: task.id, expectedVersion: 1, expected: updated, desired: fields, expectedAccessVersion: 1, using: reminders)
            XCTFail("A stale settings editor must not overwrite a manual change")
        } catch { }
        let finalItems = await reminders.items; XCTAssertEqual(finalItems.first { $0.id == initial.id }?.fields, manual); XCTAssertEqual(finalItems.count, 2)
        let package = root.appendingPathComponent("fields-package"), restored = root.appendingPathComponent("fields-restored")
        try await store.exportPackage(to: package, includeMedia: true)
        try await VoiceOSStore.restorePackage(from: package, to: restored, inspector: NativeMediaInspector())
        let recovered = try VoiceOSStore(root: restored, inspector: NativeMediaInspector()); try await recovered.recover()
        let saved = try await recovered.actions().first { $0.id == task.id }
        XCTAssertEqual(saved?.intent?.reminderFields?.observed, manual)
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
            _ = try await store.reviewClaim(claimID: action.claimID, expectedVersion: 0, action: .endorse)
            let endorsedTask = try await store.actions().first { $0.id == action.id }
            XCTAssertEqual(endorsedTask?.validity, "current")
            XCTAssertEqual(endorsedTask?.claimReviewVersion, 1)
            XCTAssertEqual(endorsedTask?.version, action.version)
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
            let discussion = try await store.beginConversationForAction(actionID: completed.id, commandID: "discuss-result")
            let replayDiscussion = try await store.beginConversationForAction(actionID: completed.id, commandID: "discuss-result")
            XCTAssertEqual(discussion, replayDiscussion)
            let question = try await store.recordUserExpression("这次阅读有哪些仍需继续研究的问题？")
            _ = try await store.setSourceLocalOnly(sourceID: question, expectedVersion: 1, localOnly: false)
            _ = try await store.appendConversationUserSource(conversationID: discussion, sourceID: question, expectedVersion: 1)
            let discussionInput = try await store.prepareConversationInput(id: discussion, expectedVersion: 2, destination: .local)
            let discussionContext = try await store.validateConversationInput(discussionInput)
            XCTAssertEqual(discussionContext.conversationFocus?.selectedActionID, completed.id)
            XCTAssertEqual(discussionContext.conversationFocus?.tasks.first?.feedbackActionVersions?[feedbackID], completed.version)
            XCTAssertTrue(discussionContext.sources.contains { $0.sourceID == feedbackID && $0.text.contains("检索质量") })
            do { _ = try await store.prepareConversationInput(id: discussion, expectedVersion: 2, destination: .cloud); XCTFail("Local result text must not be sent without permission") } catch { }

            try await store.enqueueActionFeedbackUnderstanding(cognition: outcomeModel.configuration, association: association.configuration)
            let localQueue = try await store.processingIntents()
            XCTAssertTrue(localQueue.isEmpty)
            _ = try await store.setSourceLocalOnly(sourceID: feedbackID, expectedVersion: 1, localOnly: false)
            try await store.enqueueActionFeedbackUnderstanding(cognition: outcomeModel.configuration, association: association.configuration)
        }
        // The saved result and its processing survive reopening before any request.
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
        XCTAssertEqual(recoveredTask?.claimReviewVersion, 1)
        if let path = ProcessInfo.processInfo.environment["VOICEOS_OUTCOME_DEMO_PACKAGE"] {
            try await reopened.exportPackage(to: URL(fileURLWithPath: path), includeMedia: true)
        }
        _ = try await reopened.reviewClaim(claimID: action.claimID, expectedVersion: 1, action: .reject)
        _ = try await reopened.reviewClaim(claimID: action.claimID, expectedVersion: 2, action: .endorse)
        let rejectedTask = try await reopened.actions(includeHistory: true).first { $0.id == action.id }
        XCTAssertEqual(rejectedTask?.validity, "frozen")
        // The advertised claim schema and the local parser must agree. Rejections
        // name the claim index and the failing condition, never the personal text.
        let fixtureTexts = ["空陈述。", "空白陈述。", "空引用。", "正常陈述。"]
        var fixtureSources: [String] = [], fixtureReferences: [[String: Any]] = []
        for text in fixtureTexts {
            let id = try await reopened.recordUserExpression(text)
            _ = try await reopened.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
            let context = try await reopened.prepareLocalTranscriptContext(sourceIDs: [id])
            let source = try XCTUnwrap(context.sources.first)
            fixtureReferences.append(["sourceID": source.sourceID, "transcriptVersionID": source.transcriptVersionID, "spanID": source.spans[0].id])
            fixtureSources.append(id)
        }
        func claim(_ statement: String, _ references: [[String: Any]]) -> [String: Any] {
            ["statement": statement, "ownership": "user_tentative", "references": references, "contentKind": "statement", "action": NSNull()]
        }
        func understandingReply(_ claims: [[String: Any]], id: String) throws -> ModelHTTPReply {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: ["claims": claims], options: [.sortedKeys]), as: UTF8.self)
            let envelope: [String: Any] = ["id": id, "status": "completed", "output": [["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text]]]]]
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]))
        }
        let rejectedReplies = [
            try understandingReply([claim("", [fixtureReferences[0]])], id: "empty-statement"),
            try understandingReply([claim("   ", [fixtureReferences[1]])], id: "whitespace-statement"),
            try understandingReply([claim("引用不能为空。", [])], id: "empty-references")
        ]
        let validReply = try understandingReply([claim("检索质量需要验证。", [fixtureReferences[3]])], id: "valid-claim")
        let understandingTransport = FlowFollowupTransport(rejectedReplies + [validReply])
        let understandingPort = try ResponsesModelPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture-model", transport: understandingTransport)
        let expectedReasons = [
            "陈述字段无效（claim 0：statement 缺失、为空或超过 2000 字符）",
            "陈述字段无效（claim 0：statement 缺失、为空或超过 2000 字符）",
            "陈述字段无效（claim 0：references 为空）"
        ]
        for (index, expectedReason) in expectedReasons.enumerated() {
            do {
                _ = try await reopened.continueSourceUnderstanding(sourceID: fixtureSources[index], using: understandingPort)
                XCTFail("schema-valid wiring must still reject the invalid claim")
            } catch let error as VoiceOSError {
                XCTAssertTrue(error.message.contains(expectedReason), error.message)
            }
            let database = await reopened.db
            let attempt = try XCTUnwrap(database.query("SELECT a.state,a.error FROM model_attempts a JOIN context_inputs i ON i.context_id=a.context_id WHERE i.source_id=? ORDER BY a.producer_sequence DESC LIMIT 1", [fixtureSources[index]]).first)
            XCTAssertEqual(attempt["state"], "rejected")
            XCTAssertEqual(attempt["error"], expectedReason)
        }
        let rejectedSource = try await reopened.sources().first { $0.id == fixtureSources[0] }
        XCTAssertEqual(rejectedSource?.state, "saved")
        let completedUnderstanding = try await reopened.continueSourceUnderstanding(sourceID: fixtureSources[3], using: understandingPort)
        XCTAssertEqual(completedUnderstanding.state, "completed")
        XCTAssertEqual(completedUnderstanding.claimIDs.count, 1)
        let understoodClaims = try await reopened.candidateClaims()
        XCTAssertTrue(understoodClaims.contains { $0.statement == "检索质量需要验证。" })
        let understandingRequests = await understandingTransport.requests
        XCTAssertEqual(understandingRequests.count, 4)
        let firstRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: understandingRequests[0]) as? [String: Any])
        let format = try XCTUnwrap((firstRequest["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let claimSchema = try XCTUnwrap(((schema["properties"] as? [String: Any])?["claims"] as? [String: Any])?["items"] as? [String: Any])
        let properties = try XCTUnwrap(claimSchema["properties"] as? [String: Any])
        func assertBoundedText(_ key: String, in fields: [String: Any]) throws {
            let value = try XCTUnwrap(fields[key] as? [String: Any])
            XCTAssertEqual(value["minLength"] as? Int, 1)
            XCTAssertEqual(value["maxLength"] as? Int, 2000)
            XCTAssertEqual(value["pattern"] as? String, "\\S")
        }
        try assertBoundedText("statement", in: properties)
        XCTAssertEqual((properties["references"] as? [String: Any])?["minItems"] as? Int, 1)
        let actionSchema = try XCTUnwrap((properties["action"] as? [String: Any])?["anyOf"] as? [[String: Any]])
        let actionObject = try XCTUnwrap(actionSchema.first { $0["type"] as? String == "object" })
        let actionProperties = try XCTUnwrap(actionObject["properties"] as? [String: Any])
        try assertBoundedText("title", in: actionProperties)
        try assertBoundedText("quote", in: actionProperties)
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
        do { _ = try await store.prepareRecordingFollowup(sourceID: next.sourceID); XCTFail("完整校正前不能云端跟进") }
        catch { XCTAssertTrue(error.localizedDescription.contains("全文转写校正")) }
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
        let reviewedFollowup = try await store.prepareRecordingFollowup(sourceID: next.sourceID)
        XCTAssertEqual(reviewedFollowup.current.sources.first?.text, correctedTranscript)
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
        // An old successful inbox receipt must not skip continuity enrolment.
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
        // Automatic intake: two continuous clips, an unrelated clip, then a late correction.
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
        let preparedGroupingInput=try await grouped.prepareRecordingExpressions()
        let nativeGroupingInput=try XCTUnwrap(preparedGroupingInput)
        let nativeGroupingDraft=try await fixture.group(nativeGroupingInput).0
        let nativeGroups=try JSONSerialization.jsonObject(with:JSONEncoder().encode(nativeGroupingDraft))
        func groupingReply(_ id:String,_ output:[String:Any]) throws -> ModelHTTPReply {
            let text=String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self)
            let message:[String:Any] = ["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]
            let envelope:[String:Any] = ["id":id,"status":"completed","output":[message]]
            return .init(status:200,body:try JSONSerialization.data(withJSONObject:envelope))
        }
        func nativeGroupingPort(_ transport:FlowFollowupTransport) throws -> ResponsesRecordingExpressionPort {
            try .init(baseURL:URL(string:"https://api.openai.com/v1")!,apiKey:"fixture",model:"fixture-model",transport:transport)
        }
        let wrongGroups=try groupingReply("rejected-groups",["recordings":nativeGroups])
        let exhaustedGroupingTransport=FlowFollowupTransport([wrongGroups,wrongGroups,wrongGroups])
        do {
            _ = try await grouped.connectRecordingExpressions(using:nativeGroupingPort(exhaustedGroupingTransport))
            XCTFail("格式纠正耗尽后不能接受分组")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("分组格式错误"))
            XCTAssertTrue(error.localizedDescription.contains("原件和转写保留"))
        }
        let exhaustedGroupingRequests=await exhaustedGroupingTransport.requests
        XCTAssertEqual(exhaustedGroupingRequests.count,3)
        let unsavedGroups=try await grouped.recordingExpressions()
        XCTAssertTrue(unsavedGroups.isEmpty)
        let acceptedGroupingDraft=try groupingReply("accepted-groups-draft",["groups":nativeGroups])
        let acceptedGroupingReview=try groupingReply("accepted-groups-review",["groups":nativeGroups])
        let recoveringGroupingTransport=FlowFollowupTransport([wrongGroups,acceptedGroupingDraft,wrongGroups,acceptedGroupingReview])
        let nativeGrouped=try await grouped.connectRecordingExpressions(using:nativeGroupingPort(recoveringGroupingTransport))
        XCTAssertEqual(nativeGrouped.count,2)
        XCTAssertTrue(nativeGrouped.allSatisfy { $0.responseIDs == ["accepted-groups-draft","accepted-groups-review"] })
        let groupingRequests=await recoveringGroupingTransport.requests
        XCTAssertEqual(groupingRequests.count,4)
        for (index,data) in groupingRequests.enumerated() {
            let body=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            let messages=try XCTUnwrap(body["input"] as? [[String:Any]])
            let content=try XCTUnwrap(messages.first?["content"] as? String)
            let payload=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(content.utf8)) as? [String:Any])
            let sentInput=try XCTUnwrap(payload["input"] as? [String:Any])
            let sentContext=try XCTUnwrap(sentInput["context"] as? [String:Any])
            let sentSources=try XCTUnwrap(sentContext["sources"] as? [[String:Any]])
            XCTAssertEqual(sentSources.compactMap { $0["text"] as? String },nativeGroupingInput.context.sources.map(\.text))
            if index == 1 || index == 3 {
                XCTAssertEqual(payload["rejectedOutput"] as? String,String(decoding:try JSONSerialization.data(withJSONObject:["recordings":nativeGroups],options:[.sortedKeys]),as:UTF8.self))
                XCTAssertTrue((payload["validationError"] as? String)?.contains("groups") == true)
            } else {
                XCTAssertNil(payload["rejectedOutput"])
            }
            if index >= 2 {
                let sentDraft=try XCTUnwrap(payload["draft"] as? [[String:Any]])
                XCTAssertEqual(try JSONSerialization.data(withJSONObject:sentDraft,options:[.sortedKeys]),try JSONSerialization.data(withJSONObject:nativeGroups,options:[.sortedKeys]))
            } else {
                XCTAssertNil(payload["draft"])
            }
        }
        let grouping:any RecordingExpressionPort = fixture
        let actionPort:any RecordingExpressionActionPort = fixture
        let connected=nativeGrouped
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
        let actionInput=try await grouped.prepareExpressionActionReview(whole)
        let accepted=try await fixture.reconcile(actionInput).0.map { decision in
            var reviewed=decision;reviewed.possibleNewIDs=[];return reviewed
        }
        let reportDecision=try XCTUnwrap(accepted.first { $0.relation == "same" && $0.oldID != completed.id })
        let duplicate=accepted.map { decision in
            decision.oldID == completed.id ? RecordingExpressionActionDecision(oldID:decision.oldID,newID:reportDecision.newID,relation:"same",sourceID:decision.sourceID,quote:decision.quote,possibleNewIDs:[]) : decision
        }
        XCTAssertThrowsError(try VoiceOSStore.validateExpressionActionReview(duplicate,input:actionInput)) { error in
            XCTAssertTrue(error.localizedDescription.contains("被多个旧行动沿用"))
        }
        func actionReply(_ id:String,_ decisions:[RecordingExpressionActionDecision],text:String? = nil) throws -> ModelHTTPReply {
            let text=try text ?? String(decoding:JSONEncoder().encode(["decisions":decisions]),as:UTF8.self)
            let content:[String:String] = ["type":"output_text","text":text]
            let message:[String:Any] = ["type":"message","role":"assistant","status":"completed","content":[content]]
            let envelope:[String:Any] = ["id":id,"status":"completed","output":[message]]
            return .init(status:200,body:try JSONSerialization.data(withJSONObject:envelope))
        }
        let malformed="{\"actions\":[]}"
        let actionTransport=FlowFollowupTransport(try [actionReply("malformed-draft",duplicate,text:malformed),actionReply("invalid-draft",duplicate),actionReply("malformed-review",duplicate,text:malformed),actionReply("invalid-review",duplicate),actionReply("repaired-draft",accepted),actionReply("repaired-review",accepted)])
        let repairingPort=try ResponsesRecordingExpressionPort(baseURL:URL(string:"https://api.openai.com/v1")!,apiKey:"fixture",model:"flow",transport:actionTransport)
        try await grouped.finishRecordingExpression(whole,using:repairingPort)
        let actionRequests=await actionTransport.requests
        XCTAssertEqual(actionRequests.count,6)
        for index in [1,3] {
            let body=try XCTUnwrap(JSONSerialization.jsonObject(with:actionRequests[index]) as? [String:Any])
            let content=try XCTUnwrap((body["input"] as? [[String:Any]])?.first?["content"] as? String)
            let payload=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(content.utf8)) as? [String:Any])
            XCTAssertEqual(payload["rejectedOutput"] as? String,malformed)
            XCTAssertTrue((payload["validationError"] as? String)?.contains("decisions") == true)
            XCTAssertEqual(payload["draft"] != nil,index == 3)
        }
        let repairBody=try XCTUnwrap(JSONSerialization.jsonObject(with:actionRequests[4]) as? [String:Any])
        let repairInput=try XCTUnwrap((repairBody["input"] as? [[String:Any]])?.first?["content"] as? String)
        let repairPayload=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(repairInput.utf8)) as? [String:Any])
        XCTAssertTrue((repairPayload["validationError"] as? String)?.contains(reportDecision.newID) == true)
        let repairedExpressions=try await grouped.recordingExpressions()
        let repairedExpression=try XCTUnwrap(repairedExpressions.first { $0.id == whole.id })
        XCTAssertEqual(repairedExpression.actionReviewResponseIDs,["repaired-draft","repaired-review"])
        let malformedTransport=FlowFollowupTransport(try (0..<3).map { try actionReply("malformed-\($0)",accepted,text:malformed) })
        let malformedPort=try ResponsesRecordingExpressionPort(baseURL:URL(string:"https://api.openai.com/v1")!,apiKey:"fixture",model:"flow",transport:malformedTransport)
        do {
            _ = try await malformedPort.reconcile(actionInput)
            XCTFail("Repeated malformed action output must fail without accepting a review")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("decisions"))
            XCTAssertFalse(error.localizedDescription.contains(malformed))
        }
        let malformedRequests=await malformedTransport.requests
        XCTAssertEqual(malformedRequests.count,3)
        let finalActions=try await grouped.actions(includeHistory:true)
        let current=finalActions.filter { $0.validity == "current" && $0.state != "dismissed" }
        XCTAssertEqual(current.count,2)
        XCTAssertEqual(current.first { $0.title.contains("报告") }?.id,originalActions.first { $0.title.contains("报告") }?.id)
        XCTAssertEqual(current.first { $0.id == completed.id }?.state,"completed")
        let actualFeedback=try await grouped.actionFeedback(actionID:completed.id)
        XCTAssertEqual(actualFeedback.count,1)
        XCTAssertEqual(finalActions.first { $0.id == originalActions.first { $0.title.contains("发送") }!.id }?.state,"dismissed")
        try await grouped.syncRecordingExpressionReminders(using:groupedReminders)
        let remote=await groupedReminders.items
        XCTAssertEqual(remote.count,2)
        XCTAssertTrue(remote.contains { $0.title == "整理方案B对比报告" && !$0.completed })
        XCTAssertTrue(remote.contains { $0.title.hasPrefix("已撤回") && !$0.completed && $0.fields?.alerts.isEmpty == true })
        try await grouped.dbValidateFlowActions()
        let continued=try await grouped.prepareRecordingFollowup(sourceID:members[0])
        XCTAssertEqual(continued.continuousExpression?.context.sources.map(\.sourceID),whole.sourceIDs)
        _ = try await grouped.enqueueRecordingFollowup(sourceID:members[0])
        let knowledge=try await grouped.enqueueKnowledgeReview(sourceID:members[0])
        XCTAssertEqual(knowledge.state,"queued")
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
        // A podcast and personal response share a recording clock, not ownership.
        try await verifyScopedExpressionActionReview(at:root)
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
        let dualFollowup=try await dual.prepareRecordingFollowup(sourceID:personalID)
        XCTAssertEqual(Set(dualFollowup.continuousExpression?.context.sources.map(\.sourceID) ?? []),[personalID,programmeID])
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
        // Correcting programme transcription safely reopens the whole expression.
        let programmeRecords=try await dual.sources()
        let programmeBefore=try XCTUnwrap(programmeRecords.first { $0.id == programmeID })
        _ = try await dual.correctTranscript(sourceID:programmeID,expectedVersionID:programmeBefore.transcriptVersionID!,text:"智能体不能完全自主。节目组会在明天发布报告。")
        do { _ = try await dual.recordingContextLinks(sourceID:personalID);XCTFail("旧双轨关联不能绕过节目更正") } catch {}
        let correctionMembers=try await dual.queueCorrectedRecordingUnderstanding(sourceID:programmeID,previousActionIDs:[dualTask.id])
        XCTAssertEqual(correctionMembers,[personalID])
        // Explicit user correction is authoritative text; do not invent new
        // audio alignment or run an AI transcription correction over it.
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
        try assertPanoramaDatabaseReopens()
        try await assertPanoramaSchemaRepair()
        try await assertPanoramaProgressiveRecovery(root: root)
        try await assertPanoramaTitleChangeContinues(root: root)
        try await assertPanoramaQuoteRetry(root: root)
        try await assertPanoramaSlicedGeneration(root: root)
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
        let discussionID = try await store.beginConversationForThought(claimID: claim.id)
        let questionID = try await store.recordUserExpression("围绕这条观点，我接下来应研究什么？")
        _ = try await store.setSourceLocalOnly(sourceID: questionID, expectedVersion: 1, localOnly: false)
        _ = try await store.appendConversationUserSource(conversationID: discussionID, sourceID: questionID, expectedVersion: 1)
        let discussionInput = try await store.prepareConversationInput(id: discussionID, expectedVersion: 2, destination: .cloud)
        let discussionContext = try await store.validateConversationInput(discussionInput)
        XCTAssertEqual(discussionContext.conversationFocus?.selected.claimID, claim.id)
        XCTAssertEqual(discussionContext.conversationFocus?.selected.evidence.first?.quote, "记忆系统需要关注检索质量。")
        XCTAssertEqual(discussionContext.conversationFocus?.tasks.first?.actionID, taskID)
        let discussionPort = try ResponsesDiscussionPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture")
        let request = try discussionPort.makeRequest(.init(attemptID: UUID().uuidString,
            snapshot: .init(input: discussionInput, context: discussionContext, priorReplies: []), configuration: discussionPort.configuration))
        let requestText = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(requestText.contains("discussion_focus"))
        let grouped = try await store.latestCandidateClaimsBySource()
        XCTAssertEqual(grouped[oldID]?.map(\.id), claims.map(\.id))
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
        let largeProposal=PanoramaProposal(regions: [.init(id: "r", title: "检索研究", summary: largeSummary)], questions: [], relations: [], unrepresentedSources: eligible.sources.indices.map { .init(id: "s"+String($0+1), reason: "保留全文入口") }, unrepresentedClaims: [])
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
        XCTAssertEqual(decoded.unrepresentedSources.map(\.id), eligible.sources.map(\.id))

        let prefix = "👩‍💻e\u{301} s1 t1 c1。", repeatedQuote = "重复原话。"
        let unicodeText = prefix + repeatedQuote + repeatedQuote
        let repeatedStart = (prefix + repeatedQuote).unicodeScalars.count
        let firstSpan = TranscriptSpan(textStart: 0, textEnd: repeatedStart)
        let repeatedSpan = TranscriptSpan(textStart: repeatedStart, textEnd: unicodeText.unicodeScalars.count)
        let externalText = "外部节目关于检索。"
        let externalSpan = TranscriptSpan(textStart: 0, textEnd: externalText.unicodeScalars.count)
        let literalReason = "s1 t1 c1 和真实身份 s2、c2 只是原话，不得替换。"
        let transcriptReview = TranscriptionReview(completed: true, changed: true, response_id: "private-review-receipt", response_ids: ["private-review-receipt"], context_review_version: 3,
            corrections: [.init(span_id: firstSpan.id, before: "旧词", after: "新词", context_quote: prefix, reason: literalReason, independent_reason: "保留独立核对理由 c1")],
            unresolved_issues: [.init(span_id: repeatedSpan.id, reason: literalReason)], transcriptVersionID: "t2")
        let wireSources: [PanoramaSource] = [
            .init(transcript: .init(sourceID: "s2", sourceVersionID: "original-source-version", transcriptVersionID: "t2", origin: "user", speaker: "self", localOnly: false, text: unicodeText, spans: [firstSpan, repeatedSpan], transcriptionReview: transcriptReview), title: "完整 Unicode 原文", occurredAt: "2026-10-22T01:00:00Z", policyVersion: 1),
            .init(transcript: .init(sourceID: "external-source", sourceVersionID: "external-source-version", transcriptVersionID: "external-version", origin: "external", speaker: "external", localOnly: false, text: externalText, spans: [externalSpan]), title: "完整节目", occurredAt: "2026-10-21T01:00:00Z", policyVersion: 2)
        ]
        let wireClaims: [PanoramaClaim] = [
            .init(id: "c2", statement: literalReason, ownership: "user_tentative", reviewVersion: 1, references: [.init(sourceID: "s2", transcriptVersionID: "t2", spanID: repeatedSpan.id), .init(sourceID: "external-source", transcriptVersionID: "external-version", spanID: externalSpan.id)]),
            .init(id: "other-claim", statement: "保留全部当前观点", ownership: "unresolved", reviewVersion: 2, references: [.init(sourceID: "s2", transcriptVersionID: "t2", spanID: firstSpan.id)])
        ]
        let wireInput = PanoramaInput(manifest: .init(digest: "local-manifest", sourceIDs: wireSources.map(\.id), claimIDs: wireClaims.map(\.id), unitIDs: ["expression"]),
            units: [.init(id: "expression", sourceIDs: ["s2"], dependencyIDs: ["external-source"], producerID: "private-producer", completionDigest: "private-completion")],
            sources: wireSources, claims: wireClaims, exclusions: [.init(id: "excluded-private-source", title: "不应发送", reason: "本机资料")])
        let modelEvidence = PanoramaEvidence(sourceID: "s1", transcriptVersionID: "t1", start: repeatedStart, end: unicodeText.unicodeScalars.count, quote: repeatedQuote, claimIDs: ["c1"])
        let unicodeEvidence = PanoramaEvidence(sourceID: "s1", transcriptVersionID: "t1", start: 0, end: prefix.unicodeScalars.count, quote: prefix, claimIDs: [])
        let modelProposal = PanoramaProposal(regions: [.init(id: "t1", title: "原话研究", summary: literalReason)],
            questions: [.init(id: "s1", regionID: "t1", title: "如何理解原话？", summary: literalReason, evidence: [modelEvidence]), .init(id: "c1", regionID: "t1", title: "哪些条件尚待核对？", summary: literalReason, evidence: [unicodeEvidence])],
            relations: [.init(id: "s2", from: "s1", to: "c1", label: literalReason, explanation: literalReason, fromEvidence: [modelEvidence], toEvidence: [unicodeEvidence])],
            unrepresentedSources: [.init(id: "s2", reason: literalReason)], unrepresentedClaims: [.init(id: "c2", reason: literalReason)])
        let modelReview = PanoramaReview(questions: modelProposal.questions.map { .init(id: $0.id, accepted: true, reason: literalReason) }, relations: [.init(id: "s2", accepted: false, reason: literalReason)], coverageAccepted: true, reason: literalReason)
        func modelEnvelope<T: Encodable>(_ value: T) throws -> ModelHTTPReply {
            let encoded = try JSONEncoder().encode(value)
            let content: [String: Any] = ["type": "output_text", "text": String(decoding: encoded, as: UTF8.self)]
            let message: [String: Any] = ["type": "message", "role": "assistant", "status": "completed", "content": [content]]
            let envelope: [String: Any] = ["id": "compact-fixture", "status": "completed", "output": [message]]
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: envelope))
        }
        let compactTransport = FlowFollowupTransport(try [modelEnvelope(modelProposal), modelEnvelope(modelReview), modelEnvelope(modelProposal), modelEnvelope(modelReview)])
        let compactPort = try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: compactTransport)
        let (canonical, _) = try await compactPort.generate(wireInput)
        _ = try VoiceOSStore.validatePanorama(canonical, input: wireInput)
        XCTAssertEqual(canonical.questions.map(\.id), ["s1", "c1"])
        XCTAssertEqual(canonical.relations.first?.id, "s2")
        XCTAssertEqual(canonical.questions.first?.evidence.first?.sourceID, "s2")
        XCTAssertEqual(canonical.questions.first?.evidence.first?.transcriptVersionID, "t2")
        XCTAssertEqual(canonical.questions.first?.evidence.first?.claimIDs, ["c2"])
        XCTAssertEqual(canonical.questions.first?.evidence.first?.start, repeatedStart)
        XCTAssertEqual(canonical.questions.first?.evidence.first?.quote, repeatedQuote)
        XCTAssertEqual(canonical.questions[1].evidence[0].quote, prefix)
        XCTAssertEqual(canonical.questions[1].evidence[0].end, prefix.unicodeScalars.count)
        XCTAssertEqual(canonical.unrepresentedSources.first?.id, "external-source")
        XCTAssertEqual(canonical.unrepresentedClaims.first?.id, "other-claim")
        XCTAssertEqual(canonical.relations.first?.explanation, literalReason)
        let (rejectionReview, _) = try await compactPort.verify(canonical, input: wireInput)
        let (repaired, _) = try await compactPort.repair(canonical, input: wireInput, review: rejectionReview)
        let orderedEncoder = JSONEncoder()
        orderedEncoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try orderedEncoder.encode(repaired), try orderedEncoder.encode(canonical))
        _ = try await compactPort.verify(repaired, input: wireInput, priorRejection: .init(proposal: canonical, review: rejectionReview))
        let compactRequests = await compactTransport.requests
        func content(_ request: Data) throws -> [String: Any] {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
            let text = try XCTUnwrap(messages.first?["content"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let generationContent = try content(compactRequests[0])
        XCTAssertEqual(Set(generationContent.keys), ["units", "sources", "claims"])
        let sentSources = try XCTUnwrap(generationContent["sources"] as? [[String: Any]])
        XCTAssertEqual(sentSources.count, wireSources.count)
        XCTAssertEqual(sentSources.compactMap { $0["text"] as? String }, [unicodeText, externalText])
        XCTAssertEqual(sentSources.compactMap { $0["title"] as? String }, wireSources.map(\.title))
        XCTAssertEqual(sentSources.compactMap { $0["occurredAt"] as? String }, wireSources.map(\.occurredAt))
        XCTAssertEqual(sentSources.compactMap { $0["origin"] as? String }, ["user", "external"])
        XCTAssertEqual(sentSources.compactMap { $0["speaker"] as? String }, ["self", "external"])
        XCTAssertNil(sentSources[0]["spans"])
        let sentReview = try XCTUnwrap(sentSources[0]["transcriptionReview"] as? [String: Any])
        let sentIssues = try XCTUnwrap(sentReview["unresolvedIssues"] as? [[String: Any]])
        XCTAssertEqual(sentReview["transcriptVersionID"] as? String, "t1")
        XCTAssertEqual(sentIssues.count, 1)
        XCTAssertEqual(sentIssues[0]["start"] as? Int, repeatedStart)
        XCTAssertEqual(sentIssues[0]["end"] as? Int, unicodeText.unicodeScalars.count)
        XCTAssertEqual(sentIssues[0]["reason"] as? String, literalReason)
        let sentCorrections = try XCTUnwrap(sentReview["corrections"] as? [[String: Any]])
        XCTAssertEqual(sentCorrections.count, 1)
        XCTAssertEqual(sentCorrections[0]["start"] as? Int, 0)
        XCTAssertEqual(sentCorrections[0]["end"] as? Int, repeatedStart)
        XCTAssertEqual(sentCorrections[0]["before"] as? String, "旧词")
        XCTAssertEqual(sentCorrections[0]["after"] as? String, "新词")
        XCTAssertEqual(sentCorrections[0]["context_quote"] as? String, prefix)
        XCTAssertEqual(sentCorrections[0]["reason"] as? String, literalReason)
        XCTAssertEqual(sentCorrections[0]["independent_reason"] as? String, "保留独立核对理由 c1")
        let sentClaims = try XCTUnwrap(generationContent["claims"] as? [[String: Any]])
        XCTAssertEqual(sentClaims.count, wireClaims.count)
        XCTAssertEqual(sentClaims.compactMap { $0["statement"] as? String }, wireClaims.map(\.statement))
        XCTAssertEqual(sentClaims.compactMap { $0["ownership"] as? String }, wireClaims.map(\.ownership))
        let sentReferences = try sentClaims.map { try XCTUnwrap($0["references"] as? [[String: Any]]) }
        XCTAssertEqual(sentReferences.map(\.count), [2, 1])
        XCTAssertEqual(sentReferences[0].compactMap { $0["sourceID"] as? String }, ["s1", "s2"])
        XCTAssertEqual(sentReferences[0].compactMap { $0["transcriptVersionID"] as? String }, ["t1", "t2"])
        XCTAssertEqual(sentReferences[0].compactMap { $0["start"] as? Int }, [repeatedStart, 0])
        XCTAssertEqual(sentReferences[0].compactMap { $0["end"] as? Int }, [unicodeText.unicodeScalars.count, externalText.unicodeScalars.count])
        XCTAssertEqual(sentReferences[1][0]["start"] as? Int, 0)
        XCTAssertEqual(sentReferences[1][0]["end"] as? Int, repeatedStart)
        let sentUnits = try XCTUnwrap(generationContent["units"] as? [[String: Any]])
        XCTAssertEqual(sentUnits[0]["sourceIDs"] as? [String], ["s1"])
        XCTAssertEqual(sentUnits[0]["dependencyIDs"] as? [String], ["s2"])
        let expectedProposal = try orderedEncoder.encode(modelProposal)
        let expectedReview = try orderedEncoder.encode(modelReview)
        for index in 1...3 {
            let sent = try content(compactRequests[index])
            let sentProposal = try XCTUnwrap(sent["proposal"] as? [String: Any])
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: sentProposal, options: .sortedKeys), expectedProposal)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: sent["input"] as Any, options: .sortedKeys), try JSONSerialization.data(withJSONObject: generationContent, options: .sortedKeys))
        }
        let prior = try XCTUnwrap(try content(compactRequests[3])["priorRejection"] as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: prior["proposal"] as Any, options: .sortedKeys), expectedProposal)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: prior["review"] as Any, options: .sortedKeys), expectedReview)
        let wireBytes = try JSONSerialization.data(withJSONObject: generationContent, options: .sortedKeys).count
        let canonicalBytes = try JSONEncoder().encode(wireInput).count
        XCTAssertLessThan(wireBytes, canonicalBytes)
        print("Panorama synthetic transport fixture canonical=\(canonicalBytes) bytes compact=\(wireBytes) bytes; complete text, 2 sources, 2 claims, 3 references")

        let unknownProposal = PanoramaProposal(regions: [], questions: [], relations: [], unrepresentedSources: [.init(id: "unknown-alias", reason: literalReason)], unrepresentedClaims: [])
        let unknownPort = try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([try modelEnvelope(unknownProposal)]))
        do { _ = try await unknownPort.generate(wireInput); XCTFail("未知短身份不能返回资料库") } catch {}
        let wrongVersion = PanoramaProposal(regions: modelProposal.regions, questions: [.init(id: "s1", regionID: "t1", title: "版本错误", summary: literalReason, evidence: [.init(sourceID: "s1", transcriptVersionID: "t2", start: repeatedStart, end: unicodeText.unicodeScalars.count, quote: repeatedQuote, claimIDs: ["c1"])])], relations: [], unrepresentedSources: [], unrepresentedClaims: [])
        let wrongVersionPort = try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([try modelEnvelope(wrongVersion)]))
        do { _ = try await wrongVersionPort.generate(wireInput); XCTFail("短身份存在也不能串用来源和版本") } catch {}
        var missingIssueTranscript = wireSources[0].transcript
        missingIssueTranscript.transcriptionReview = .init(completed: true, changed: false, response_id: "fixture", response_ids: nil, context_review_version: nil, unresolved_issues: [.init(span_id: "missing-span", reason: literalReason)], transcriptVersionID: "t2")
        let missingIssueInput = PanoramaInput(manifest: wireInput.manifest, units: wireInput.units, sources: [.init(transcript: missingIssueTranscript, title: wireSources[0].title, occurredAt: wireSources[0].occurredAt, policyVersion: 1), wireSources[1]], claims: wireClaims, exclusions: [])
        let missingTransport = FlowFollowupTransport([])
        let missingPort = try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: missingTransport)
        do { _ = try await missingPort.generate(missingIssueInput); XCTFail("无法定位的待核对项不能丢弃") } catch {}
        let missingReferenceInput = PanoramaInput(manifest: wireInput.manifest, units: wireInput.units, sources: wireSources, claims: [.init(id: "c2", statement: literalReason, ownership: "unresolved", reviewVersion: 1, references: [.init(sourceID: "s2", transcriptVersionID: "t2", spanID: "missing-span")])], exclusions: [])
        do { _ = try await missingPort.generate(missingReferenceInput); XCTFail("无法定位的观点引用不能丢弃") } catch {}
        let missingRequests = await missingTransport.requests
        XCTAssertTrue(missingRequests.isEmpty)
        let failureStore=try await panoramaFixtureStore(root.appendingPathComponent("failure-paths"), count: 1)
        let invalid=try JSONSerialization.data(withJSONObject: ["status":"completed", "output":[["type":"unsupported"]]])
        let rejectedPort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([.init(status: 200, body: invalid)]))
        do { try await failureStore.generatePanorama(using: rejectedPort); XCTFail("无效响应不能发布") } catch {}
        let rejected=try await failureStore.panoramaState()
        XCTAssertEqual(rejected.status, "failed")
        XCTAssertTrue(rejected.error?.contains("响应包含不支持的输出项") == true, "失败信息应保留核对原因：\(rejected.error ?? "nil")")
        XCTAssertNil(rejected.snapshot)
        let privateDetail="https://fixture.invalid/private?key=fixture-secret"
        let terminalFailures: [([String:Any],String,Bool)]=[
            (["status":"failed", "error":["code":"server_error", "message":privateDetail]], "响应未完成（status=failed；error.code=server_error）；未接纳部分结果", true),
            (["status":"failed", "error":["code":"upstream_error", "message":privateDetail]], "响应未完成（status=failed；error.code=upstream_error）；未接纳部分结果", true),
            (["status":"failed", "error":["code":privateDetail, "message":privateDetail]], "响应未完成（status=failed；error.code=unknown）；未接纳部分结果", false),
            (["status":"completed"], "响应已完成但 output 缺失或格式无效（status=completed）", false),
            (["status":"incomplete", "incomplete_details":["reason":"max_output_tokens"]], "响应未完成（status=incomplete；incomplete_details.reason=max_output_tokens）；未接纳部分结果", false),
            (["status":"incomplete", "incomplete_details":["reason":privateDetail]], "响应未完成（status=incomplete；incomplete_details.reason=unknown）；未接纳部分结果", false),
            (["status":privateDetail], "响应未完成（status=unknown）；未接纳部分结果", false)
        ]
        for (var response, expected, transient) in terminalFailures {
            response["usage"]=["input_tokens":120,"output_tokens":100]
            let reply=ModelHTTPReply(status:200, body:try JSONSerialization.data(withJSONObject:response))
            let transport=FlowFollowupTransport(Array(repeating: reply, count: transient ? 3 : 1))
            let port=try ResponsesPanoramaPort(baseURL:URL(string:"https://api.openai.com/v1")!,apiKey:"fixture",model:"fixture",transport:transport)
            do { try await failureStore.generatePanorama(using:port,retry:true); XCTFail("终态失败不能发布") }
            catch let failure as PanoramaUnitFailures {
                XCTAssertEqual(failure.firstReason,expected)
                XCTAssertEqual(failure.verifiedCount,0)
                XCTAssertEqual(failure.totalCount,1)
            }
            catch { XCTFail("预期 PanoramaUnitFailures，实际 \(error)") }
            let failure=try await failureStore.panoramaState()
            XCTAssertEqual(failure.status,"failed")
            XCTAssertTrue(failure.error?.contains(expected) == true, "失败信息应保留核对原因：\(failure.error ?? "nil")")
            XCTAssertFalse(failure.error?.contains("fixture-secret") ?? true)
            XCTAssertNil(failure.snapshot)
            let requests=await transport.requests
            XCTAssertEqual(requests.count, transient ? 3 : 1)
        }
        let timedOutPort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowPanoramaFailureTransport())
        do { try await failureStore.generatePanorama(using: timedOutPort, retry: true); XCTFail("网络失败不能发布") } catch {}
        let timedOut=try await failureStore.panoramaState()
        XCTAssertEqual(timedOut.status, "failed")
        XCTAssertTrue(timedOut.error?.contains("全景请求达到单次 600 秒窗口；未发布部分结果，材料保留，可明确重试") == true, "失败信息应保留网络原因：\(timedOut.error ?? "nil")")
        XCTAssertNil(timedOut.snapshot)
        let upstreamBody=try JSONSerialization.data(withJSONObject: ["status":"failed", "error":["code":"upstream_error"]])
        let upstreamPort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([.init(status: 200, body: upstreamBody)]))
        do { _ = try await upstreamPort.generate(wireInput); XCTFail("上游失败应归类为可重试的瞬时失败") }
        catch is PanoramaTransientFailure {}
        catch { XCTFail("预期 PanoramaTransientFailure，实际 \(error)") }
        let authBody=try JSONSerialization.data(withJSONObject: ["status":"failed", "error":["code":"invalid_api_key"]])
        let authPort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([.init(status: 200, body: authBody)]))
        do { _ = try await authPort.generate(wireInput); XCTFail("认证失败必须保持终态拒绝") }
        catch ModelPortFailure.rejected(let reason,_,_) { XCTAssertTrue(reason.contains("error.code=invalid_api_key")) }
        catch { XCTFail("预期 ModelPortFailure.rejected，实际 \(error)") }
        let starvationDirectory=root.appendingPathComponent("panorama-unit-failure")
        let starvationStore=try VoiceOSStore(root: starvationDirectory, inspector: NativeMediaInspector())
        try await starvationStore.recover()
        var starvationIDs: [String]=[]
        for (index, repetitions) in [40, 120, 260].enumerated() {
            let id=try await starvationStore.recordUserExpression(String(repeating: "单元失败隔离材料第\(index)项。", count: repetitions))
            _ = try await starvationStore.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
            starvationIDs.append(id)
        }
        let starvationContext=try await starvationStore.prepareLocalTranscriptContext(sourceIDs: starvationIDs, scalarBudget: Int.max)
        _ = try await starvationStore.importOrganizedClaims(context: starvationContext, proposals: [], commandID: "unit-failure-fixture")
        let starvationPort=ProgressivePanoramaFixture(unitTransientFailures: [starvationIDs[1]: 3])
        do { try await starvationStore.generatePanorama(using: starvationPort); XCTFail("单元失败后整次尝试仍应汇总失败") } catch {}
        let starvationState=try await starvationStore.panoramaState()
        XCTAssertEqual(starvationState.status, "failed")
        let starvationCalls=await starvationPort.generatedSourceIDs
        XCTAssertTrue(starvationCalls.contains { $0.contains(starvationIDs[2]) }, "后续单元必须继续尝试；实际调用：\(starvationCalls)")
        XCTAssertEqual(Set(starvationState.snapshot?.workflow?.verifiedUnitIDs ?? []), Set([starvationIDs[0], starvationIDs[2]]), "部分快照应保留已核对单元")
        XCTAssertTrue(starvationState.error?.contains(starvationIDs[1]) == true, "失败信息应点名失败单元：\(starvationState.error ?? "nil")")
        XCTAssertTrue(starvationState.error?.contains("已核对 2/3 个") == true, "失败信息应带核对进度：\(starvationState.error ?? "nil")")
        let starvationSteps=try Database(starvationDirectory.appendingPathComponent("voiceos.sqlite")).query("SELECT state FROM panorama_steps WHERE stage='unit.generate' AND scope_id=? ORDER BY rowid", [starvationIDs[1]])
        XCTAssertFalse(starvationSteps.isEmpty)
        XCTAssertTrue(starvationSteps.allSatisfy { $0["state"] == "failed" }, "失败单元的生成步骤应记录为失败")
        do { try await starvationStore.generatePanorama(using: starvationPort, retry: true) }
        catch { XCTFail("明确重试应继续失败单元：\(error)") }
        let starvationRecovered=try await starvationStore.panoramaState()
        XCTAssertEqual(starvationRecovered.status, "completed")
        let transientDirectory=root.appendingPathComponent("panorama-transient-unit")
        let transientStore=try VoiceOSStore(root: transientDirectory, inspector: NativeMediaInspector())
        try await transientStore.recover()
        let transientID=try await transientStore.recordUserExpression("瞬时上游失败重试后仍须完成完整核对。")
        _ = try await transientStore.setSourceLocalOnly(sourceID: transientID, expectedVersion: 1, localOnly: false)
        let transientContext=try await transientStore.prepareLocalTranscriptContext(sourceIDs: [transientID], scalarBudget: Int.max)
        _ = try await transientStore.importOrganizedClaims(context: transientContext, proposals: [], commandID: "transient-fixture")
        let transientPort=ProgressivePanoramaFixture(unitTransientFailures: [transientID: 2])
        do { try await transientStore.generatePanorama(using: transientPort) }
        catch { XCTFail("瞬时上游失败应在重试后完成：\(error)") }
        let transientState=try await transientStore.panoramaState()
        XCTAssertEqual(transientState.status, "completed")
        let transientGenerations=await transientPort.generations
        XCTAssertEqual(transientGenerations, 3, "单元生成应经历两次重试后成功")
        let transientSteps=try Database(transientDirectory.appendingPathComponent("voiceos.sqlite")).query("SELECT state FROM panorama_steps WHERE stage='unit.generate' ORDER BY rowid")
        XCTAssertEqual(transientSteps.compactMap { $0["state"] }, ["failed", "failed", "completed"])
        do { try await store.generatePanorama(using: panorama, retry: true); XCTFail("全局核对尚未完成不能完成全景") }
        catch { XCTAssertEqual((error as? VoiceOSError)?.message, "当前模型端口尚不支持跨单元全景核对，已核对区域保留") }
        try await store.generatePanorama(using: panorama)
        let state=try await store.panoramaState(), snapshot=try XCTUnwrap(state.snapshot)
        XCTAssertEqual(snapshot.coverage.submittedSourceIDs.count, 4)
        XCTAssertEqual(snapshot.coverage.representedSourceIDs.count, 4)
        XCTAssertEqual(snapshot.coverage.unrepresentedSources.count, 0)
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertEqual(snapshot.workflow?.verifiedUnitIDs.count, 4)
        XCTAssertEqual(state.status, "failed")
        XCTAssertTrue(snapshot.proposal.relations.isEmpty)
        let generationCount=await panorama.generations, reviewCount=await panorama.reviews, repairCount=await panorama.repairs
        XCTAssertEqual(generationCount, 4); XCTAssertEqual(reviewCount, 5); XCTAssertEqual(repairCount, 1)
        let receivedRejection=await panorama.receivedRejection
        XCTAssertTrue(receivedRejection)
        XCTAssertEqual(snapshot.proposal.questions.first?.evidence.first?.start, 0)
        XCTAssertEqual(snapshot.generation.responseID, "generation-4")
        do { try await store.generatePanorama(using: panorama, retry: true) } catch {}
        let resumedGenerationCount=await panorama.generations
        XCTAssertEqual(resumedGenerationCount, generationCount)
        let repeated=eligible.sources[0]
        let ambiguous=PanoramaEvidence(sourceID: repeated.id, transcriptVersionID: repeated.transcript.transcriptVersionID, start: -1, end: -1, quote: "合成检索资料需要完整保留。", claimIDs: [])
        let ambiguousProposal=PanoramaProposal(regions: snapshot.proposal.regions, questions: [.init(id: "ambiguous", regionID: "r", title: "重复原话", summary: "不能猜测位置", evidence: [ambiguous])], relations: [], unrepresentedSources: [], unrepresentedClaims: [])
        XCTAssertThrowsError(try VoiceOSStore.locatePanoramaQuotes(ambiguousProposal, input: eligible))
        let entry=try await store.beginPanoramaConversation(snapshotID: snapshot.id, selection: .question(snapshot.proposal.questions[0].id))
        XCTAssertTrue(entry.draft.contains("AI 全景候选"))
        let noTurns=try await store.conversationUserTurns(conversationID: entry.conversation.id)
        XCTAssertTrue(noTurns.isEmpty)
        try await store.endConversation(id: entry.conversation.id, expectedVersion: 1)
        let reopened=try await store.beginPanoramaConversation(snapshotID: snapshot.id, selection: .question(snapshot.proposal.questions[0].id))
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
        do { _ = try await store.beginPanoramaConversation(snapshotID: snapshot.id, selection: .question(snapshot.proposal.questions[0].id)); XCTFail("旧图不能继续讨论") } catch {}
    }

    private func assertPanoramaDatabaseReopens() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url=root.appendingPathComponent("panorama-schema.sqlite")
        var created: Database?=try Database(url)
        XCTAssertEqual(try created?.query("PRAGMA user_version").first?["user_version"], "49")
        created=nil
        let reopened=try Database(url)
        XCTAssertEqual(try reopened.query("PRAGMA table_info(panorama_steps)").filter { $0["name"] == "receipt_json" }.count, 1)
    }
    private func assertPanoramaSchemaRepair() async throws {
        let text="格式核对需要完整原文。"
        let transcript=ContextTranscript(sourceID: "format-source", sourceVersionID: "format-source-version", transcriptVersionID: "format-version", origin: "user", speaker: "user", localOnly: false,
            text: text, spans: [.init(textStart: 0, textEnd: text.unicodeScalars.count)])
        let input=PanoramaInput(manifest: .init(digest: "format-fixture", sourceIDs: [transcript.sourceID], claimIDs: [], unitIDs: ["format-unit"]),
            units: [.init(id: "format-unit", sourceIDs: [transcript.sourceID], dependencyIDs: [], producerID: "format-producer", completionDigest: "format-complete")],
            sources: [.init(transcript: transcript, title: "格式回放", occurredAt: "2026-10-23", policyVersion: 1)], claims: [], exclusions: [])
        let evidence: [String: Any]=["sourceID":"s1","transcriptVersionID":"t1","start":0,"end":text.unicodeScalars.count,"quote":text,"claimIDs":[]]
        let nestedQuestion: [String: Any]=["id":"q","title":"如何核对格式？","summary":"保留原话","evidence":[evidence]]
        let bad: [String: Any]=["regions":[["id":"r","title":"格式核对","summary":"保留原话","questions":[nestedQuestion]]], "relations":[], "unrepresentedSources":[], "unrepresentedClaims":[]]
        var flatQuestion=nestedQuestion; flatQuestion["regionID"]="r"
        let valid: [String: Any]=["regions":[["id":"r","title":"格式核对","summary":"保留原话"]], "questions":[flatQuestion], "relations":[], "unrepresentedSources":[], "unrepresentedClaims":[]]
        func reply(_ object: [String: Any], id: String) throws -> ModelHTTPReply {
            let content=String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["id":id,"status":"completed","output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":content]]]]]))
        }
        let transport=FlowFollowupTransport(try [reply(bad,id: "nested-fixture"),reply(valid,id: "flat-fixture")])
        let port=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: transport)
        let (proposal,receipt)=try await port.generate(input)
        _ = try VoiceOSStore.validatePanorama(proposal, input: input)
        XCTAssertEqual(receipt.responseID,"flat-fixture")
        XCTAssertEqual(proposal.questions.first?.regionID,"r")
        let requests=await transport.requests
        XCTAssertEqual(requests.count,2)
        let body=try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1]) as? [String: Any])
        let messages=try XCTUnwrap(body["input"] as? [[String: Any]])
        let instruction=try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(instruction.contains("keyNotFound"))
        XCTAssertTrue(instruction.contains("$.questions"))
        XCTAssertTrue(instruction.contains("regionID"))
        XCTAssertTrue(instruction.contains("绝不嵌套 questions"))
    }

    func testPeriodReflectionKeepsKnowledgeActionsResultsAndCompleteEvidence() async throws {
        let store = try await openStore(), model = FlowModel()
        let calendar = Calendar.current, now = Date()
        let day = ReflectionPeriod.day.interval(containing: now)
        let month = ReflectionPeriod.month.interval(containing: now)
        let earlier = calendar.date(byAdding: .month, value: -1, to: now)!
        let oldID = try await expression(store, text: "我会阅读检索评测的论文，并做一次对照实验。", model: FlowModel(createsTask: true))
        try await store.dateFlowExpression(oldID, at: earlier)
        let actions = try await store.actions()
        let task = try XCTUnwrap(actions.first)
        let completionVersion = try await store.setActionState(actionID: task.id, expectedVersion: task.version, state: .completed)
        let feedbackID = try await store.recordActionFeedback(actionID: task.id, expectedVersion: completionVersion, kind: .outcome, text: "完成对照后发现，相关文档的位置会影响检索结果，还不能推广到所有任务。")
        _ = try await store.setSourceLocalOnly(sourceID: feedbackID, expectedVersion: 1, localOnly: false)
        _ = try await store.continueSourceUnderstanding(sourceID: feedbackID, using: model)
        _ = try await expression(store, text: "今天读到检索增强：容量增加不一定改善答案，需要观察召回质量。", model: model)
        _ = try await expression(store, text: "学习实验设计时，我开始区分看到的相关性和有证据的因果关系。", model: model)
        let focus = try await store.reflection(start: day.start, end: day.end, timeZoneID: calendar.timeZone.identifier)
        XCTAssertEqual(focus.expressions.filter(\.isInPeriod).count, 2)
        XCTAssertEqual(focus.expressions.first(where: { $0.id == oldID })?.isInPeriod, false)
        XCTAssertEqual(focus.completions.count, 1)
        XCTAssertEqual(focus.outcomes.map(\.sourceID), [feedbackID])
        XCTAssertTrue(focus.thoughts.contains { $0.evidence.contains { $0.reference.sourceID == feedbackID } })
        let monthly = try await store.reflection(start: month.start, end: month.end, timeZoneID: calendar.timeZone.identifier)
        XCTAssertEqual(monthly.completions.map(\.actionID), [task.id])
        let empty = ReflectionPeriod.day.interval(containing: calendar.date(byAdding: .year, value: -1, to: now)!)
        let emptyFocus = try await store.reflection(start: empty.start, end: empty.end, timeZoneID: calendar.timeZone.identifier)
        XCTAssertTrue(emptyFocus.sourceIDs.isEmpty)
        if let path = ProcessInfo.processInfo.environment["VOICEOS_REFLECTION_DEMO_EXPORT"] {
            try await store.exportPackage(to: URL(fileURLWithPath: path), includeMedia: true)
        }
        var longIDs: [String] = []
        for topic in ["检索评测", "实验设计", "知识结构", "反思迭代"] {
            let id = try await store.recordUserExpression(String(repeating: topic + "需要保留完整原话。", count: 280) + "最后的学习意图也必须保留。")
            _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
            longIDs.append(id)
        }
        let complete = try await store.reflection(start: month.start, end: month.end, timeZoneID: calendar.timeZone.identifier)
        let discussionID = try await store.beginConversationForReflection(complete, commandID: "period-review")
        let replay = try await store.beginConversationForReflection(complete, commandID: "period-review")
        XCTAssertEqual(replay, discussionID)
        let turnsBefore = try await store.conversationUserTurns(conversationID: discussionID)
        XCTAssertTrue(turnsBefore.isEmpty)
        let questionID = try await store.recordUserExpression("请比较这些主题的联系，结合实际结果提出需要继续验证的问题。")
        _ = try await store.setSourceLocalOnly(sourceID: questionID, expectedVersion: 1, localOnly: false)
        _ = try await store.appendConversationUserSource(conversationID: discussionID, sourceID: questionID, expectedVersion: 1)
        let input = try await store.prepareConversationInput(id: discussionID, expectedVersion: 2, destination: .cloud)
        let context = try await store.validateConversationInput(input)
        XCTAssertGreaterThan(context.scalarBudget, 12000)
        XCTAssertTrue(longIDs.allSatisfy { id in context.sources.contains { $0.sourceID == id && $0.text.hasSuffix("最后的学习意图也必须保留。") } })
        let port = try ResponsesDiscussionPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture")
        let request = try port.makeRequest(.init(attemptID: UUID().uuidString, snapshot: .init(input: input, context: context, priorReplies: []), configuration: port.configuration))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["truncation"] as? String, "disabled")
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let focusText = try XCTUnwrap(messages.compactMap { $0["content"] as? String }.first { $0.contains("reflection_focus") })
        let focusMessage = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(focusText.utf8)) as? [String: Any])
        let sentFocus = try XCTUnwrap(focusMessage["focus"] as? [String: Any])
        let sentStart = try XCTUnwrap(sentFocus["start"] as? String)
        XCTAssertEqual(ISO8601DateFormatter().date(from: sentStart), month.start)
        let replyID = try await store.performConversationReply(input, using: FlowDiscussion())
        let retainedID = try await store.retainDiscussionAICandidate(attemptID: replyID, partIndex: 0)
        let afterRetention = try await store.conversation(id: discussionID)
        XCTAssertEqual(afterRetention.validity, "current")
        let enriched = try await store.reflection(start: month.start, end: month.end, timeZoneID: calendar.timeZone.identifier)
        XCTAssertTrue(enriched.thoughts.contains { $0.claimID == retainedID && $0.ownership == "ai_candidate" })
        XCTAssertTrue(Set(complete.thoughts.map(\.claimID)).isSubset(of: Set(enriched.thoughts.map(\.claimID))))
        try await store.endConversation(id: discussionID, expectedVersion: 2)
        let outcome = try await store.prepareConversationOutcome(id: discussionID, expectedVersion: 3, destination: .cloud)
        XCTAssertEqual(outcome.context.reflectionFocus?.sourceIDs, complete.sourceIDs)
        XCTAssertGreaterThan(outcome.context.scalarBudget, 12000)
        let package = root.appendingPathComponent("reflection-package"), restored = root.appendingPathComponent("reflection-restored")
        try await store.exportPackage(to: package, includeMedia: true)
        try await VoiceOSStore.restorePackage(from: package, to: restored, inspector: NativeMediaInspector())
        let recovered = try VoiceOSStore(root: restored, inspector: NativeMediaInspector()); try await recovered.recover()
        let saved = try await recovered.conversationReflectionFocus(conversationID: discussionID)
        XCTAssertEqual(saved?.sourceIDs, complete.sourceIDs)
        _ = try await recovered.setActionState(actionID: task.id, expectedVersion: completionVersion, state: .open)
        let retained = try await recovered.candidateClaims(includeFrozen: true).first { $0.id == retainedID }
        XCTAssertEqual(retained?.validity, "frozen")
        let frozen = try await recovered.conversation(id: discussionID)
        XCTAssertEqual(frozen.validity, "frozen")
        let replies = try await recovered.discussionAttempts(conversationID: discussionID)
        XCTAssertEqual(replies.first?.validity, "frozen")
        do { try await recovered.validateConversationOutcome(outcome); XCTFail("任务变化后旧回顾成果应暂停使用") } catch {}
    }

    func testQuestionConnectsUnderstandingExperimentResultsAndPortableReview() async throws {
        let store = try await openStore(), taskModel = FlowModel(createsTask: true)
        let relevant = try await expression(store, text: "下次开发先写清完成标准，观察任务是否更稳定。", model: taskModel)
        let unrelated = try await expression(store, text: "周末整理书架。", model: taskModel)
        let week = ReflectionPeriod.week.interval(containing: Date()), zone = Calendar.current.timeZone.identifier
        try await store.dateFlowExpression(relevant, at: week.start.addingTimeInterval(-86400 * 21))
        let question = try await store.createReflectionQuestion(title: "怎样让 Agent 稳定完成真实任务？")
        try await store.linkReflectionQuestionSource(questionID: question.id, sourceID: relevant)
        let observation = try await store.addReflectionQuestionEntry(questionID: question.id, kind: .observation, text: "我先前认为模型能力是主要原因。", sourceIDs: [relevant])
        _ = try await store.addReflectionQuestionEntry(questionID: question.id, kind: .change, text: "现在我认为任务边界也值得检验，这仍是暂定判断。", sourceIDs: [relevant, observation.sourceID])
        let experiment = try await store.addReflectionQuestionEntry(questionID: question.id, kind: .experiment, text: "下次先明确完成标准，记录哪些条件实际满足。", sourceIDs: [relevant])
        _ = try await store.addReflectionQuestionEntry(questionID: question.id, kind: .result, text: "这次更容易发现遗漏，但一次经历还不能证明原因。", sourceIDs: [experiment.sourceID])
        var focus = try await store.reflectionForQuestion(questionID: question.id, start: week.start, end: week.end, timeZoneID: zone)
        focus.period = .week
        XCTAssertEqual(focus.question?.entries.count, 4)
        XCTAssertTrue(focus.sourceIDs.contains(question.sourceID))
        XCTAssertTrue(focus.sourceIDs.contains(experiment.sourceID))
        XCTAssertFalse(focus.sourceIDs.contains(unrelated))
        XCTAssertEqual(focus.tasks.count, 1)
        XCTAssertEqual(focus.expressions.first(where: { $0.id == relevant })?.isInPeriod, false)
        let topicFocus = try await store.reflectionForTopic(questionID: question.id, timeZoneID: zone)
        XCTAssertTrue(topicFocus.isTopicOverview)
        XCTAssertTrue(topicFocus.expressions.first(where: { $0.id == relevant })?.isInPeriod == true)
        XCTAssertFalse(topicFocus.sourceIDs.contains(unrelated))
        XCTAssertTrue(topicFocus.topicReviewPrompt.contains("跨时间"))
        let later = Date().addingTimeInterval(15 * 86_400)
        let quietTopics = try await store.topicResurfacing(now: later)
        XCTAssertTrue(quietTopics.contains { $0.id == question.id })
        try await store.saveTopicFeedback(questionID: question.id, mode: .normal, snooze: true, now: later)
        let snoozedTopics = try await store.topicResurfacing(now: later.addingTimeInterval(6 * 86_400))
        XCTAssertFalse(snoozedTopics.contains { $0.id == question.id })
        try await store.saveTopicFeedback(questionID: question.id, mode: .paused, snooze: false, now: later)
        let pausedTopics = try await store.topicResurfacing(now: later.addingTimeInterval(40 * 86_400))
        XCTAssertFalse(pausedTopics.contains { $0.id == question.id })
        try await store.saveTopicFeedback(questionID: question.id, mode: .normal, snooze: false, now: later)
        try await store.markTopicReviewed(questionID: question.id, now: later)
        let reviewedTopics = try await store.topicResurfacing(now: later)
        XCTAssertFalse(reviewedTopics.contains { $0.id == question.id })
        let linkActions = try await store.actions()
        let linkedTask = try XCTUnwrap(linkActions.first { $0.kind == "task" && $0.title.contains("下次开发") })
        try await store.linkTopicAction(questionID: question.id, actionID: linkedTask.id, expectedVersion: linkedTask.version)
        let linkClaims = try await store.candidateClaims()
        let linkedClaim = try XCTUnwrap(linkClaims.first { $0.references.contains { $0.sourceID == relevant } })
        try await store.linkTopicClaim(questionID: question.id, claimID: linkedClaim.id, expectedReviewVersion: linkedClaim.reviewVersion)
        focus = try await store.reflectionForQuestion(questionID: question.id, start: week.start, end: week.end, timeZoneID: zone)
        focus.period = .week
        let session = try await store.beginConversationForReflection(focus)
        let turn = try await store.recordUserExpression("请比较我的判断与尝试，找出需要继续验证的地方。")
        _ = try await store.setSourceLocalOnly(sourceID: turn, expectedVersion: 1, localOnly: false)
        _ = try await store.appendConversationUserSource(conversationID: session, sourceID: turn, expectedVersion: 1)
        do { _ = try await store.prepareConversationInput(id: session, expectedVersion: 2, destination: .cloud); XCTFail("标题和笔记的本地许可不能绕过") } catch {}
        // Grant each actual source; merely creating or opening a question never grants cloud access.
        for id in focus.sourceIDs {
            if let source = try await store.sources().first(where: { $0.id == id }), source.localOnly {
                _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: source.policyVersion, localOnly: false)
            }
        }
        // Policy changes pause the first session; enter again using the current complete basis.
        focus = try await store.reflectionForQuestion(questionID: question.id, start: week.start, end: week.end, timeZoneID: zone)
        focus.period = .week
        let currentSession = try await store.beginConversationForReflection(focus)
        _ = try await store.appendConversationUserSource(conversationID: currentSession, sourceID: turn, expectedVersion: 1)
        let input = try await store.prepareConversationInput(id: currentSession, expectedVersion: 2, destination: .cloud)
        let context = try await store.validateConversationInput(input)
        let port = try ResponsesDiscussionPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture")
        let request = try port.makeRequest(.init(attemptID: UUID().uuidString, snapshot: .init(input: input, context: context, priorReplies: []), configuration: port.configuration))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("\"reviewPeriod\":\"week\"") == true })
        let reply = try await store.performConversationReply(input, using: FlowDiscussion())
        let retained = try await store.retainDiscussionAICandidate(attemptID: reply, partIndex: 0)
        // Explicit delegation produces a durable AI artifact, while ordinary
        // plans stay tasks. Exercise the actual HTTP port with synthetic replies.
        let delegatedSource = try await expression(store, text: "请帮我调研 Agent 记忆方案，并给出带来源的报告。", model: taskModel)
        let assistantActions = try await store.actions()
        let delegatedAction = try XCTUnwrap(assistantActions.first { $0.title.contains("请帮我调研") })
        let transport = FlowAssistantTransport()
        let assistant = try ResponsesAssistantPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: transport)
        try await store.discoverAutomaticAssistantExecutions(using: assistant)
        let discovered = try await store.assistantExecutions()
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.actionID, delegatedAction.id)
        try await store.discoverAutomaticAssistantExecutions(using: assistant)
        let assessmentCount = await transport.assessments
        XCTAssertEqual(assessmentCount, 3)
        let didDeliver = try await store.processNextAssistantExecution(using: assistant)
        XCTAssertTrue(didDeliver)
        let deliveredExecutions = try await store.assistantExecutions()
        let delivery = try XCTUnwrap(deliveredExecutions.first)
        XCTAssertEqual(delivery.state, "completed")
        XCTAssertEqual(delivery.references.first?.url, "https://example.com/agent-memory")
        XCTAssertTrue(delivery.report?.contains("[合成来源示例](<https://example.com/agent-memory>)") == true)
        let assistantSources = try await store.sources()
        let deliveredSource = try XCTUnwrap(assistantSources.first { $0.id == delivery.resultSourceID })
        XCTAssertEqual(deliveredSource.origin, "ai")
        XCTAssertEqual(deliveredSource.speaker, "assistant")
        let taskAfterDelivery = try await store.actions().first { $0.id == delegatedAction.id }
        XCTAssertEqual(taskAfterDelivery?.state, "open")
        try await store.attachAssistantExecution(id: delivery.id, questionID: question.id)
        let topicWithResult = try await store.reflectionForTopic(questionID: question.id, timeZoneID: zone)
        XCTAssertTrue(topicWithResult.sourceIDs.contains(deliveredSource.id))
        let resultDiscussion = try await store.beginConversationForReflection(topicWithResult)
        _ = try await store.appendConversationUserSource(conversationID: resultDiscussion, sourceID: turn, expectedVersion: 1)
        let resultInput = try await store.prepareConversationInput(id: resultDiscussion, expectedVersion: 2, destination: .cloud)
        let resultContext = try await store.validateConversationInput(resultInput)
        XCTAssertEqual(resultContext.sources.first { $0.sourceID == deliveredSource.id }?.origin, "ai")
        let resultRequest = try port.makeRequest(.init(attemptID: UUID().uuidString, snapshot: .init(input: resultInput, context: resultContext, priorReplies: []), configuration: port.configuration))
        XCTAssertTrue(String(decoding: resultRequest.httpBody!, as: UTF8.self).contains("all_history"))
        let resultReply=try await store.performConversationReply(resultInput,using:FlowDiscussion())
        XCTAssertThrowsError(try ResponsesAssistantPort.parseDelivery(FlowAssistantTransport.delivery(search: false), fallbackTitle: "调研", kind: .research))
        let ordinaryTask = try XCTUnwrap(assistantActions.first { $0.title.contains("下次开发") })
        let privateInstruction = try await store.enqueueAssistantExecution(actionID: ordinaryTask.id, expectedVersion: ordinaryTask.version, instruction: "请调研怎样检验任务边界。")
        _ = try await store.processNextAssistantExecution(using: assistant)
        let privateDelivery = try await store.assistantExecutions().first { $0.id == privateInstruction.id }
        XCTAssertEqual(privateDelivery?.state, "failed")
        let callsBeforeManual = await transport.deliveries
        XCTAssertEqual(callsBeforeManual, 1)
        let manual = try await store.enqueueAssistantExecution(actionID: ordinaryTask.id, expectedVersion: ordinaryTask.version, instruction: "请调研怎样检验任务边界。", questionID: question.id, allowInstructionCloud: true)
        try await store.cancelAssistantExecution(id: manual.id)
        let cancelled = try await store.assistantExecutions().first { $0.id == manual.id }
        XCTAssertEqual(cancelled?.state, "cancelled")
        try await store.retryAssistantExecution(id: manual.id)
        let orderedDelegations = try await store.assistantExecutions(actionID: ordinaryTask.id)
        XCTAssertEqual(orderedDelegations.first?.id, manual.id)
        // Automatic grouping preserves full text and actual attribution, spans
        // weeks, and does not manufacture a personal expression for an AI label.
        let privateSource=try await store.recordUserExpression("只留本地的合成资料，不进入自动归组。")
        let livingTasks=try await store.actions()
        let livingTask=try XCTUnwrap(livingTasks.first { $0.title == "周末整理书架。" })
        _ = try await store.setActionState(actionID:livingTask.id,expectedVersion:livingTask.version,state:.completed)
        let beforeGrouping=try await store.sources().count
        let topicPort=FlowTopics(questionID:question.id,unrelatedID:unrelated,sharedSourceID:relevant)
        let grouped=try await store.organizeTopics(using:topicPort)
        XCTAssertTrue(grouped)
        let preparedGrouping=try await store.prepareTopicOrganization()
        let groupingInput=try XCTUnwrap(preparedGrouping)
        XCTAssertFalse(groupingInput.context.sources.contains { $0.sourceID == privateSource })
        XCTAssertTrue(groupingInput.context.sources.contains { $0.sourceID == deliveredSource.id && $0.origin == "ai" && $0.text == deliveredSource.transcript })
        XCTAssertTrue(groupingInput.discussionReplies.contains { $0.id == resultReply })
        let groupedSources=try await store.sources().count
        XCTAssertEqual(beforeGrouping,groupedSources)
        let groupedQuestions=try await store.reflectionQuestions()
        let aiTopic=try XCTUnwrap(groupedQuestions.first { $0.title == "生活整理" })
        XCTAssertEqual(aiTopic.isAIOrganized,true)
        XCTAssertNotNil(aiTopic.organization)
        let groupedFocus=try await store.reflectionForTopic(questionID:aiTopic.id,timeZoneID:zone)
        XCTAssertEqual(Set(groupedFocus.sourceIDs),Set([unrelated,relevant]))
        let assigned=Set(aiTopic.organization?.sections?.flatMap(\.actionIDs) ?? [])
        XCTAssertTrue(groupingInput.tasks.contains { $0.state == "completed" },"主题整理必须带入已完成行动")
        XCTAssertFalse(groupingInput.tasks.filter { $0.sourceIDs.contains(relevant) }.contains { assigned.contains($0.id) },"共享材料不能把另一个主题的任务一起带入")
        XCTAssertFalse(aiTopic.organization?.sections?.isEmpty ?? true)
        XCTAssertEqual(groupedFocus.question?.isAIOrganized,true)
        let forcedGrouping=try await store.organizeTopics(using:topicPort,force:true)
        XCTAssertTrue(forcedGrouping)
        _ = try await store.validateConversationInput(resultInput)
        let stableBriefing=try await store.workspaceBriefing()
        XCTAssertNotNil(stableBriefing)
        let repeatGrouping=try await store.organizeTopics(using:topicPort)
        XCTAssertFalse(repeatGrouping)
        let groupingCalls=await topicPort.calls
        XCTAssertEqual(groupingCalls,2)
        let package = root.appendingPathComponent("question-package"), restored = root.appendingPathComponent("question-restored")
        try await store.exportPackage(to: package, includeMedia: true)
        try await VoiceOSStore.restorePackage(from: package, to: restored, inspector: NativeMediaInspector())
        let recovered = try VoiceOSStore(root: restored, inspector: NativeMediaInspector()); try await recovered.recover()
        let savedQuestions = try await recovered.reflectionQuestions(), savedEntries = try await recovered.reflectionQuestionEntries(questionID: question.id)
        XCTAssertEqual(savedQuestions.first { $0.id == question.id }?.title, question.title)
        XCTAssertNil(savedQuestions.first { $0.id == aiTopic.id }?.organization,"迁移后的观点是只读历史，结构卡片需重新连接当前观点后再显示")
        let restoredBriefing=try await recovered.workspaceBriefing()
        XCTAssertNil(restoredBriefing,"迁移后的讨论是只读历史，包含这些回复的简报应等待重新整理")
        let restoredAITopic=try await recovered.reflectionForTopic(questionID:aiTopic.id,timeZoneID:zone)
        XCTAssertEqual(restoredAITopic.question?.title,"生活整理")
        let privatePolicy=try await recovered.sourcePolicy(sourceID:unrelated)
        _ = try await recovered.setSourceLocalOnly(sourceID:unrelated,expectedVersion:privatePolicy.version,localOnly:true)
        let withdrawnBriefing=try await recovered.workspaceBriefing()
        XCTAssertNil(withdrawnBriefing)
        let withdrawnTopics=try await recovered.reflectionQuestions()
        XCTAssertNil(withdrawnTopics.first { $0.id == aiTopic.id }?.organization)
        XCTAssertEqual(savedEntries.count, 4)
        XCTAssertEqual(savedEntries.map(\.kind), [.observation, .change, .experiment, .result])
        XCTAssertTrue(savedEntries.contains { $0.kind == .result && $0.sourceIDs == [experiment.sourceID] })
        let restoredQueue = try await recovered.assistantExecutions().first { $0.id == manual.id }
        XCTAssertEqual(restoredQueue?.state, "queued")
        let restoredOrder = try await recovered.assistantExecutions(actionID: ordinaryTask.id)
        XCTAssertEqual(restoredOrder.first?.id, manual.id)
        let resumed = try await recovered.processNextAssistantExecution(using: assistant)
        XCTAssertTrue(resumed)
        let resumedDelivery = try await recovered.assistantExecutions().first { $0.id == manual.id }
        XCTAssertEqual(resumedDelivery?.state, "completed")
        let restoredDelivery = try await recovered.assistantExecutions().first { $0.id == delivery.id }
        XCTAssertEqual(restoredDelivery?.report, delivery.report)
        XCTAssertEqual(restoredDelivery?.validity, "current")
        // Unknown assessment is visible independently of a delegation. It is
        // retried only by the user, and only a confirmed delegation is queued.
        let failedAssessmentSource = try await expression(recovered, text: "请帮我起草一份访谈提纲。", model: taskModel)
        let recoveryActions = try await recovered.actions()
        let failedAssessmentAction = try XCTUnwrap(recoveryActions.first { action in action.title == "请帮我起草一份访谈提纲。" })
        let reliability = FlowAssistantReliability(assessmentFailures: 1)
        try await recovered.discoverAutomaticAssistantExecutions(using: reliability)
        let issues = try await recovered.assistantAssessmentIssues()
        XCTAssertEqual(issues.map(\.actionID), [failedAssessmentAction.id])
        XCTAssertTrue(issues.first?.error.contains("识别请求中断") == true)
        let unconfirmedExecutions = try await recovered.assistantExecutions(actionID: failedAssessmentAction.id)
        XCTAssertTrue(unconfirmedExecutions.isEmpty)
        try await recovered.discoverAutomaticAssistantExecutions(using: reliability)
        let repeatedExecutions = try await recovered.assistantExecutions(actionID: failedAssessmentAction.id)
        XCTAssertTrue(repeatedExecutions.isEmpty, "未知识别不能自动重发或变成委托")
        try await recovered.retryAssistantAssessment(actionID: failedAssessmentAction.id, expectedVersion: failedAssessmentAction.version, using: reliability)
        let resolvedIssues = try await recovered.assistantAssessmentIssues()
        XCTAssertTrue(resolvedIssues.isEmpty)
        let confirmedQueue = try await recovered.assistantExecutions(actionID: failedAssessmentAction.id)
        XCTAssertEqual(confirmedQueue.first?.state, "queued")
        _ = try await recovered.processNextAssistantExecution(using: reliability)
        let confirmedResults = try await recovered.assistantExecutions(actionID: failedAssessmentAction.id)
        let confirmedDelivery = try XCTUnwrap(confirmedResults.first)
        XCTAssertEqual(confirmedDelivery.state, "completed")
        let completedVersion = try await recovered.setActionState(actionID: failedAssessmentAction.id, expectedVersion: failedAssessmentAction.version, state: .completed)
        let reportAfterCompletion = try await recovered.assistantExecutions(actionID: failedAssessmentAction.id).first
        XCTAssertEqual(reportAfterCompletion?.validity, "current", "完成事实不会使正确交付失效")
        let completedReportID = try XCTUnwrap(confirmedDelivery.resultSourceID)
        let completedReportContext = try await recovered.prepareLocalTranscriptContext(sourceIDs: [completedReportID], scalarBudget: 4000)
        XCTAssertEqual(completedReportContext.sources.first?.origin, "ai")
        do {
            _ = try await recovered.enqueueAssistantExecution(actionID: failedAssessmentAction.id, expectedVersion: completedVersion)
            XCTFail("已完成任务不能被新增代办")
        } catch {}
        let sourcesAfterCompletion = try await recovered.sources()
        XCTAssertTrue(sourcesAfterCompletion.contains { $0.id == failedAssessmentSource })
        // A cancelled network request releases the worker immediately; it does
        // not occupy the queue until its original 30-second deadline.
        _ = try await expression(recovered, text: "请帮我起草第一份方案。", model: taskModel)
        _ = try await expression(recovered, text: "请帮我起草第二份方案。", model: taskModel)
        let cancellationActions = try await recovered.actions()
        let firstAction = try XCTUnwrap(cancellationActions.first { $0.title == "请帮我起草第一份方案。" })
        let secondAction = try XCTUnwrap(cancellationActions.first { $0.title == "请帮我起草第二份方案。" })
        let firstExecution = try await recovered.enqueueAssistantExecution(actionID: firstAction.id, expectedVersion: firstAction.version)
        let secondExecution = try await recovered.enqueueAssistantExecution(actionID: secondAction.id, expectedVersion: secondAction.version)
        let cancellable = FlowAssistantReliability(blockedActionID: firstAction.id)
        let firstWorker = Task { try await recovered.processNextAssistantExecution(using: cancellable) }
        await cancellable.waitForBlockedRequest()
        let cancelledAt = Date()
        try await recovered.cancelAssistantExecution(id: firstExecution.id)
        _ = try await firstWorker.value
        let cancellationObserved = await cancellable.cancellationObserved
        XCTAssertTrue(cancellationObserved)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
        let nextDelivered = try await recovered.processNextAssistantExecution(using: cancellable)
        XCTAssertTrue(nextDelivered)
        let cancellationResults = try await recovered.assistantExecutions()
        XCTAssertEqual(cancellationResults.first { $0.id == firstExecution.id }?.state, "cancelled")
        XCTAssertEqual(cancellationResults.first { $0.id == secondExecution.id }?.state, "completed")
        // Knowledge review keeps the complete personal source, verifies public
        // facts independently, and resumes only unchecked candidates after failure.
        let knowledgeText = "私人代号只留在原文。" + String(repeating: "这段是个人背景，不作为公开检索词。", count: 100) + "SQLite quick_check 会完整检查所有索引与表记录的一致性。SQLite integrity_check 不能证明业务逻辑没有错误。这个术语的转写还没听准。我喜欢简洁界面；作者说数据库足够可靠，但我未表态。"
        let knowledgeSource = try await expression(recovered, text: knowledgeText, model: FlowModel())
        let knowledgeTransport = FlowKnowledgeTransport(expectedText: knowledgeText)
        let knowledgePort = try ResponsesKnowledgeReviewPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: knowledgeTransport)
        let failedKnowledge = try await recovered.processKnowledgeReview(sourceID: knowledgeSource, using: knowledgePort)
        XCTAssertEqual(failedKnowledge.state, "failed")
        XCTAssertEqual(failedKnowledge.issues.map(\.id), ["incorrect"])
        let completedKnowledge = try await recovered.processKnowledgeReview(sourceID: knowledgeSource, using: knowledgePort, retry: true)
        XCTAssertEqual(completedKnowledge.state, "completed")
        XCTAssertEqual(completedKnowledge.issues.map(\.kind), [.factualError, .transcriptionUncertain])
        XCTAssertEqual(completedKnowledge.issues.first?.references.first?.url, "https://www.sqlite.org/pragma.html")
        XCTAssertFalse(completedKnowledge.issues.contains { $0.quote.contains("作者说") || $0.quote.contains("我喜欢") })
        let identifyCalls = await knowledgeTransport.identifications, researchCalls = await knowledgeTransport.researches, reviewCalls = await knowledgeTransport.reviews
        XCTAssertEqual(identifyCalls, 1)
        XCTAssertEqual(researchCalls, 3)
        XCTAssertEqual(reviewCalls, 2)
        let reusedKnowledge = try await recovered.processKnowledgeReview(sourceID: knowledgeSource, using: knowledgePort)
        XCTAssertEqual(reusedKnowledge.id, completedKnowledge.id)
        let knowledgePackage = root.appendingPathComponent("knowledge-package"), knowledgeRestore = root.appendingPathComponent("knowledge-restored")
        try await recovered.exportPackage(to: knowledgePackage, includeMedia: true)
        try await VoiceOSStore.restorePackage(from: knowledgePackage, to: knowledgeRestore, inspector: NativeMediaInspector())
        let knowledgeReopened = try VoiceOSStore(root: knowledgeRestore, inspector: NativeMediaInspector())
        try await knowledgeReopened.recover()
        let portableKnowledge = try await knowledgeReopened.knowledgeReviews(sourceID: knowledgeSource)
        XCTAssertEqual(portableKnowledge.first?.issues.map(\.quote), completedKnowledge.issues.map(\.quote))
        XCTAssertEqual(portableKnowledge.first?.responseIDs, completedKnowledge.responseIDs)
        let knowledgeClaims = try await knowledgeReopened.latestCandidateClaims(for: knowledgeSource)
        let knowledgeClaim = try XCTUnwrap(knowledgeClaims.first)
        _ = try await knowledgeReopened.reviewClaim(claimID: knowledgeClaim.id, expectedVersion: knowledgeClaim.reviewVersion, action: .endorse)
        let claimFrozenKnowledge = try await knowledgeReopened.knowledgeReviews(sourceID: knowledgeSource)
        XCTAssertEqual(claimFrozenKnowledge.first?.validity, "frozen")
        let knowledgePolicy = try await recovered.sourcePolicy(sourceID: knowledgeSource)
        _ = try await recovered.setSourceLocalOnly(sourceID: knowledgeSource, expectedVersion: knowledgePolicy.version, localOnly: true)
        let permissionFrozenKnowledge = try await recovered.knowledgeReviews(sourceID: knowledgeSource)
        XCTAssertEqual(permissionFrozenKnowledge.first?.validity, "frozen")
        let fullOriginalAfterReview = try await recovered.sources().first { $0.id == knowledgeSource }?.transcript
        XCTAssertEqual(fullOriginalAfterReview, knowledgeText)
        if let path = ProcessInfo.processInfo.environment["VOICEOS_ASSISTANT_DEMO_EXPORT"] {
            try await store.exportPackage(to: URL(fileURLWithPath: path), includeMedia: true)
        }
        let delegatedHistory = try await recovered.transcriptHistory(sourceID: delegatedSource)
        let delegatedVersion = delegatedHistory.last!.id
        _ = try await recovered.correctTranscript(sourceID: delegatedSource, expectedVersionID: delegatedVersion, text: "先不调研，稍后再决定。")
        do { _ = try await recovered.validateConversationInput(resultInput); XCTFail("更正委托后，旧 AI 交付不能继续进入讨论") } catch {}
        let recoveredDatabase = await recovered.db
        try recoveredDatabase.execute("UPDATE transcript_versions SET text='',spans_json='[]',reason='ai_superseded',actor='system' WHERE id=?", [delegatedVersion])
        try recoveredDatabase.execute("UPDATE transcripts SET text='' WHERE source_id=?", [delegatedSource])
        do { try VoiceOSStore.validateStoredAssistantExecutions(recoveredDatabase); XCTFail("当前委托不能借用已剪除的历史占位") }
        catch { XCTAssertEqual(error.localizedDescription, "助理委托原话与真实版本不一致") }
        let invalidatedDelivery = try await recovered.assistantExecutions().first { $0.id == delivery.id }
        XCTAssertEqual(invalidatedDelivery?.validity, "frozen")
        try VoiceOSStore.validateStoredAssistantExecutions(recoveredDatabase)
        try await recovered.stopReflectionQuestionEntry(id: experiment.id)
        do { _ = try await recovered.beginConversationForReflection(focus); XCTFail("撤回验证记录后不能复用旧回顾") } catch {}
        let afterWithdrawal = try await recovered.reflectionForQuestion(questionID: question.id, start: week.start, end: week.end, timeZoneID: zone)
        XCTAssertFalse(afterWithdrawal.sourceIDs.contains(experiment.sourceID))
        XCTAssertTrue(afterWithdrawal.question?.entries.first(where: { $0.kind == .result })?.unavailableSourceIDs.contains(experiment.sourceID) == true)
        let workspace = try await recovered.workspaceSnapshot()
        for topic in workspace.topics {
            let individual = try await recovered.reflectionQuestionSourceIDs(questionID: topic.id)
            XCTAssertEqual(workspace.topicSources[topic.id], individual)
        }
        XCTAssertFalse(workspace.topicSources[question.id]?.contains(experiment.sourceID) == true)
        for source in workspace.sources {
            let individual = try await recovered.modelAttempts(sourceID: source.id)
            XCTAssertEqual(workspace.attempts[source.id]?.map(\.id) ?? [], individual.map(\.id))
        }
        let candidate = try await recovered.candidateClaims(includeFrozen: true).first { $0.id == retained }
        XCTAssertEqual(candidate?.validity, "frozen")
        let history = try await recovered.transcriptHistory(sourceID: relevant)
        _ = try await recovered.correctTranscript(sourceID: relevant, expectedVersionID: history.last!.id, text: "下次开发先核对边界，观察任务是否更稳定。")
        let changedEntries = try await recovered.reflectionQuestionEntries(questionID: question.id)
        XCTAssertTrue(changedEntries.first(where: { $0.id == observation.id })?.unavailableSourceIDs.contains(relevant) == true)
        if let path = ProcessInfo.processInfo.environment["VOICEOS_QUESTION_DEMO_EXPORT"] {
            try await store.exportPackage(to: URL(fileURLWithPath: path), includeMedia: true)
        }

    }

    func testCorrectionPreservesHistoryAndRefreshesUnderstanding() async throws {
        let store = try await openStore(), model = FlowModel(createsTask: true)
        let sourceID = try await expression(store, text: "我认为容量最重要。", model: model)
        let sources = try await store.sources(), original = try XCTUnwrap(sources.first?.transcriptVersionID)
        let initialActions = try await store.actions()
        let completedAction = try XCTUnwrap(initialActions.first)
        _ = try await store.setActionState(actionID:completedAction.id,expectedVersion:completedAction.version,state:.completed)
        let review = try JSONDecoder().decode(TranscriptionReview.self,from:Data("""
            {"completed":true,"changed":false,"response_id":"synthetic-review-2","response_ids":["synthetic-review-1","synthetic-review-2"],"context_review_version":2,"corrections":[],"unresolved_issues":[],"scope":"complete_expression_knowledge_and_intent","full_text_independent_passes":2}
            """.utf8))
        try await store.saveTranscriptionReview(review,sourceID:sourceID)
        let paused = try await store.actions(includeHistory:true)
        XCTAssertEqual(paused.first?.validity,"frozen")
        XCTAssertEqual(paused.first?.state,"completed","提取暂停不能撤销实际完成记录")
        let explanation = try await store.understandingPauseExplanation(sourceID:sourceID)
        XCTAssertTrue(explanation.contains("转写文字没有变化"))
        let refreshed = try await store.continueSourceUnderstanding(sourceID:sourceID,using:model)
        XCTAssertFalse(refreshed.reused,"补上转写核对后应允许按新依据识别，而不是卡在旧回执")
        let repeated = try await store.continueSourceUnderstanding(sourceID:sourceID,using:model)
        XCTAssertTrue(repeated.reused)
        let calls = await model.calls
        XCTAssertEqual(calls,2,"重复点击复用本次识别，不重复创建任务")
        let retained = try await store.actions(includeHistory:true)
        XCTAssertEqual(retained.first(where: { $0.id == completedAction.id })?.state,"completed")
        XCTAssertEqual(retained.filter { $0.validity == "current" }.count,1)
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
        let claim = try XCTUnwrap(current.first)
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: claim.reviewVersion, action: .correct,
                                        statement: "检索质量是待研究因素，并非已验证的结论。", note: "修正过强的结论")
        let correctedClaims = try await store.latestCandidateClaims(for: sourceID)
        let affected = try await store.actions(includeHistory: true)
        XCTAssertEqual(correctedClaims.first?.reviewState, "pending")
        XCTAssertEqual(correctedClaims.first?.statement, "检索质量是待研究因素，并非已验证的结论。")
        XCTAssertTrue(affected.allSatisfy { $0.validity == "frozen" })
        let workspace = try await store.workspaceSnapshot()
        XCTAssertEqual(workspace.sources.first?.transcriptVersionID, version)
        XCTAssertEqual(workspace.currentClaimsBySource[sourceID]?.map(\.id), correctedClaims.map(\.id))
        XCTAssertTrue(workspace.actions.allSatisfy { $0.validity == "frozen" })
        let source = try XCTUnwrap(workspace.sources.first)
        try Data("合成原件已损坏".utf8).write(to: root.appendingPathComponent(source.relativePath))
        let unavailable = try await store.latestCandidateClaims(for: sourceID)
        XCTAssertTrue(unavailable.isEmpty, "定向读取仍须核对原件，不能因优化而复用已损坏的依据")
        let invalidated = try await store.workspaceSnapshot()
        XCTAssertEqual(invalidated.sources.first?.state, "quarantined")
        XCTAssertTrue(invalidated.claims.allSatisfy { $0.validity == "frozen" })
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
        let model = FlowModel(createsTask: true)
        let sourceID: String
        let article = String(repeating: "外部作者认为检索需要评估，作者计划明天做实验。", count: 350) + "末尾观点也必须完整保留。"
        let personal = String(repeating: "我还需要比较任务边界与实际结果。", count: 400) + "保留我的最后一句。"
        let externalID: String, personalID: String
        do {
            let store = try await openStore()
            sourceID = try await expression(store, text: "记忆系统要保留来源。", model: model)
            externalID = try await store.recordCapturedText(article, title: "外部作者全文", ownership: .external, commandID: "captured-external")
            personalID = try await store.recordCapturedText(personal, title: "我的长表达", ownership: .personal)
        }
        let reopened = try await openStore()
        let result = try await reopened.continueSourceUnderstanding(sourceID: sourceID, using: model)
        let claims = try await reopened.candidateClaims(), calls = await model.calls
        XCTAssertTrue(result.reused)
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(calls, 1)
        let captured = try await reopened.sources()
        XCTAssertEqual(captured.first { $0.id == externalID }?.transcript, article)
        XCTAssertEqual(captured.first { $0.id == externalID }?.localOnly, true)
        XCTAssertEqual(captured.first { $0.id == personalID }?.transcript, personal)
        let externalModel = FlowModel()
        _ = try await reopened.continueSourceUnderstanding(sourceID: externalID, using: externalModel)
        let externalClaims = try await reopened.latestCandidateClaims(for: externalID)
        XCTAssertEqual(externalClaims.first?.ownership, "external")
        let sourceActions = try await reopened.actions()
        XCTAssertEqual(sourceActions.count, 1)
        // Continue a real-sized discussion across a long article and a long personal expression.
        for id in [externalID, personalID] { _ = try await reopened.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false) }
        let discussion = try await reopened.beginConversation(sourceIDs: [externalID, personalID])
        let longQuestion = String(repeating: "请对照完整材料中的条件、推断和真实行动。", count: 300) + "追问末尾也要保留。"
        for index in 0..<41 {
            let turn = try await reopened.recordUserExpression(index == 40 ? longQuestion : "第\(index + 1)次合成追问：继续核对证据。")
            _ = try await reopened.setSourceLocalOnly(sourceID: turn, expectedVersion: 1, localOnly: false)
            _ = try await reopened.appendConversationUserSource(conversationID: discussion, sourceID: turn, expectedVersion: index + 1)
        }
        let discussionInput = try await reopened.prepareConversationInput(id: discussion, expectedVersion: 42, destination: .cloud)
        let fullContext = try await reopened.validateConversationInput(discussionInput)
        XCTAssertEqual(fullContext.sources.first { $0.sourceID == externalID }?.text, article)
        XCTAssertEqual(fullContext.sources.first { $0.sourceID == personalID }?.text, personal)
        XCTAssertEqual(fullContext.sources.last?.text, longQuestion)
        XCTAssertGreaterThan(fullContext.scalarBudget, 12000)
        let discussionPort = try ResponsesDiscussionPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture")
        let request = try discussionPort.makeRequest(.init(attemptID: UUID().uuidString, snapshot: .init(input: discussionInput, context: fullContext, priorReplies: []), configuration: discussionPort.configuration))
        XCTAssertEqual(request.timeoutInterval, 600)
        XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("追问末尾也要保留。"))
        let longReply = String(repeating: "这只是合成验证回复，仍需区分依据、假设与实际效果。", count: 250)
        _ = try await reopened.performConversationReply(discussionInput, using: FlowDiscussion(responseText: longReply))
        try await reopened.endConversation(id: discussion, expectedVersion: 42)
        let outcome = try await reopened.prepareReusableConversationOutcome(id: discussion, expectedVersion: 43, destination: .cloud)
        XCTAssertEqual(outcome.replies.first?.parts.first?.text, longReply)
        XCTAssertGreaterThan(outcome.context.scalarBudget, fullContext.scalarBudget)
        let outcomePort = try ResponsesOutcomePort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture")
        let outcomeRequest = try outcomePort.makeRequest(.init(attemptID: UUID().uuidString, snapshot: outcome, configuration: outcomePort.configuration))
        XCTAssertTrue(String(decoding: outcomeRequest.httpBody!, as: UTF8.self).contains("追问末尾也要保留。"))
        let package = root.deletingLastPathComponent().appendingPathComponent("captured-text-package-" + UUID().uuidString)
        let restoredRoot = root.deletingLastPathComponent().appendingPathComponent("captured-text-restored-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: package); try? FileManager.default.removeItem(at: restoredRoot) }
        try await reopened.exportPackage(to: package, includeMedia: true)
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: NativeMediaInspector())
        try await restored.recover()
        let recovered = try await restored.sources()
        XCTAssertEqual(recovered.first { $0.id == externalID }?.transcript, article)
        XCTAssertEqual(recovered.first { $0.id == personalID }?.transcript, personal)
        let restoredReplies = try await restored.discussionAttempts(conversationID: discussion)
        XCTAssertEqual(restoredReplies.first?.parts.first?.text, longReply)
        try await reopened.setMaterialDisposition(sourceIDs:[personalID],disposition:.archived)
        let archived = try await reopened.sources().first { $0.id == personalID }
        XCTAssertEqual(archived?.isArchived,true)
        XCTAssertEqual(archived?.transcript,personal)
        let managedSourceID = try await expression(reopened,text:"我会核对归档资料的原件。",model:FlowModel(createsTask:true))
        let managedClaims = try await reopened.latestCandidateClaims(for:managedSourceID)
        let managedTasks = try await reopened.actions(includeHistory:true)
        let managedTask = try XCTUnwrap(managedTasks.first { $0.claimID == managedClaims.first?.id })
        _ = try await reopened.setActionState(actionID:managedTask.id,expectedVersion:managedTask.version,state:.completed)
        try await reopened.setMaterialDisposition(sourceIDs:[managedSourceID],disposition:.trashed)
        let retainedTask = try await reopened.actions(includeHistory:true).first { $0.id == managedTask.id }
        XCTAssertEqual(retainedTask?.state,"completed")
        XCTAssertEqual(retainedTask?.validity,"frozen")
        try await reopened.setMaterialDisposition(sourceIDs:[managedSourceID],disposition:.active)
        try await reopened.setMaterialDisposition(sourceIDs:[externalID],disposition:.trashed)
        let trashed = try await reopened.sources().first { $0.id == externalID }
        XCTAssertEqual(trashed?.isTrashed,true)
        XCTAssertEqual(trashed?.localOnly,true)
        do {
            _ = try await reopened.prepareLocalTranscriptContext(sourceIDs:[externalID])
            XCTFail("回收站材料不能进入当前理解")
        } catch {}
        let trashPackage = root.deletingLastPathComponent().appendingPathComponent("trash-package-"+UUID().uuidString)
        let trashRoot = root.deletingLastPathComponent().appendingPathComponent("trash-restored-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:trashPackage); try? FileManager.default.removeItem(at:trashRoot) }
        try await reopened.exportPackage(to:trashPackage,includeMedia:true)
        try await VoiceOSStore.restorePackage(from:trashPackage,to:trashRoot,inspector:NativeMediaInspector())
        let trashStore = try VoiceOSStore(root:trashRoot,inspector:NativeMediaInspector())
        try await trashStore.recover()
        let trashSources = try await trashStore.sources()
        XCTAssertEqual(trashSources.first { $0.id == externalID }?.isTrashed,true)
        XCTAssertEqual(trashSources.first { $0.id == personalID }?.isArchived,true)
        try await trashStore.setMaterialDisposition(sourceIDs:[externalID],disposition:.active)
        let recoveredArticle = try await trashStore.sources().first { $0.id == externalID }
        XCTAssertEqual(recoveredArticle?.transcript,article)
        XCTAssertEqual(recoveredArticle?.localOnly,true)
        XCTAssertEqual(recoveredArticle?.isTrashed,false)
        let trashIntegrity = try await trashStore.integrityCheck()
        XCTAssertTrue(trashIntegrity)
        // Warm validation must still detect equal-size edits even when mtime is restored.
        let original = try await reopened.playableURL(sourceID: sourceID)
        let modified = try XCTUnwrap(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let writer = try FileHandle(forWritingTo: original)
        try writer.write(contentsOf: Data([0x41])); try writer.synchronize(); try writer.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: original.path)
        let frozenClaims = try await reopened.candidateClaims(includeFrozen: true)
        let frozenActions = try await reopened.actions(includeHistory: true)
        XCTAssertEqual(frozenClaims.first { $0.references.contains { $0.sourceID == sourceID } }?.validity, "frozen")
        XCTAssertEqual(frozenActions.first?.validity, "frozen")
        let damagedSources = try await reopened.sources()
        XCTAssertEqual(damagedSources.first { $0.id == sourceID }?.state, "quarantined")
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
        // The new unrelated expression changed the future context, but did not
        // cancel the in-flight result. Re-enqueueing a completed exact input reuses it.
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
        let linkedStep = try XCTUnwrap(linked.result?.goalPlans.first?.nextStep)
        XCTAssertEqual(linkedStep.existingTaskID, taskID)
        let linkedTaskID = try await store.activateGoalStep(receiptID: linked.id, goalID: goalID, step: linkedStep)
        XCTAssertEqual(linkedTaskID, taskID)
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
        let taskDiscussion = try await store.beginConversationForAction(actionID: taskID)
        let question = try await expression(store, text: "结合这次讲解结果，下一次应该怎么练习？", model: model)
        _ = try await store.appendConversationUserSource(conversationID: taskDiscussion, sourceID: question, expectedVersion: 1)
        let taskDiscussionInput = try await store.prepareConversationInput(id: taskDiscussion, expectedVersion: 2, destination: .cloud)
        let taskContext = try await store.validateConversationInput(taskDiscussionInput)
        XCTAssertEqual(taskContext.conversationFocus?.selectedActionID, taskID)
        XCTAssertEqual(Set(taskContext.conversationFocus?.tasks.map(\.actionID) ?? []), [taskID, goalID])
        XCTAssertTrue(taskContext.sources.contains { $0.sourceID == feedbackSource })
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
        let crossInput = try await isolated.prepareRecordingFollowup(sourceID: practiceC)
        let crossStep = GoalStep(title: separatePlans[1].nextStep.title, condition: "同一条件下继续", existingTaskID: secondGoalTask)
        let crossPlan = GoalPlan(goalID: separatePlans[0].goalID, summary: "跨目标步骤必须被拒绝", adjustment: "核对任务归属", phases: [.init(title: "归属核对", steps: [crossStep])], nextStep: crossStep)
        let crossResult = RecordingFollowupResult(thoughtUpdates: [], goalPlans: [crossPlan], english: .init(isPractice: false, evidenceQuote: "", suggestions: [], comparisons: [], nextExercise: ""))
        let crossTask = try XCTUnwrap(crossInput.tasks.first { $0.id == secondGoalTask })
        XCTAssertEqual(crossTask.goalID, separatePlans[1].goalID)
        XCTAssertNotEqual(crossTask.goalID, crossPlan.goalID)
        do { try VoiceOSStore.validateFollowupResult(crossResult, input: crossInput); XCTFail("跨目标任务不能成为下一步") }
        catch { XCTAssertEqual(error.localizedDescription, "下一步应沿用同一目标的未完成任务") }
        try await store.corruptFlowFollowupPath()
        do { _ = try await store.recordingFollowups(); XCTFail("Malformed stored follow-up must fail") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("跟进回执解码失败"))
            XCTAssertTrue(error.localizedDescription.contains("[0].input.current.sources[0].text"))
        }
    }

    func testRecordingTrackRolesRejectProgramAudioAsOwnVoice() {
        let three = RecordingMediaInfo(duration: 60, tracks: [
            .init(id: 0, title: "混音"), .init(id: 1, title: "我的声音"), .init(id: 2, title: "系统内录")
        ])
        XCTAssertEqual(FullRecordingOrganizer.decide(track: 0, ownVoice: true, in: three).fixedRole, .mix)
        XCTAssertEqual(FullRecordingOrganizer.decide(track: 1, ownVoice: true, in: three).fixedRole, .personal)
        XCTAssertEqual(FullRecordingOrganizer.decide(track: 2, ownVoice: true, in: three).fixedRole, .context)
        XCTAssertTrue(FullRecordingOrganizer.decide(track: 1, ownVoice: true, in: three).importsAsPersonal)
        XCTAssertFalse(FullRecordingOrganizer.decide(track: 2, ownVoice: true, in: three).allowsOwnVoice)
        XCTAssertFalse(FullRecordingOrganizer.decide(track: 2, ownVoice: true, in: three).importsAsPersonal)

        let two = RecordingMediaInfo(duration: 60, tracks: [.init(id: 0, title: "音轨 0"), .init(id: 1, title: "音轨 1")])
        XCTAssertNil(FullRecordingOrganizer.decide(track: 0, ownVoice: true, in: two).fixedRole)
        XCTAssertNil(FullRecordingOrganizer.decide(track: 1, ownVoice: true, in: two).fixedRole)
        XCTAssertTrue(FullRecordingOrganizer.decide(track: 0, ownVoice: true, in: two).allowsOwnVoice)
        XCTAssertTrue(FullRecordingOrganizer.decide(track: 0, ownVoice: true, in: two).importsAsPersonal)
        XCTAssertTrue(FullRecordingOrganizer.decide(track: 1, ownVoice: true, in: two).importsAsPersonal)
        XCTAssertFalse(FullRecordingOrganizer.decide(track: 1, ownVoice: false, in: two).importsAsPersonal)

        let single = RecordingMediaInfo(duration: 60, tracks: [.init(id: 0, title: "音轨 0")])
        XCTAssertNil(FullRecordingOrganizer.decide(track: 0, ownVoice: false, in: single).fixedRole)
        XCTAssertFalse(FullRecordingOrganizer.decide(track: 0, ownVoice: false, in: single).importsAsPersonal)
        XCTAssertTrue(FullRecordingOrganizer.decide(track: 0, ownVoice: true, in: single).importsAsPersonal)

        let unknown = FullRecordingOrganizer.decide(track: 9, ownVoice: true, in: single)
        XCTAssertNil(unknown.fixedRole)
        XCTAssertFalse(unknown.allowsOwnVoice)
        XCTAssertFalse(unknown.importsAsPersonal)
    }
}
