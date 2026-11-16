import SwiftUI
import VoiceOSCore

/// Which way a stale someday goal leaves the weekly review.
enum SomedayReviewDecision { case keep, restore, abandon }

/// The entrance that opened the clarify queue.
enum ClarifyQueueScope: String { case questions, goals }

/// One-at-a-time clarification for open outcomes, scoped by entrance type.
/// The questions entrance lets VoiceOS answer first. The goals entrance gives
/// each goal a destination and closes with a triage stretch for untriaged
/// suggestions. Narration matches neither queue. Store exits keep a stable
/// command identity, so retries converge.
struct ActionClarifyQueueView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ControlCenter
    let scope: ClarifyQueueScope
    @State private var handled: Set<String> = []
    @State private var nextTitle = ""
    @State private var busy = false
    @State private var error = ""

    private func nature(_ action: ActionRecord) -> ActionNature {
        ActionNature(rawValue: action.nature) ?? .unknown
    }

    private var openItems: [ActionRecord] {
        model.actionRecords.filter { $0.kind != "task" && $0.state == "open" && $0.validity == "current" }
    }

    /// Goals first, then unknown suggestions as the final triage stretch.
    /// The questions scope lists only questions.
    private var queue: [ActionRecord] {
        switch scope {
        case .questions:
            return openItems.filter { nature($0) == .question }
        case .goals:
            return openItems.filter { nature($0) == .goal } + openItems.filter { nature($0) == .unknown }
        }
    }
    private var remaining: [ActionRecord] { queue.filter { !handled.contains($0.id) } }
    private var current: ActionRecord? { remaining.first }

    private var heading: WorkspaceHeading {
        switch scope {
        case .questions:
            return WorkspaceHeading(eyebrow: "问题 · VoiceOS 先回答", title: "一次一条，先让 VoiceOS 试着回答",
                                    subtitle: "让它先给出一个回答；想清楚了可以自己收尾，也可以先加下一步或留到以后。")
        case .goals:
            return WorkspaceHeading(eyebrow: "目标 · 逐个澄清", title: "一次一条，给每个目标一个去处",
                                    subtitle: "留作目标、放到将来、不做了，或者先加一个下一步；最后把系统整理的建议逐条归类。")
        }
    }

    private var emptyText: String {
        if !handled.isEmpty { return "这一轮澄清完成，共处理 \(handled.count) 条。" }
        return scope == .questions ? "当前没有需要回答的问题。" : "当前没有需要澄清的目标。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                heading
                Spacer(minLength: 12)
                Button("关闭") { dismiss() }
            }
            if let current {
                Text("剩余 \(remaining.count) 条").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                Text(StatementTagParser.split(current.title).text).vosFont(WorkspaceText.sectionTitle).textSelection(.enabled)
                if nature(current) == .unknown {
                    Text("系统整理的建议 · 未归类").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("归为问题") { triage(current, .question) }
                        Button("归为目标") { triage(current, .goal) }
                        Button("是旁白") { triage(current, .narration) }
                    }.disabled(busy)
                } else if scope == .questions {
                    questionExits(current)
                    nextStep(current)
                    if !model.modelConfigured {
                        HStack(spacing: 8) {
                            Text("未配置文本模型，暂时不能试答；配置后可用。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                            Button("配置文本模型…") { model.chooseTextModel() }
                        }
                    }
                } else {
                    goalExits(current)
                    nextStep(current)
                }
                if !error.isEmpty {
                    Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                }
            } else {
                Text(emptyText).vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
        }
        .padding(WorkspaceMetrics.pagePadding)
        .frame(minWidth: WorkspaceMetrics.modalSmall, minHeight: 420, alignment: .topLeading)
    }

    private func questionExits(_ action: ActionRecord) -> some View {
        HStack(spacing: 10) {
            Button("让 VoiceOS 试答") { trialAnswer(action) }
                .buttonStyle(.borderedProminent)
                .disabled(!model.modelConfigured)
            Button("想清楚了") { apply(action, .complete) }
            Button("以后再说") { apply(action, .someday) }
            Button("跳过") { advance(action) }
        }.disabled(busy)
    }

    private func goalExits(_ action: ActionRecord) -> some View {
        HStack(spacing: 10) {
            Button("留作目标") { advance(action) }.buttonStyle(.borderedProminent)
            Button("将来也许") { apply(action, .someday) }
            Button("不是我要做的事") { apply(action, .abandon) }
            Button("跳过") { advance(action) }
        }.disabled(busy)
    }

    private func nextStep(_ action: ActionRecord) -> some View {
        HStack(spacing: 8) {
            TextField("下一步要做的事", text: $nextTitle).textFieldStyle(.roundedBorder)
            Button("加下一步") { applyNext(action) }
                .disabled(busy || nextTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Local-only exits: 留作目标 confirms a goal in place, 跳过 defers it.
    private func advance(_ action: ActionRecord) {
        handled.insert(action.id); nextTitle = ""; error = ""
    }

    private func apply(_ action: ActionRecord, _ exit: ActionClarifyExit) {
        guard !busy else { return }
        busy = true
        Task {
            let saved = await model.clarifyQueueExit(action, exit: exit)
            busy = false
            error = saved ? "" : (model.status.isEmpty ? "澄清未能保存，请重试" : model.status)
            if saved { handled.insert(action.id); nextTitle = "" }
        }
    }

    private func applyNext(_ action: ActionRecord) {
        guard !busy else { return }
        busy = true
        let title = nextTitle
        Task {
            let saved = await model.clarifyQueueExit(action, exit: .next, nextTitle: title)
            busy = false
            error = saved ? "" : (model.status.isEmpty ? "下一步未能保存，请重试" : model.status)
            if saved { handled.insert(action.id); nextTitle = "" }
        }
    }

    /// Queues VoiceOS's first answer, then moves on without waiting for it.
    private func trialAnswer(_ action: ActionRecord) {
        guard !busy else { return }
        busy = true
        Task {
            let queued = await model.enqueueTrialAnswer(action)
            busy = false
            error = queued ? "" : (model.assistantStatus.isEmpty ? "试答未能排队，请重试" : model.assistantStatus)
            if queued { handled.insert(action.id); nextTitle = "" }
        }
    }

    private func triage(_ action: ActionRecord, _ nature: ActionNature) {
        guard !busy else { return }
        busy = true
        Task {
            let saved = await model.triageSuggestion(action, as: nature)
            busy = false
            error = saved ? "" : (model.status.isEmpty ? "归类未能保存，请重试" : model.status)
            if saved { handled.insert(action.id); nextTitle = "" }
        }
    }
}

extension ControlCenter {
    /// Applies one clarify-queue exit. The command identity is stable per goal,
    /// exit, and version, so a retried save never writes twice.
    @discardableResult
    func clarifyQueueExit(_ action: ActionRecord, exit: ActionClarifyExit, nextTitle: String = "") async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        let command = VoiceOSStore.clarifyCommandID(actionID: action.id, exit: exit, version: action.version)
        do {
            switch exit {
            case .complete:
                _ = try await store.completeOutcome(actionID: action.id, expectedVersion: action.version, commandID: command)
                status = "已想清楚了"
            case .abandon:
                _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: .dismissed, note: "逐个澄清：不是我要做的事", commandID: command)
                status = "已放下这条目标"
            case .someday:
                _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: .someday, note: "逐个澄清：留到以后", commandID: command)
                status = "已留到以后"
            case .next:
                let title = nextTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = try await store.createAction(claimID: action.claimID, expectedClaimReviewVersion: action.claimReviewVersion,
                                                      title: title, kind: .task, commandID: command)
                _ = try await store.attachNextAction(outcomeID: action.id, actionID: id, commandID: command)
                status = "已添加下一步"
            }
            Task { await refresh() }
            return true
        } catch {
            status = error.localizedDescription
            await refresh()
            return false
        }
    }

    /// Files an untriaged suggestion. The receipt is stable per item, nature,
    /// and version, so a retried classification converges to one revision.
    @discardableResult
    func triageSuggestion(_ action: ActionRecord, as nature: ActionNature) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        let command = "clarify-triage:" + action.id + ":" + nature.rawValue + ":" + String(action.version)
        do {
            _ = try await store.setActionNature(id: action.id, expectedVersion: action.version, nature: nature, commandID: command)
            switch nature {
            case .question: status = "已归为问题，可以去问题入口查看"
            case .goal: status = "已归为目标，可以去目标入口查看"
            case .narration: status = "已标记为旁白，不再出现在问题与目标里"
            case .unknown: status = "已保持未归类"
            }
            Task { await refresh() }
            return true
        } catch {
            status = error.localizedDescription
            await refresh()
            return false
        }
    }

    func somedayReviewCandidates() async -> [ActionRecord] {
        guard let store else { return [] }
        do { return try await store.somedayReviewCandidates() }
        catch { status = error.localizedDescription; return [] }
    }

    @discardableResult
    func revisitSomeday(_ goal: ActionRecord) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.revisitSomeday(actionID: goal.id, expectedVersion: goal.version,
                                               commandID: "someday-review:" + goal.id + ":" + String(goal.version))
            await refresh()
            guard actionRecords.first(where: { $0.id == goal.id })?.version == goal.version + 1 else { throw VoiceOSError("回看未能保存，请重试") }
            status = "已记录回看，60 天后再提醒"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }

    @discardableResult
    func restoreSomeday(_ goal: ActionRecord) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.setActionState(actionID: goal.id, expectedVersion: goal.version, state: .open, note: "回看 · 恢复为目标",
                                               commandID: "someday-restore:" + goal.id + ":" + String(goal.version))
            await refresh()
            guard actionRecords.first(where: { $0.id == goal.id })?.state == LocalActionState.open.rawValue else { throw VoiceOSError("恢复为目标未能保存，请重试") }
            status = "已恢复为目标"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }

    @discardableResult
    func abandonSomeday(_ goal: ActionRecord) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.setActionState(actionID: goal.id, expectedVersion: goal.version, state: .dismissed, note: "回看 · 放弃",
                                               commandID: "someday-abandon:" + goal.id + ":" + String(goal.version))
            await refresh()
            guard actionRecords.first(where: { $0.id == goal.id })?.state == LocalActionState.dismissed.rawValue else { throw VoiceOSError("放弃未能保存，请重试") }
            status = "已放下这条目标"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
}
