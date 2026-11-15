import SwiftUI
import VoiceOSCore

/// Content-first home: recordings on the left, the selected one read as
/// threads of thought on the right. A thread is a pure grouping of the
/// recording's insights, goals and notes, so the same recording always reads
/// the same way.
struct RecentContentHome: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let openSource: (String) -> Void
    let openTask: (String) -> Void
    let capture: () -> Void
    @State private var selectedID: String?
    private let topAnchor = "home.top"

    private var days: [RecentContentDay] { model.homeSnapshot.days }
    private var items: [RecentContentItem] { days.flatMap(\.items) }
    private var selected: RecentContentItem? {
        items.first { $0.id == selectedID } ?? items.first { !$0.thoughts.isEmpty } ?? items.first
    }

    var body: some View {
        if items.isEmpty {
            empty
        } else {
            HStack(spacing: 0) {
                timeline.frame(width: 264)
                Rectangle().fill(palette.border).frame(width: 1)
                reader
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Text("还没有可以回看的内容").vosFont(WorkspaceText.sectionTitle)
            Text("录一段，或写几句。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            Button("记录想法") { capture() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dayLabel(day.date)).vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(palette.secondaryText).padding(.horizontal, 10)
                        ForEach(day.items) { item in
                            Button { selectedID = item.id } label: { row(item) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("recent.item")
                        }
                    }
                }
            }.padding(14)
        }
    }

    private func row(_ item: RecentContentItem) -> some View {
        let isSelected = selected?.id == item.id
        return VStack(alignment: .leading, spacing: 3) {
            Text(item.title).vosFont(WorkspaceText.rowTitle)
                .foregroundStyle(palette.text).lineLimit(2).multilineTextAlignment(.leading)
            Text(rowMeta(item)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isSelected ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
    }

    private func rowMeta(_ item: RecentContentItem) -> String {
        timeLabel(item.date)
    }

    private var reader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let item = selected {
                    readerContent(item)
                        .frame(maxWidth: WorkspaceMetrics.readerWidth, alignment: .leading)
                        .padding(WorkspaceMetrics.pagePadding)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id(topAnchor)
                }
            }
            .onChange(of: selected?.id) { _, _ in
                proxy.scrollTo(topAnchor, anchor: .top)
            }
        }
    }

    @ViewBuilder private func readerContent(_ item: RecentContentItem) -> some View {
        if item.kind == .feedback {
            let rows = model.homeSnapshot.progressRows[item.id] ?? []
            VStack(alignment: .leading, spacing: 18) {
                Text([dateLabel(item.date), "任务进展"].joined(separator: " · "))
                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                Text(item.title).vosFont(WorkspaceText.pageTitle).lineSpacing(4).textSelection(.enabled)
                if rows.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(item.excerpts.enumerated()), id: \.offset) { index, excerpt in
                            if index > 0 { Divider() }
                            Text(excerpt).vosFont(WorkspaceText.body).lineSpacing(5).textSelection(.enabled)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            progressRow(row)
                        }
                    }
                }
            }
        } else {
            materialReader(item)
        }
    }

    private func progressRow(_ row: RecentContentProgressRow) -> some View {
        Button { openTask(row.actionID) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.taskTitle).vosFont(WorkspaceText.rowTitle)
                    Text(row.relationLabel).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
                Text(row.text).vosFont(WorkspaceText.body).lineSpacing(5).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.isTaskAvailable)
    }

    private func materialReader(_ item: RecentContentItem) -> some View {
        let digest = model.homeSnapshot.digests[item.id] ?? RecentContentDigest.build(thoughts: item.thoughts, duration: item.duration)
        return VStack(alignment: .leading, spacing: 0) {
            Text(readerMeta(item)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            Text(item.title).vosFont(WorkspaceText.pageTitle).lineSpacing(4)
                .padding(.top, 16).textSelection(.enabled)
            if !item.summary.isEmpty {
                Text(item.summary).vosFont(WorkspaceText.body).lineSpacing(5)
                    .textSelection(.enabled)
                    .padding(.top, 24)
            }
            ForEach(digest.threads) { thread in
                threadSection(thread)
                    .padding(.top, 44)
                    .id("home.thread.\(thread.id)")
            }
            tasksSummary(digest.tasks)
            if let first = item.sourceIDs.first {
                Button("打开材料") { openSource(first) }.buttonStyle(.plain)
                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.accent).padding(.top, 40)
            }
        }
    }

    private func readerMeta(_ item: RecentContentItem) -> String {
        var parts = [dateLabel(item.date), timeLabel(item.date)]
        let duration = RecentContentDigest.durationLabel(item.duration)
        if !duration.isEmpty { parts.append(duration) }
        return parts.joined(separator: " · ")
    }

    private func threadSection(_ thread: RecentContentThread) -> some View {
        let notes = thread.thoughts.filter { $0.kind != .goal }
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 18)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(thread.title).vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.text)
                Spacer(minLength: 8)
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, thought in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").vosFont(WorkspaceText.caption.size, weight: WorkspaceText.caption.weight, monospacedDigit: true)
                                .foregroundStyle(palette.tertiaryText).frame(width: 18, alignment: .trailing)
                                .padding(.top, 3)
                            Text(thought.statement).vosFont(WorkspaceText.body).lineSpacing(5).textSelection(.enabled)
                        }
                    }
                }.padding(.top, 18).padding(.leading, 42)
            }
            if !thread.goals.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("想慢慢做到").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                    ForEach(thread.goals) { thought in
                        Text(thought.statement).vosFont(WorkspaceText.body).lineSpacing(5).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 13).padding(.horizontal, 17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                .padding(.top, 20).padding(.leading, 42)
            }
        }.accessibilityIdentifier("home.thread")
    }

    @ViewBuilder private func tasksSummary(_ tasks: [RecentContentTask]) -> some View {
        if let first = tasks.first {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 20)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("这条材料带出了 \(tasks.count) 条待办").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    Spacer(minLength: 0)
                    Button("查看") { openTask(first.id) }
                        .buttonStyle(.plain)
                        .vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.accent)
                        .accessibilityIdentifier("home.tasks.view")
                }
            }.padding(.top, 54)
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private func dateLabel(_ date: Date) -> String { dayLabel(date) }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
