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
    @Environment(\.vosTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ControlCenter
    let openSource: (String) -> Void
    /// 打开纯笔记阅读页（文章本体）；没有笔记的条目仍走 openSource。
    var openNote: (String) -> Void = { _ in }
    let openSpan: (String, String) -> Void
    let openTask: (String) -> Void
    let capture: () -> Void
    @State private var selectedID: String? = RecentContentHomeSelection.shared.itemID
    @SceneStorage("recentHome.selectedItem") private var storedSelection = ""
    @SceneStorage("recentHome.timelineAnchor") private var storedTimelineAnchor = ""
    @State private var timelineRestored = false
    @State private var readingStates: [String: SourceReadingState] = [:]
    /// 阅读态到达前「待处理」过滤无法算出真正的可见集合；过早按全部材料
    /// 读笔记会在状态落回后立刻再读一次，两次查询在 store actor 上串行。
    @State private var readingStatesLoaded = false
    @AppStorage("voiceos.home.pendingOnly") private var showsOnlyPending = true
    @State private var clueRename: ClueRenameRequest?
    @State private var clueFailureText = ""
    @State private var clueFailureTitle = "操作未完成"
    @State private var showingClueFailure = false
    @State private var organizeAttemptSourceID: String?
    @State private var organizeToast: String?
    @State private var organizeToastSourceID: String?
    @AppStorage("voiceos.home.recentThoughts.expanded") private var recentThoughtsExpanded = false
    /// 首页「最近笔记」：按笔记整理时间浮现，旧录音今天整理的笔记也能接着读。
    @AppStorage("voiceos.home.recentNotes.expanded") private var recentNotesExpanded = true
    @State private var recentNotes: [StoredMaterialNote] = []
    @State private var recentThoughtsHighlighted = false
    @State private var frozenViewpointsItemID: String?
    @FocusState private var timelineFocused: Bool
    /// Arrow-key moves both select and scroll; a mouse click selects but must
    /// leave the timeline where the reader put it.
    @State private var keyboardDrivenSelection = false
    private let topAnchor = "home.top"
    private let timelineSpace = "home.timeline"
    private let tasksAnchor = "home.tasks.summary"
    private let recentThoughtsRowID = "home.recentThoughts"
    private let recentNotesRowID = "home.recentNotes"

    // Only 特大 (1.45) crosses 1.3; 大 (1.28) keeps the single-line rows.
    private var isLargeText: Bool { textScale >= 1.3 }
    private var timelineWidth: CGFloat { 288 * min(max(textScale, 1), 1.3) }

    private var days: [RecentContentDay] { model.homeSnapshot.days }
    /// The inbox default: only materials still unread or in progress; action
    /// feedback always stays because it has no reading state of its own.
    private var visibleDays: [RecentContentDay] {
        guard showsOnlyPending else { return days }
        return days.compactMap { day in
            let kept = day.items.filter { item in
                guard item.kind == .material, let source = materialSource(item) else { return true }
                return (readingStates[source.id] ?? .unread) != .read
            }
            return kept.isEmpty ? nil : RecentContentDay(id: day.id, date: day.date, items: kept)
        }
    }
    private var items: [RecentContentItem] { visibleDays.flatMap(\.items) }
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
                    Group {
                        if days.isEmpty {
                            empty
                        } else if !recentNotes.isEmpty {
                            // 全部读完时仍留着重访入口：最近整理的笔记就在上面接着读。
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    recentNotesEntry
                                    WorkspaceEmptyState(title: "待处理的都处理完了", systemImage: "checkmark.circle",
                                                        description: "最近整理的笔记留在上面；已读的内容也在「材料」页。") {
                                        Button("查看全部") { showsOnlyPending = false }.buttonStyle(.workspaceSecondary)
                                    }
                                    .padding(.top, 24)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                            }
                        } else {
                            WorkspaceEmptyState(title: "待处理的都处理完了", systemImage: "checkmark.circle",
                                                description: "已读的内容留在「材料」页；也可以看全部最近记录。") {
                                Button("查看全部") { showsOnlyPending = false }.buttonStyle(.workspaceSecondary)
                            }
                        }
                    }.onAppear { StartupTrace.mark("home.appear.empty") }
                } else {
                    HStack(spacing: 0) {
                        timeline.frame(width: timelineWidth)
                        // Vertical seam between timeline and reader; WorkspaceListDivider is horizontal-only.
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
        .task(id: materialNotesReadKey) { await reloadMaterialNotes() }
        .task(id: HomeRecentNotesKey(records: model.recordsRevision, notes: model.materialNotesRevision)) {
            recentNotes = await model.recentMaterialNotes(limit: 8)
        }
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
            Picker("范围", selection: $showsOnlyPending) {
                Text("待处理").tag(true)
                Text("全部").tag(false)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            .accessibilityLabel("时间线范围")
            Spacer()
            Button(action: openWeeklyReview) {
                HStack(spacing: 4) {
                    Label("每周回顾", systemImage: "calendar.badge.clock")
                    if pendingOutcomeCount > 0 {
                        Text("· \(pendingOutcomeCount)").foregroundStyle(palette.warning)
                    }
                }
            }
            .buttonStyle(.plain).vosFont(WorkspaceText.meta.size, weight: .medium)
            .foregroundStyle(palette.accent)
            .help(weeklyReviewHelp)
            .accessibilityLabel(weeklyReviewAccessibilityLabel)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(palette.canvas)
        .overlay(alignment: .bottom) { WorkspaceListDivider() }
    }

    private func openWeeklyReview() {
        model.pendingWorkspaceRoute = .weeklyReview
    }

    private var weeklyReviewHelp: String {
        pendingOutcomeCount > 0
            ? "\(pendingOutcomeCount) 项结果待填，打开每周回顾：完成、待补结果、停滞目标与待确认"
            : "打开每周回顾：完成、待补结果、停滞目标与待确认"
    }

    private var weeklyReviewAccessibilityLabel: String {
        pendingOutcomeCount > 0 ? "\(pendingOutcomeCount) 项结果待填，打开每周回顾" : "打开每周回顾"
    }

    private var empty: some View {
        Group {
            if let message = model.workspaceLastError {
                WorkspaceEmptyState(title: "资料库读取失败", systemImage: "tray", description: message,
                                    severity: .danger, selectableMessage: true) {
                    if model.workspaceLastErrorRetry != nil {
                        Button("重试") { model.retryWorkspaceError() }.buttonStyle(.workspacePrimary)
                    }
                }
            } else if hasAnyMaterial {
                WorkspaceEmptyState(title: "材料都还没有可读内容", systemImage: "tray",
                                    description: "材料还在转写或识别，完成并保存后会出现在这里。") {
                    Button("记录想法") { capture() }.buttonStyle(.workspacePrimary)
                    Button("导入录音") { model.chooseFullRecording() }.buttonStyle(.workspaceSecondary)
                }
            } else {
                WorkspaceEmptyState(title: "资料库里还没有材料", systemImage: "tray",
                                    description: "录一段、导入一段录音，或写几句。") {
                    Button("记录想法") { capture() }.buttonStyle(.workspacePrimary)
                    Button("导入录音") { model.chooseFullRecording() }.buttonStyle(.workspaceSecondary)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !recentNotes.isEmpty { recentNotesEntry }
                    if !recentThoughts.isEmpty { recentThoughtsEntry(recentThoughts).id(recentThoughtsRowID) }
                    ForEach(Array(visibleDays.enumerated()), id: \.element.id) { index, day in
                        VStack(alignment: .leading, spacing: 0) {
                            // The day label hugs its own rows; the gap before the
                            // next label is the one that grows, so grouping reads
                            // before any text does.
                            dayHeader(day)
                                .padding(.top, index == 0 && recentThoughts.isEmpty ? 2 : 20)
                                .padding(.bottom, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(day.items) { item in
                                    Button { keyboardDrivenSelection = false; recentThoughtsHighlighted = false; selectedID = item.id } label: { row(item) }
                                        .buttonStyle(.plain)
                                        .id(item.id)
                                        .contextMenu {
                                            if item.kind == .material {
                                                Button("标为未读") { setReading(item, .unread) }
                                                Button("标为在读") { setReading(item, .reading) }
                                                Button("标为已读") { setReading(item, .read) }
                                            }
                                        }
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
                guard keyboardDrivenSelection else { return }
                keyboardDrivenSelection = false
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: recentThoughtsHighlighted) { _, highlighted in
                guard highlighted else { return }
                timelineFocused = true
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(recentThoughtsRowID, anchor: .top)
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
        // A label and a hairline, no accent: accent in this column belongs to
        // the open row and the actions that lead into the reader.
        HStack(spacing: 10) {
            Text(dayLabel(day.date)).vosFont(WorkspaceText.meta.size, weight: .semibold)
                .foregroundStyle(palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
                .fixedSize()
            WorkspaceListDivider()
        }.padding(.horizontal, 10)
    }

    private func updateTimelineAnchor(_ positions: [String: CGFloat]) {
        // Keep the saved anchor until the restore has run, so first layout cannot overwrite it with the top row.
        guard timelineRestored || storedTimelineAnchor.isEmpty else { return }
        guard let anchor = positions.min(by: { abs($0.value) < abs($1.value) })?.key else { return }
        if anchor != storedTimelineAnchor { storedTimelineAnchor = anchor }
    }

    private func restoreTimeline(_ proxy: ScrollViewProxy) {
        if storedTimelineAnchor.isEmpty || !items.isEmpty { timelineRestored = true }
        // Re-anchoring on every appear and item-count change keeps live inserts from moving the reader's top row; scrolling to the tracked anchor reports the same id back, so this settles instead of looping.
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
        let showsRecentThoughts = !recentThoughts.isEmpty
        let ids = (showsRecentThoughts ? [recentThoughtsRowID] : []) + items.map(\.id)
        switch press.key {
        case .downArrow, .upArrow:
            guard !ids.isEmpty else { return .ignored }
            let current: Int?
            if recentThoughtsHighlighted, showsRecentThoughts {
                current = 0
            } else if let item = selected, let index = items.firstIndex(where: { $0.id == item.id }) {
                current = index + (showsRecentThoughts ? 1 : 0)
            } else {
                current = nil
            }
            let next: Int
            if press.key == .upArrow { next = current.map { max(0, $0 - 1) } ?? ids.count - 1 }
            else { next = current.map { min(ids.count - 1, $0 + 1) } ?? 0 }
            if showsRecentThoughts, next == 0 {
                recentThoughtsHighlighted = true
            } else {
                recentThoughtsHighlighted = false
                keyboardDrivenSelection = true
                selectedID = ids[next]
            }
            return .handled
        case .return, .space:
            if press.key == .space, !recentThoughtsHighlighted { return .ignored }
            if recentThoughtsHighlighted, showsRecentThoughts {
                toggleRecentThoughts()
                return .handled
            }
            guard let item = selected else { return .ignored }
            guard item.kind == .material else { return .handled }
            guard let sourceID = item.sourceIDs.first else { return .ignored }
            openSource(sourceID)
            return .handled
        default:
            return .ignored
        }
    }

    /// One timeline row: the reading state hangs in a reserved gutter before
    /// the title, the title wraps instead of truncating, and the first
    /// paragraph the reader opens with previews up to two quiet lines.
    private func row(_ item: RecentContentItem) -> some View {
        let isSelected = selected?.id == item.id
        let presentation = rowPresentation(item)
        let state = readingState(item)
        // A read row stays quiet unless it is the open one; the reader beside
        // it then shows the same title at full strength.
        let titleColor = state == .read && !isSelected ? palette.secondaryText : palette.text
        return HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(state == .unread ? palette.accent : palette.secondaryText)
                .frame(width: 6, height: 6)
                .padding(.top, 6 * textScale)
                .opacity(state == nil || state == .read ? 0 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                // Long titles take the lines they need; the preview and the
                // meta line are what give way when the column is narrow.
                Text(presentation.title).vosFont(WorkspaceText.rowTitle)
                    .foregroundStyle(titleColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let preview = presentation.preview {
                    Text(preview).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        .lineSpacing(2).lineLimit(2).multilineTextAlignment(.leading)
                }
                HStack(spacing: 4) {
                    Text(presentation.meta).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                    if let trailing = presentation.trailing {
                        Text("·").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        Text(trailing).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeRowChrome(isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
    }

    private struct HomeRowPresentation {
        let title: String
        let preview: String?
        let meta: String
        let trailing: String?
        let accessibilityLabel: String
    }

    /// One title fit, one preview read and one status read per row; title,
    /// preview, meta, trailing and spoken label all read from this result.
    private func rowPresentation(_ item: RecentContentItem) -> HomeRowPresentation {
        let storedNote = materialNote(for: item)
        let fit = WorkspaceTitleFit.present(storedNote.flatMap { MaterialNoteHomeText.title($0.note) } ?? item.title)
        let title = item.kind == .feedback ? fit.title + " · \(progressCount(item)) 条" : fit.title
        let note = rowStatusNote(item)
        let time = timeLabel(item.date)
        let trailing = rowTrailing(item)
        var metaParts: [String] = []
        if let source = fit.source { metaParts.append(source) }
        metaParts.append(time)
        if let note { metaParts.append(note) }
        var spokenParts = [title]
        if let note { spokenParts.append(note) }
        spokenParts.append(time)
        if let trailing { spokenParts.append(trailing) }
        return HomeRowPresentation(
            title: title,
            preview: rowPreview(item, note: storedNote, title: fit.title),
            meta: metaParts.joined(separator: " · "),
            trailing: trailing,
            accessibilityLabel: spokenParts.joined(separator: "，")
        )
    }

    /// The preview prefers the saved note's lead or first paragraph, then the
    /// row's own summary or its opening thought. Every source flattens to one
    /// line of flow so a stray newline cannot break the row's rhythm.
    private func rowPreview(_ item: RecentContentItem, note: StoredMaterialNote?, title: String) -> String? {
        guard item.kind == .material else { return nil }
        let raw = note.flatMap { MaterialNoteHomeText.preview($0.note) }
            ?? (item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (item.thoughts.first?.statement ?? "")
                : item.summary)
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed != title else { return nil }
        return collapsed
    }

    private func materialSource(_ item: RecentContentItem) -> SourceRecord? {
        guard let id = item.sourceIDs.first else { return nil }
        return model.sourcePageIndex.recordsByID[id]
    }
    private func readingState(_ item: RecentContentItem) -> SourceReadingState? {
        guard item.kind == .material, let source = materialSource(item) else { return nil }
        return readingStates[source.id] ?? .unread
    }
    private func setReading(_ item: RecentContentItem, _ state: SourceReadingState) {
        guard let source = materialSource(item) else { return }
        let previous = readingStates[source.id]
        readingStates[source.id] = state
        Task {
            let ok = await model.setReadingState(sourceID: source.id, state: state)
            if !ok { readingStates[source.id] = previous }
        }
    }

    /// The trailing slot carries the value a material produced: its open tasks.
    /// Process states read inline as secondary text instead.
    private func rowTrailing(_ item: RecentContentItem) -> String? {
        guard item.kind != .feedback,
              let count = model.homeSnapshot.digests[item.id]?.tasks.count, count > 0 else { return nil }
        return "\(count) 条待办"
    }

    private func rowStatusNote(_ item: RecentContentItem) -> String? {
        switch model.homeSnapshot.rows[item.id]?.status {
        case .some(.localOnly): return "仅本地"
        case .some(.organizing): return "整理中"
        case .some(.needsReview): return "待核对"
        case .some(.issues(let count)): return "疑点 \(count)"
        case nil: break
        }
        guard item.kind == .material, let source = materialSource(item) else { return nil }
        switch readingStates[source.id] ?? .unread {
        case .unread: return "未读"
        case .reading: return "在读"
        case .read: return "已读"
        }
    }

    private func progressCount(_ item: RecentContentItem) -> Int {
        model.homeSnapshot.rows[item.id]?.count ?? item.excerpts.count
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
        return VStack(alignment: .leading, spacing: WorkspaceMetrics.groupGap) {
            Text([dateLabel(item.date), timeLabel(item.date)].joined(separator: " · "))
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            Text("\(item.title) · \(count) 条")
                .vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                    ForEach(Array(item.excerpts.enumerated()), id: \.offset) { index, excerpt in
                        if index > 0 { WorkspaceListDivider() }
                        feedbackExcerpt(excerpt, primary: index == 0)
                    }
                }
            } else if let first = rows.first {
                progressRow(first, style: WorkspaceText.pageTitle)
                ForEach(rows.dropFirst()) { row in
                    WorkspaceListDivider().padding(.top, 4)
                    progressRow(row, style: WorkspaceText.body)
                }
            }
        }
    }

    /// A captured note may start with a link followed by commentary. Headline
    /// the readable words; keep the link on its own quiet line.
    @ViewBuilder private func feedbackExcerpt(_ excerpt: String, primary: Bool) -> some View {
        if let split = WorkspaceTitleFit.splitLeadingLink(excerpt) {
            VStack(alignment: .leading, spacing: 8) {
                if primary {
                    Text(WorkspaceTitleFit.present(split.link).title)
                        .vosFont(WorkspaceText.pageTitle).lineSpacing(4)
                        .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                }
                Text(split.rest)
                    .vosFont(primary ? WorkspaceText.sectionTitle : WorkspaceText.body)
                    .lineSpacing(5).textSelection(.enabled)
                Text(split.link)
                    .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        } else {
            Text(excerpt)
                .vosFont(primary ? WorkspaceText.pageTitle : WorkspaceText.body)
                .lineSpacing(primary ? 4 : 5)
                .textSelection(.enabled)
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
            if let split = WorkspaceTitleFit.splitLeadingLink(row.text) {
                if style.size > 20 {
                    Text(WorkspaceTitleFit.present(split.link).title)
                        .vosFont(style).lineSpacing(4).textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(split.rest)
                    .vosFont(style.size > 20 ? WorkspaceText.sectionTitle : style)
                    .lineSpacing(5).textSelection(.enabled)
                Text(split.link)
                    .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            } else {
                Text(row.text).vosFont(style).lineSpacing(style.size > 20 ? 4 : 5).textSelection(.enabled)
            }
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
                    let hasNote = materialNote(for: item) != nil
                    Button(hasNote ? "继续读" : "打开材料") { hasNote ? openNote(first) : openSource(first) }
                        .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                        .help(hasNote ? "继续读这篇笔记，回到上次读到的位置" : "打开这份材料")
                }
            }
            let note = materialNote(for: item)
            let fit = WorkspaceTitleFit.present(note.flatMap { MaterialNoteHomeText.title($0.note) } ?? item.title)
            Text(fit.title).vosFont(WorkspaceText.pageTitle).lineSpacing(4).lineLimit(4)
                .padding(.top, WorkspaceMetrics.groupGap).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            if let source = fit.source {
                Text(source).vosFont(WorkspaceText.meta).foregroundStyle(palette.tertiaryText)
                    .padding(.top, 6).textSelection(.enabled)
            }
            if let summary = note.flatMap({ MaterialNoteHomeText.preview($0.note) })
                ?? (item.summary.isEmpty ? nil : item.summary) {
                Text(summary).vosFont(WorkspaceText.body).lineSpacing(5)
                    .textSelection(.enabled)
                    .padding(.top, WorkspaceMetrics.sectionGap)
            }
            if !digest.tasks.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : WorkspaceMotion.scroll) { proxy.scrollTo(tasksAnchor, anchor: .top) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "checklist")
                            .vosFont(WorkspaceText.caption.size, weight: .semibold)
                            .accessibilityHidden(true)
                        Text("\(digest.tasks.count) 条待办")
                            .vosFont(WorkspaceText.meta.size, weight: .semibold, monospacedDigit: true)
                        Text("跳到列表")
                            .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                    }
                    .foregroundStyle(palette.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, WorkspaceMetrics.groupGap)
                .help("跳到这条材料下方的待办列表")
                .accessibilityLabel("\(digest.tasks.count) 条待办，跳到列表")
                .accessibilityIdentifier("home.tasks.badge")
            }
            if item.thoughts.isEmpty {
                organizePrompt(item).padding(.top, 44)
            } else {
                ForEach(digest.threads) { thread in
                    threadSection(thread, siblings: digest.threads.filter { $0.id != thread.id })
                        .padding(.top, WorkspaceMetrics.sectionGap)
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
            WorkspaceListDivider().padding(.bottom, WorkspaceMetrics.groupGap)
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
                VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, thought in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").vosFont(WorkspaceText.caption.size, weight: WorkspaceText.caption.weight, monospacedDigit: true)
                                .foregroundStyle(palette.tertiaryText).frame(width: 18 * vosLayoutScale(textScale), alignment: .trailing)
                                .padding(.top, 3)
                            ThoughtLine(thought: thought, openOriginal: { openOriginal(thought) })
                        }
                    }
                }.padding(.top, WorkspaceMetrics.groupGap).padding(.leading, 42)
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
                .padding(.top, WorkspaceMetrics.groupGap).padding(.leading, 42)
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
                WorkspaceListDivider().padding(.bottom, WorkspaceMetrics.groupGap)
                Text("这条材料带出了 \(tasks.count) 条待办").vosFont(WorkspaceText.meta, monospacedDigit: true).foregroundStyle(palette.secondaryText)
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
            }.padding(.top, WorkspaceMetrics.sectionGap)
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

    private var pendingOutcomeCount: Int { model.visibleOutcomeFollowups.count }

    private func toggleRecentThoughts() {
        withAnimation(reduceMotion ? nil : WorkspaceMotion.expand) { recentThoughtsExpanded.toggle() }
    }

    /// 最近整理的笔记：标题与预览和材料页同一篇，点开即回到上次读到的位置。
    private var recentNotesEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : WorkspaceMotion.expand) { recentNotesExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(recentNotesExpanded ? 90 : 0))
                        .vosFont(WorkspaceText.caption.size, weight: .semibold)
                        .foregroundStyle(palette.tertiaryText)
                        .accessibilityHidden(true)
                    Text("最近笔记").vosFont(WorkspaceText.meta.size, weight: .semibold)
                        .foregroundStyle(palette.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(recentNotes.count) 篇")
                        .vosFont(WorkspaceText.caption, monospacedDigit: true).foregroundStyle(palette.tertiaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recentNotesExpanded ? "收起最近笔记" : "展开最近整理的笔记")
            .accessibilityIdentifier("home.recentNotes.toggle")
            .accessibilityValue(recentNotesExpanded ? "已展开" : "已收起")
            if recentNotesExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recentNotes.enumerated()), id: \.element.id) { index, stored in
                        if index > 0 { WorkspaceListDivider().padding(.horizontal, 10) }
                        Button { openRecentNote(stored) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(MaterialNoteHomeText.title(stored.note) ?? "未命名笔记")
                                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.text)
                                    .lineLimit(isLargeText ? 3 : 2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                if let preview = MaterialNoteHomeText.preview(stored.note) {
                                    Text(preview).vosFont(WorkspaceText.caption)
                                        .foregroundStyle(palette.secondaryText)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .homeRowChrome(isSelected: false)
                        }
                        .buttonStyle(.plain)
                        .help("打开这篇笔记，回到上次读到的位置")
                        .accessibilityIdentifier("home.recentNotes.row")
                    }
                }
            }
            WorkspaceListDivider().padding(.top, 8)
        }
        .id(recentNotesRowID)
    }

    private func openRecentNote(_ stored: StoredMaterialNote) {
        guard let first = stored.expressionKey.split(separator: "|").first.map(String.init) else { return }
        openNote(first)
    }

    private func recentThoughtsEntry(_ groups: [RecentThoughtDay]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleRecentThoughts()
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
                        .vosFont(WorkspaceText.caption, monospacedDigit: true).foregroundStyle(palette.tertiaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .background(recentThoughtsHighlighted ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                .workspaceFocusRing(recentThoughtsHighlighted, radius: WorkspaceMetrics.controlRadius)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recentThoughtsExpanded ? "收起最近想法" : "展开最近想法，查看近 14 天的观点")
            .accessibilityIdentifier("home.recentThoughts.toggle")
            .accessibilityValue(recentThoughtsExpanded ? "已展开" : "已收起")
            if recentThoughtsExpanded {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(dayLabel(group.date)) · \(group.entries.count) 条")
                            .vosFont(WorkspaceText.caption, monospacedDigit: true).foregroundStyle(palette.tertiaryText)
                            .padding(.horizontal, 10)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { WorkspaceListDivider().padding(.horizontal, 10) }
                                Button { openClaim(entry.id) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.statement).vosFont(WorkspaceText.meta)
                                            .foregroundStyle(palette.text).lineLimit(isLargeText ? 4 : 3)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                        Text(entry.sourceTitle).vosFont(WorkspaceText.caption)
                                            .foregroundStyle(palette.secondaryText).lineLimit(isLargeText ? 3 : 2)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .homeRowChrome(isSelected: false)
                                }
                                .buttonStyle(.plain)
                                .help("打开这条想法的原话")
                                .accessibilityIdentifier("recent.thought")
                            }
                        }
                    }
                }
            }
            WorkspaceListDivider().padding(.top, 8)
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
                    Text("重新整理会生成新观点，旧观点保留为历史。")
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
        readingStatesLoaded = true
    }

    /// The note read refreshes when the library or a note revision changes, or
    /// when the visible row set does. `task(id:)` cancels the old read; the key
    /// comparison before writing back stops a late result landing on a newer set.
    /// 阅读态未就绪时键集合为空，等它落回后再一次性读真正的可见行。
    private var materialNotesReadKey: HomeMaterialNotesKey {
        let keys = readingStatesLoaded
            ? items.compactMap { $0.kind == .material ? materialNoteExpressionKey(for: $0) : nil }
            : []
        return HomeMaterialNotesKey(records: model.recordsRevision, notes: model.materialNotesRevision,
                                    expressionKeys: Set(keys).sorted())
    }

    /// The expression's member set exactly as note generation saved it: source
    /// IDs plus paired external sources, canonicalized by the store.
    private func materialNoteExpressionKey(for item: RecentContentItem) -> String? {
        guard let sourceID = item.sourceIDs.first else { return nil }
        let memberIDs = model.sourcePageIndex.expression(for: sourceID).map { expression in
            expression.sourceIDs + (expression.externalVersions ?? [:]).keys.sorted()
                .filter { !expression.sourceIDs.contains($0) }
        } ?? [sourceID]
        return VoiceOSStore.materialNoteExpressionKey(memberIDs)
    }

    private func materialNote(for item: RecentContentItem) -> StoredMaterialNote? {
        guard item.kind == .material, let key = materialNoteExpressionKey(for: item) else { return nil }
        return model.materialNoteRows[key]
    }

    @MainActor
    private func reloadMaterialNotes() async {
        let key = materialNotesReadKey
        guard !key.expressionKeys.isEmpty else { return }
        // 结果直接并入 ControlCenter 的会话缓存（按条比较新旧，迟到的旧结果
        // 不会覆盖新版本）；视图从缓存读，返回首页首帧就有笔记标题。
        _ = await model.latestMaterialNotes(expressionKeys: key.expressionKeys)
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
        let formatter = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
            ? HomeDateFormatting.dayCurrentYear
            : HomeDateFormatting.dayOtherYear
        return formatter.string(from: date)
    }

    private func dateLabel(_ date: Date) -> String { dayLabel(date) }

    private func timeLabel(_ date: Date) -> String {
        HomeDateFormatting.time.string(from: date)
    }
}

