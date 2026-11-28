import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor TaskInitiationFakePort: TaskInitiationModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "initiation", promptVersion: "task-initiation-v2",
                                           schemaVersion: "task-initiation-v2", destination: .cloud)
    private let proposal: TaskInitiationProposal?
    private let failure: VoiceOSError?
    private let reply: String
    private(set) var received: [TaskInitiationInput] = []
    private(set) var answered: [TaskInitiationInput] = []
    init(proposal: TaskInitiationProposal) { self.proposal = proposal; failure = nil; reply = "" }
    init(error: VoiceOSError) { proposal = nil; failure = error; reply = "" }
    init(answer: String) { proposal = nil; failure = nil; reply = answer }
    func initiate(_ input: TaskInitiationInput) async throws -> TaskInitiationProposal {
        received.append(input)
        if let failure { throw failure }
        return proposal!
    }
    func answer(_ input: TaskInitiationInput) async throws -> String {
        answered.append(input)
        if let failure { throw failure }
        guard !reply.isEmpty else { throw VoiceOSError("fixture 没有回答") }
        return reply
    }
}

/// Replays a scripted structured or plain text reply and records what the
/// real Responses port built, including whether it requested JSON output.
private actor TaskInitiationWireTransport: ModelHTTPTransport {
    private let reply: String
    private(set) var instructions: [String] = []
    private(set) var inputs: [String] = []
    private(set) var hasResponseFormat: [Bool] = []
    init(reply: String) { self.reply = reply }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        let payload = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        instructions.append(payload?["instructions"] as? String ?? "")
        inputs.append((payload?["input"] as? [[String: Any]])?.first?["content"] as? String ?? "")
        hasResponseFormat.append(payload?["text"] != nil)
        let envelope: [String: Any] = ["status": "completed", "output": [
            ["type": "message", "role": "assistant", "status": "completed",
             "content": [["type": "output_text", "text": reply]]]]]
        return .init(status: 200, body: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]))
    }
}

private enum TaskInitiationFixtures {
    static func handoff(preference: TaskInitiationPreference = .quickDelivery,
                        acceptance: [String] = ["内容与主题相关", "结构清晰"]) -> TaskInitiationProposal {
        .init(isTaskInitiation: true, route: .agentHandoff, title: "制作课程演示 PPT",
              objective: "制作能用于课程汇报的 PPT",
              knownFacts: ["老师要求制作一份课程 PPT"],
              assumptions: ["受众和时长尚未确定"],
              missingInformation: ["听众、时长和提供的材料"],
              constraints: [], acceptanceCriteria: acceptance, preference: preference, targetExecutor: "Codex",
              deliverables: ["可播放的 PPT 文件"], reason: "用户希望交给执行 Agent")
    }
    static func guided() -> TaskInitiationProposal {
        .init(isTaskInitiation: true, route: .guidedStart, title: "学会 Git Hook",
              objective: "在自己的项目里配置一个提交前检查",
              knownFacts: ["用户想自己动手学习 Git Hook"], assumptions: ["尚未指定 Git 版本"],
              missingInformation: ["操作系统与 Git 版本"], acceptanceCriteria: ["钩子能拦截不合格提交"],
              guidePrerequisites: ["已安装 Git", "有一个可练习的仓库"],
              guideSteps: ["在仓库根目录运行 git status 确认状态",
                           "创建 .git/hooks/pre-commit 并写入检查命令",
                           "执行 git commit 触发钩子"],
              firstAction: "打开终端并运行 git status",
              verification: "提交时钩子执行并输出了检查结果", reason: "用户想自己动手")
    }
    static func clarify(question: String = "这项工作最需要先确定的是听众还是时长？") -> TaskInitiationProposal {
        .init(isTaskInitiation: true, route: .clarify, title: "先理清 PPT 任务",
              clarifyQuestion: question, reason: "目标仍不明确")
    }
    static func capture() -> TaskInitiationProposal {
        .init(isTaskInitiation: false, route: .agentHandoff, title: "只想吐槽",
              reason: "用户明确只想记录，不要安排任务")
    }
    static func answer(_ body: String = "Git Hook 是 Git 在提交等动作前后自动运行的脚本。\n\n常见用途是提交前检查。") -> TaskInitiationProposal {
        .init(isTaskInitiation: false, route: .answer, title: "Git Hook 是什么",
              reason: "用户在提问，可以直接回答", answer: body)
    }
}

