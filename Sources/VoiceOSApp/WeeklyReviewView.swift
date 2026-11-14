import SwiftUI
import VoiceOSCore

/// Read-only weekly review over the action workspace. Each section caps at five
/// rows and opens the task it names; the panel itself never writes.
struct WeeklyReviewView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ControlCenter
    let openTask: (String) -> Void

    private var openTasks: [ActionRecord] {
        model.actionRecords.filter { $0.kind == "task" && $0.state == "open" && $0.validity == "current" }
    }
    private var surface: ActionTimeSurface {
        ActionTimeSurface.build(actions: openTasks, schedules: model.scheduleIntents, links: model.reminderLinks, now: Date(), calendar: .current)
    }
    private var todayEntries: [ActionTimeEntry] { Array(surface.today.prefix(5)) }
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
        todayEntries.isEmpty && staleTasks.isEmpty && unclarifiedTasks.isEmpty && weekProgress.isEmpty && pausedTasks.isEmpty
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    WorkspaceHeading(eyebrow: "行动 · 每周回顾", title: "这一周，行动走到了哪里", subtitle: "只读回顾；点开任意一条查看任务、原话与结果。")
                    Button("关闭") { dismiss() }
                }
                if isEmpty {
                    Text("这一周没有需要回顾的行动。").font(.callout).foregroundStyle(.secondary)
                }
                if !todayEntries.isEmpty { todaySection }
                if !staleTasks.isEmpty { staleSection }
                if !unclarifiedTasks.isEmpty { unclarifiedSection }
                if !weekProgress.isEmpty { progressSection }
                if !pausedTasks.isEmpty { pausedSection }
            }.frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading).padding(WorkspaceMetrics.pagePadding)
        }
        .frame(minWidth: WorkspaceMetrics.modalSmall, minHeight: 560)
    }

    private var todaySection: some View {
        WorkspaceSection(title: "今天与逾期", subtitle: "按本地排期与提醒事项回读，今天到期和已经过去的期限。", icon: "sun.max", count: todayEntries.count) {
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
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                reviewRow(title: action.title, subtitle: staleLabel(action), trailing: "搁置", icon: "hourglass") { openTask(action.id) }
            }
        }
    }
    private var unclarifiedSection: some View {
        let rows = Array(unclarifiedTasks.prefix(5))
        return WorkspaceSection(title: "待确认", subtitle: "最近 14 天从原话抽取，还没有确认是承诺、问题与目标，还是不是。", icon: "questionmark.circle", count: unclarifiedTasks.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider() }
                reviewRow(title: action.title, subtitle: "打开任务页完成一次三选一澄清。", trailing: "待确认", icon: "questionmark.circle") { openTask(action.id) }
            }
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