extension ControlCenter {
    /// One read for the visible rows. Results merge into the session cache by
    /// revision: a late response can never replace a newer note, and a failed
    /// read keeps the previous rows instead of blanking every title on home.
    /// 首页「最近笔记」：每个表达的最新一版，按整理时间倒序。
    @MainActor
    func recentMaterialNotes(limit: Int = 8) async -> [StoredMaterialNote] {
        guard let store else { return [] }
        return (try? await store.recentMaterialNotes(limit: limit)) ?? []
    }

    @MainActor
    @discardableResult
    func latestMaterialNotes(expressionKeys: [String]) async -> [String: StoredMaterialNote] {
        guard !expressionKeys.isEmpty, let store else { return materialNoteRows }
        guard let fresh = try? await store.latestMaterialNotes(expressionKeys: expressionKeys) else {
            return materialNoteRows
        }
        var merged = materialNoteRows
        var changed = false
        for (key, note) in fresh {
            if let existing = merged[key], existing.createdAt > note.createdAt { continue }
            if merged[key] != note { merged[key] = note; changed = true }
        }
        if changed { materialNoteRows = merged }
        return fresh
    }
}

private enum HomeDateFormatting {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    static let dayCurrentYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
    static let dayOtherYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}

private struct ClueRenameRequest: Identifiable {
    let clue: String
    let title: String
    let resettable: Bool
    var id: String { clue }
}

