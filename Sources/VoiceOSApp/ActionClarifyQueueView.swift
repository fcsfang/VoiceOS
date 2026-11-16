import SwiftUI
import VoiceOSCore

/// Which way a stale someday goal leaves the weekly review.
enum SomedayReviewDecision { case keep, restore, abandon }

/// One-at-a-time clarification for open outcomes. Every exit carries the
/// command identity `clarify:<id>:<exit>:<version>`, so retries converge.
struct ActionClarifyQueueView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ControlCenter
    @State private var handled: Set<String> = []
    @State private var nextTitle = ""
    @State private var busy = false
    @State private var error = ""

    private var queue: [ActionRecord] {
        model.actionRecords.filter { $0.kind != "task" && $0.state == "open" && $0.validity == "current" }
    }
    private var remaining: [ActionRecord] { queue.filter { !handled.contains($0.id) } }
    private var current: ActionRecord? { remaining.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                WorkspaceHeading(eyebrow: "问题与目标 · 逐个澄清", title: "一次一条，给每个目标一个去处",
                                 subtitle: "达成、放弃、留到以后，或者先加一个下一步；也可以跳过。")
                Spacer(minLength: 12)
                Button("关闭") { dismiss() }
            }
            if let current {
                Text("剩余 \(remaining.count) 条").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                Text(StatementTagParser.split(current.title).text).vosFont(WorkspaceText.sectionTitle).textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("达成") { apply(current, .complete) }.buttonStyle(.borderedProminent)
                    Button("放弃") { apply(current, .abandon) }
                    Button("将来也许") { apply(current, .someday) }
                    Button("跳过") { handled.insert(current.id); nextTitle = ""; error = "" }
                }.disabled(busy)
                HStack(spacing: 8) {
                    TextField("下一步要做的事", text: $nextTitle).textFieldStyle(.roundedBorder)
                    Button("加下一步") { applyNext(current) }
                        .disabled(busy || nextTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !error.isEmpty {
                    Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                }
            } else {
                Text(handled.isEmpty ? "当前没有需要澄清的问题与目标。" : "这一轮澄清完成，共处理 \(handled.count) 条。")
                    .vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
        }
        .padding(WorkspaceMetrics.pagePadding)
        .frame(minWidth: WorkspaceMetrics.modalSmall, minHeight: 420, alignment: .topLeading)
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
                status = "已标记达成"
            case .abandon:
                _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: .dismissed, note: "逐个澄清：放弃", commandID: command)
                status = "已放弃这条目标"
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
