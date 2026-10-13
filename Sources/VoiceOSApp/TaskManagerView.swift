import SwiftUI
import VoiceOSCore

struct TaskManagerView: View {
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var section = "tasks"
    @State private var query = ""
    @State private var ideaKind = "all"
    @State private var feedbackAction: ActionRecord?
    @State private var historyAction: ActionRecord?
    private let sections = [("tasks", "待跟进"), ("review", "待核对"), ("ideas", "问题与目标"), ("completed", "已完成"), ("activities", "录音活动")]

    private func category(_ action: ActionRecord) -> String {
        if action.state == "completed" { return "completed" }
        if action.validity != "current" || action.intent?.uncertain == true || action.intent?.followupState == "needs_review" || action.title.contains("待核对") { return "review" }
        if action.intent?.followupState == "recorded_activity" || action.title.hasPrefix("【录音中活动】") { return "activities" }
        return action.kind == "task" ? "tasks" : "ideas"
    }
    private var visible: [ActionRecord] {
        model.actionRecords.filter { action in
            category(action) == section && action.state != "dismissed" && (section != "ideas" || ideaKind == "all" || action.intent?.intentType == ideaKind) &&
            (query.isEmpty || action.title.localizedCaseInsensitiveContains(query) || action.note.localizedCaseInsensitiveContains(query))
        }
    }
    private func selectFocusedTask() {
        if let action = model.actionRecords.first(where: { $0.id == model.focusedTaskID }) { section = category(action) }
    }
    private func sourceNames(_ action: ActionRecord) -> String {
        guard let claim = model.claims.first(where: { $0.id == action.claimID }) else { return "出处待核对" }
        return Set(claim.references.compactMap { ref in model.records.first(where: { $0.id == ref.sourceID })?.name }).sorted().joined(separator: " · ")
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
                Button("补充提醒出处") { Task { await model.enrichReminderContexts() } }.disabled(model.remindersBusy || model.reminderAccess?.enabled != true)
            }
            Picker("查看", selection: $section) {
                ForEach(sections, id: \.0) { key, label in
                    Text(label + "（\(model.actionRecords.filter { category($0) == key && $0.state != "dismissed" }.count)）").tag(key)
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
                    LazyVStack(alignment: .leading, spacing: 16) {
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
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(24).frame(width: 920, height: 660)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: action.state == "completed" ? "checkmark.circle.fill" : action.kind == "task" ? "circle" : "lightbulb")
                    .foregroundStyle(action.state == "completed" ? .green : .secondary)
                Text(action.title).font(.headline).textSelection(.enabled)
                Spacer()
                if feedbackCount(action) > 0 { Text("\(feedbackCount(action)) 条结果").font(.caption).foregroundStyle(.secondary) }
            }
            Text(sourceNames(action)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if !action.note.isEmpty {
                DisclosureGroup("原话与说明") {
                    Text(action.note).textSelection(.enabled)
                    if let claim = model.claims.first(where: { $0.id == action.claimID }), let detail = claim.statement.components(separatedBy: "\n说明：").dropFirst().first {
                        Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.font(.callout)
            }
            HStack {
                Button("查看出处") {
                    if let id = model.claims.first(where: { $0.id == action.claimID })?.references.first?.sourceID { model.selected = id; dismiss() }
                }
                Button(action.state == "completed" ? "记录结果或收获" : "记录进展") { feedbackAction = action }.disabled(model.savingFeedback || action.validity != "current")
                if feedbackCount(action) > 0 { Button("查看结果") { Task { await model.actionHistory(action); historyAction = action } } }
                Spacer()
                if action.kind == "task", action.validity == "current" {
                    Button(action.state == "completed" ? "重新跟进" : "标记已完成") { Task { await model.changeAction(action, state: action.state == "completed" ? .open : .completed) } }
                        .disabled(model.savingAction || model.remindersBusy)
                }
            }.buttonStyle(.bordered)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(action.id == model.focusedTaskID ? Color.accentColor : .clear, lineWidth: 2))
    }
}
