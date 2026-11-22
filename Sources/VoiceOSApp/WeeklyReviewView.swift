import SwiftUI
import VoiceOSCore

struct WeeklyReviewView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var somedayRows: [ActionRecord] = []
    @State private var showingClarifyQueue = false
    @State private var nextStepGoal: ActionRecord?
    @State private var nextStepNotice = ""
    @State private var outcomeDrafts: [String: TaskFeedbackDraft] = [:]
    @State private var expandedOutcomeID: String?
    @State private var outcomeError = ""
    @State private var showingReflectionMap = false
    @State private var showingDiscussion = false
    @State private var discussionDraft = ""
    @State private var loadError = ""
    @State private var loadState: LoadState = .idle
    @State private var showSlowLoad = false
    @FocusState private var reviewListFocused: Bool
    @State private var keyboardSelection = ReviewKeySelection()

    private enum ReviewFilter: String {
        case todo = "我的待办", review = "待核对", completed = "已完成"
    }
    private enum LoadState: Equatable {
        case idle, loading, loaded, failed
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
    private var weekCompleted: [ActionRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return model.actionRecords
            .filter { action in
                guard action.state == "completed" else { return false }
                return completedDate(action).map { $0 >= cutoff } ?? false
            }
            .sorted { (completedDate($0) ?? .distantPast) > (completedDate($1) ?? .distantPast) }
    }
    private var pausedTasks: [ActionRecord] { model.workspacePausedTasks }
    private var stalledGoals: [ActionRecord] { model.stalledOutcomes }
    private var isEmpty: Bool {
        dailyReview.today.isEmpty && dailyReview.overdue.isEmpty && dailyReview.remaining.isEmpty &&
            staleTasks.isEmpty && unclarifiedTasks.isEmpty && weekCompleted.isEmpty && weekProgress.isEmpty && pausedTasks.isEmpty &&
            stalledGoals.isEmpty && somedayRows.isEmpty &&
            nextWeekEntries.isEmpty
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
                    WorkspacePageHeading(eyebrow: "行动 · 每周回顾", title: "这一周，行动走到了哪里") {
                        HStack(spacing: 10) {
                            Button("认知地图", systemImage: "point.3.connected.trianglepath.dotted") { showingReflectionMap = true }
                                .buttonStyle(.workspaceSecondary)
                                .help("周期切换、认知对照与一起回顾都在这里")
                            Button("关闭") { dismiss() }
                                .buttonStyle(.workspaceQuiet)
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                    summaryRow(proxy)
                    if loadState == .loading && showSlowLoad {
                        ProgressView("正在读取本周行动…").controlSize(.small)
                    }
                    if !loadError.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            WorkspaceNoticeText(message: loadError, severity: .danger)
                            Button("重试") { Task { await load() } }.controlSize(.small)
                        }
                    }
                    dailyCloseSection
                    if loadState == .loaded && isEmpty {
                        emptyReviewState
                    }
                    if !nextWeekEntries.isEmpty { nextWeekSection }
                    if !staleTasks.isEmpty { staleSection }
                    if !unclarifiedTasks.isEmpty { unclarifiedSection.id("review.unclarified") }
                    if !stalledGoals.isEmpty { stalledGoalsSection.id("review.stalled") }
                    if !somedayRows.isEmpty { somedaySection }
                    if !weekCompleted.isEmpty { weekCompletedSection.id("review.completed") }
                    if !weekProgress.isEmpty { progressSection }
                    if !pausedTasks.isEmpty { pausedSection }
                }.frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading).padding(WorkspaceMetrics.pagePadding)
            }
            .frame(minWidth: WorkspaceMetrics.modalSmall, minHeight: 560)
            .overlay(alignment: .bottom) { undoBar }
            .animation(reduceMotion ? nil : WorkspaceMotion.transient, value: undoEntry?.id)
            .task { await load() }
            .onChange(of: loadState) { previous, state in
                guard state == .loaded, previous != .loaded else { return }
                AccessibilityNotification.Announcement("本周行动已载入").post()
            }
            .focusable()
            .focused($reviewListFocused)
            .focusEffectDisabled()
            .onKeyPress { handleReviewKey($0) }
            .onChange(of: keyboardSelection.id) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            .onAppear { requestReviewFocus() }
            .workspaceSlowLoading(loadState == .loading, into: $showSlowLoad)
            .task(id: undoEntry?.id) {
                guard let id = undoEntry?.id else { return }
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                if undoEntry?.id == id { withAnimation(reduceMotion ? nil : WorkspaceMotion.transient) { undoEntry = nil } }
            }
            .sheet(isPresented: $showingClarifyQueue) { ActionClarifyQueueView(model: model, scope: .goals) }
            .sheet(item: $nextStepGoal) { goal in
                NextActionFormSheet(model: model, outcome: goal, onAdded: { _ in nextStepNotice = "已添加下一步" })
            }
            .sheet(isPresented: $showingReflectionMap) { reflectionMapSheet }
            // A dismissed sheet leaves the sheet's window with first responder;
            // re-request the list focus so arrows/Return keep working.
            .onChange(of: showingClarifyQueue) { _, shown in if !shown { requestReviewFocus() } }
            .onChange(of: nextStepGoal?.id) { _, id in if id == nil { requestReviewFocus() } }
            .onChange(of: showingReflectionMap) { _, shown in if !shown { requestReviewFocus() } }
        }
        .workspaceModalSurface()
    }

    private var pendingOutcomeAnchor: String {
        guard let action = weekCompleted.first(where: { action in
            model.visibleOutcomeFollowups.contains { $0.id == action.id }
        }) else { return "review.completed" }
        return "review.pending." + action.id
    }

    private func summaryRow(_ proxy: ScrollViewProxy) -> some View {
        let links = WeeklyReviewSummaryLinks(weekCompleted: weekCompleted.count,
                                             pendingOutcomes: model.visibleOutcomeFollowups.count,
                                             stalledGoals: stalledGoals.count,
                                             unclarifiedTasks: unclarifiedTasks.count)
        return HStack(spacing: 10) {
            summaryStat("本周完成", count: weekCompleted.count, target: "review.completed", isLink: links.completed, proxy: proxy)
            Text("·").foregroundStyle(palette.tertiaryText)
            summaryStat("待补结果", count: model.visibleOutcomeFollowups.count, target: pendingOutcomeAnchor, isLink: links.pendingOutcome, proxy: proxy)
            Text("·").foregroundStyle(palette.tertiaryText)
            summaryStat("停滞目标", count: stalledGoals.count, target: "review.stalled", isLink: links.stalled, proxy: proxy)
            Text("·").foregroundStyle(palette.tertiaryText)
            summaryStat("待确认", count: unclarifiedTasks.count, target: "review.unclarified", isLink: links.unclarified, proxy: proxy)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func summaryStat(_ title: String, count: Int, target: String, isLink: Bool, proxy: ScrollViewProxy) -> some View {
        let label = Text("\(title) \(count)")
        if isLink {
            Button {
                withAnimation(reduceMotion ? nil : WorkspaceMotion.scroll) { proxy.scrollTo(target, anchor: .top) }
            } label: {
                label
            }
            .buttonStyle(WorkspaceButtonStyle(emphasis: .quiet, compact: true, monospacedDigit: true))
            .help("跳到「\(title) \(count)」所在区块")
        } else {
            label.vosFont(WorkspaceText.meta.size, weight: .medium, monospacedDigit: true)
                .foregroundStyle(palette.secondaryText)
        }
    }

    private func load() async {
        loadError = ""
        loadState = .loading
        showSlowLoad = false
        let previousStatus = model.status
        focusedIDs = await model.focusedActionIDs()
        somedayRows = await model.somedayReviewCandidates()
        focusLoaded = true
        if model.status != previousStatus {
            loadError = model.status
            loadState = .failed
        } else {
            loadState = .loaded
        }
    }

    private var emptyReviewState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这一周没有需要回顾的行动。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            HStack(spacing: 8) {
                Button("打开行动页") { jump(.todo) }
                    .buttonStyle(.workspaceQuiet)
                Button("查看待确认") { jump(.review) }
                    .buttonStyle(.workspaceQuiet)
            }
        }
    }

    private var reflectionMapSheet: some View {
        ReflectionTimelineView(
            model: model,
            startPeriodic: true,
            openSource: { id in
                showingReflectionMap = false
                dismiss()
                model.requestWorkspaceSource(id)
            },
            dismiss: { showingReflectionMap = false },
            discuss: { claim in
                Task {
                    if await model.beginThoughtDiscussion(claim) { showingDiscussion = true }
                    else { loadError = model.status.isEmpty ? "讨论未能开始，请稍后重试" : model.status }
                }
            },
            reflect: { focus, prompt in
                guard await model.beginReflectionDiscussion(focus) else {
                    loadError = model.status.isEmpty ? "回顾未能开始，请稍后重试" : model.status
                    return false
                }
                if !prompt.isEmpty { discussionDraft = prompt }
                showingDiscussion = true
                return true
            }
        )
        .sheet(isPresented: $showingDiscussion) {
            WorkspaceDiscussionView(model: model, draft: $discussionDraft,
                close: { showingDiscussion = false },
                openSource: { id in
                    showingDiscussion = false
                    showingReflectionMap = false
                    dismiss()
                    model.requestWorkspaceSource(id)
                })
        }
    }

    private var dailyCloseSection: some View {
        let review = dailyReview
        let todayRows = Array(review.today.prefix(5))
        let overdueRows = Array(review.overdue.prefix(5))
        return WorkspaceSection(title: "今天收尾", icon: "checkmark.circle", count: review.remainingCount) {
            if review.isClear {
                Text("今天没有未收尾的行动").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText).padding(.vertical, 10)
            }
            if !todayRows.isEmpty {
                ForEach(Array(todayRows.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { WorkspaceListDivider() }
                    dailyRow(entry, overdue: false,
                             highlighted: isReviewHighlighted("today", entry.action.id))
                        .id(reviewRowID("today", entry.action.id))
                }
            }
            if review.today.count > todayRows.count { allButton(review.today.count, .todo) }
            if !overdueRows.isEmpty {
                if !todayRows.isEmpty { WorkspaceListDivider() }
                Text("逾期").vosFont(WorkspaceText.rowTitle).foregroundStyle(palette.warning).accessibilityAddTraits(.isHeader)
                    .padding(.top, WorkspaceMetrics.groupGap).padding(.bottom, 2)
                ForEach(Array(overdueRows.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { WorkspaceListDivider() }
                    dailyRow(entry, overdue: true,
                             highlighted: isReviewHighlighted("overdue", entry.action.id))
                        .id(reviewRowID("overdue", entry.action.id))
                }
            }
            if review.overdue.count > overdueRows.count { allButton(review.overdue.count, .todo) }
            if review.completedCount + review.dismissedCount > 0 {
                Text("已完成 \(review.completedCount) 条，已放下 \(review.dismissedCount) 条。")
                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.top, 10)
            }
            if review.remainingCount > 0 {
                Button("到行动页查看 →") { jump(.todo) }
                    .buttonStyle(.workspaceQuietCompact)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !actionError.isEmpty {
                Text(actionError).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning).padding(.top, 10)
            }
        }
    }

    private func dailyRow(_ entry: ActionTimeEntry, overdue: Bool, highlighted: Bool) -> some View {
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
                            Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 8)
                    WorkspaceRowChevron().padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }.buttonStyle(.plain)
            if overdue {
                WorkspaceBadge(text: "逾期", tone: .warning).padding(.top, 3)
            }
            Button("完成") { apply(entry, .completed) }
                .buttonStyle(.workspaceSecondaryCompact).disabled(model.savingAction)
                .accessibilityLabel("完成：" + entry.action.title)
            Button("不再跟进") { apply(entry, .dismissed) }
                .buttonStyle(.workspaceSecondaryCompact).disabled(model.savingAction)
                .accessibilityLabel("不再跟进：" + entry.action.title)
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(highlighted ? palette.selection.opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
        .workspaceFocusRing(highlighted, radius: WorkspaceMetrics.panelRadius)
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
            withAnimation(reduceMotion ? nil : WorkspaceMotion.transient) {
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
                withAnimation(reduceMotion ? nil : WorkspaceMotion.transient) { undoEntry = nil }
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
            .buttonStyle(.workspaceQuiet)
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
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                }.buttonStyle(.plain)
                    .accessibilityLabel("撤销：\(undoEntry.label)")
                    .padding(.horizontal, 24).padding(.bottom, 20)
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func dailySubtitle(_ entry: ActionTimeEntry) -> String {
        var parts: [String] = []
        if let title = actionSourceTitle(entry.action) {
            parts.append("来自『\(shortenedSourceName(title))』")
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

    private func shortenedSourceName(_ title: String) -> String {
        title.count > 12 ? String(title.prefix(12)) + "…" : title
    }

    private func actionSourceLabel(_ action: ActionRecord) -> String {
        if let title = actionSourceTitle(action) {
            return "来自『\(shortenedSourceName(title))』"
        }
        if model.claims.first(where: { $0.id == action.claimID })?.references.isEmpty == false {
            return "来自『相关材料』"
        }
        return "来自行动记录"
    }

    private func completedDate(_ action: ActionRecord) -> Date? {
        action.completedAt.flatMap(ConversationReflectionFocus.date)
    }

    private var nextWeekSection: some View {
        let candidates = nextWeekCandidates
        let rows = Array(candidates.prefix(5))
        return WorkspaceSection(title: "下周先做", subtitle: "加入本周专注", icon: "calendar.badge.plus", count: nextWeekEntries.count) {
            if focusSlots == 0 {
                HStack(spacing: 8) {
                    Text("已有 3 条专注，先到行动页移出。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    Button("到行动页移出 →") { jump(.todo) }
                        .buttonStyle(.workspaceQuietCompact)
                }.padding(.top, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { WorkspaceListDivider() }
                nextWeekRow(entry, highlighted: isReviewHighlighted("nextWeek", entry.action.id))
                    .id(reviewRowID("nextWeek", entry.action.id))
            }
            if candidates.count > rows.count { allButton(candidates.count, .todo) }
            HStack(spacing: 10) {
                Text(selectedFocusIDs.isEmpty ? "最多还能加入 \(focusSlots) 条" : "已选 \(selectedFocusIDs.count) 条")
                    .vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                Spacer()
                Button("加入专注") { applyNextWeekFocus() }
                    .buttonStyle(.workspacePrimary)
                    .disabled(selectedFocusIDs.isEmpty || focusSaving)
            }.padding(.top, 10)
            if !focusError.isEmpty {
                HStack(spacing: 8) {
                    Text(focusError).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    if focusSlots == 0 {
                        Button("到行动页移出 →") { jump(.todo) }
                            .buttonStyle(.workspaceQuietCompact)
                    }
                }.padding(.top, 10)
            }
        }
    }

    private func nextWeekRow(_ entry: ActionTimeEntry, highlighted: Bool) -> some View {
        let focused = focusedIDs.contains(entry.action.id)
        let selected = selectedFocusIDs.contains(entry.action.id)
        let subtitle = dueLabel(entry)
        return Button {
            toggleNextWeekSelection(entry)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: focused ? "pin.fill" : selected ? "checkmark.circle.fill" : "circle").vosFont(WorkspaceText.rowTitle.size)
                    .foregroundStyle(focused || selected ? palette.accent : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.action.title).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                    Text(subtitle.isEmpty ? "随时" : subtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if focused {
                    WorkspaceBadge(text: "已专注", tone: .accent).padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }.buttonStyle(.plain)
        .accessibilityValue(focused ? "已专注" : selected ? "已选" : "未选")
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(highlighted ? palette.selection.opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
        .workspaceFocusRing(highlighted, radius: WorkspaceMetrics.panelRadius)
    }

    private func toggleNextWeekSelection(_ entry: ActionTimeEntry) {
        guard focusLoaded, !focusedIDs.contains(entry.action.id), !focusSaving else { return }
        if selectedFocusIDs.contains(entry.action.id) {
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
                if index > 0 { WorkspaceListDivider() }
                reviewRow(title: action.title, subtitle: staleLabel(action), trailing: "搁置", icon: "hourglass",
                          highlighted: isReviewHighlighted("stale", action.id)) { openTask(action.id) }
                    .id(reviewRowID("stale", action.id))
            }
            if staleTasks.count > rows.count { allButton(staleTasks.count, .todo) }
        }
    }
    private var unclarifiedSection: some View {
        let rows = Array(unclarifiedTasks.prefix(5))
        return WorkspaceSection(title: "待确认", subtitle: "最近 14 天抽取，尚未确认类型。", icon: "questionmark.circle", count: unclarifiedTasks.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { WorkspaceListDivider() }
                reviewRow(title: action.title, trailing: "待确认", icon: "questionmark.circle",
                          highlighted: isReviewHighlighted("unclarified", action.id)) { openTask(action.id) }
                    .id(reviewRowID("unclarified", action.id))
            }
            if unclarifiedTasks.count > rows.count { linkButton("到待核对查看", .review).padding(.top, 10) }
        }
    }
    private var progressSection: some View {
        let rows = Array(weekProgress.prefix(5))
        return WorkspaceSection(title: "本周结果", subtitle: "最近 7 天记录的结果与进展。", icon: "checkmark.seal", count: weekProgress.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { WorkspaceListDivider() }
                if row.isTaskAvailable {
                    reviewRow(title: row.taskTitle, subtitle: row.relationLabel, detail: row.text,
                              trailing: dayLabel(row.date),
                              highlighted: isReviewHighlighted("progress", row.id)) { openTask(row.actionID) }
                        .id(reviewRowID("progress", row.id))
                } else {
                    unavailableProgressRow(row, highlighted: isReviewHighlighted("progress", row.id))
                        .id(reviewRowID("progress", row.id))
                }
            }
            if weekProgress.count > rows.count {
                Text("还有 \(weekProgress.count - rows.count) 条结果，到对应任务详情查看。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.top, 10)
            }
        }
    }
    private func unavailableProgressRow(_ row: RecentContentProgressRow, highlighted: Bool) -> some View {
        let hasMaterial = progressRowHasMaterial(row)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "circle").vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                .frame(width: 34, height: 34)
                .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(StatementTagParser.split(row.taskTitle).text).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                Text(row.relationLabel).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(2).multilineTextAlignment(.leading)
                Text(row.text).vosFont(WorkspaceText.body).lineSpacing(3).lineLimit(3).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(progressUnavailableReason(row)).vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(palette.secondaryText).padding(.top, 3)
                if hasMaterial {
                    Button("查看材料") { model.requestWorkspaceSource(row.id); dismiss() }
                        .buttonStyle(.workspaceQuietCompact)
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(highlighted ? palette.selection.opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .workspaceFocusRing(highlighted, radius: WorkspaceMetrics.panelRadius)
    }

    private func progressRowHasMaterial(_ row: RecentContentProgressRow) -> Bool {
        model.records.contains(where: { $0.id == row.id })
    }

    private func progressUnavailableReason(_ row: RecentContentProgressRow) -> String {
        guard let action = model.actionRecords.first(where: { $0.id == row.actionID }) else { return "任务已结束" }
        return model.workspaceTaskRequiresReview(action) ? "任务已暂停" : "任务已结束"
    }

    private var weekCompletedSection: some View {
        WorkspaceSection(title: "本周完成", subtitle: "最近 7 天完成的行动。", icon: "checkmark.circle", count: weekCompleted.count) {
            ForEach(Array(weekCompleted.enumerated()), id: \.element.id) { index, action in
                if index > 0 { WorkspaceListDivider() }
                weekCompletedRow(action, highlighted: isReviewHighlighted("completed", action.id))
                    .id(reviewRowID("completed", action.id))
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                linkButton("去「已完成」查看", .completed)
            }.padding(.top, 10)
        }
    }

    private func weekCompletedRow(_ action: ActionRecord, highlighted: Bool) -> some View {
        let subtitle = completedDate(action).map { "完成于 " + dayLabel($0) } ?? "完成时间未知"
        let pending = model.visibleOutcomeFollowups.contains { $0.id == action.id }
        let expanded = expandedOutcomeID == action.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button { openTask(action.id) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "checkmark.circle").vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                            .frame(width: 34, height: 34)
                            .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(StatementTagParser.split(action.title).text).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                            Text(subtitle + " · " + actionSourceLabel(action)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        if pending {
                            WorkspaceBadge(text: "待补结果", tone: .warning).padding(.top, 3)
                        }
                        Image(systemName: "chevron.right").vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText).padding(.top, 3).accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                }.buttonStyle(.plain)
                if pending {
                    Button(expanded ? "收起" : "记录结果") {
                        outcomeError = ""
                        withAnimation(reduceMotion ? nil : WorkspaceMotion.expand) { expandedOutcomeID = expanded ? nil : action.id }
                    }
                    .buttonStyle(expanded ? WorkspaceButtonStyle.workspaceQuietCompact : WorkspaceButtonStyle.workspaceSecondaryCompact)
                    .disabled(model.savingFeedback)
                    .accessibilityLabel("记录结果：" + action.title)
                }
            }
            if pending && expanded {
                TaskFeedbackEditor(model: model, draft: outcomeDraft(action.id), onSave: { saveOutcome(action) })
                    .padding(18)
                    .background(palette.selection, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            }
            if expanded, !outcomeError.isEmpty {
                WorkspaceNoticeText(message: outcomeError, severity: .danger)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(highlighted ? palette.selection.opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
        .workspaceFocusRing(highlighted, radius: WorkspaceMetrics.panelRadius)
    }

    private func outcomeDraft(_ id: String) -> Binding<TaskFeedbackDraft> {
        Binding(get: { outcomeDrafts[id] ?? TaskFeedbackDraft() },
                set: { outcomeDrafts[id] = $0 })
    }

    private func saveOutcome(_ action: ActionRecord) {
        let input = outcomeDrafts[action.id] ?? TaskFeedbackDraft()
        Task {
            if await model.saveFeedback(action, kind: input.kind, text: input.text, commandID: input.commandID) {
                outcomeDrafts[action.id] = TaskFeedbackDraft()
                outcomeError = ""
                withAnimation(reduceMotion ? nil : WorkspaceMotion.expand) { expandedOutcomeID = nil }
            } else {
                outcomeError = model.status.isEmpty ? "结果未能保存，请稍后重试" : model.status
            }
        }
    }

    private func linkButton(_ label: String, _ filter: ReviewFilter) -> some View {
        Button(label + " →") { jump(filter) }
            .buttonStyle(.workspaceQuiet)
    }

    private var pausedSection: some View {
        let rows = Array(pausedTasks.prefix(5))
        return WorkspaceSection(title: "暂停与冻结", subtitle: "暂停或待核对的待办；状态保留。", icon: "pause.circle", count: pausedTasks.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                if index > 0 { WorkspaceListDivider() }
                reviewRow(title: action.title, subtitle: model.workspaceActionStatus(action),
                          trailing: "待核对", icon: "pause.circle",
                          highlighted: isReviewHighlighted("paused", action.id)) { openTask(action.id) }
                    .id(reviewRowID("paused", action.id))
            }
            if pausedTasks.count > rows.count { linkButton("到待核对查看", .review).padding(.top, 10) }
        }
    }

    private var stalledGoalsSection: some View {
        let rows = Array(stalledGoals.prefix(5))
        return WorkspaceSection(title: "没有下一步的目标", icon: "exclamationmark.circle", count: stalledGoals.count,
                                actionTitle: "逐个澄清", action: { showingClarifyQueue = true }) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, goal in
                if index > 0 { WorkspaceListDivider() }
                stalledGoalRow(goal, highlighted: isReviewHighlighted("stalled", goal.id))
                    .id(reviewRowID("stalled", goal.id))
            }
            if stalledGoals.count > rows.count {
                Text("还有 \(stalledGoals.count - rows.count) 个目标，到问题与目标页查看。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.top, 10)
            }
            if !nextStepNotice.isEmpty {
                Text(nextStepNotice).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.top, 10)
            }
        }
    }

    private func stalledGoalRow(_ goal: ActionRecord, highlighted: Bool) -> some View {
        let title = StatementTagParser.split(goal.title).text
        return HStack(alignment: .top, spacing: 12) {
            Button { openTask(goal.id) } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "exclamationmark.circle").vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                        .frame(width: 34, height: 34)
                        .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                        Text("还没有下一步").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    WorkspaceBadge(text: "停滞", tone: .neutral).padding(.top, 3)
                    Image(systemName: "chevron.right").vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText).padding(.top, 3).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("目标：" + title + "，还没有下一步")
            }.buttonStyle(.plain)
            Button("加下一步") { nextStepNotice = ""; nextStepGoal = goal }
                .buttonStyle(.workspaceSecondaryCompact).disabled(model.savingAction)
                .accessibilityLabel("加下一步：" + title)
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(highlighted ? palette.selection.opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
        .workspaceFocusRing(highlighted, radius: WorkspaceMetrics.panelRadius)
    }

    private var somedaySection: some View {
        let rows = Array(somedayRows.prefix(5))
        return WorkspaceSection(title: "留到以后的问题与目标", subtitle: "超过 60 天没有回看。", icon: "tray", count: somedayRows.count) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, goal in
                if index > 0 { WorkspaceListDivider() }
                somedayRow(goal, highlighted: isReviewHighlighted("someday", goal.id))
                    .id(reviewRowID("someday", goal.id))
            }
            if somedayRows.count > rows.count {
                Text("还有 \(somedayRows.count - rows.count) 个目标，回看一批后再处理。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.top, 10)
            }
            if !actionError.isEmpty {
                Text(actionError).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning).padding(.top, 10)
            }
        }
    }

    private func somedayRow(_ goal: ActionRecord, highlighted: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { openTask(goal.id) } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "tray").vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                        .frame(width: 34, height: 34)
                        .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(goal.title).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                        Text("将来也许 · 留到以后").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    }
                    Spacer(minLength: 8)
                    WorkspaceRowChevron().padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }.buttonStyle(.plain)
            Button("恢复为目标") { applySomeday(goal, .restore) }
                .buttonStyle(.workspaceSecondaryCompact).disabled(model.savingAction)
                .accessibilityLabel("恢复为目标：" + goal.title)
            Button("仍留到以后") { applySomeday(goal, .keep) }
                .buttonStyle(.workspaceSecondaryCompact).disabled(model.savingAction)
                .accessibilityLabel("记录回看：" + goal.title)
            Button("放弃") { applySomeday(goal, .abandon) }
                .buttonStyle(.workspaceDestructive).disabled(model.savingAction)
                .accessibilityLabel("放弃：" + goal.title)
        }
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(highlighted ? palette.selection.opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
        .workspaceFocusRing(highlighted, radius: WorkspaceMetrics.panelRadius)
    }

    private func applySomeday(_ goal: ActionRecord, _ decision: SomedayReviewDecision) {
        Task {
            let saved: Bool
            switch decision {
            case .keep: saved = await model.revisitSomeday(goal)
            case .restore: saved = await model.restoreSomeday(goal)
            case .abandon: saved = await model.abandonSomeday(goal)
            }
            actionError = saved ? "" : (model.status.isEmpty ? "回看未能保存，请稍后重试" : model.status)
            somedayRows = await model.somedayReviewCandidates()
        }
    }
    private func reviewRow(title: String, subtitle: String = "", detail: String = "", trailing: String = "",
                           icon: String = "circle", accessibilityLabel: String? = nil,
                           highlighted: Bool, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                    .frame(width: 34, height: 34)
                    .background(palette.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(StatementTagParser.split(title).text).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                    if !subtitle.isEmpty {
                        Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if !detail.isEmpty {
                        Text(detail).vosFont(WorkspaceText.body).lineSpacing(3).lineLimit(3).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if !trailing.isEmpty {
                    Text(trailing).vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(palette.secondaryText).padding(.top, 3)
                }
                Image(systemName: "chevron.right").vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText).padding(.top, 3).accessibilityHidden(true)
            }
            .padding(.vertical, 10).padding(.horizontal, 10)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }.buttonStyle(.plain)
            .accessibilityLabelIfPresent(accessibilityLabel)
            .background(highlighted ? palette.selection.opacity(0.5) : Color.clear,
                        in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
            .workspaceFocusRing(highlighted, radius: WorkspaceMetrics.panelRadius)
    }
    private struct ReviewNavigationRow {
        let id: String
        let open: () -> Void
    }

    // Completed rows reuse the review.pending anchor the summary links already scroll to.
    private func reviewRowID(_ section: String, _ id: String) -> String {
        section == "completed" ? "review.pending." + id : "review.nav.\(section).\(id)"
    }

    private func isReviewHighlighted(_ section: String, _ id: String) -> Bool {
        keyboardSelection.id == reviewRowID(section, id)
    }

    private var reviewNavigationRows: [ReviewNavigationRow] {
        var rows: [ReviewNavigationRow] = []
        func add(_ section: String, _ id: String, _ open: @escaping () -> Void) {
            rows.append(ReviewNavigationRow(id: reviewRowID(section, id), open: open))
        }
        for entry in dailyReview.today.prefix(5) { add("today", entry.action.id) { openTask(entry.action.id) } }
        for entry in dailyReview.overdue.prefix(5) { add("overdue", entry.action.id) { openTask(entry.action.id) } }
        for entry in nextWeekCandidates.prefix(5) { add("nextWeek", entry.action.id) { toggleNextWeekSelection(entry) } }
        for action in staleTasks.prefix(5) { add("stale", action.id) { openTask(action.id) } }
        for action in unclarifiedTasks.prefix(5) { add("unclarified", action.id) { openTask(action.id) } }
        for goal in stalledGoals.prefix(5) { add("stalled", goal.id) { openTask(goal.id) } }
        for goal in somedayRows.prefix(5) { add("someday", goal.id) { openTask(goal.id) } }
        for action in weekCompleted { add("completed", action.id) { openTask(action.id) } }
        for row in weekProgress.prefix(5) {
            if row.isTaskAvailable {
                add("progress", row.id) { openTask(row.actionID) }
            } else if progressRowHasMaterial(row) {
                add("progress", row.id) {
                    model.requestWorkspaceSource(row.id)
                    dismiss()
                }
            }
        }
        for action in pausedTasks.prefix(5) { add("paused", action.id) { openTask(action.id) } }
        return rows
    }

    private func handleReviewKey(_ press: KeyPress) -> KeyPress.Result {
        guard reviewListFocused,
              press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let rows = reviewNavigationRows
        switch press.key {
        case .downArrow, .upArrow:
            guard keyboardSelection.step(up: press.key == .upArrow, over: rows.map(\.id)) else { return .ignored }
            return .handled
        case .return:
            guard let row = rows.first(where: { $0.id == keyboardSelection.id }) else { return .ignored }
            row.open()
            return .handled
        default:
            return .ignored
        }
    }

    private func requestReviewFocus() {
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            reviewListFocused = true
        }
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
private typealias ReviewKeySelection = WorkspaceKeyboardSelection
private extension View {
    @ViewBuilder func accessibilityLabelIfPresent(_ label: String?) -> some View {
        if let label { self.accessibilityLabel(label) } else { self }
    }
}
