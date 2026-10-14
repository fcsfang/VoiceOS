import SwiftUI
import AVKit
import VoiceOSCore

struct TaskManagerView: View {
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var section = "tasks"
    @State private var query = ""
    @State private var ideaKind = "all"
    @State private var feedbackAction: ActionRecord?
    @State private var historyAction: ActionRecord?
    @State private var confirmingAction: ActionRecord?
    @State private var playbackActionID: String?
    @State private var expandedActions: Set<String> = []
    private let sections = [("tasks", "待跟进"), ("review", "待核对"), ("ideas", "问题与目标"), ("completed", "已完成"), ("activities", "录音活动")]

    private func category(_ action: ActionRecord) -> String {
        if action.state == "completed" { return "completed" }
        if action.validity != "current" { return "review" }
        if let intent = action.intent {
            if intent.uncertain || intent.followupState == "needs_review" || intent.intentType == "uncertain" { return "review" }
            if intent.followupState == "recorded_activity" { return "activities" }
        } else {
            if action.title.contains("待核对") { return "review" }
            if action.title.hasPrefix("【录音中活动】") { return "activities" }
        }
        return action.kind == "task" ? "tasks" : "ideas"
    }
    private var visible: [ActionRecord] {
        listedActions.filter { action in
            category(action) == section && action.state != "dismissed" && (section != "ideas" || ideaKind == "all" || action.intent?.intentType == ideaKind) &&
            (query.isEmpty || action.title.localizedCaseInsensitiveContains(query) || action.note.localizedCaseInsensitiveContains(query))
        }
    }
    private var listedActions: [ActionRecord] {
        let current = Set(model.currentClaimsBySource.values.flatMap { $0.map(\.id) })
        // A new complete organization replaces prior idea proposals, while real tasks and results stay visible.
        return model.actionRecords.filter { $0.kind != "opportunity" || $0.intent == nil || $0.validity != "current" || $0.state != "open" || current.contains($0.claimID) }
    }
    private func selectFocusedTask() {
        if let action = model.actionRecords.first(where: { $0.id == model.focusedTaskID }) { query = ""; ideaKind = "all"; section = category(action); expandedActions.insert(action.id) }
    }
    private func sourceNames(_ action: ActionRecord) -> String {
        guard let claim = model.claims.first(where: { $0.id == action.claimID }) else { return "出处待核对" }
        return Set(claim.references.map(\.sourceID)).sorted().compactMap { id in
            guard let record = model.records.first(where: { $0.id == id }) else { return nil }
            let refs = claim.references.filter { $0.sourceID == id && $0.transcriptVersionID == record.transcriptVersionID }
            let timed = record.spans.filter { span in refs.contains(where: { $0.spanID == span.id }) }.compactMap { span -> (Int, Int)? in
                guard let start = span.startMS, let end = span.endMS else { return nil }; return (start, end)
            }.sorted { $0.0 < $1.0 }
            var ranges: [(Int, Int)] = []
            for (start, end) in timed {
                if let last = ranges.last, start <= last.1 + 1000 { ranges[ranges.count - 1].1 = max(last.1, end) }
                else { ranges.append((start, end)) }
            }
            func time(_ ms: Int) -> String { let sec = ms / 1000; return String(format: "%02d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60) }
            return record.name + (ranges.isEmpty ? "" : " · " + ranges.map { time($0.0) + "–" + time($0.1) }.joined(separator: "；"))
        }.joined(separator: "\n")
    }
    private func feedbackCount(_ action: ActionRecord) -> Int {
        model.records.filter { $0.feedbackActionID == action.id }.count
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("任务与后续").font(.title2)
                    Text("从原话接续行动，完成后留下一句结果或收获。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("同步提醒事项") { Task { await model.refreshTaskReminders() } }.disabled(model.remindersBusy || model.reminderAccess?.enabled != true)
                Button("精简提醒显示") { Task { await model.enrichReminderContexts() } }.disabled(model.remindersBusy || model.reminderAccess?.enabled != true)
            }
            Picker("查看", selection: $section) {
                ForEach(sections, id: \.0) { key, label in
                    Text(label + "（\(listedActions.filter { category($0) == key && $0.state != "dismissed" }.count)）").tag(key)
                }
            }.pickerStyle(.segmented)
            if section == "ideas" {
                Picker("意图类型", selection: $ideaKind) {
                    Text("全部").tag("all"); Text("问题").tag("question"); Text("长期目标").tag("goal"); Text("想法与需求").tag("idea")
                }.pickerStyle(.segmented)
            }
            TextField("查找任务或原话", text: $query)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if visible.isEmpty {
                            ContentUnavailableView(section == "completed" ? "完成的任务会汇入这里" : "这里暂时没有事项", systemImage: section == "completed" ? "checkmark.circle" : "tray",
                                                   description: Text(section == "completed" ? "在 VoiceOS 或 Apple 提醒事项中完成任务后，可以记录结果或继续思考。" : "可以切换分类，或换一个关键词。"))
                        }
                        ForEach(visible) { action in
                            card(action).id(action.id)
                        }
                    }.padding(.vertical, 8)
                }
                .onChange(of: model.focusedTaskID) { _, id in selectFocusedTask(); if let id { proxy.scrollTo(id, anchor: .top) } }
                .onChange(of: section) { _, _ in if let id = model.focusedTaskID { proxy.scrollTo(id, anchor: .top) } }
                .onAppear { selectFocusedTask(); if let id = model.focusedTaskID { proxy.scrollTo(id, anchor: .top) } }
            }
            HStack {
                Text(model.remindersBusy ? "正在同步提醒事项…" : model.reminderSyncStatus).font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
            }
            if let id = playbackActionID, let player = model.player {
                Text("回听：" + (model.actionRecords.first(where: { $0.id == id })?.title ?? "原话")).font(.caption).lineLimit(1)
                NativePlayerView(player: player).frame(height: 64)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(24).frame(width: 920, height: 660)
        .onDisappear { if playbackActionID != nil { model.stopPlayback() } }
        .sheet(item: $confirmingAction) { action in ConfirmTaskView(action: action, model: model) { confirmingAction = nil } }
        .sheet(item: $feedbackAction) { action in ActionFeedbackView(action: action, model: model) { feedbackAction = nil } }
        .sheet(item: $historyAction) { action in
            VStack(alignment: .leading, spacing: 16) {
                Text(action.title).font(.title2)
                ScrollView {
                    if model.feedbackRecords.isEmpty { Text("还没有结果记录。愿意时补一句实际进展或收获即可。").foregroundStyle(.secondary) }
                    ForEach(model.feedbackRecords) { feedback in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(feedback.kind == "outcome" ? "实际结果" : "我的反思").font(.headline)
                            Text(feedback.text).textSelection(.enabled)
                            if let recordingID = feedback.recordingSourceID {
                                Button("查看原始口述") { model.selected = recordingID; historyAction = nil; dismiss() }
                            }
                            Divider()
                        }
                    }
                }
                HStack { Spacer(); Button("返回") { historyAction = nil } }
            }.padding(24).frame(width: 640, height: 430)
        }
    }
    @ViewBuilder private func card(_ action: ActionRecord) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedActions.contains(action.id) }, set: { if $0 { expandedActions.insert(action.id) } else { expandedActions.remove(action.id) } })) {
        VStack(alignment: .leading, spacing: 10) {
            Text(sourceNames(action)).font(.caption).foregroundStyle(.secondary)
            if !action.note.isEmpty {
                Text(action.note).textSelection(.enabled)
                if let claim = model.claims.first(where: { $0.id == action.claimID }), let detail = claim.statement.components(separatedBy: "\n说明：").dropFirst().first {
                    Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            HStack {
                Button("查看出处") {
                    if let id = model.claims.first(where: { $0.id == action.claimID })?.references.first?.sourceID { model.selected = id; dismiss() }
                }
                Button("回听原话") { Task { if await model.playActionOriginal(action) { playbackActionID = action.id } } }.disabled(action.validity != "current")
                Button(action.state == "completed" ? "记录结果或收获" : "记录进展") { feedbackAction = action }.disabled(model.savingFeedback || action.validity != "current")
                if feedbackCount(action) > 0 { Button("查看结果") { Task { await model.actionHistory(action); historyAction = action } } }
                Spacer()
                if action.kind == "opportunity", action.validity == "current", action.state == "open", action.intentActor == "user" {
                    Button("核对为待办") { confirmingAction = action }.disabled(model.savingAction)
                }
                if action.kind == "task", action.validity == "current" {
                    Button(action.state == "completed" ? "重新跟进" : "标记已完成") { Task { await model.changeAction(action, state: action.state == "completed" ? .open : .completed) } }.disabled(model.savingAction || model.remindersBusy)
                }
            }.buttonStyle(.bordered)
        }.padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: action.state == "completed" ? "checkmark.circle.fill" : action.kind == "task" ? "circle" : "lightbulb")
                    .foregroundStyle(action.state == "completed" ? .green : .secondary)
                Text(action.title).font(.body).textSelection(.enabled)
                Spacer()
                if feedbackCount(action) > 0 { Text("\(feedbackCount(action)) 条结果").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(action.id == model.focusedTaskID ? Color.accentColor : .clear, lineWidth: 2))
    }
}

private struct ConfirmTaskView: View {
    let action: ActionRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var title = ""
    @State private var error = ""
    @State private var commandID = UUID().uuidString
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("核对为明确待办").font(.title2)
            Text("确认这是你仍需跟进的事情，并把标题改成实际要做的动作。保存后会同步到已连接的提醒事项清单。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("需要跟进什么", text: $title).disabled(model.savingAction)
            ScrollView { Text(action.note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Button("取消", action: dismiss).disabled(model.savingAction)
                Spacer()
                Button("确认为待办") {
                    Task {
                        if await model.confirmTask(action, title: title, commandID: commandID) { dismiss() }
                        else { error = model.status }
                    }
                }.buttonStyle(.borderedProminent).disabled(model.savingAction || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 620)
        .onAppear {
            title = action.title.replacingOccurrences(of: "（待核对）", with: "")
            if title.hasPrefix("【"), let end = title.firstIndex(of: "】") { title = String(title[title.index(after: end)...]) }
        }
        .interactiveDismissDisabled(model.savingAction)
    }
}
