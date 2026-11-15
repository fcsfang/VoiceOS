import SwiftUI
import VoiceOSCore

struct WeeklyReviewView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ControlCenter
    let openTask: (String) -> Void
    let openActions: () -> Void
    var openFilter: ((String) -> Void)? = nil
    @State private var actionError = ""
    @State private var focusError = ""
    @State private var focusedIDs: Set<String> = []
    @State private var selectedFocusIDs: Set<String> = []
    @State private var focusSaving = false
    @State private var focusLoaded = false
    @State private var undoEntry: UndoEntry?

    private enum ReviewFilter: String {
        case todo = "我的待办", review = "待核对", completed = "已完成", history = "历史记录"
    }
    private struct UndoEntry: Identifiable, Equatable {
        let id = UUID()
        let actionID: String
        let label: String
    }

    private var openTasks: [ActionRecord] {
        model.actionRecords.filter { $0.kind == "task" && $0.state == "open" && $0.validity == "current" }
    }
    private var surface: ActionTimeSurface {
        ActionTimeSurface.build(actions: openTasks, schedules: model.scheduleIntents, links: model.reminderLinks, now: Date(), calendar: .current)
    }
    private var dailyReview: DailyReview {
        DailyReview.build(actions: model.actionRecords, schedules: model.scheduleIntents,
                          links: model.reminderLinks, now: Date(), calendar: .current)
    }
    private var nextWeekEntries: [ActionTimeEntry] { surface.soon + surface.anytime }
    private var nextWeekCandidates: [ActionTimeEntry] {
        let focused = nextWeekEntries.filter { focusedIDs.contains($0.action.id) }
        let rest = nextWeekEntries.filter { !focusedIDs.contains($0.action.id) }
        return focused + rest
    }
    private var focusSlots: Int { max(0, 3 - focusedIDs.count) }
    private var staleTasks: [ActionRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        return openTasks.filter { action in
            ConversationReflectionFocus.date(action.createdAt).map { $0 < cutoff } ?? false
        }.sorted { left, right in
            (ConversationReflectionFocus.date(left.createdAt) ?? .distantPast) < (ConversationReflectionFocus.date(right.createdAt) ?? .distantPast)
        }
    }
    private var unclarifiedTasks: [ActionRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        return openTasks.filter { action in
            guard action.isExtracted, model.actionClarifications[action.id] == nil else { return false }
            return ConversationReflectionFocus.date(action.createdAt).map { $0 >= cutoff } ?? false
        }.sorted { left, right in
            (ConversationReflectionFocus.date(left.createdAt) ?? .distantPast) > (ConversationReflectionFocus.date(right.createdAt) ?? .distantPast)
        }
    }
    private var weekProgress: [RecentContentProgressRow] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return model.homeSnapshot.progressRows.values.flatMap { $0 }
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }
    }
    private var pausedTasks: [ActionRecord] {
        var seen = Set<String>()
        return (model.workspacePausedTasks + model.actionRecords.filter { $0.validity != "current" })
            .filter { seen.insert($0.id).inserted }
    }
    private var stalledGoals: [ActionRecord] { model.stalledOutcomes }
    private var isEmpty: Bool {
        dailyReview.today.isEmpty && dailyReview.overdue.isEmpty && dailyReview.remaining.isEmpty &&
            staleTasks.isEmpty && unclarifiedTasks.isEmpty && weekProgress.isEmpty && pausedTasks.isEmpty &&
            stalledGoals.isEmpty &&
            nextWeekEntries.isEmpty
    }
    private var undoHint: some View {
        Text("完成或不再跟进后可立即撤销，任务页也保留撤销。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    WorkspaceHeading(eyebrow: "行动 · 每周回顾", title: "这一周，行动走到了哪里", subtitle: "今天收尾可直接完成或不再跟进；点开任意一条查看任务、原话与结果。")
                    Button("关闭") { dismiss() }
                }
                undoHint
                dailyCloseSection
                if isEmpty {
                    Text("这一周没有需要回顾的行动。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                }
                if !nextWeekEntries.isEmpty { nextWeekSection }
                if !staleTasks.isEmpty { staleSection }
                if !unclarifiedTasks.isEmpty { unclarifiedSection }
                if !stalledGoals.isEmpty { stalledGoalsSection }
                if !weekProgress.isEmpty { progressSection }
                if !pausedTasks.isEmpty { pausedSection }
            }.frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading).padding(WorkspaceMetrics.pagePadding)
        }
        .frame(minWidth: WorkspaceMetrics.modalSmall, minHeight: 560)
        .overlay(alignment: .bottom) { undoBar }
        .animation(.easeOut(duration: 0.2), value: undoEntry?.id)
        .task {
            focusedIDs = await model.focusedActionIDs()
            focusLoaded = true
        }
        .task(id: undoEntry?.id) {
            guard let id = undoEntry?.id else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if undoEntry?.id == id { withAnimation { undoEntry = nil } }
        }
    }

    private var dailyCloseSection: some View {
        let review = dailyReview
        let todayRows = Array(review.today.prefix(5))
        let overdueRows = Array(review.overdue.prefix(5))
        return WorkspaceSection(title: "今天收尾", subtitle: "逐条完成或不再跟进；改天仍到任务页处理。", icon: "checkmark.circle", count: review.remainingCount) {
            if review.isClear {
                Text("今天没有未收尾的行动").vosFont(WorkspaceText.body).foregroundStyle(.secondary).padding(.vertical, 10)
            }
            if !todayRows.isEmpty {
                ForEach(Array(todayRows.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    dailyRow(entry, overdue: false)
                }
            }
            if review.today.count > todayRows.count { allButton(review.today.count, .todo) }
            if !overdueRows.isEmpty {
                if !todayRows.isEmpty { Divider() }
                Text("逾期").vosFont(WorkspaceText.rowTitle).foregroundStyle(palette.warning).accessibilityAddTraits(.isHeader)
                    .padding(.top, 12).padding(.bottom, 2)
                ForEach(Array(overdueRows.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    dailyRow(entry, overdue: true)
                }
            }
            if review.overdue.count > overdueRows.count { allButton(review.overdue.count, .todo) }
            if review.completedCount + review.dismissedCount > 0 {
                Text("已完成 \(review.completedCount) 条，已放下 \(review.dismissedCount) 条。")
                    .vosFont(WorkspaceText.meta).foregroundStyle(.secondary).padding(.top, 10)
            }
            if review.remainingCount > 0 {
                HStack(spacing: 8) {
                    Text("今天与逾期共 \(review.remainingCount) 条").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("到行动页查看 →") { jump(.todo) }
                        .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                }.padding(.top, 10)
            }
            if !actionError.isEmpty {
                Text(actionError).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning).padding(.top, 10)
            }
        }
    }

    private func dailyRow(_ entry: ActionTimeEntry, overdue: Bool) -> some View {
        let subtitle = dailySubtitle(entry)
        return HStack(alignment: .top, spacing: 12) {
            Button { openTask(entry.action.id) } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: overdue ? "exclamationmark.circle" : "circle").vosFont(WorkspaceText.rowTitle.size)
                        .foregroundStyle(overdue ? palette.warning : palette.accent)
                        .frame(width: 34, height: 34)
                        .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.action.title).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                        if !subtitle.isEmpty {
                            Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }.buttonStyle(.plain)
            if overdue {
                Text("逾期").vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(palette.warning).padding(.top, 5)
            }
            Button("完成") { apply(entry, .completed) }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.savingAction)
                .accessibilityLabel("完成：" + entry.action.title)
            Button("不再跟进") { apply(entry, .dismissed) }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.savingAction)
                .accessibilityLabel("不再跟进：" + entry.action.title)
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
    }

    private func apply(_ entry: ActionTimeEntry, _ state: LocalActionState) {
        Task {
            await model.changeAction(entry.action, state: state)
            let current = model.actionRecords.first { $0.id == entry.action.id }
            guard current?.state == state.rawValue else {
                actionError = "状态未能更新，请到任务页核对"
                return
            }
            actionError = ""
            withAnimation {
                undoEntry = UndoEntry(actionID: entry.action.id,
                                      label: state == .completed ? "已完成" : "不再跟进")
            }
        }
    }

    private func undoLastChange() {
        guard let entry = undoEntry else { return }
        Task {
            if await model.undoActionState(actionID: entry.actionID) {
                actionError = ""
                withAnimation { undoEntry = nil }
            } else {
                actionError = model.status.isEmpty ? "撤销未能完成，请到任务页核对" : model.status
            }
        }
    }

    private func jump(_ filter: ReviewFilter) {
        if let openFilter { openFilter(filter.rawValue) } else { openActions() }
    }

    private func allButton(_ count: Int, _ filter: ReviewFilter) -> some View {
        Button("查看全部 \(count) 条 →") { jump(filter) }
            .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
            .padding(.top, 10)
            .accessibilityLabel("查看全部 \(count) 条")
    }

    private var undoBar: some View {
        Group {
            if let undoEntry {
                Button(action: undoLastChange) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
                        Text("\(undoEntry.label) · 撤销").vosFont(WorkspaceText.meta.size, weight: .medium)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                    .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border, lineWidth: 1) }
                    .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                }.buttonStyle(.plain)
                    .accessibilityLabel("撤销：\(undoEntry.label)")
                    .padding(.horizontal, 24).padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func dailySubtitle(_ entry: ActionTimeEntry) -> String {
        var parts: [String] = []
        if let title = actionSourceTitle(entry.action) {
            let shortened = title.count > 12 ? String(title.prefix(12)) + "…" : title
            parts.append("来自『\(shortened)』")
        }
        if let due = entry.due { parts.append(due.summary) }
        return parts.joined(separator: " · ")
    }

    private func actionSourceTitle(_ action: ActionRecord) -> String? {
        guard let claim = model.claims.first(where: { $0.id == action.claimID }) else { return nil }
        for reference in claim.references {
            guard let source = model.records.first(where: { $0.id == reference.sourceID }) else { continue }
            let title = source.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private var nextWeekSection: some View {
        let candidates = nextWeekCandidates
        let rows = Array(candidates.prefix(5))
        return WorkspaceSection(title: "下周先做", subtitle: "从即将与随时里挑最多 3 条，确认后加入专注。", icon: "calendar.badge.plus", count: nextWeekEntries.count) {
            if focusSlots == 0 {
                Text("已有 3 条专注，先到行动页移出。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning).padding(.top, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                nextWeekRow(entry)
            }
            if candidates.count > rows.count { allButton(candidates.count, .todo) }
            HStack(spacing: 10) {
                Text(selectedFocusIDs.isEmpty ? "最多还能加入 \(focusSlots) 条" : "已选 \(selectedFocusIDs.count) 条")
                    .vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                Spacer()
                Button("加入专注") { applyNextWeekFocus() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(selectedFocusIDs.isEmpty || focusSaving)
            }.padding(.top, 10)
            if !focusError.isEmpty {
                Text(focusError).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning).padding(.top, 10)
            }
        }
    }

    private func nextWeekRow(_ entry: ActionTimeEntry) -> some View {
        let focused = focusedIDs.contains(entry.action.id)
        let selected = selectedFocusIDs.contains(entry.action.id)
        let subtitle = dueLabel(entry)
        return Button {
            guard focusLoaded, !focused, !focusSaving else { return }
            if selected {
                selectedFocusIDs.remove(entry.action.id)
                focusError = ""
            } else if focusSlots == 0 {
                focusError = "已有 3 条专注，先到行动页移出"
            } else if selectedFocusIDs.count >= focusSlots {
                focusError = "最多还能加入 \(focusSlots) 条"
            } else {
                selectedFocusIDs.insert(entry.action.id)
                focusError = ""
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: focused ? "pin.fill" : selected ? "checkmark.circle.fill" : "circle").vosFont(WorkspaceText.rowTitle.size)
                    .foregroundStyle(focused || selected ? palette.accent : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.action.title).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                    Text(subtitle.isEmpty ? "随时" : subtitle).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if focused {
                    Text("已专注").vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(palette.accent).padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }.buttonStyle(.plain)
        .accessibilityValue(focused ? "已专注" : selected ? "已选" : "未选")
        .padding(.vertical, 10).padding(.horizontal, 10)
        .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
    }

    private func applyNextWeekFocus() {
        guard !selectedFocusIDs.isEmpty, !focusSaving else { return }
        let selected = selectedFocusIDs
        focusSaving = true
        Task {
            let current = await model.focusedActionIDs()
            focusedIDs = current
            var failure = ""
            for id in selected where !current.contains(id) {
                if await model.toggleActionFocus(actionID: id) == nil, failure.isEmpty {
                    failure = model.status
                }
            }
            focusedIDs = await model.focusedActionIDs()
            selectedFocusIDs.removeAll()
            focusSaving = false
            focusError = failure
        }
    }

    private var staleSection: some View {
        let rows = Array(staleTasks.prefix(5))
        return WorkspaceSection(title: "长期未动", subtitle: "创建超过 14 天，仍是未完成状态。", icon: "hourglass", count: staleTasks.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                reviewRow(title: action.title, subtitle: staleLabel(action), trailing: "搁置", icon: "hourglass") { openTask(action.id) }
            }
            if staleTasks.count > rows.count { allButton(staleTasks.count, .todo) }
        }
    }
    private var unclarifiedSection: some View {
        let rows = Array(unclarifiedTasks.prefix(5))
        return WorkspaceSection(title: "待确认", subtitle: "最近 14 天从原话抽取，还没有确认是承诺、问题与目标，还是不是。", icon: "questionmark.circle", count: unclarifiedTasks.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                reviewRow(title: action.title, subtitle: "打开任务页完成一次三选一澄清。", trailing: "待确认", icon: "questionmark.circle") { openTask(action.id) }
            }
            if unclarifiedTasks.count > rows.count { allButton(unclarifiedTasks.count, .review) }
        }
    }
    private var progressSection: some View {
        let rows = Array(weekProgress.prefix(5))
        return WorkspaceSection(title: "本周完成与结果", subtitle: "最近 7 天记录的完成、进展与结果。", icon: "checkmark.seal", count: weekProgress.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                reviewRow(title: row.taskTitle, subtitle: row.relationLabel, detail: row.text,
                          trailing: dayLabel(row.date), enabled: row.isTaskAvailable) { openTask(row.actionID) }
            }
            if weekProgress.count > rows.count { allButton(weekProgress.count, .completed) }
        }
    }
    private var pausedSection: some View {
        let rows = Array(pausedTasks.prefix(5))
        return WorkspaceSection(title: "暂停与冻结", subtitle: "AI 提取暂停或不再随当前理解更新的行动，状态保留。", icon: "pause.circle", count: pausedTasks.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                reviewRow(title: action.title, subtitle: model.workspaceActionStatus(action),
                          trailing: action.validity == "current" ? "待核对" : "已冻结", icon: "pause.circle") { openTask(action.id) }
            }
            if pausedTasks.count > rows.count { allButton(pausedTasks.count, .history) }
        }
    }

    private var stalledGoalsSection: some View {
        let rows = Array(stalledGoals.prefix(5))
        return WorkspaceSection(title: "没有下一步的目标", subtitle: "目标还没有可以推进的下一步。", icon: "exclamationmark.circle", count: stalledGoals.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, goal in
                if index > 0 { Divider() }
                reviewRow(title: goal.title, subtitle: "还没有下一步", trailing: "停滞", icon: "exclamationmark.circle",
                          accessibilityLabel: "目标：" + goal.title + "，还没有下一步") { openTask(goal.id) }
            }
            if stalledGoals.count > rows.count {
                Text("还有 \(stalledGoals.count - rows.count) 个目标，到问题与目标页查看。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary).padding(.top, 10)
            }
        }
    }
    private func reviewRow(title: String, subtitle: String, detail: String = "", trailing: String = "",
                           icon: String = "circle", enabled: Bool = true, accessibilityLabel: String? = nil,
                           open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                    .frame(width: 34, height: 34)
                    .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                    if !subtitle.isEmpty {
                        Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if !detail.isEmpty {
                        Text(detail).vosFont(WorkspaceText.body).lineSpacing(3).lineLimit(3).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if !trailing.isEmpty {
                    Text(trailing).vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(.secondary).padding(.top, 3)
                }
                Image(systemName: "chevron.right").vosFont(WorkspaceText.caption).foregroundStyle(.tertiary).padding(.top, 3).accessibilityHidden(true)
            }
            .padding(.vertical, 14).padding(.horizontal, 10)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }.buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabelIfPresent(accessibilityLabel)
            .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
    }
    private func dueLabel(_ entry: ActionTimeEntry) -> String {
        var parts: [String] = []
        if let due = entry.due { parts.append(due.summary) }
        if entry.source == .reminderReadback { parts.append("提醒事项回读") }
        if entry.needsLocalSyncLabel { parts.append("本地未同步") }
        return parts.joined(separator: " · ")
    }
    private func staleLabel(_ action: ActionRecord) -> String {
        guard let days = Calendar.current.dateComponents([.day], from: ConversationReflectionFocus.date(action.createdAt) ?? Date(), to: Date()).day else {
            return "创建时间未知"
        }
        return "\(days) 天前创建"
    }
    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
private extension View {
    @ViewBuilder func accessibilityLabelIfPresent(_ label: String?) -> some View {
        if let label { self.accessibilityLabel(label) } else { self }
    }
}