private struct ClueHeaderMenu: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: visible)
    }
}

private struct RecentClueRenameSheet: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let clue: String
    let resettable: Bool
    let dismiss: () -> Void
    @State private var title: String
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    init(model: ControlCenter, clue: String, title: String, resettable: Bool, dismiss: @escaping () -> Void) {
        self.model = model; self.clue = clue; self.resettable = resettable; self.dismiss = dismiss
        _title = State(initialValue: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改线索标题").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            TextField("线索标题", text: $title).focused($titleFocused)
            Text("只改变这条线索的显示名，原始想法不变。")
                .vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            if !model.status.isEmpty {
                Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
            HStack {
                if resettable {
                    Button("恢复默认") {
                        saving = true
                        Task { if await model.renameRecentClue(clue, title: nil) { dismiss() }; saving = false }
                    }
                }
                Button("取消", action: dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    saving = true
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        if await model.renameRecentClue(clue, title: trimmed.isEmpty ? nil : trimmed) { dismiss() }
                        saving = false
                    }
                }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(title.count > 100)
            }.disabled(saving)
        }.padding(24).frame(width: 520)
            .workspaceModalSurface()
            .task { try? await Task.sleep(for: .milliseconds(100)); titleFocused = true }
    }
}

/// The home timeline's batched note read: the library revision, the note
/// revision and the canonical expression keys of the visible rows.
private struct HomeMaterialNotesKey: Equatable {
    let records: Int
    let notes: Int
    let expressionKeys: [String]
}

