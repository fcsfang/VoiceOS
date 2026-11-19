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
    @State private var clueRename: ClueRenameRequest?
    @State private var clueFailureText = ""
    @State private var clueFailureTitle = "操作未完成"
    @State private var showingClueFailure = false
    @State private var organizeAttemptSourceID: String?
    @State private var organizeToast: String?
    @State private var organizeToastSourceID: String?
    @AppStorage("voiceos.home.recentThoughts.expanded") private var recentThoughtsExpanded = false
    @State private var frozenViewpointsItemID: String?
    @FocusState private var timelineFocused: Bool
    private let topAnchor = "home.top"
    private let timelineSpace = "home.timeline"
    private let tasksAnchor = "home.tasks.summary"

    private var days: [RecentContentDay] { model.homeSnapshot.days }
    private var items: [RecentContentItem] { days.flatMap(\.items) }
    private var selected: RecentContentItem? {
        items.first { $0.id == selectedID }
            ?? items.first { !storedSelection.isEmpty && $0.id == storedSelection }
            ?? items.first { $0.id == RecentContentHomeSelection.shared.itemID }
            ?? items.first { !$0.thoughts.isEmpty } ?? items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            homeHeader
            Group {
                if items.isEmpty {
                    empty.onAppear { StartupTrace.mark("home.appear.empty") }
                } else {
                    HStack(spacing: 0) {
                        timeline.frame(width: 288)
                        Rectangle().fill(palette.border).frame(width: 1)
                        reader
                    }.onAppear { StartupTrace.mark("home.appear items=\(items.count)") }
                }
            }
        }
        .onAppear {
            syncSelection()
            Task { await reloadReadingStates() }
        }
        .onChange(of: selected?.id) { _, _ in syncSelection() }
        .task(id: model.homeSnapshot) { await reloadReadingStates() }
        .onChange(of: model.understandingSource) { _, id in finishOrganizeAttempt(id) }
        .sheet(item: $clueRename) { request in
            RecentClueRenameSheet(model: model, clue: request.clue, title: request.title, resettable: request.resettable) { clueRename = nil }
        }
        .alert(clueFailureTitle, isPresented: $showingClueFailure) {
            Button("好", role: .cancel) {}
        } message: { Text(clueFailureText) }
    }

    private func syncSelection() {
        RecentContentHomeSelection.shared.itemID = selected?.id
        if let id = selected?.id, id != storedSelection { storedSelection = id }
    }

    private var homeHeader: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("每周回顾", systemImage: "calendar.badge.clock") { openWeeklyReview() }
                .buttonStyle(.plain).vosFont(WorkspaceText.meta.size, weight: .medium)
                .foregroundStyle(palette.accent)
                .help("打开每周回顾：完成、待补结果、停滞目标与待确认")
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(palette.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private func openWeeklyReview() {
        model.pendingWorkspaceRoute = .weeklyReview
    }

    private var empty: some View {
        VStack(spacing: 14) {
            if let message = model.workspaceLastError {
                Text("资料库读取失败").vosFont(WorkspaceText.sectionTitle)
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .vosFont(WorkspaceText.body).foregroundStyle(palette.danger).textSelection(.enabled)
                if model.workspaceLastErrorRetry != nil {
                    Button("重试") { model.retryWorkspaceError() }.buttonStyle(.workspacePrimary)
                }
            } else if hasAnyMaterial {
                Text("材料都还没有可读内容").vosFont(WorkspaceText.sectionTitle)
                Text("材料还在转写或识别，完成并保存后会出现在这里。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                Button("记录想法") { capture() }.buttonStyle(.workspacePrimary)
                Button("导入录音") { model.chooseFullRecording() }.buttonStyle(.workspaceSecondary)
            } else {
                Text("知识库里还没有材料").vosFont(WorkspaceText.sectionTitle)
                Text("录一段、导入一段录音，或写几句。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                Button("记录想法") { capture() }.buttonStyle(.workspacePrimary)
                Button("导入录音") { model.chooseFullRecording() }.buttonStyle(.workspaceSecondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        let pendingOutcomeBadge = outcomeBadge
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !recentThoughts.isEmpty { recentThoughtsEntry(recentThoughts) }
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 6) {
                            dayHeader(day)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(day.items) { item in
                                    Button { selectedID = item.id } label: { row(item, outcomeBadge: pendingOutcomeBadge) }
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

    private func dayHeader(_ day: RecentContentDay) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1).fill(palette.accent).frame(width: 2, height: 12)
                .accessibilityHidden(true)
            Text(dayLabel(day.date)).vosFont(WorkspaceText.meta.size, weight: .semibold)
                .foregroundStyle(palette.secondaryText).accessibilityAddTraits(.isHeader)
        }.padding(.horizontal, 10)
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

    private func row(_ item: RecentContentItem, outcomeBadge: String?) -> some View {
        let isSelected = selected?.id == item.id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: rowIcon(item)).vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                .frame(width: 28, height: 28).background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(rowTitle(item)).vosFont(WorkspaceText.rowTitle)
                    .foregroundStyle(palette.text).lineLimit(2).multilineTextAlignment(.leading)
                Text(rowMeta(item)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let trailing = rowTrailing(item, outcomeBadge: outcomeBadge) {
                switch trailing {
                case .badge(let text, let tone):
                    WorkspaceBadge(text: text, tone: tone).padding(.top, 1)
                case .text(let text, let color):
                    Text(text).vosFont(WorkspaceText.meta).foregroundStyle(color).padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeCard(isSelected: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
    }

    private func rowIcon(_ item: RecentContentItem) -> String {
        model.homeSnapshot.rows[item.id]?.icon
            ?? (item.kind == .feedback ? "arrow.triangle.2.circlepath" : "waveform")
    }

    private func materialSource(_ item: RecentContentItem) -> SourceRecord? {
        guard let id = item.sourceIDs.first else { return nil }
        return model.sourcePageIndex.recordsByID[id]
    }

    /// The trailing slot carries the value a material produced: its open tasks.
    /// Process states read inline as secondary text instead.
    private enum RowTrailing {
        case badge(String, WorkspaceBadge.Tone)
        case text(String, Color)
    }

    private func rowTrailing(_ item: RecentContentItem, outcomeBadge: String?) -> RowTrailing? {
        if item.kind == .feedback { return outcomeBadge.map { .text($0, palette.warning) } }
        guard let count = model.homeSnapshot.digests[item.id]?.tasks.count, count > 0 else { return nil }
        return .badge("\(count) 条待办", .accent)
    }

    private func rowStatusNote(_ item: RecentContentItem) -> String? {
        switch model.homeSnapshot.rows[item.id]?.status {
        case .some(.localOnly): return "仅本地"
        case .some(.organizing): return "整理中"
        case .some(.needsReview): return "待核对"
        case .some(.issues(let count)): return "疑点 \(count)"
        case nil: break
        }
        guard item.kind == .material, let source = materialSource(item), readingStates[source.id] == .reading else { return nil }
        return "在读"
    }

    private func rowTitle(_ item: RecentContentItem) -> String {
        let fit = WorkspaceTitleFit.present(item.title)
        return item.kind == .feedback ? fit.title + " · \(progressCount(item)) 条" : fit.title
    }

    private func progressCount(_ item: RecentContentItem) -> Int {
        model.homeSnapshot.rows[item.id]?.count ?? item.excerpts.count
    }

    private func rowMeta(_ item: RecentContentItem) -> String {
        var parts: [String] = []
        if let source = WorkspaceTitleFit.present(item.title).source { parts.append(source) }
        parts.append(timeLabel(item.date))
        if let note = rowStatusNote(item) { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private var reader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let item = selected {
                    readerContent(item, proxy: proxy)
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

    @ViewBuilder private func readerContent(_ item: RecentContentItem, proxy: ScrollViewProxy) -> some View {
        if item.kind == .feedback {
            feedbackReader(item)
        } else {
            materialReader(item, proxy: proxy)
        }
    }

    private func feedbackReader(_ item: RecentContentItem) -> some View {
        let rows = model.homeSnapshot.progressRows[item.id] ?? []
        let count = rows.isEmpty ? item.excerpts.count : rows.count
        return VStack(alignment: .leading, spacing: 16) {
            Text([dateLabel(item.date), timeLabel(item.date)].joined(separator: " · "))
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(item.title) · \(count) 条")
                    .vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                if let badge = outcomeBadge {
                    Button(badge) { openWeeklyReview() }
                        .buttonStyle(.plain)
                        .vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                        .help("打开每周回顾，记录这些结果")
                        .accessibilityLabel("待补结果，" + badge + "，打开每周回顾")
                }
                Spacer(minLength: 0)
            }
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
                    if model.sourcePageIndex.recordsByID[row.id] != nil {
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
        guard let action = model.sourcePageIndex.activeAction(for: row.actionID) else { return "任务已结束" }
        return model.sourcePageIndex.requiresReview(action.id) ? "任务已暂停" : "任务已结束"
    }

    private func materialReader(_ item: RecentContentItem, proxy: ScrollViewProxy) -> some View {
        let digest = model.homeSnapshot.digests[item.id] ?? RecentContentDigest.build(thoughts: item.thoughts, duration: item.duration, overrides: model.recentClueOverrides)
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
            let fit = WorkspaceTitleFit.present(item.title)
            Text(fit.title).vosFont(WorkspaceText.pageTitle).lineSpacing(4).lineLimit(4)
                .padding(.top, 16).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            if let source = fit.source {
                Text(source).vosFont(WorkspaceText.meta).foregroundStyle(palette.tertiaryText)
                    .padding(.top, 6).textSelection(.enabled)
            }
            if !item.summary.isEmpty {
                Text(item.summary).vosFont(WorkspaceText.body).lineSpacing(5)
                    .textSelection(.enabled)
                    .padding(.top, 24)
            }
            if !digest.tasks.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(tasksAnchor, anchor: .top) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "checklist")
                            .vosFont(WorkspaceText.caption.size, weight: .semibold)
                            .accessibilityHidden(true)
                        Text("\(digest.tasks.count) 条待办")
                            .vosFont(WorkspaceText.meta.size, weight: .semibold)
                        Text("跳到列表")
                            .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                    }
                    .foregroundStyle(palette.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 20)
                .help("跳到这条材料下方的待办列表")
                .accessibilityLabel("\(digest.tasks.count) 条待办，跳到列表")
                .accessibilityIdentifier("home.tasks.badge")
            }
            if item.thoughts.isEmpty {
                organizePrompt(item).padding(.top, 44)
            } else {
                ForEach(digest.threads) { thread in
                    threadSection(thread, siblings: digest.threads.filter { $0.id != thread.id })
                        .padding(.top, 44)
                        .id("home.thread.\(thread.id)")
                }
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

    private func threadSection(_ thread: RecentContentThread, siblings: [RecentContentThread]) -> some View {
        let notes = thread.thoughts.filter { $0.kind != .goal }
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 18)
            HStack(alignment: .center, spacing: 14) {
                Text(thread.title).vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.secondaryText).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                ClueHeaderMenu(title: thread.title,
                               siblings: siblings,
                               hidden: model.recentClueOverrides.filter(\.hidden),
                               rename: { beginClueRename(thread) },
                               merge: { target in mergeClue(thread, into: target) },
                               hide: { setClueHidden(thread.id, hidden: true) },
                               restore: { override in setClueHidden(override.clue, hidden: false) })
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
                .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                .padding(.top, 20).padding(.leading, 42)
            }
        }.accessibilityIdentifier("home.thread")
    }

    private func beginClueRename(_ thread: RecentContentThread) {
        let override = model.recentClueOverrides.first { $0.clue == thread.id }
        clueRename = ClueRenameRequest(clue: thread.id, title: thread.title, resettable: override?.displayTitle != nil)
    }

    private func mergeClue(_ thread: RecentContentThread, into target: RecentContentThread) {
        Task { if !(await model.mergeRecentClue(thread.id, into: target.id)) { showClueFailure() } }
    }

    private func setClueHidden(_ clue: String, hidden: Bool) {
        Task { if !(await model.setRecentClueHidden(clue, hidden: hidden)) { showClueFailure() } }
    }

    private func showClueFailure(title: String = "操作未完成", message: String? = nil) {
        clueFailureTitle = title
        clueFailureText = message ?? (model.status.isEmpty ? "操作未完成，请稍后重试。" : model.status)
        showingClueFailure = true
    }

    private func openOriginal(_ thought: RecentContentThought) {
        openClaim(thought.claimID)
    }

    private func openClaim(_ claimID: String) {
        guard let claim = model.sourcePageIndex.claim(for: claimID),
              let reference = claim.references.first else {
            showClueFailure(title: "无法打开原话", message: "这条想法的原话已不可用，可能已随整理更新或来源被删除。")
            return
        }
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
            .id(tasksAnchor)
        }
    }

    private var recentThoughts: [RecentThoughtDay] {
        model.homeSnapshot.recentThoughts
    }

    private var recentThoughtCount: Int {
        recentThoughts.reduce(0) { $0 + $1.entries.count }
    }

    /// The same material filter the index uses, so an empty home can tell an
    /// empty library apart from materials that have no readable content yet.
    private var hasAnyMaterial: Bool {
        model.records.contains {
            ["saved", "reference_only"].contains($0.state) && $0.origin == "user" && $0.speaker == "user"
                && $0.feedbackKind == nil && !$0.name.hasPrefix("行动反馈")
        }
    }

    private var outcomeBadge: String? {
        let pending = model.visibleOutcomeFollowups.count
        return pending > 0 ? "\(pending) 项结果待填" : nil
    }

    private func recentThoughtsEntry(_ groups: [RecentThoughtDay]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { recentThoughtsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(recentThoughtsExpanded ? 90 : 0))
                        .vosFont(WorkspaceText.caption.size, weight: .semibold)
                        .foregroundStyle(palette.tertiaryText)
                        .accessibilityHidden(true)
                    Text("最近想法").vosFont(WorkspaceText.meta.size, weight: .semibold)
                        .foregroundStyle(palette.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(recentThoughtCount) 条 · 近 14 天")
                        .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recentThoughtsExpanded ? "收起最近想法" : "展开最近想法，查看近 14 天的观点")
            .accessibilityIdentifier("home.recentThoughts.toggle")
            if recentThoughtsExpanded {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(dayLabel(group.date)) · \(group.entries.count) 条")
                            .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                            .padding(.horizontal, 10)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.entries) { entry in
                                Button { openClaim(entry.id) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.statement).vosFont(WorkspaceText.meta)
                                            .foregroundStyle(palette.text).lineLimit(3)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                        Text(entry.sourceTitle).vosFont(WorkspaceText.caption)
                                            .foregroundStyle(palette.secondaryText).lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .homeCard(isSelected: false)
                                }
                                .buttonStyle(.plain)
                                .help("打开这条想法的原话")
                                .accessibilityIdentifier("recent.thought")
                            }
                        }
                    }
                }
            }
            Rectangle().fill(palette.border).frame(height: 1).padding(.top, 8)
        }
    }

    @ViewBuilder private func organizePrompt(_ item: RecentContentItem) -> some View {
        if let source = materialSource(item) {
            let organizing = model.understandingSource == source.id
            let blocker = organizeBlocker(source, organizing: organizing)
            let frozen = frozenThoughts(item)
            VStack(alignment: .leading, spacing: 12) {
                if frozen.isEmpty {
                    Text("这份材料还没有整理出想法").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                } else {
                    Text("这份材料上次整理的观点已冻结").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                    Text("原话或处理许可变化后，旧观点不再作为当前观点显示。重新整理会生成新的观点，旧观点保留为历史。")
                        .vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                }
                HStack(spacing: 10) {
                    if !frozen.isEmpty {
                        Button(frozenViewpointsItemID == item.id ? "收起旧观点" : "查看旧观点") {
                            frozenViewpointsItemID = frozenViewpointsItemID == item.id ? nil : item.id
                        }
                        .buttonStyle(.workspaceSecondary)
                        .accessibilityIdentifier("home.frozenViewpoints.toggle")
                    }
                    Button(organizing ? "正在整理…" : (frozen.isEmpty ? "整理这份材料" : "重新整理这份材料")) {
                        attemptOrganize(source)
                    }
                    .buttonStyle(.workspacePrimary)
                    .disabled(organizing || blocker != nil || !model.modelConfigured || source.localOnly)
                    if organizing { ProgressView().controlSize(.small) }
                }
                if frozenViewpointsItemID == item.id, !frozen.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(frozen) { thought in
                            HStack(alignment: .top, spacing: 10) {
                                Text(thought.statement).vosFont(WorkspaceText.body).lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                Button("看原话") { openClaim(thought.claimID) }
                                    .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                                    .accessibilityLabel("查看这条旧观点的原话")
                            }
                            if thought.id != frozen.last?.id { WorkspaceListDivider() }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(palette.border, lineWidth: 1) }
                    .accessibilityIdentifier("home.frozenViewpoints")
                }
                if let blocker {
                    Text(blocker).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                }
                if source.localOnly {
                    Text("这份材料仅本机保存，允许云端后才能整理。")
                        .vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                } else if !model.modelConfigured {
                    HStack(spacing: 8) {
                        Text("整理需要先配置文本模型。").vosFont(WorkspaceText.caption).foregroundStyle(palette.warning)
                        Button("配置文本模型…") { model.chooseTextModel() }.vosFont(WorkspaceText.caption)
                    }
                } else if organizeToastSourceID == source.id, let toast = organizeToast {
                    Label(toast, systemImage: "exclamationmark.circle")
                        .vosFont(WorkspaceText.caption).foregroundStyle(palette.warning).textSelection(.enabled)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .accessibilityIdentifier("home.organizePrompt")
        }
    }

    /// Old viewpoints whose claims were frozen keep their audit trail but no
    /// longer read as current thoughts. Newest first, one row per statement.
    private func frozenThoughts(_ item: RecentContentItem) -> [RecentContentThought] {
        let sourceIDs = Set(item.sourceIDs)
        var seen: Set<String> = []
        return model.claims.reversed().compactMap { claim in
            guard claim.validity == "frozen", claim.ownership == "user_tentative", claim.reviewState != "rejected",
                  claim.references.contains(where: { sourceIDs.contains($0.sourceID) }),
                  let statement = RecentContentIndex.thoughtStatement(claim.statement),
                  seen.insert(statement).inserted else { return nil }
            return RecentContentThought(claimID: claim.id, statement: statement)
        }
    }

    private func reloadReadingStates() async {
        guard model.initialized else { return }
        readingStates = await model.readingStates()
    }

    private func organizeBlocker(_ source: SourceRecord, organizing: Bool) -> String? {
        guard !organizing else { return nil }
        if model.fullRecordingBusy { return "正在处理录音，完成后再整理。" }
        if let understanding = model.understandingSource, understanding != source.id {
            return "正在理解另一份材料，完成后再整理。"
        }
        if model.pausedActionBatch?.isRunning == true { return "批量重新识别进行中，完成后再整理。" }
        return nil
    }

    private func attemptOrganize(_ source: SourceRecord) {
        organizeAttemptSourceID = source.id
        organizeToast = nil
        organizeToastSourceID = nil
        model.reidentify(source)
        guard model.understandingSource != source.id else { return }
        organizeAttemptSourceID = nil
        showOrganizeToast("整理没有开始：另有理解或批量任务进行中，请稍后再试。", sourceID: source.id)
    }

    private func finishOrganizeAttempt(_ understandingSourceID: String?) {
        guard understandingSourceID == nil, let attempted = organizeAttemptSourceID else { return }
        organizeAttemptSourceID = nil
        showOrganizeToast(model.status.isEmpty ? "整理未完成，请稍后再试。" : model.status, sourceID: attempted)
    }

    private func showOrganizeToast(_ text: String, sourceID: String) {
        organizeToast = text
        organizeToastSourceID = sourceID
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

private struct ClueRenameRequest: Identifiable {
    let clue: String
    let title: String
    let resettable: Bool
    var id: String { clue }
}

private struct ClueHeaderMenu: View {
    @Environment(\.workspacePalette) private var palette
    let title: String
    let siblings: [RecentContentThread]
    let hidden: [RecentClueOverride]
    let rename: () -> Void
    let merge: (RecentContentThread) -> Void
    let hide: () -> Void
    let restore: (RecentClueOverride) -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var visible: Bool { hovered || focused }

    var body: some View {
        Menu {
            Button("重命名…", action: rename)
            if !siblings.isEmpty {
                Menu("合并到…") {
                    ForEach(siblings) { target in
                        Button("并入「\(target.title)」") { merge(target) }
                    }
                }
            }
            Button("隐藏", action: hide)
            if !hidden.isEmpty {
                Divider()
                Menu("显示隐藏的线索") {
                    ForEach(hidden, id: \.clue) { override in
                        Button("恢复「\(override.displayTitle ?? RecentContentDigest.threadTitle(override.clue))」") { restore(override) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis").vosFont(WorkspaceText.meta.size, weight: .semibold)
                .foregroundStyle(palette.secondaryText)
                .frame(width: WorkspaceMetrics.rowActionMinHeight, height: WorkspaceMetrics.rowActionMinHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .focused($focused)
        .help("更多操作")
        .accessibilityLabel("更多操作：" + title)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(palette.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.border, lineWidth: 1) }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: visible)
    }
}

private struct RecentClueRenameSheet: View {
    @ObservedObject var model: ControlCenter
    let clue: String
    let resettable: Bool
    let dismiss: () -> Void
    @State private var title: String
    @State private var saving = false

    init(model: ControlCenter, clue: String, title: String, resettable: Bool, dismiss: @escaping () -> Void) {
        self.model = model; self.clue = clue; self.resettable = resettable; self.dismiss = dismiss
        _title = State(initialValue: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改线索标题").vosFont(WorkspaceText.sectionTitle)
            TextField("线索标题", text: $title)
            Text("只改变这条线索的显示名，原始想法不变；留空或恢复默认后回到「\(RecentContentDigest.threadTitle(clue))」。")
                .vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            if !model.status.isEmpty {
                Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if resettable {
                    Button("恢复默认") {
                        saving = true
                        Task { if await model.renameRecentClue(clue, title: nil) { dismiss() }; saving = false }
                    }
                }
                Spacer()
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                Button("保存") {
                    saving = true
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        if await model.renameRecentClue(clue, title: trimmed.isEmpty ? nil : trimmed) { dismiss() }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(title.count > 100)
            }.disabled(saving)
        }.padding(24).frame(width: 520)
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

private struct HomeCard: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let isSelected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius)
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(isSelected ? palette.selection : palette.surface, in: shape)
            .overlay { shape.strokeBorder(isSelected ? palette.focusRing : palette.border, lineWidth: 1) }
            .contentShape(shape)
    }
}

private extension View {
    func homeCard(isSelected: Bool) -> some View {
        modifier(HomeCard(isSelected: isSelected))
    }
}