final class TaskInitiationChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-initiation-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeStore(at root: URL) async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func openStore() async throws -> VoiceOSStore { try await makeStore(at: root) }
    private func personalSource(_ store: VoiceOSStore, text: String, localOnly: Bool = false) async throws -> String {
        let id = try await store.recordUserExpression(text)
        if !localOnly { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false) }
        return id
    }
    private func input(_ store: VoiceOSStore, source: String, mode: TaskInitiationMode = .direct,
                       preferredRoute: TaskInitiationRoute? = nil, answer: String = "") async throws -> TaskInitiationInput {
        try await store.taskInitiationInput(sourceID: source, mode: mode, preferredRoute: preferredRoute, answer: answer)
    }
    private func expectFailure(_ block: () async throws -> Void, _ message: String) async {
        do { try await block(); XCTFail(message) } catch {}
    }
    private func step(_ store: VoiceOSStore, record: String, title: String, command: String) async throws -> String {
        try await store.recordCapturedText("这一步：" + title, title: title, ownership: .personal,
                                           commandID: "initiation-step:" + record + ":" + command)
    }

    func testHandoffPackageSeparatesFactsAndAlwaysChecksEnvironment() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "老师让我做一份课程PPT，我不会，也不知道怎么开始。")
        let input = try await input(store, source: source)
        let port = TaskInitiationFakePort(proposal: TaskInitiationFixtures.handoff(preference: .learnWhileDoing))
        let proposal = try await port.initiate(input)
        let received = await port.received
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.text, input.text)

        let row = try await store.recordTaskInitiation(input, proposal: proposal, commandID: "fixture-handoff")
        let duplicate = try await store.recordTaskInitiation(input, proposal: proposal, commandID: "fixture-handoff")
        XCTAssertEqual(row.id, duplicate.id)
        XCTAssertEqual(row.state, "draft")
        XCTAssertEqual(row.route, .agentHandoff)
        let allRows = try await store.taskInitiations()
        XCTAssertEqual(allRows.count, 1)

        let artifact = row.artifact
        for heading in ["# 任务目标", "# 已知背景", "# 约束与偏好", "# 请先做的事", "# 执行要求",
                        "# 预期交付物", "# 验收标准", "# 遇到阻碍时"] {
            XCTAssertTrue(artifact.contains(heading), "缺少交接包段落：\(heading)")
        }
        XCTAssertTrue(artifact.contains("- 假设（请先核实）：受众和时长尚未确定"))
        XCTAssertTrue(artifact.contains("- 待确认：听众、时长和提供的材料"))
        XCTAssertFalse(artifact.contains("听众、时长和提供的材料\n- 假设（请先核实）"))
        XCTAssertTrue(artifact.contains("先检查真实环境（仓库、文件、工具与已有资料），不要假设已经读过它们"))
        XCTAssertTrue(artifact.contains("边做边学：交付时解释关键实现、入口与验证方法"))

        let actions = try await store.actions(includeHistory: true)
        let claims = try await store.candidateClaims(includeFrozen: true)
        let executions = try await store.assistantExecutions()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(claims.isEmpty)
        XCTAssertTrue(executions.isEmpty)
    }

    func testGuidedStartRendersActionableTutorial() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "我想自己学 Git Hook，不用让 Agent 代写。")
        let input = try await input(store, source: source)
        let row = try await store.recordTaskInitiation(input, proposal: TaskInitiationFixtures.guided())
        XCTAssertEqual(row.state, "draft")
        XCTAssertEqual(row.route, .guidedStart)
        XCTAssertEqual(row.proposal.guideSteps.count, 3)
        XCTAssertTrue(row.artifact.contains("# 开始前需要的条件"))
        XCTAssertTrue(row.artifact.contains("# 操作步骤"))
        XCTAssertTrue(row.artifact.contains("1. 在仓库根目录运行 git status 确认状态"))
        XCTAssertTrue(row.artifact.contains("# 第一步\n打开终端并运行 git status"))
        XCTAssertTrue(row.artifact.contains("# 验证是否做到\n提交时钩子执行并输出了检查结果"))
    }

    func testExplicitCaptureOnlyNeverBecomesTask() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "今天实习任务真烦，我只想吐槽一下。")
        let row = try await store.recordTaskInitiation(try await input(store, source: source),
                                                       proposal: TaskInitiationFixtures.capture())
        XCTAssertEqual(row.route, .captureOnly)
        XCTAssertEqual(row.state, "draft")
        XCTAssertEqual(row.artifact, "")
        let actions = try await store.actions(includeHistory: true)
        let claims = try await store.candidateClaims(includeFrozen: true)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(claims.isEmpty)
    }

    func testAnswerRouteRecordsBodyWithoutTaskSideEffects() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "Git Hook 是什么？能一句话解释吗？")
        let sourcesBefore = try await store.sources().count
        let row = try await store.recordTaskInitiation(try await input(store, source: source),
                                                       proposal: TaskInitiationFixtures.answer())
        XCTAssertEqual(row.route, .answer)
        XCTAssertEqual(row.state, "draft")
        XCTAssertEqual(row.artifact, TaskInitiationFixtures.answer().answer)
        XCTAssertNil(row.input.preferredRoute)
        let sourcesAfter = try await store.sources().count
        XCTAssertEqual(sourcesAfter, sourcesBefore)
        let actions = try await store.actions(includeHistory: true)
        let claims = try await store.candidateClaims(includeFrozen: true)
        let executions = try await store.assistantExecutions()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(claims.isEmpty)
        XCTAssertTrue(executions.isEmpty)

        let copied = try await store.markTaskInitiationCopied(id: row.id, artifact: row.artifact)
        XCTAssertNotNil(copied.copiedAt)
        let saved = try await store.confirmTaskInitiation(id: row.id, artifact: copied.artifact)
        XCTAssertEqual(saved.state, "confirmed")
        XCTAssertTrue(saved.isArchived)
        XCTAssertEqual(saved.artifact, TaskInitiationFixtures.answer().answer)
        let live = try await store.taskInitiations()
        XCTAssertTrue(live.isEmpty)
        let archived = try await store.taskInitiations(includeArchived: true)
        XCTAssertEqual(archived.map(\.id), [row.id])
        let actionsAfter = try await store.actions(includeHistory: true)
        XCTAssertTrue(actionsAfter.isEmpty)
    }

    func testAnswerWithoutBodyFailsAndPageFallsBackToClarify() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "这个问题能直接回答吗？")
        let input = try await input(store, source: source)
        let empty = TaskInitiationProposal(isTaskInitiation: false, route: .answer, reason: "用户在提问")
        XCTAssertTrue(TaskInitiationComposer.needsClarifyFallback(empty))
        XCTAssertTrue(TaskInitiationComposer.clarifyFallbackMessage.contains("更具体"))
        do {
            _ = try await store.recordTaskInitiation(input, proposal: empty)
            XCTFail("缺少回答正文不应落行")
        } catch let error as VoiceOSError {
            XCTAssertTrue(error.message.contains("回答正文"))
        }
        let rows = try await store.taskInitiations()
        XCTAssertTrue(rows.isEmpty)

        let valid = TaskInitiationFixtures.answer()
        XCTAssertFalse(TaskInitiationComposer.needsClarifyFallback(valid))
        XCTAssertEqual(TaskInitiationComposer.render(valid), valid.answer)
        let oversized = TaskInitiationProposal(isTaskInitiation: false, route: .answer,
                                               answer: String(repeating: "字", count: TaskInitiationComposer.answerLimit + 1))
        XCTAssertThrowsError(try TaskInitiationComposer.validate(oversized, mode: .direct, preferredRoute: nil))
    }

    func testAnswerRecordSurvivesReopenUnderSchema72() async throws {
        var id = ""
        do {
            let store = try await openStore()
            let source = try await personalSource(store, text: "什么是范围经济？")
            id = try await store.recordTaskInitiation(try await input(store, source: source),
                                                      proposal: TaskInitiationFixtures.answer()).id
        }
        let reopened = try await makeStore(at: root)
        let rows = try await reopened.taskInitiations(includeArchived: true)
        XCTAssertEqual(rows.map(\.id), [id])
        XCTAssertEqual(rows.first?.route, .answer)
        XCTAssertEqual(rows.first?.proposal.answer, TaskInitiationFixtures.answer().answer)
        let database = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try database.query("PRAGMA user_version").first?["user_version"], String(Database.schemaVersion))
    }

    func testManualAnswerReusesOriginalWordsAndParsesPlainReply() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "什么是沉没成本？")
        let record = try await store.recordTaskInitiation(try await input(store, source: source),
                                                          proposal: TaskInitiationFixtures.handoff())
        let fake = TaskInitiationFakePort(answer: "沉没成本是已经发生且无法收回的成本。")
        let fakeReply = try await fake.answer(record.input)
        XCTAssertEqual(fakeReply, "沉没成本是已经发生且无法收回的成本。")
        let answered = await fake.answered
        XCTAssertEqual(answered.first?.text, record.input.text)

        let wire = TaskInitiationWireTransport(reply: "沉没成本是已经发生且无法收回的成本。\n\n所以决策时应忽略它。")
        let port = try ResponsesTaskInitiationPort(baseURL: URL(string: "https://api.chiyi.cc/v1")!,
                                                   apiKey: "fixture", model: "fixture-model", transport: wire)
        XCTAssertEqual(port.configuration.promptVersion, "task-initiation-v2")
        let input = TaskInitiationInput(sourceID: "source", transcriptVersionID: "version", text: "什么是沉没成本？",
                                        answer: "一句话解释即可", mode: .direct, preferredRoute: nil,
                                        recordedAt: "2026-11-17T00:00:00Z", timeZone: "Asia/Shanghai")
        let text = try await port.answer(input)
        XCTAssertTrue(text.contains("沉没成本"))
        let inputs = await wire.inputs
        XCTAssertTrue(inputs.first?.contains("什么是沉没成本？") == true)
        XCTAssertTrue(inputs.first?.contains("一句话解释即可") == true)
        // The answer request carries its prompt in the user content, not in a
        // separate instructions field.
        XCTAssertTrue(inputs.first?.contains("直接回答") == true)
        let structured = await wire.hasResponseFormat
        XCTAssertEqual(structured, [false])
    }

    func testClassificationWireAcceptsAnswerRouteWithBody() async throws {
        let body = #"{"is_task_initiation":false,"route":"answer","title":"Git Hook 是什么","objective":"","known_facts":[],"assumptions":[],"missing_information":[],"constraints":[],"acceptance_criteria":[],"execution_preference":"quick_delivery","target_executor":"","deliverables":[],"guide_prerequisites":[],"guide_steps":[],"first_action":"","verification":"","clarify_question":"","reason":"用户在提问","answer":"Git Hook 是自动运行的脚本。"}"#
        let wire = TaskInitiationWireTransport(reply: body)
        let port = try ResponsesTaskInitiationPort(baseURL: URL(string: "https://api.chiyi.cc/v1")!,
                                                   apiKey: "fixture", model: "fixture-model", transport: wire)
        let input = TaskInitiationInput(sourceID: "source", transcriptVersionID: "version", text: "Git Hook 是什么？",
                                        answer: "", mode: .direct, preferredRoute: nil,
                                        recordedAt: "2026-11-17T00:00:00Z", timeZone: "Asia/Shanghai")
        let proposal = try await port.initiate(input)
        XCTAssertEqual(proposal.route, .answer)
        XCTAssertFalse(proposal.isTaskInitiation)
        XCTAssertEqual(proposal.answer, "Git Hook 是自动运行的脚本。")
        let structured = await wire.hasResponseFormat
        XCTAssertEqual(structured, [true])
        let instructions = await wire.instructions
        XCTAssertTrue(instructions.first?.contains("answer") == true)
    }

    func testClarifyAsksOneQuestionThenBecomesDraft() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "我有个 PPT 想法但说不清楚。")
        let interactive = try await input(store, source: source, mode: .interactive)
        let row = try await store.recordTaskInitiation(interactive, proposal: TaskInitiationFixtures.clarify())
        XCTAssertEqual(row.state, "clarify")
        XCTAssertEqual(row.route, .clarify)
        XCTAssertFalse(row.proposal.clarifyQuestion.isEmpty)
        XCTAssertEqual(row.artifact, "")

        await expectFailure({
            _ = try await store.recordTaskInitiationClarification(
                id: row.id, answer: "先确定时长", proposal: TaskInitiationFixtures.clarify(question: "第二个问题？"))
        }, "直接回答阶段不能再次反问")

        let answered = try await store.recordTaskInitiationClarification(
            id: row.id, answer: "先确定时长和听众", proposal: TaskInitiationFixtures.handoff())
        XCTAssertEqual(answered.id, row.id)
        XCTAssertEqual(answered.state, "draft")
        XCTAssertEqual(answered.route, .agentHandoff)
        XCTAssertEqual(answered.input.answer, "先确定时长和听众")
        XCTAssertTrue(answered.artifact.contains("# 任务目标"))

        let direct = try await input(store, source: source, mode: .direct)
        await expectFailure({
            _ = try await store.recordTaskInitiation(direct, proposal: TaskInitiationFixtures.clarify())
        }, "直接模式不能返回澄清路线")
        let drafted = try await store.recordTaskInitiation(direct, proposal: TaskInitiationFixtures.handoff())
        XCTAssertEqual(drafted.state, "draft")
        XCTAssertTrue(drafted.artifact.contains("假设（请先核实）"))
    }

    func testRouteChangeKeepsOneRowAndClearsCopied() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "帮我把这个任务交给 Codex。")
        let row = try await store.recordTaskInitiation(try await input(store, source: source),
                                                       proposal: TaskInitiationFixtures.handoff())
        let copied = try await store.markTaskInitiationCopied(id: row.id, artifact: row.artifact)
        XCTAssertNotNil(copied.copiedAt)

        let switched = try await store.replaceTaskInitiation(id: row.id, preferredRoute: .guidedStart,
                                                              proposal: TaskInitiationFixtures.guided())
        XCTAssertEqual(switched.id, row.id)
        XCTAssertEqual(switched.route, .guidedStart)
        XCTAssertNil(switched.copiedAt)
        XCTAssertNil(switched.editedArtifact)
        XCTAssertTrue(switched.artifact.contains("# 操作步骤"))
        let rows = try await store.taskInitiations()
        XCTAssertEqual(rows.count, 1)

        let confirmed = try await store.confirmTaskInitiation(id: switched.id, artifact: switched.artifact)
        XCTAssertEqual(confirmed.state, "confirmed")
        await expectFailure({
            _ = try await store.replaceTaskInitiation(id: switched.id, preferredRoute: .agentHandoff,
                                                      proposal: TaskInitiationFixtures.handoff())
        }, "已确认的启动包不能更换路线")
    }

    func testCopyLeavesDraftAndConfirmDoesNotImplyCompletion() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "给 Codex 写一个开发提示词。")
        let row = try await store.recordTaskInitiation(try await input(store, source: source),
                                                       proposal: TaskInitiationFixtures.handoff())
        let copied = try await store.markTaskInitiationCopied(id: row.id, artifact: row.artifact)
        XCTAssertNotNil(copied.copiedAt)
        XCTAssertEqual(copied.state, "draft")

        let confirmed = try await store.confirmTaskInitiation(id: row.id, artifact: row.artifact)
        XCTAssertEqual(confirmed.state, "confirmed")
        let actions = try await store.actions(includeHistory: true)
        let claims = try await store.candidateClaims(includeFrozen: true)
        let executions = try await store.assistantExecutions()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(claims.isEmpty)
        XCTAssertTrue(executions.isEmpty)
    }

    func testDiscardOnlyRemovesDrafts() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "先记一下，不用做。")
        let draft = try await store.recordTaskInitiation(try await input(store, source: source),
                                                         proposal: TaskInitiationFixtures.handoff())
        try await store.discardTaskInitiation(id: draft.id)
        let remaining = try await store.taskInitiations()
        XCTAssertTrue(remaining.isEmpty)

        let confirmedDraft = try await store.recordTaskInitiation(try await input(store, source: source),
                                                                  proposal: TaskInitiationFixtures.handoff())
        let confirmed = try await store.confirmTaskInitiation(id: confirmedDraft.id, artifact: confirmedDraft.artifact)
        XCTAssertEqual(confirmed.state, "confirmed")
        await expectFailure({ try await store.discardTaskInitiation(id: confirmed.id) },
                            "已确认的启动包不能删除")
        let kept = try await store.taskInitiations()
        XCTAssertEqual(kept.count, 1)
    }

    func testStepsDeriveFromCommandIDPrefixInRecordedOrder() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "老师让我做一份课程 PPT。")
        let record = try await store.recordTaskInitiation(try await input(store, source: source),
                                                          proposal: TaskInitiationFixtures.handoff())
        let other = try await store.recordTaskInitiation(try await input(store, source: source),
                                                         proposal: TaskInitiationFixtures.handoff())
        let quiet = try await store.recordTaskInitiation(try await input(store, source: source),
                                                         proposal: TaskInitiationFixtures.guided())
        let first = try await step(store, record: record.id, title: "启动后：制作课程演示 PPT", command: "a")
        let second = try await step(store, record: record.id, title: "启动后：制作课程演示 PPT", command: "b")
        let foreign = try await step(store, record: other.id, title: "启动后：制作课程演示 PPT", command: "a")
        _ = try await store.recordCapturedText("前缀不对", title: "前缀不对", ownership: .personal,
                                               commandID: "initiation-step-extra:" + record.id + ":a")

        let steps = try await store.taskInitiationSteps()
        XCTAssertEqual(steps[record.id]?.map(\.id), [first, second])
        XCTAssertEqual(steps[record.id]?.map(\.title), ["启动后：制作课程演示 PPT", "启动后：制作课程演示 PPT"])
        XCTAssertEqual(steps[record.id]?.map(\.createdAt).count, 2)
        XCTAssertEqual(steps[other.id]?.map(\.id), [foreign])
        XCTAssertNil(steps[quiet.id])
        XCTAssertNil(steps["initiation-step-extra"])
    }

    func testArchiveOnlyConfirmedHidesFromDefaultListAndKeepsSemantics() async throws {
        var confirmedID = ""
        var liveID = ""
        var archivedAt: String?
        do {
            let store = try await openStore()
            let source = try await personalSource(store, text: "给 Codex 写一个开发提示词。")
            let draft = try await store.recordTaskInitiation(try await input(store, source: source),
                                                             proposal: TaskInitiationFixtures.handoff())
            await expectFailure({ _ = try await store.archiveTaskInitiation(id: draft.id) }, "草稿不能归档")

            let copied = try await store.markTaskInitiationCopied(id: draft.id, artifact: draft.artifact)
            let confirmed = try await store.confirmTaskInitiation(id: draft.id, artifact: copied.artifact)
            XCTAssertEqual(confirmed.state, "confirmed")
            XCTAssertFalse(confirmed.isArchived)

            let archived = try await store.archiveTaskInitiation(id: confirmed.id)
            XCTAssertTrue(archived.isArchived)
            XCTAssertEqual(archived.state, "confirmed")
            XCTAssertEqual(archived.copiedAt, confirmed.copiedAt)
            XCTAssertEqual(archived.artifact, confirmed.artifact)
            archivedAt = archived.input.presentation?.archivedAt

            let live = try await store.recordTaskInitiation(try await input(store, source: source),
                                                            proposal: TaskInitiationFixtures.guided())
            confirmedID = confirmed.id
            liveID = live.id
            let liveOnly = try await store.taskInitiations()
            XCTAssertEqual(liveOnly.map(\.id), [live.id])
            let all = try await store.taskInitiations(includeArchived: true)
            XCTAssertEqual(Set(all.map(\.id)), Set([live.id, confirmed.id]))
            XCTAssertEqual(all.first(where: { $0.id == confirmed.id })?.input.presentation?.archivedAt,
                           archived.input.presentation?.archivedAt)

            let again = try await store.archiveTaskInitiation(id: confirmed.id)
            XCTAssertEqual(again.input.presentation?.archivedAt, archived.input.presentation?.archivedAt)
            await expectFailure({ try await store.discardTaskInitiation(id: confirmed.id) },
                                "已确认的启动包不能删除")
        }

        let reopened = try await makeStore(at: root)
        let reopenedLive = try await reopened.taskInitiations()
        XCTAssertEqual(reopenedLive.map(\.id), [liveID])
        let reopenedAll = try await reopened.taskInitiations(includeArchived: true)
        XCTAssertEqual(reopenedAll.first(where: { $0.id == confirmedID })?.isArchived, true)
        XCTAssertEqual(reopenedAll.first(where: { $0.id == confirmedID })?.input.presentation?.archivedAt, archivedAt)
    }

    func testInvalidOrIncompleteProposalNeverPersists() async throws {
        let store = try await openStore()
        let source = try await personalSource(store, text: "帮我整理一个任务。")
        let input = try await input(store, source: source)

        let failing = TaskInitiationFakePort(error: VoiceOSError("合成启动请求中断"))
        await expectFailure({ _ = try await failing.initiate(input) }, "端口错误应由调用方处理")
        var rows = try await store.taskInitiations()
        XCTAssertTrue(rows.isEmpty)

        let invalid = TaskInitiationFixtures.handoff(acceptance: [])
        await expectFailure({ _ = try await store.recordTaskInitiation(input, proposal: invalid) },
                            "缺少验收标准不应落行")
        rows = try await store.taskInitiations()
        XCTAssertTrue(rows.isEmpty)

        XCTAssertThrowsError(try JSONDecoder().decode(TaskInitiationProposal.self,
                                                      from: Data(#"{"route":"agent_handoff"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(TaskInitiationProposal.self,
                                                      from: Data(#"{"is_task_initiation":true}"#.utf8)))
        let partial = try JSONDecoder().decode(TaskInitiationProposal.self,
                                               from: Data(#"{"is_task_initiation":true,"route":"agent_handoff"}"#.utf8))
        XCTAssertEqual(partial.knownFacts, [])
        XCTAssertEqual(partial.preference, .quickDelivery)
        XCTAssertEqual(partial.title, "")
    }

    func testSecretWarningAndLocalOnlySources() async throws {
        XCTAssertNotNil(TaskInitiationComposer.secretWarning(in: "key: sk-abcdefghijklmnopqrstuvwxyz012345"))
        XCTAssertNotNil(TaskInitiationComposer.secretWarning(in: "AKIA1234567890ABCDEF"))
        XCTAssertNotNil(TaskInitiationComposer.secretWarning(in: "-----BEGIN RSA PRIVATE KEY-----"))
        XCTAssertNotNil(TaskInitiationComposer.secretWarning(in: "password=hunter2"))
        XCTAssertNotNil(TaskInitiationComposer.secretWarning(in: "api_key=abc123"))
        XCTAssertNil(TaskInitiationComposer.secretWarning(in: "老师让我做一份课程 PPT，我不会。"))

        let store = try await openStore()
        let localOnly = try await personalSource(store, text: "这份材料还没有授权云端。", localOnly: true)
        do {
            _ = try await store.taskInitiationInput(sourceID: localOnly, mode: .direct)
            XCTFail("仅本地来源不应生成启动包")
        } catch let error as VoiceOSError {
            XCTAssertTrue(error.message.contains("仅本地"))
        }
    }

    func testRecordSurvivesReopenUnderSchema52() async throws {
        func seed() async throws -> String {
            let store = try await makeStore(at: root)
            let source = try await personalSource(store, text: "老师让我做一份课程 PPT。")
            let input = try await store.taskInitiationInput(sourceID: source, mode: .direct)
            return try await store.recordTaskInitiation(input, proposal: TaskInitiationFixtures.handoff()).id
        }
        let id = try await seed()

        let reopened = try await makeStore(at: root)
        let rows = try await reopened.taskInitiations()
        XCTAssertEqual(rows.map(\.id), [id])
        XCTAssertEqual(rows.first?.state, "draft")
        XCTAssertEqual(rows.first?.basisChanged, false)
        let database = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try database.query("PRAGMA user_version").first?["user_version"], String(Database.schemaVersion))
        XCTAssertEqual(try database.query("SELECT name FROM sqlite_master WHERE name='task_initiations'").count, 1)
        for table in ["action_review_resolutions", "expression_review_acknowledgements"] {
            XCTAssertEqual(try database.query("SELECT name FROM sqlite_master WHERE name=?", [table]).count, 1)
        }
    }
}
