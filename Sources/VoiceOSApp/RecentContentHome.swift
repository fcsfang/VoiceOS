import SwiftUI
import VoiceOSCore

/// The row the reader currently shows. The workspace header's discussion action
/// lives outside this view and starts from the same material.
final class RecentContentHomeSelection {
    static let shared = RecentContentHomeSelection()
    var itemID: String?
}

/// Content-first home: recordings on the left, the selected one read as
/// threads of thought on the right. A thread is a pure grouping of the
/// recording's insights, goals and notes, so the same recording always reads
/// the same way.
struct RecentContentHome: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let openSource: (String) -> Void
    let openSpan: (String, String) -> Void
    let openTask: (String) -> Void
    let capture: () -> Void
    @State private var selectedID: String? = RecentContentHomeSelection.shared.itemID
    @SceneStorage("recentHome.selectedItem") private var storedSelection = ""
    @SceneStorage("recentHome.timelineAnchor") private var storedTimelineAnchor = ""
    @State private var timelineRestored = false
    @State private var readingStates: [String: SourceReadingState] = [:]
    @FocusState private var timelineFocused: Bool
    private let topAnchor = "home.top"
    private let timelineSpace = "home.timeline"

    private var days: [RecentContentDay] { model.homeSnapshot.days }
    private var items: [RecentContentItem] { days.flatMap(\.items) }
    private var selected: RecentContentItem? {
        items.first { $0.id == selectedID }
            ?? items.first { !storedSelection.isEmpty && $0.id == storedSelection }
            ?? items.first { $0.id == RecentContentHomeSelection.shared.itemID }
            ?? items.first { !$0.thoughts.isEmpty } ?? items.first
    }

    var body: some View {
        Group {
            if items.isEmpty {
                empty.onAppear { StartupTrace.mark("home.appear.empty") }
            } else {
                HStack(spacing: 0) {
                    timeline.frame(width: 264)
                    Rectangle().fill(palette.border).frame(width: 1)
                    reader
                }.onAppear { StartupTrace.mark("home.appear items=\(items.count)") }
            }
        }
        .onAppear { syncSelection() }
        .onChange(of: selected?.id) { _, _ in syncSelection() }
        .task(id: model.initialized) { if model.initialized { readingStates = await model.readingStates() } }
    }

    private func syncSelection() {
        RecentContentHomeSelection.shared.itemID = selected?.id
        if let id = selected?.id, id != storedSelection { storedSelection = id }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Text("还没有可以回看的内容").vosFont(WorkspaceText.sectionTitle)
            Text("录一段，或写几句。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            Button("记录想法") { capture() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dayLabel(day.date)).vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(palette.secondaryText).accessibilityAddTraits(.isHeader).padding(.horizontal, 10)
                            ForEach(day.items) { item in
                                Button { selectedID = item.id } label: { row(item) }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: TimelineAnchorKey.self, value: [item.id: geometry.frame(in: .named(timelineSpace)).minY])
                                        }
                                    }
                                    .accessibilityIdentifier("recent.item")
                            }
                        }
                    }
                }.padding(14)
            }
            .coordinateSpace(name: timelineSpace)
            .onPreferenceChange(TimelineAnchorKey.self) { updateTimelineAnchor($0) }
            .onAppear { restoreTimeline(proxy) }
            .onChange(of: items.count) { _, _ in restoreTimeline(proxy) }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                timelineFocused = true
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .focusable()
            .focused($timelineFocused)
            .focusEffectDisabled()
            .onKeyPress { handleTimelineKey($0) }
            .onAppear { requestTimelineFocus() }
        }
    }

    private func updateTimelineAnchor(_ positions: [String: CGFloat]) {
        // Keep the saved anchor until the restore has run, so first layout cannot overwrite it with the top row.
        guard timelineRestored || storedTimelineAnchor.isEmpty else { return }
        guard let anchor = positions.min(by: { abs($0.value) < abs($1.value) })?.key else { return }
        if anchor != storedTimelineAnchor { storedTimelineAnchor = anchor }
    }

    private func restoreTimeline(_ proxy: ScrollViewProxy) {
        guard !timelineRestored else { return }
        if storedTimelineAnchor.isEmpty || !items.isEmpty { timelineRestored = true }
        guard !storedTimelineAnchor.isEmpty, items.contains(where: { $0.id == storedTimelineAnchor }) else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(storedTimelineAnchor, anchor: .top)
        }
    }

    private func requestTimelineFocus() {
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            timelineFocused = true
        }
    }

    private func handleTimelineKey(_ press: KeyPress) -> KeyPress.Result {
        guard timelineFocused, press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let ids = items.map(\.id)
        switch press.key {
        case .downArrow, .upArrow:
            guard !ids.isEmpty else { return .ignored }
            let current = selected.flatMap { item in ids.firstIndex(of: item.id) }
            let next: Int
            if press.key == .upArrow { next = current.map { max(0, $0 - 1) } ?? ids.count - 1 }
            else { next = current.map { min(ids.count - 1, $0 + 1) } ?? 0 }
            selectedID = ids[next]
            return .handled
        case .return:
            guard let item = selected, item.kind == .material, let sourceID = item.sourceIDs.first else { return .ignored }
            openSource(sourceID)
            return .handled
        default:
            return .ignored
        }
    }

    private func row(_ item: RecentContentItem) -> some View {
        let isSelected = selected?.id == item.id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: rowIcon(item)).vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                .frame(width: 28, height: 28).background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(rowTitle(item)).vosFont(WorkspaceText.rowTitle)
                    .foregroundStyle(palette.text).lineLimit(2).multilineTextAlignment(.leading)
                Text(rowMeta(item)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 6)
            if let status = statusSlot(item) {
                Text(status.text).vosFont(WorkspaceText.meta).foregroundStyle(status.color).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isSelected ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay { if isSelected { RoundedRectangle(cornerRadius: 9).strokeBorder(palette.focusRing, lineWidth: 1) } }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
    }

    private func rowIcon(_ item: RecentContentItem) -> String {
        if item.kind == .feedback { return "arrow.triangle.2.circlepath" }
        return materialSource(item)?.kind.contains("text") == true ? "doc.text" : "waveform"
    }

    private func materialSource(_ item: RecentContentItem) -> SourceRecord? {
        guard let id = item.sourceIDs.first else { return nil }
        return model.records.first { $0.id == id }
    }

    /// Slot 3 holds only a non-default state, one at a time.
    private func statusSlot(_ item: RecentContentItem) -> (text: String, color: Color)? {
        guard item.kind == .material, let source = materialSource(item) else { return nil }
        if source.localOnly { return ("仅本地", palette.secondaryText) }
        if ["queued", "running", "reserved"].contains(source.jobState ?? "") { return ("整理中", palette.accent) }
        if source.needsTranscriptionReview { return ("待核对", palette.warning) }
        let issues = source.unresolvedTranscriptionIssueCount
        if issues > 0 { return ("疑点 \(issues)", palette.warning) }
        if readingStates[source.id] == .reading { return ("在读", palette.accent) }
        return nil
    }

    private func rowTitle(_ item: RecentContentItem) -> String {
        item.kind == .feedback ? item.title + " · \(progressCount(item)) 条" : item.title
    }

    private func progressCount(_ item: RecentContentItem) -> Int {
        model.homeSnapshot.progressRows[item.id]?.count ?? item.excerpts.count
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
            feedbackReader(item)
        } else {
            materialReader(item)
        }
    }

    private func feedbackReader(_ item: RecentContentItem) -> some View {
        let rows = model.homeSnapshot.progressRows[item.id] ?? []
        let count = rows.isEmpty ? item.excerpts.count : rows.count
        return VStack(alignment: .leading, spacing: 16) {
            Text([dateLabel(item.date), timeLabel(item.date)].joined(separator: " · "))
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            Text("\(item.title) · \(count) 条")
                .vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(item.excerpts.enumerated()), id: \.offset) { index, excerpt in
                        if index > 0 { Divider() }
                        Text(excerpt)
                            .vosFont(index == 0 ? WorkspaceText.pageTitle : WorkspaceText.body)
                            .lineSpacing(index == 0 ? 4 : 5)
                            .textSelection(.enabled)
                    }
                }
            } else if let first = rows.first {
                progressRow(first, style: WorkspaceText.pageTitle)
                ForEach(rows.dropFirst()) { row in
                    Divider().padding(.top, 4)
                    progressRow(row, style: WorkspaceText.body)
                }
            }
        }
    }

    @ViewBuilder private func progressRow(_ row: RecentContentProgressRow, style: WorkspaceTextStyle) -> some View {
        if row.isTaskAvailable {
            Button { openTask(row.actionID) } label: {
                progressRowContent(row, style: style)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(alignment: .top, spacing: 10) {
                progressRowContent(row, style: style)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(taskUnavailableReason(row)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    if model.records.contains(where: { $0.id == row.id }) {
                        Button("查看材料") { openSource(row.id) }
                            .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                    }
                }
            }
        }
    }

    private func progressRowContent(_ row: RecentContentProgressRow, style: WorkspaceTextStyle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.text).vosFont(style).lineSpacing(style.size > 20 ? 4 : 5).textSelection(.enabled)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.taskTitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                Text(row.relationLabel).vosFont(WorkspaceText.meta).foregroundStyle(palette.tertiaryText)
            }
        }
    }

    private func taskUnavailableReason(_ row: RecentContentProgressRow) -> String {
        guard let action = model.actionRecords.first(where: { $0.id == row.actionID }) else { return "任务已结束" }
        return model.workspaceTaskRequiresReview(action) ? "任务已暂停" : "任务已结束"
    }

    private func materialReader(_ item: RecentContentItem) -> some View {
        let digest = model.homeSnapshot.digests[item.id] ?? RecentContentDigest.build(thoughts: item.thoughts, duration: item.duration)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(readerMeta(item)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                Spacer(minLength: 8)
                if let source = materialSource(item), ["audio", "video"].contains(source.kind) {
                    Button("回听") { Task { await model.play(source) } }
                        .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                        .disabled(source.state != "saved")
                        .help(source.state == "saved" ? "播放这段录音" : "录音尚未就绪，暂时无法回听")
                }
                if let first = item.sourceIDs.first {
                    Button("打开材料") { openSource(first) }
                        .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                }
            }
            Text(item.title).vosFont(WorkspaceText.pageTitle).lineSpacing(4)
                .padding(.top, 16).textSelection(.enabled).accessibilityAddTraits(.isHeader)
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
                Text(thread.title).vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.secondaryText).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, thought in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").vosFont(WorkspaceText.caption.size, weight: WorkspaceText.caption.weight, monospacedDigit: true)
                                .foregroundStyle(palette.tertiaryText).frame(width: 18, alignment: .trailing)
                                .padding(.top, 3)
                            ThoughtLine(thought: thought, openOriginal: { openOriginal(thought) })
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

    private func openOriginal(_ thought: RecentContentThought) {
        guard let claim = model.claims.first(where: { $0.id == thought.claimID }),
              let reference = claim.references.first else { return }
        openSpan(reference.sourceID, reference.spanID)
    }

    @ViewBuilder private func tasksSummary(_ tasks: [RecentContentTask]) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 20)
                Text("这条材料带出了 \(tasks.count) 条待办").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "circle").vosFont(WorkspaceText.caption.size, weight: .regular)
                                .foregroundStyle(palette.tertiaryText)
                                .accessibilityHidden(true)
                            Text(task.title).vosFont(WorkspaceText.body).lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Button("详情") { openTask(task.id) }
                                .buttonStyle(.plain)
                                .vosFont(WorkspaceText.meta)
                                .foregroundStyle(palette.accent)
                                .accessibilityLabel("打开待办详情：" + task.title)
                        }.padding(.vertical, 10)
                        if task.id != tasks.last?.id { WorkspaceListDivider() }
                    }
                }.padding(.top, 8)
            }.padding(.top, 54)
            .accessibilityIdentifier("home.tasks.list")
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

private struct TimelineAnchorKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ThoughtLine: View {
    @Environment(\.workspacePalette) private var palette
    let thought: RecentContentThought
    let openOriginal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(thought.statement).vosFont(WorkspaceText.body).lineSpacing(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { openOriginal() } label: {
                Image(systemName: "text.quote")
                    .vosFont(WorkspaceText.caption)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .help("打开这条想法出自的材料")
            .accessibilityLabel("看原话")
        }
    }
}
