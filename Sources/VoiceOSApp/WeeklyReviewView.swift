import SwiftUI
import VoiceOSCore

struct WeeklyReviewView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ControlCenter
    let openTask: (String) -> Void
    @State private var actionError = ""
    @State private var focusError = ""
    @State private var focusedIDs: Set<String> = []
    @State private var selectedFocusIDs: Set<String> = []
    @State private var focusSaving = false
    @State private var focusLoaded = false

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
    private var todayEntries: [ActionTimeEntry] { Array(surface.today.prefix(5)) }
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
    private var isEmpty: Bool {
        dailyReview.today.isEmpty && dailyReview.overdue.isEmpty && dailyReview.remaining.isEmpty &&
            staleTasks.isEmpty && unclarifiedTasks.isEmpty && weekProgress.isEmpty && pausedTasks.isEmpty &&
            nextWeekEntries.isEmpty
    }
    private var undoHint: some View {
        Text("完成后可在任务页撤销，或按 ⌥⌘Z").vosFont(12).foregroundStyle(.secondary)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    WorkspaceHeading(eyebrow: "行动 · 每周回顾", title: "这一周，行动走到了哪里", subtitle: "今天收尾可直接完成或不再跟进；点开任意一条查看任务、原话与结果。")
                    Button("关闭") { dismiss() }
                }
                dailyCloseSection
                if isEmpty {
                    Text("这一周没有需要回顾的行动。").font(.callout).foregroundStyle(.secondary)
                }
                if !todayEntries.isEmpty { todaySection }
                if !nextWeekEntries.isEmpty { nextWeekSection }
                if !staleTasks.isEmpty { staleSection }
                if !unclarifiedTasks.isEmpty { unclarifiedSection }
                if !weekProgress.isEmpty { progressSection }
                if !pausedTasks.isEmpty { pausedSection }
            }.frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading).padding(WorkspaceMetrics.pagePadding)
        }
        .frame(minWidth: WorkspaceMetrics.modalSmall, minHeight: 560)
        .task {
            focusedIDs = await model.focusedActionIDs()
            focusLoaded = true
        }
    }

    private var dailyCloseSection: some View {
        let review = dailyReview
        return WorkspaceSection(title: "今天收尾", subtitle: "逐条完成或不再跟进；改天仍到任务页处理。", icon: "checkmark.circle", count: review.remainingCount) {
            undoHint
            if review.isClear {
                Text("今天没有未收尾的行动").font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
            }
            if !review.today.isEmpty {
                ForEach(Array(review.today.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    dailyRow(entry, overdue: false)
                }
            }
            if !review.overdue.isEmpty {
                if !review.today.isEmpty { Divider() }
                Text("逾期").vosFont(13, weight: .semibold).foregroundStyle(palette.warning)
                    .padding(.top, 12).padding(.bottom, 2)
                ForEach(Array(review.overdue.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    dailyRow(entry, overdue: true)
                }
            }
            if review.completedCount + review.dismissedCount > 0 {
                Text("已完成 \(review.completedCount) 条，已放下 \(review.dismissedCount) 条。")
                    .vosFont(12).foregroundStyle(.secondary).padding(.top, 10)
            }
            if !actionError.isEmpty {
                Text(actionError).vosFont(12).foregroundStyle(palette.warning).padding(.top, 10)
            }
        }
    }

    private func dailyRow(_ entry: ActionTimeEntry, overdue: Bool) -> some View {
        let subtitle = dailySubtitle(entry)
        return HStack(alignment: .top, spacing: 12) {
            Button { openTask(entry.action.id) } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: overdue ? "exclamationmark.circle" : "circle").vosFont(16)
                        .foregroundStyle(overdue ? palette.warning : palette.accent)
                        .frame(width: 34, height: 34)
                        .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.action.title).vosFont(16, weight: .semibold).lineLimit(2).multilineTextAlignment(.leading)
                        if !subtitle.isEmpty {
                            Text(subtitle).vosFont(13).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if overdue {
                Text("逾期").vosFont(12, weight: .medium).foregroundStyle(palette.warning).padding(.top, 5)
            }
            Button("完成") { apply(entry, .completed) }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.savingAction)
            Button("不再跟进") { apply(entry, .dismissed) }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.savingAction)
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
    }

    private func apply(_ entry: ActionTimeEntry, _ state: LocalActionState) {
        Task {
            await model.changeAction(entry.action, state: state)
            let current = model.actionRecords.first { $0.id == entry.action.id }
            actionError = current?.state == state.rawValue ? "" : "状态未能更新，请到任务页核对"
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
        let rows = Array(nextWeekCandidates.prefix(5))
        return WorkspaceSection(title: "下周先做", subtitle: "从即将与随时里挑最多 3 条，确认后加入专注。", icon: "calendar.badge.plus", count: nextWeekEntries.count) {
            undoHint
            if focusSlots == 0 {
                Text("已有 3 条专注，先到行动页移出。").vosFont(12).foregroundStyle(palette.warning).padding(.top, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                nextWeekRow(entry)
            }
            HStack(spacing: 10) {
                Text(selectedFocusIDs.isEmpty ? "最多还能加入 \(focusSlots) 条" : "已选 \(selectedFocusIDs.count) 条")
                    .vosFont(12).foregroundStyle(.secondary)
                Spacer()
                Button("加入专注") { applyNextWeekFocus() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(selectedFocusIDs.isEmpty || focusSaving)
            }.padding(.top, 10)
            if !focusError.isEmpty {
                Text(focusError).vosFont(12).foregroundStyle(palette.warning).padding(.top, 10)
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
                Image(systemName: focused ? "pin.fill" : selected ? "checkmark.circle.fill" : "circle").vosFont(16)
                    .foregroundStyle(focused || selected ? palette.accent : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.action.title).vosFont(16, weight: .semibold).lineLimit(2).multilineTextAlignment(.leading)
                    Text(subtitle.isEmpty ? "随时" : subtitle).vosFont(13).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if focused {
                    Text("已专注").vosFont(12, weight: .medium).foregroundStyle(palette.accent).padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .padding(.vertical, 10).padding(.horizontal, 10)
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

    private var todaySection: some View {
        WorkspaceSection(title: "今天与逾期", subtitle: "按本地排期与提醒事项回读，今天到期和已经过去的期限。", icon: "sun.max", count: todayEntries.count) {
            undoHint
            ForEach(Array(todayEntries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                reviewRow(title: entry.action.title, subtitle: dueLabel(entry),
                          trailing: entry.isOverdue ? "已逾期" : "今天",
                          trailingColor: entry.isOverdue ? palette.warning : nil,
                          icon: entry.isOverdue ? "exclamationmark.circle" : "circle") { openTask(entry.action.id) }
            }
        }
    }
    private var staleSection: some View {
        let rows = Array(staleTasks.prefix(5))
        return WorkspaceSection(title: "长期未动", subtitle: "创建超过 14 天，仍是未完成状态。", icon: "hourglass", count: staleTasks.count) {
            undoHint
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                reviewRow(title: action.title, subtitle: staleLabel(action), trailing: "搁置", icon: "hourglass") { openTask(action.id) }
            }
        }
    }
    private var unclarifiedSection: some View {
        let rows = Array(unclarifiedTasks.prefix(5))
        return WorkspaceSection(title: "待确认", subtitle: "最近 14 天从原话抽取，还没有确认是承诺、问题与目标，还是不是。", icon: "questionmark.circle", count: unclarifiedTasks.count) {
            undoHint
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                reviewRow(title: action.title, subtitle: "打开任务页完成一次三选一澄清。", trailing: "待确认", icon: "questionmark.circle") { openTask(action.id) }
            }
        }
    }
    private var progressSection: some View {
        let rows = Array(weekProgress.prefix(5))
        return WorkspaceSection(title: "本周完成与结果", subtitle: "最近 7 天记录的完成、进展与结果。", icon: "checkmark.seal", count: weekProgress.count) {
            undoHint
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                reviewRow(title: row.taskTitle, subtitle: row.relationLabel, detail: row.text,
                          trailing: dayLabel(row.date), enabled: row.isTaskAvailable) { openTask(row.actionID) }
            }
        }
    }
    private var pausedSection: some View {
        let rows = Array(pausedTasks.prefix(5))
        return WorkspaceSection(title: "暂停与冻结", subtitle: "AI 提取暂停或不再随当前理解更新的行动，状态保留。", icon: "pause.circle", count: pausedTasks.count) {
            undoHint
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                reviewRow(title: action.title, subtitle: model.workspaceActionStatus(action),
                          trailing: action.validity == "current" ? "待核对" : "已冻结", icon: "pause.circle") { openTask(action.id) }
            }
        }
    }

    private func reviewRow(title: String, subtitle: String, detail: String = "", trailing: String = "",
                           trailingColor: Color? = nil, icon: String = "circle", enabled: Bool = true,
                           open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).vosFont(16).foregroundStyle(palette.accent)
                    .frame(width: 34, height: 34)
                    .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).vosFont(16, weight: .semibold).lineLimit(2).multilineTextAlignment(.leading)
                    if !subtitle.isEmpty {
                        Text(subtitle).vosFont(13).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if !detail.isEmpty {
                        Text(detail).vosFont(13).lineSpacing(3).lineLimit(3).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if !trailing.isEmpty {
                    Text(trailing).vosFont(12, weight: .medium).foregroundStyle(trailingColor ?? Color.secondary).padding(.top, 3)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 3)
            }
            .padding(.vertical, 14).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled)
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
