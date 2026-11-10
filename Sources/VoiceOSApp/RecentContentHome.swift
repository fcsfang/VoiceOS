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
    let capture: () -> Void
    @State private var selectedID: String?
    @State private var expandedThreads: Set<String> = []
    @State private var showsAllTasks = false
    private let topAnchor = "home.top"

    private var days: [RecentContentDay] { RecentContentIndex.build(sources: model.records, claims: model.claims) }
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
            Text("还没有可以回看的内容").font(.title3.weight(.medium))
            Text("录一段想法，或写下几句。整理完成后，这里按时间显示你说过的想法。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("记录想法") { capture() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dayLabel(day.date)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
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
            if item.kind == .feedback {
                Text(timeLabel(item.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(item.title).font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(palette.text).lineLimit(2).multilineTextAlignment(.leading)
                Text("\(item.excerpts.count) 段反馈").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(item.title).font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(palette.text).lineLimit(2).multilineTextAlignment(.leading)
                Text(rowMeta(item)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isSelected ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
    }

    private func rowMeta(_ item: RecentContentItem) -> String {
        let digest = RecentContentDigest.build(thoughts: item.thoughts, duration: item.duration)
        guard digest.thoughtCount > 0 else { return timeLabel(item.date) }
        return "\(timeLabel(item.date)) · \(digest.thoughtCount) 条想法 · \(digest.threads.count) 条线索"
    }

    private var reader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let item = selected {
                    readerContent(item, scroll: proxy)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(30)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id(topAnchor)
                }
            }
            .onChange(of: selected?.id) { _, _ in
                expandedThreads = []
                showsAllTasks = false
                proxy.scrollTo(topAnchor, anchor: .top)
            }
        }
    }

    @ViewBuilder private func readerContent(_ item: RecentContentItem, scroll: ScrollViewProxy) -> some View {
        if item.kind == .feedback {
            VStack(alignment: .leading, spacing: 18) {
                Text([dateLabel(item.date), timeLabel(item.date), "行动反馈"].joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(item.title).font(.system(size: 27, weight: .semibold, design: .serif)).lineSpacing(4).textSelection(.enabled)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(item.excerpts.enumerated()), id: \.offset) { index, excerpt in
                        if index > 0 { Divider() }
                        Text(excerpt).font(.system(size: 14.5)).lineSpacing(4).textSelection(.enabled)
                    }
                }
            }
        } else {
            materialReader(item, scroll: scroll)
        }
    }

    private func materialReader(_ item: RecentContentItem, scroll: ScrollViewProxy) -> some View {
        let digest = RecentContentDigest.build(thoughts: item.thoughts, duration: item.duration, tasks: tasks(for: item))
        return VStack(alignment: .leading, spacing: 0) {
            Text(readerMeta(item, digest: digest)).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(item.title).font(.system(size: 27, weight: .semibold, design: .serif)).lineSpacing(4)
                .padding(.top, 16).textSelection(.enabled)
            Text(standfirst(digest)).font(.system(size: 14.5)).lineSpacing(5).foregroundStyle(.secondary).padding(.top, 18)
            if !digest.threads.isEmpty { threadIndex(digest, scroll: scroll) }
            ForEach(Array(digest.threads.enumerated()), id: \.element.id) { index, thread in
                threadSection(thread, number: index + 1)
                    .padding(.top, 44)
                    .id("home.thread.\(thread.id)")
            }
            nextSection(digest.tasks)
            overview(item)
            if let first = item.sourceIDs.first {
                Button("打开材料") { openSource(first) }.buttonStyle(.plain)
                    .font(.system(size: 13)).foregroundStyle(palette.accent).padding(.top, 40)
            }
        }
    }

    private func readerMeta(_ item: RecentContentItem, digest: RecentContentDigest) -> String {
        var parts = [dateLabel(item.date), timeLabel(item.date)]
        let duration = RecentContentDigest.durationLabel(item.duration)
        if !duration.isEmpty { parts.append(duration) }
        parts.append("\(digest.thoughtCount) 条想法")
        return parts.joined(separator: " · ")
    }

    private func standfirst(_ digest: RecentContentDigest) -> String {
        let duration = RecentContentDigest.durationLabel(digest.duration)
        let opening = duration.isEmpty ? "这次留下 \(digest.thoughtCount) 条想法" : "这次录了 \(duration)，留下 \(digest.thoughtCount) 条想法"
        return digest.threads.isEmpty ? opening + "。" : opening + "，可以归成 \(digest.threads.count) 条线索。"
    }

    private func threadIndex(_ digest: RecentContentDigest, scroll: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(digest.threads.enumerated()), id: \.element.id) { index, thread in
                if index > 0 { Text("·").font(.system(size: 12)).foregroundStyle(.tertiary) }
                Button {
                    withAnimation(.easeOut(duration: 0.3)) { scroll.scrollTo("home.thread.\(thread.id)", anchor: .top) }
                } label: {
                    HStack(spacing: 5) {
                        Text(thread.title).font(.system(size: 12))
                        Text("\(thread.thoughts.count)").font(.system(size: 10.5))
                    }.foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.top, 24)
    }

    private func threadSection(_ thread: RecentContentThread, number: Int) -> some View {
        let expanded = expandedThreads.contains(thread.id)
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 18)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(String(format: "%02d", number)).font(.system(size: 13, design: .serif)).tracking(1.2)
                    .foregroundStyle(palette.accent).frame(width: 28, alignment: .leading)
                Text(thread.title).font(.system(size: 15.5, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(thread.thoughts.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let lead = thread.lead {
                Text(lead.statement).font(.system(size: 19, design: .serif)).lineSpacing(7).textSelection(.enabled)
                    .padding(.leading, 16)
                    .overlay(alignment: .leading) { Rectangle().fill(palette.accent).frame(width: 2) }
                    .padding(.top, 20).padding(.leading, 42)
            }
            if !thread.supporting.isEmpty {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(thread.supporting) { thought in
                        Text(thought.statement).font(.system(size: 14.5)).lineSpacing(5).textSelection(.enabled)
                    }
                }.padding(.top, 20).padding(.leading, 42)
            }
            if !thread.goals.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("想慢慢做到").font(.system(size: 10)).tracking(1.4).foregroundStyle(palette.accent)
                    ForEach(Array(thread.goals.prefix(2))) { thought in
                        Text(thought.statement).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 13).padding(.horizontal, 17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                .padding(.top, 20).padding(.leading, 42)
            }
            if thread.hiddenCount > 0 {
                Button(expanded ? "收起" : "展开这一线索的 \(thread.hiddenCount) 条") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expanded { expandedThreads.remove(thread.id) } else { expandedThreads.insert(thread.id) }
                    }
                }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(palette.accent)
                    .padding(.top, 15).padding(.leading, 42)
                    .accessibilityIdentifier("home.thread.expand")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(thread.remaining) { thought in
                        HStack(alignment: .top, spacing: 10) {
                            Text(kindLabel(thought.kind)).font(.system(size: 10)).tracking(0.8)
                                .foregroundStyle(.secondary).frame(width: 30, alignment: .leading).padding(.top, 2)
                            Text(thought.statement).font(.system(size: 13.5)).lineSpacing(4).textSelection(.enabled)
                        }
                    }
                }.padding(.top, 13).padding(.leading, 42)
            }
        }.accessibilityIdentifier("home.thread")
    }

    @ViewBuilder private func nextSection(_ tasks: [RecentContentTask]) -> some View {
        if !tasks.isEmpty {
            let visible = showsAllTasks ? tasks : Array(tasks.prefix(4))
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 24)
                Text("接下来").font(.system(size: 10.5)).tracking(1.6).foregroundStyle(.secondary)
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, task in
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 15) {
                            Circle().strokeBorder(palette.border, lineWidth: 1).frame(width: 14, height: 14).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).font(.system(size: 14.5)).lineSpacing(3).textSelection(.enabled)
                                Text("来自这次录音 · 待办").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 15)
                        if index < visible.count - 1 { Rectangle().fill(palette.border).frame(height: 1) }
                    }.accessibilityIdentifier("home.task")
                }
                if tasks.count > 4 {
                    Button(showsAllTasks ? "收起" : "全部 \(tasks.count) 条") {
                        withAnimation(.easeInOut(duration: 0.2)) { showsAllTasks.toggle() }
                    }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(palette.accent).padding(.top, 14)
                }
            }.padding(.top, 54)
        }
    }

    @ViewBuilder private func overview(_ item: RecentContentItem) -> some View {
        if !item.summary.isEmpty {
            DisclosureGroup {
                Text(item.summary).font(.system(size: 13.5)).lineSpacing(5).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: 640, alignment: .leading).padding(.top, 10)
            } label: {
                Text("录音概览（AI 整理）").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.top, 44)
        }
    }

    private func tasks(for item: RecentContentItem) -> [RecentContentTask] {
        let claimIDs = Set(item.thoughts.map(\.claimID))
        return model.actionRecords
            .filter { $0.state == "open" && $0.validity == "current" && $0.kind == "task" && claimIDs.contains($0.claimID) }
            .map { RecentContentTask(id: $0.id, title: $0.title) }
    }

    private func kindLabel(_ kind: RecentThoughtKind) -> String {
        switch kind {
        case .insight: "观点"
        case .goal: "目标"
        case .note: "想法"
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