private struct HomeRecentNotesKey: Equatable {
    let records: Int
    let notes: Int
}

/// Title and preview text the home rows and the reader take from a saved note.
/// The preview is the lead when present, otherwise the first paragraph's first
/// sentence, cut to `excerptLength` characters with an ellipsis.
enum MaterialNoteHomeText {
    static func title(_ note: MaterialNote) -> String? {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func preview(_ note: MaterialNote) -> String? {
        if let lead = note.lead {
            let text = flattened(lead)
            if !text.isEmpty { return text }
        }
        for section in note.sections {
            for paragraph in section.paragraphs {
                let text = flattened(paragraph.text)
                if !text.isEmpty { return excerpt(text) }
            }
        }
        return nil
    }

    private static let excerptLength = 80
    private static let sentenceEndings: Set<Character> = ["。", "！", "？", "!", "?", "…"]

    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func excerpt(_ text: String) -> String {
        if let ending = text.firstIndex(where: { sentenceEndings.contains($0) }),
           text.distance(from: text.startIndex, to: ending) < excerptLength {
            var end = text.index(after: ending)
            while end < text.endIndex, text[end] == "…" { end = text.index(after: end) }
            return String(text[..<end])
        }
        guard text.count > excerptLength else { return text }
        return String(text.prefix(excerptLength)) + "…"
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

/// Timeline rows are flat: date labels and hairlines carry the structure, so
/// stacked frames never read as one repeated outline. The open row fills with
/// the selection wash and hangs an accent bar in its leading gutter, the same
/// accent the reader on the right uses for its actions.
private struct HomeRowChrome: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius)
        content
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(isSelected ? palette.selection : hovered && isEnabled ? palette.hover : .clear, in: shape)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule().fill(palette.accent).frame(width: 3).padding(.vertical, 8)
                }
            }
            .contentShape(shape)
            .onHover { hovered = $0 && isEnabled }
            .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
            .animation(reduceMotion ? nil : WorkspaceMotion.selection, value: isSelected)
    }
}

private extension View {
    func homeRowChrome(isSelected: Bool) -> some View {
        modifier(HomeRowChrome(isSelected: isSelected))
    }
}
