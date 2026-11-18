import SwiftUI
import AppKit
import AVKit
import VoiceOSCore

// One navigation state owns the workspace. Discussion is a sibling, so expanding
// it never replaces the reading view or its disclosure/scroll state.
enum WorkspacePage: Hashable {
    case home, themes, materials, monitor, actions, initiate, source(String), delivery(String), task(String), settings, capture, search, tool(String)
    var isTopLevel: Bool {
        switch self {
        case .home, .themes, .materials, .monitor, .actions, .initiate, .settings: true
        default: false
        }
    }
}
private struct WorkspaceNavigationEntry: Hashable {
    let page: WorkspacePage
    let topicID: String?
    let topicTab: String
    let topicReadingMode: String
    var listFilter: String = ""
}
private struct WorkspaceReminderSettingsTarget: Identifiable {
    let action: ActionRecord
    let snapshot: ReminderSnapshot
    var id: String { action.id }
}
private struct TodayReadingItem: Identifiable {
    let plan: IncrementalPlan
    let source: SourceRecord
    let chunks: Int
    var id: String { plan.sourceID }
}
private struct MaterialDayGroup: Identifiable {
    let id: Date
    let label: String
    let sources: [SourceRecord]
}
private enum WorkspaceRowChrome {
    /// Kept free at the trailing edge so the hover capsule never covers the status slot.
    static let actionGutter: CGFloat = 46
    static let materialGutter: CGFloat = 44
    static let materialWideGutter: CGFloat = 152
}
// Mirrors the guard in ActionStore.promoteAction so the row menu and detail page share one rule.
extension ActionRecord {
    var canPromoteToTask: Bool { kind == "opportunity" && state == "open" && validity == "current" }
}
extension ControlCenter {
    // Nature-scoped projections behind the 问题 and 目标 entrances. The
    // coordinator may replace these with published arrays from the store.
    var openQuestions: [ActionRecord] { openOutcomes(nature: .question) }
    var openGoals: [ActionRecord] { openOutcomes(nature: .goal) }
    var untriagedSuggestions: [ActionRecord] { openOutcomes(nature: .unknown) }
    private func openOutcomes(nature: ActionNature) -> [ActionRecord] {
        actionRecords.filter { $0.nature == nature.rawValue && $0.kind == "opportunity" && $0.state == "open" && $0.validity == "current" }
    }
}

extension ControlCenter {
    /// Splitting and re-judging share the detach step. Re-judging then reuses
    /// the existing grouping channel, so receipts and validation stay the same.
    func splitRecordingExpression(sourceIDs: Set<String>) async throws -> Int {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        let count = try await store.detachRecordingsFromExpressions(sourceIDs: sourceIDs)
        await refresh()
        return count
    }
    func rejudgeRecordingExpressions(sourceIDs: Set<String>) async throws -> Int {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        guard let port = recordingExpressionModel else { throw VoiceOSError("需要先配置文本模型，才能重新判断连续表达") }
        guard !fullRecordingBusy, understandingSource == nil else { throw VoiceOSError("当前录音仍在处理，完成后再重新判断") }
        _ = try await store.detachRecordingsFromExpressions(sourceIDs: sourceIDs)
        let groups = try await store.connectRecordingExpressions(using: port)
        await refresh()
        queueRecordingTitles()
        queueTopicOrganization()
        return groups.count
    }
}
struct WorkspaceHeading: View {
    let eyebrow: String
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment:.leading,spacing:11) {
            if !eyebrow.isEmpty { Text(eyebrow).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
            Text(title).vosFont(WorkspaceText.pageTitle).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty { Text(subtitle).vosFont(WorkspaceText.body).foregroundStyle(.secondary).lineSpacing(4) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
func workspaceStateLabel(_ value:String) -> String {
    switch value {
    case "queued": return "排队中"
    case "running": return "处理中"
    case "reserved": return "等待结果"
    case "completed": return "已完成"
    case "failed": return "处理失败"
    case "blocked": return "等待条件"
    case "cancelled": return "已取消"
    case "frozen": return "已冻结"
    case "unknown": return "结果未知"
    case "rejected": return "未接纳"
    case "saved": return "已保存"
    case "reference_only": return "仅作参考"
    case "interrupted": return "处理中断"
    case "quarantined": return "已隔离"
    case "trashed": return "已移入回收站"
    default: return "状态待确认"
    }
}
fileprivate func displayTitle(_ raw:String) -> String { MarkdownDocument.plainTitle(raw) }
fileprivate let recentSearchDefaultsKey = "voiceos.recentSearches.v1"
struct WorkspaceRow: View {
    enum TrailingStyle {
        case secondary
        case status(Color)
        case link
        case dot(Color)
    }
    struct CompletionControl {
        let enabled: Bool
        let complete: () -> Void
    }
    @Environment(\.workspacePalette) private var palette
    @State private var hovered = false
    let title: String
    let subtitle: String
    var icon: String = "doc.text"
    var iconTint: Color? = nil
    var trailing: String = ""
    var trailingStyle: TrailingStyle = .secondary
    /// Spoken status for the dot style, which carries no text of its own.
    var statusAccessibility: String = ""
    var trailingGutter: CGFloat = 0
    var completion: CompletionControl? = nil
    let open: () -> Void
    var body: some View {
        if let completion {
            HStack(alignment:.top,spacing:14) {
                Button(action:completion.complete) {
                    Image(systemName:"circle").vosFont(21)
                        .foregroundStyle(completion.enabled ? palette.accent : palette.disabledText)
                        .frame(width:30,height:30).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!completion.enabled)
                    .help("标为完成").accessibilityLabel("标为完成：" + title)
                Button(action:open) { titleAndTrailing }
                    .buttonStyle(.plain).accessibilityLabel(accessibilityText)
            }
            .padding(.vertical,10).padding(.horizontal,10).padding(.trailing,trailingGutter)
            .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .background(hovered ? palette.selection.opacity(0.5) : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .onHover { hovered=$0 }
        } else {
            Button(action:open) {
                HStack(alignment:.top,spacing:14) {
                    Image(systemName:icon).vosFont(WorkspaceText.rowTitle.size).foregroundStyle(iconTint ?? palette.accent)
                        .frame(width:30,height:30).background(palette.selection.opacity(0.6),in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                        .accessibilityHidden(true)
                    titleAndTrailing
                }.padding(.vertical,10).padding(.horizontal,10).padding(.trailing,trailingGutter)
                    .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                    .background(hovered ? palette.selection.opacity(0.5) : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                    .accessibilityElement(children:.combine)
            }.buttonStyle(.plain).onHover { hovered=$0 }
                .accessibilityLabel(accessibilityText)
        }
    }
    private var accessibilityText: String {
        var parts=[title]
        if !subtitle.isEmpty { parts.append(subtitle) }
        if !statusAccessibility.isEmpty { parts.append(statusAccessibility) }
        return parts.joined(separator:" · ")
    }
    private var titleAndTrailing: some View {
        HStack(alignment:.top,spacing:14) {
            VStack(alignment:.leading,spacing:3) {
                Text(title).vosFont(WorkspaceText.rowTitle).lineSpacing(3).lineLimit(3).fixedSize(horizontal:false,vertical:true).help(title)
                if !subtitle.isEmpty { Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3).lineLimit(2).fixedSize(horizontal:false,vertical:true).help(subtitle) }
            }
            Spacer(minLength:8)
            if showsTrailing { trailingLabel }
        }
    }
    private var showsTrailing: Bool {
        if case .dot = trailingStyle { return true }
        return !trailing.isEmpty
    }
    @ViewBuilder private var trailingLabel: some View {
        switch trailingStyle {
        case .secondary:
            Text(trailing).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.top,3)
        case .status(let color):
            Text(trailing).vosFont(WorkspaceText.meta).foregroundStyle(color).padding(.top,3)
        case .link:
            HStack(spacing:3) {
                Text(trailing).vosFont(WorkspaceText.meta)
                Image(systemName:"chevron.right").vosFont(WorkspaceText.caption.size, weight: .semibold)
            }.foregroundStyle(palette.accent).padding(.top,3)
        case .dot(let color):
            Circle().fill(color).frame(width:6,height:6).padding(.top,7).accessibilityHidden(true)
        }
    }
}
private struct WorkspaceAttentionDot: View {
    @ObservedObject var model: ControlCenter
    @ObservedObject var inbox: RecordingInbox
    let open: () -> Void
    var body: some View {
        let count = model.workspaceAttentionCount
        let inboxNeedsAttention = inbox.pendingItems.contains(where: { $0.state == .needsAttention }) || !inbox.folderErrors.isEmpty
        if count > 0 || inboxNeedsAttention {
            let title = count > 0 ? "有 \(count) 项需要查看" : "有事项需要查看"
            Button(action:open) {
                HStack(spacing:7) {
                    Circle().fill(.orange).frame(width:7,height:7)
                    Text(title).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("打开处理情况").accessibilityLabel(title + "，打开处理情况")
        }
    }
}
struct WorkspaceView: View {
    @ObservedObject var model: ControlCenter
    @AppStorage("voiceos.workspaceTheme") private var theme = WorkspaceTheme.graphite
    @AppStorage("voiceos.backupRetention") private var backupRetention = 7
    @AppStorage("voiceos.sourceRail.visible") private var sourceRailVisible = true
    @Environment(\.colorScheme) private var colorScheme
    private var palette: WorkspacePalette { WorkspacePalette(theme: theme) }
    private var brandImage: NSImage? { AppBrand.image(for: colorScheme) }
    @State private var page: WorkspacePage = .home
    @State private var homeShowsPanorama = false
    @State private var path: [WorkspaceNavigationEntry] = []
    @State private var scrollPositions: [WorkspaceNavigationEntry: ScrollPosition] = [:]
    @State private var sourceScrollPositions: [String: ScrollPosition] = [:]
    @State private var topicID: String?
    @State private var topicTab = "概览"
    @State private var topicReadingMode = "卡片"
    @State private var showingDiscussion = false
    @State private var discussionContext: String?
    @State private var discussionDraft = ""
    @State private var discussionDraftSessionID: String?
    @State private var discussionDrafts: [String: String] = [:]
    @State private var pendingURL: URL?
    @State private var panoramaSourceEditor: SourceRecord?
    @State private var panoramaClaimEditor: CandidateClaim?
    @State private var showingOutcome = false
    @State private var materialFilter = "日常材料"
    @State private var actionFilter = "全部"
    @State private var savedViews: [SavedWorkspaceView] = []
    @State private var showingSaveView = false
    @State private var savingView = false
    @State private var newViewName = ""
    @State private var saveViewPage: SavedViewPage = .materials
    @State private var saveViewFilter = ""
    @State private var pendingDeleteView: SavedWorkspaceView?
    @State private var focusedActionIDs: Set<String> = []
    @State private var showingPlanToday = false
    @State private var planningToday = false
    @State private var planSelection: [String] = []
    @State private var planLimitHint = ""
    @State private var reminderSettingsTarget: WorkspaceReminderSettingsTarget?
    @State private var actionKeyboardHighlightID: String?
    @FocusState private var actionListFocused: Bool
    @State private var materialKeyboardFocus = WorkspaceKeySelection()
    @FocusState private var materialListFocused: Bool
    @State private var readingStates: [String: SourceReadingState] = [:]
    @State private var readingPlans: [IncrementalPlan] = []
    @State private var selectingActions = false
    @State private var selectedActionIDs: Set<String> = []
    @State private var pendingBatchState: LocalActionState?
    @State private var batchRunning = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var searchKeyboardFocus = WorkspaceKeySelection()
    @FocusState private var searchListFocused: Bool
    @State private var searchHits: [SearchHit] = []
    @State private var searchTotals: [SearchHit.Kind: Int] = [:]
    @State private var searchExpandedKinds: Set<SearchHit.Kind> = []
    @State private var searchFailed = false
    @State private var searchBusy = false
    @State private var searchHovered = false
    @State private var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: recentSearchDefaultsKey) ?? []
    @State private var searchArrowMonitor: Any?
    @State private var taskFeedbackDrafts: [String: TaskFeedbackDraft] = [:]
    @State private var creatingTopic = false
    @State private var savingTopic = false
    @State private var newTopicTitle = ""
    @State private var editingTopicID: String? = nil
    @State private var topicFocus: ConversationReflectionFocus?
    @State private var reviewPeriod = ReflectionPeriod.week
    @State private var reviewAnchor = Date()
    @State private var error = ""
    @State private var actionUndo: ActionUndoState?
    @State private var resultFeedbackTarget: ActionRecord?
    @State private var localCompletionOffer: ActionRecord?
    @State private var showingPendingReminderSyncs = false
    @State private var showingBackupRestore = false
    @State private var confirmingLocalSpeechDelete = false
    @State private var nextActionOutcome: ActionRecord?
    @State private var completingOutcome: ActionRecord?
    @State private var toastMessage: String?
    @State private var showingWeeklyReview = false
    @Environment(\.openWindow) private var openWindow
    private var discussionIsPresented: Bool {
        showingDiscussion && discussionDraftSessionID != nil && discussionDraftSessionID == model.discussionSession?.id
    }
    private var topic: ReflectionQuestion? { model.workspaceTopics.first { $0.id == topicID } }
    private var sourceIDs: Set<String> { Set(topicID.flatMap { model.workspaceTopicSources[$0] } ?? []) }
    private var topicSources: [SourceRecord] { model.records.filter { sourceIDs.contains($0.id) } }
    private var panoramaTopicLinks: [PanoramaTopicLink] {
        model.workspaceTopics.map { PanoramaTopicLink(id: $0.id, title: $0.title, sourceIDs: Set(model.workspaceTopicSources[$0.id] ?? [])) }
    }
    private var topicClaims: [CandidateClaim] {
        let ids=Set(topic?.organization?.sections?.flatMap(\.claimIDs) ?? [])
        return model.claims.filter { ids.contains($0.id) && $0.validity == "current" && $0.reviewState != "rejected" }
    }
    private var topicActions: [ActionRecord] {
        let ids=Set(topic?.organization?.sections?.flatMap(\.actionIDs) ?? [])
        return model.actionRecords.filter { ids.contains($0.id) && $0.validity == "current" && $0.state != "dismissed" }
    }
    private var deliveries: [AssistantExecutionRecord] { model.sortedAssistantDeliveries(model.assistantExecutions.filter { $0.validity == "current" && $0.state == "completed" }) }
    private var activeMaterials: [SourceRecord] { model.records.filter { !$0.isArchived && !$0.isTrashed } }
    private var section: String {
        switch page {
        case .themes: "主题"
        case .materials: "材料"
        case .monitor: "消息监测"
        case .source: sourceOpenedFromTheme ? "主题" : "材料"
        case .actions,.task,.delivery: "行动"
        case .home: "首页"
        case .settings: "设置"
        case .capture: "记录想法"
        case .initiate: "启动"
        case .search: "搜索"
        case .tool(let name): name
        }
    }
    private var sourceOpenedFromTheme: Bool {
        // Keep the material page in the navigation path it was opened from.
        for previous in path.reversed() {
            switch previous.page {
            case .themes: return true
            case .home, .materials, .actions, .search, .capture, .settings, .initiate: return false
            default: continue
            }
        }
        return false
    }
    var body: some View {
        alertContent
    }
    private var chrome: some View {
        HStack(spacing:0) {
            sidebar
            Divider()
            mainColumn
            if discussionIsPresented {
                Divider()
                WorkspaceDiscussionView(model:model,draft:$discussionDraft,close:{ showingDiscussion=false },openSource:{ go(.source($0)) })
                    .frame(minWidth:290,idealWidth:320,maxWidth:380)
            }
        }
    }
    private var styledContent: some View {
        chrome
            .vosFont(WorkspaceText.body).foregroundStyle(palette.text).background(palette.canvas).tint(palette.accent)
            .windowCanvasTint(palette.canvas)
            .environment(\.workspacePalette, palette)
            .environment(\.vosTextScale, model.textSize.scale)
            .dynamicTypeSize(model.textSize.dynamicType)
            .frame(minWidth:980,minHeight:700)
            .onExitCommand {
                if discussionIsPresented { showingDiscussion = false }
                else if selectingActions { exitActionSelection() }
                else if page == .search, !query.isEmpty { query="";searchFocused=true;searchKeyboardFocus.id=nil }
                else if !path.isEmpty { back() }
            }
            .workspaceToast($toastMessage)
            .navigationTitle(model.libraryTitle)
            .focusedSceneValue(\.voiceOSController,model)
    }
    private var lifecycleContent: some View {
        styledContent
            .task { await model.start() }
            .task(id:model.initialized) { if model.initialized { readingStates = await model.readingStates() } }
            .task(id:model.initialized) { if model.initialized { savedViews = await model.savedWorkspaceViews() } }
            .task { await model.setPanoramaVisible(page == .home && homeShowsPanorama) }
            .task(id:topicLoadKey) {
                guard page == .themes, let id=topicID else { topicFocus=nil; return }
                do { let focus=try await model.loadTopicReflection(id); if topicID == id && !Task.isCancelled { topicFocus=focus } }
                catch { if topicID == id && !Task.isCancelled { topicFocus=nil; self.error=error.localizedDescription } }
            }
            .onChange(of:page) { _, next in
                model.stopPlayback()
                if next != .search { searchFocused = false }
                if case .source(let id) = next { model.selected = id }
                Task { await model.setPanoramaVisible(next == .home && homeShowsPanorama) }
            }
            .onChange(of:homeShowsPanorama) { _, show in
                Task { await model.setPanoramaVisible(page == .home && show) }
            }
            .onChange(of:model.selected) { _, id in
                model.stopPlayback()
                Task { await model.refreshSourceDiscussions(); await model.refreshAssociationSelection() }
            }
            .onChange(of:model.pendingWorkspaceSourceID) { _, id in
                guard let id else { return }
                model.pendingWorkspaceSourceID = nil
                go(.source(id))
            }
            .onChange(of:model.pendingWorkspaceRoute) { _, _ in consumePendingNavigation() }
            .onChange(of:model.pendingWorkspaceTaskID) { _, _ in consumePendingNavigation() }
            .onChange(of:model.taskPresentation) { _, _ in
                if let id=model.focusedTaskID { go(.task(id)) } else { go(.actions) }
            }
            .onChange(of:model.fullRecordingInput?.id) { _, id in
                if id != nil { go(.tool("导入录音")); showingDiscussion=false }
                else if page == .tool("导入录音") { back() }
            }
            .onChange(of:page) { _, next in if next != .actions { exitActionSelection() } }
            .onChange(of:actionFilter) { _, filter in actionKeyboardHighlightID=nil;if !["全部","我的待办"].contains(filter) { exitActionSelection() } }
            .onChange(of:materialFilter) { _, _ in materialKeyboardFocus.id=nil }
            .onOpenURL { url in if model.initialized { routeExternalURL(url) } else { pendingURL=url } }
            .onChange(of:model.initialized) { _, ready in if ready,let url=pendingURL { pendingURL=nil;routeExternalURL(url) } }
            .onAppear { consumePendingNavigation() }
            .onDisappear { Task { await model.setPanoramaVisible(false) } }
    }
    private var sheetContent: some View {
        lifecycleContent
            .sheet(isPresented:$model.choosingReminderCalendar) {
                VStack(alignment:.leading,spacing:16) {
                    Text("选择提醒事项清单").vosFont(WorkspaceText.sectionTitle)
                    ForEach(model.reminderCalendars) { calendar in Button(calendar.title) { Task { model.proposedReminderCalendarID=calendar.id; await model.saveReminderConnection() } }.disabled(model.remindersBusy) }
                    if !model.status.isEmpty { Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                    Button("取消") { model.choosingReminderCalendar=false }
                }.padding(24)
                    .frame(minWidth:440,idealWidth:440,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }
            .sheet(item: $panoramaSourceEditor) { source in
                WorkspaceTranscriptEditor(model: model, source: source) { panoramaSourceEditor = nil }
            }
            .sheet(item: $panoramaClaimEditor) { claim in
                ClaimCorrectionView(claim: claim, model: model) { panoramaClaimEditor = nil }
            }
            .sheet(item:$model.pendingScheduleEffect) { effect in ReminderScheduleConfirmationView(effect:effect,model:model) { model.pendingScheduleEffect=nil } }
            .sheet(isPresented:$showingOutcome) {
                OutcomeFollowupView(actions:model.visibleOutcomeFollowups,
                    onRecord:{ action in showingOutcome=false;go(.task(action.id)) },
                    onOpen:{ action in showingOutcome=false;go(.task(action.id)) },
                    onSkip:{ model.skipOutcome($0) },
                    onDone:{ showingOutcome=false })
            }
            .sheet(isPresented:$showingWeeklyReview) {
                WeeklyReviewView(model:model,openTask:{ id in showingWeeklyReview=false;go(.task(id)) },openActions:{ showingWeeklyReview=false;go(.actions) },openFilter:{ filter in actionFilter=filter; showingWeeklyReview=false; go(.actions) })
            }
            .onChange(of:showingWeeklyReview) { _, shown in if !shown { Task { focusedActionIDs = await model.focusedActionIDs() } } }
            .sheet(isPresented:$showingSaveView) { saveViewSheet }
            .sheet(isPresented:$showingPlanToday) { planTodaySheet }
            .sheet(item:$reminderSettingsTarget) { target in
                ReminderSettingsView(action:target.action,snapshot:target.snapshot,model:model) { reminderSettingsTarget=nil }
            }
            .sheet(item:$resultFeedbackTarget) { action in ActionFeedbackView(action:action,model:model) { resultFeedbackTarget=nil } }
            .sheet(isPresented:$showingPendingReminderSyncs) { pendingReminderSyncSheet }
            .sheet(isPresented:$showingBackupRestore) { BackupLibraryRestoreView(currentRoot:model.libraryRoot) { showingBackupRestore=false } }
    }
    private var alertContent: some View {
        sheetContent
            .alert("无法导入录音或视频", isPresented: importIssueAlertPresented) {
                Button("好") { model.fullRecordingImportIssue = nil }
            } message: {
                Text(model.fullRecordingImportIssue ?? "")
            }
            .alert(batchConfirmTitle, isPresented: batchAlertPresented) {
                Button("取消", role: .cancel) { pendingBatchState = nil }
                Button(pendingBatchState == .dismissed ? "不再跟进" : "标为完成") {
                    guard let state = pendingBatchState else { return }
                    pendingBatchState = nil
                    Task { await applyActionBatch(state) }
                }
            } message: {
                Text(batchConfirmMessage)
            }
            .alert("删除视图？", isPresented: deleteViewAlertPresented) {
                Button("取消", role: .cancel) { pendingDeleteView = nil }
                Button("删除", role: .destructive) {
                    guard let view = pendingDeleteView else { return }
                    pendingDeleteView = nil
                    deleteSavedView(view)
                }
            } message: {
                Text(pendingDeleteView.map { "会从侧栏移除「\($0.name)」，材料与行动不受影响。" } ?? "")
            }
    }
    private var saveViewSheet: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("保存当前视图").vosFont(WorkspaceText.sectionTitle)
            Text(saveViewPage == .materials ? "材料 · " + saveViewFilter : "行动 · " + saveViewFilter).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            TextField("视图名称",text:$newViewName).textFieldStyle(.roundedBorder)
                .onChange(of:newViewName) { _, value in if value.count > ControlCenter.savedViewNameLimit { newViewName = String(value.prefix(ControlCenter.savedViewNameLimit)) } }
            if savedViews.count >= ControlCenter.savedViewsLimit {
                Text("最多保存 \(ControlCenter.savedViewsLimit) 个视图，可先删除一个。").vosFont(WorkspaceText.meta).foregroundStyle(palette.danger)
            } else if savedViews.contains(where: { $0.name == trimmedNewViewName }) {
                Text("已有同名视图，请换一个名称。").vosFont(WorkspaceText.meta).foregroundStyle(palette.danger)
            }
            HStack {
                Spacer()
                Button("取消") { showingSaveView=false }
                Button("保存") { Task { await saveView() } }.buttonStyle(.borderedProminent).disabled(!canSaveView || savingView)
            }
        }.padding(24).frame(width:400)
    }
    private var importIssueAlertPresented: Binding<Bool> {
        Binding(get: { model.fullRecordingImportIssue != nil }, set: { if !$0 { model.fullRecordingImportIssue = nil } })
    }
    private var batchAlertPresented: Binding<Bool> {
        Binding(get: { pendingBatchState != nil }, set: { if !$0 { pendingBatchState = nil } })
    }
    private var deleteViewAlertPresented: Binding<Bool> {
        Binding(get: { pendingDeleteView != nil }, set: { if !$0 { pendingDeleteView = nil } })
    }
    private var completingOutcomeAlertPresented: Binding<Bool> {
        Binding(get: { completingOutcome != nil }, set: { if !$0 { completingOutcome = nil } })
    }
    private var mainColumn: some View {
        VStack(spacing:0) {
            header
            Divider()
            workspaceErrorBanner
            Group {
                if !model.startupIssue.isEmpty {
                    ContentUnavailableView {
                        Label("资料库尚未打开",systemImage:"exclamationmark.triangle")
                    } description: {
                        Text(model.startupIssue).textSelection(.enabled)
                    } actions: {
                        Button("重试打开资料库") { Task { await model.start() } }.buttonStyle(.borderedProminent)
                        Button("打开其他资料库",action:chooseLibrary)
                    }
                } else if !model.initialized || !model.workspaceLoaded {
                    ProgressView("正在打开资料库…").controlSize(.small).frame(maxWidth:.infinity,maxHeight:.infinity)
                } else { pageContent }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            if !error.isEmpty { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger).textSelection(.enabled).padding(12) }
            if model.workspaceProcessingBarVisible, page != .tool("处理情况") {
                WorkspaceProcessingBar(model: model) { go(.tool("处理情况")) }
            }
        }.frame(minWidth:440)
    }
    @ViewBuilder private var workspaceErrorBanner: some View {
        if let message = model.workspaceLastError {
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Label(message,systemImage:"exclamationmark.triangle.fill").vosFont(WorkspaceText.meta).foregroundStyle(palette.danger).textSelection(.enabled)
                Spacer(minLength:8)
                if model.workspaceLastErrorRetry != nil { Button("重试") { model.retryWorkspaceError() } }
                Button { model.clearWorkspaceError() } label: { Image(systemName:"xmark").vosFont(WorkspaceText.caption) }
                    .buttonStyle(.plain).accessibilityLabel("关闭错误提示")
            }.padding(.horizontal,20).padding(.vertical,10).background(palette.surface)
        }
    }
    private var topicLoadKey: String {
        guard page == .themes, let id = topicID else { return "" }
        return id + (topic?.updatedAt ?? "") + String(model.recentOutcomes.count) + topicActions.map { $0.id+String($0.version) }.joined()
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:28) {
            HStack(spacing:9) {
                if let brandImage {
                    Image(nsImage: brandImage).resizable().interpolation(.high).frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName:"waveform").vosFont(19, weight: .medium)
                }
                Text("VoiceOS").vosFont(19, weight: .medium)
            }.padding(.horizontal,9)
            VStack(spacing:5) {
                nav("首页",icon:"house",target:.home,id:"home")
                nav("主题",icon:"circle.hexagongrid",target:.themes,id:"themes")
                nav("材料",icon:"books.vertical",target:.materials,id:"materials")
                nav("消息监测",icon:"bell.badge",target:.monitor,id:"monitor",badge:model.monitorOpenItemCount,badgeAccessibility:"未处理事项 \(model.monitorOpenItemCount) 条")
                nav("行动",icon:"checkmark.circle",target:.actions,id:"actions",badge:model.unreadDeliveryCount)
                nav("启动",icon:"arrow.up.forward",target:.initiate,id:"initiate")
            }
            if !savedViews.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    Text("视图").vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(.secondary).padding(.horizontal,9).accessibilityAddTraits(.isHeader)
                    VStack(spacing:2) {
                        ForEach(savedViews) { view in
                            Button { openSavedView(view) } label: {
                                Label(view.name,systemImage:view.page == .materials ? "books.vertical" : "checkmark.circle")
                                    .vosFont(WorkspaceText.body).lineLimit(1)
                                    .frame(maxWidth:.infinity,alignment:.leading)
                                    .padding(.horizontal,9).padding(.vertical,7)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .help(view.page == .materials ? "材料：" + view.filter : "行动：" + view.filter)
                                .contextMenu { Button("删除视图",role:.destructive) { pendingDeleteView = view } }
                                .accessibilityLabel("打开视图：" + view.name)
                                .accessibilityIdentifier("workspace.savedView." + view.name)
                        }
                    }
                }
            }
            Spacer()
            VStack(alignment:.leading,spacing:12) {
                HStack(spacing:7) {
                    if model.organizingTopics || model.assistantBusy || model.followupBusy { ProgressView().controlSize(.mini) }
                    if model.organizingTopics { Text("AI 正在连接主题").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                }
                if page != .tool("处理情况") {
                    WorkspaceAttentionDot(model: model, inbox: model.recordingInbox) { go(.tool("处理情况")) }
                }
                Button { go(.settings);showingDiscussion=false } label: { Label("设置",systemImage:"slider.horizontal.3").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    .accessibilityIdentifier("nav.settings")
            }.padding(.horizontal,8)
                .onChange(of:model.pendingWorkspacePageRequest) { _, request in
                    guard let request else { return }
                    model.pendingWorkspacePageRequest = nil
                    switch request {
                    case .home: path=[];page = .home;error=""
                    case .themes: path=[];page = .themes;topicID=nil;topicFocus=nil;error=""
                    case .materials: path=[];page = .materials;error=""
                    case .actions: path=[];page = .actions;error=""
                    case .initiate: path=[];page = .initiate;error=""
                    case .processing: path=[];page = .tool("处理情况");error=""
                    case .back: back()
                    }
                }
        }.padding(.horizontal,13).padding(.vertical,28).frame(width:172).background(palette.sidebar)
            .onAppear { AppBrand.applyApplicationIcon() }
            .onChange(of: colorScheme) { _, _ in AppBrand.applyApplicationIcon() }
    }
    private func nav(_ title:String,icon:String,target:WorkspacePage,id:String,badge:Int = 0,badgeAccessibility:String? = nil) -> some View {
        Button { path=[];page=target;if target == .themes { topicID=nil;topicFocus=nil };error="" } label: {
            HStack(spacing:8) {
                Label(title,systemImage:icon).vosFont(WorkspaceText.body.size, weight: section == title ? .semibold : .regular)
                Spacer(minLength:0)
                if badge > 0 {
                    Text(String(badge)).vosFont(WorkspaceText.caption.size, weight: .semibold)
                        .foregroundStyle(palette.canvas).padding(.horizontal,6).frame(minWidth:18,minHeight:18)
                        .background(palette.accent,in:Capsule())
                }
            }
                .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,11)
                .background(section == title ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                // Plain buttons otherwise only hit-test the icon and text, leaving the padded row inert.
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("nav."+id)
            .accessibilityLabel(badge > 0 ? title + "，" + (badgeAccessibility ?? "AI 交付 \(badge) 份待读") : title)
            .accessibilityAddTraits(section == title ? .isSelected : [])
    }
    private var header: some View {
        HStack(spacing:12) {
            if !path.isEmpty {
                Button(action:back) {
                    Image(systemName:"chevron.left").vosFont(WorkspaceText.body.size, weight: .medium)
                        .frame(width:44,height:44)
                        .background(palette.selection.opacity(0.5),in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("返回").help("返回上一页")
                if showsBreadcrumb { Text(breadcrumb).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button { if page == .search { searchFocused = true } else { go(.search) } } label: {
                HStack(spacing:6) {
                    Image(systemName:"magnifyingglass").vosFont(WorkspaceText.meta.size, weight: .medium)
                    Text("搜索").vosFont(WorkspaceText.meta)
                }.foregroundStyle(.secondary).padding(.horizontal,10).frame(height: WorkspaceMetrics.fieldHeight)
                    .background(searchHovered ? palette.hover : palette.surface,in:Capsule())
                    .overlay { Capsule().strokeBorder(palette.border,lineWidth:1) }
                    .contentShape(Capsule())
            }.buttonStyle(.plain).onHover { searchHovered=$0 }
                .accessibilityLabel("搜索").help("搜索全部内容（⌘F）")
            WorkspaceIconButton(systemImage:"sidebar.right",label:"讨论") { Task { await toggleDiscussion() } }
                .disabled(model.discussionSaving || model.discussionSending || !discussionEntryAvailable)
                .help(discussionEntryHint)
                .accessibilityIdentifier("workspace.discussion")
            Button { go(.capture) } label: {
                HStack(spacing:6) {
                    Image(systemName:"mic").vosFont(WorkspaceText.meta.size, weight: .medium)
                    Text("记录想法").vosFont(WorkspaceText.meta.size, weight: .medium)
                }.foregroundStyle(palette.canvas).padding(.horizontal,12).frame(height:30)
                    .background(palette.accent,in:Capsule())
                    .contentShape(Capsule())
            }.buttonStyle(.plain)
                .accessibilityLabel("记录想法").help("记录想法")
        }.padding(.horizontal,26).frame(minHeight:58).background(palette.canvas)
    }
    private var showsBreadcrumb: Bool {
        guard !path.isEmpty else { return false }
        switch page {
        case .source, .task, .delivery: return true
        default: return false
        }
    }
    private var breadcrumb: String {
        switch page {
        case .source(let id): (sourceOpenedFromTheme ? "主题 / " + (sourceIDs.contains(id) ? topic?.title ?? "全部材料" : "全部材料") : "材料") + " / " + sourceNavigationTitle(id)
        case .delivery: "行动 / AI 交付"
        case .task: "行动 / 任务与结果"
        case .themes: topic.map { "主题 / " + $0.title } ?? "主题"
        default: section
        }
    }
    @ViewBuilder private var pageContent: some View {
        switch page {
        case .home:
            VStack(spacing: 0) {
                HStack {
                    Picker("首页视图", selection: $homeShowsPanorama) {
                        Text("最近").tag(false)
                        Text("全景").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 172)
                    Spacer()
                }.padding(.horizontal, 26).padding(.top, 12).padding(.bottom, 2)
                if homeShowsPanorama {
                    PanoramaHome(screen: model.panorama, retry: model.retryPanorama, draft: model.generateDraftPanorama, chooseTextModel: model.chooseTextModel,
                        openMaterials: { go(.materials) }, openSource: { go(.source($0)) }, correctSource: { id in
                            panoramaSourceEditor = model.sourcePageIndex.recordsByID[id]
                        }, correctClaim: { id in
                            panoramaClaimEditor = model.sourcePageIndex.claim(for: id)
                        }, discuss: { snapshot, selection in
                            Task { await openPanoramaDiscussion(snapshotID: snapshot, selection: selection) }
                        }, topicLinks: panoramaTopicLinks, openTopic: { selectTopic($0) }, themeReply: { briefing in
                            try await model.themeReply(briefing)
                        })
                } else {
                    RecentContentHome(model: model, openSource: { go(.source($0)) }, openSpan: { sourceID, spanID in
                        sourceScrollPositions[sourceID] = ScrollPosition(id: "source-span-" + spanID)
                        go(.source(sourceID))
                    }, openTask: { go(.task($0)) }, capture: { go(.capture) })
                }
            }
        case .themes: scrolled { themes }.id(navigationEntry)
        case .materials:
            ScrollViewReader { proxy in
                scrolled { materials }
                    .focusable()
                    .focused($materialListFocused)
                    .focusEffectDisabled()
                    .onKeyPress { handleMaterialListKey($0) }
                    .onChange(of:materialKeyboardFocus.id) { _, id in guard let id else { return };proxy.scrollTo(id,anchor:.center) }
                    .onAppear { requestMaterialListFocus() }
            }
        case .actions:
            ScrollViewReader { proxy in
                scrolled { actions }
                    .focusable()
                    .focused($actionListFocused)
                    .focusEffectDisabled()
                    .onKeyPress { handleActionListKey($0) }
                    .onChange(of:actionKeyboardHighlightID) { _, id in guard let id else { return };proxy.scrollTo(id,anchor:.center) }
                    .onChange(of:showingPlanToday) { _, shown in if !shown { requestActionListFocus() } }
                    .onAppear { requestActionListFocus() }
                    .task(id:actionUndo?.token) {
                        guard actionUndo != nil else { return }
                        do { try await Task.sleep(for:.seconds(8)) } catch { return }
                        actionUndo=nil
                    }
                    .overlay(alignment:.bottom) {
                        VStack(spacing:8) {
                            if actionUndo != nil { actionUndoBar }
                            if selectingActions { actionSelectionBar }
                        }
                    }
            }
        case .initiate: TaskInitiationView(model:model,openSource:{ go(.source($0)) })
        case .source(let id):
            HStack(spacing:0) {
                if sourceRailVisible {
                    sourceRail(selectedID:id)
                    Divider()
                } else {
                    collapsedSourceRail
                }
                Group {
                    if let source=model.sourcePageIndex.recordsByID[id] {
                        if source.isTrashed { TrashedMaterialView(model:model,source:source) }
                        else {
                            WorkspaceSourceView(model:model,source:source,openTask:{ go(.task($0)) },openDelivery:{ go(.delivery($0)) },openDiscussion:{ id in Task { await openSavedDiscussion(id) } },openSource:{ go(.source($0)) },openInitiation:{ id in
                                model.initiationSourceID = id
                                model.initiationText = model.sourcePageIndex.recordsByID[id]?.transcript ?? ""
                                go(.initiate)
                            },openFollowups:{ go(.tool("思想与下一步")) },scroll:sourceScrollBinding(id))
                                .id(id)
                        }
                    } else { unavailable("这份材料暂时不可用",description:"可以搜索其他材料，或回到主题。") }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        case .delivery(let id):
            if let execution=model.assistantExecutions.first(where: { $0.id == id }) {
                WorkspaceDeliveryView(model:model,execution:execution,openTask:{ go(.task($0)) },openTopic:{ selectTopic($0) },discuss:{ Task { await toggleDiscussion(force:true) } })
            } else { unavailable("交付暂时不可用",description:"可以回到行动查看当前结果。") }
        case .task(let id):
            if let action=model.sourcePageIndex.allAction(for: id) {
                WorkspaceTaskView(model:model,action:action,draft:Binding(
                    get: { taskFeedbackDrafts[id] ?? TaskFeedbackDraft() },
                    set: { taskFeedbackDrafts[id] = $0 }
                ),openSource:{ go(.source($0)) },openDelivery:{ go(.delivery($0)) },discuss:{ Task { await toggleDiscussion(force:true) } })
                    .id(id)
            } else { unavailable("任务暂时不可用",description:"可以回到行动查看当前事项。") }
        case .monitor: scrolled { WorkspaceMonitorView(model:model) }
        case .settings: scrolled { settings }
        case .capture:
            VStack(alignment:.leading,spacing:0) {
                VStack(alignment:.leading,spacing:10) {
                    HStack {
                        Button(model.dictationActive ? "停止并整理" : "开始口述并自动整理",systemImage:model.dictationActive ? "stop.circle" : "mic") {
                            if model.dictationActive { model.stopDictation() } else { Task { await model.startDictation(processAfterTranscription:true) } }
                        }.buttonStyle(.borderedProminent).disabled(model.dictationBusy || model.fullRecordingBusy || (!model.dictationActive && model.recordingModelIssue != nil))
                        Button("导入音频 / 视频") { model.chooseFullRecording() }
                    }
                    if let issue = model.recordingModelIssue {
                        HStack(spacing:10) {
                            Text(issue).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                            if !model.speechConfigured { Button("配置本地 Qwen 转写…") { model.chooseLocalSpeech() }.controlSize(.small) }
                            if !model.textModelConfigured { Button("配置文本模型…") { model.chooseTextModel() }.controlSize(.small) }
                        }
                    }
                }.padding(24)
                TextCaptureView(model:model,draft:$model.textCaptureDraft,onSaved:{ if page == .capture { go(.source($0)) } },dismiss:back)
            }.frame(maxWidth: WorkspaceMetrics.pageWidth).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        case .search:
            ScrollViewReader { proxy in
                scrolled { search }
                    .focusable()
                    .focused($searchListFocused)
                    .focusEffectDisabled()
                    .onKeyPress { handleSearchListKey($0) }
                    .onChange(of:searchKeyboardFocus.id) { _, id in guard let id else { return };proxy.scrollTo(id,anchor:.center) }
                    .onAppear { installSearchArrowMonitor() }
                    .onDisappear { removeSearchArrowMonitor() }
            }
        case .tool(let name): tool(name)
        }
    }
    private func scrolled<Content:View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView { content().frame(maxWidth: WorkspaceMetrics.pageWidth,alignment:.leading).padding(WorkspaceMetrics.pagePadding).frame(maxWidth:.infinity,alignment:.top) }
            .scrollPosition(scrollBinding(for: scrollKey))
    }
    private func scrollBinding(for key: WorkspaceNavigationEntry) -> Binding<ScrollPosition> {
        Binding(get: { scrollPositions[key] ?? ScrollPosition(edge: .top) }, set: { scrollPositions[key] = $0 })
    }
    private var scrollKey: WorkspaceNavigationEntry {
        // A filter switches the visible list, so it must not inherit another list's offset.
        var entry = navigationEntry
        switch page {
        case .materials: entry.listFilter = materialFilter
        case .actions: entry.listFilter = actionFilter
        default: break
        }
        return entry
    }
    private func sourceScrollBinding(_ id:String) -> Binding<ScrollPosition> {
        Binding(get: { sourceScrollPositions[id] ?? ScrollPosition(edge: .top) }, set: { sourceScrollPositions[id] = $0 })
    }
    private func unavailable(_ title:String,description:String) -> some View { ContentUnavailableView(title,systemImage:"leaf",description:Text(description)).frame(maxWidth:.infinity) }
    private func distinctExpressions(_ sources:[SourceRecord]) -> [SourceRecord] {
        let index=model.sourcePageIndex
        let catalog=index.recordsByID
        let attachedContextIDs=Set(sources.compactMap { contextSourceID($0,catalog:catalog) })
        var seen=Set<String>()
        return sources.filter { source in
            // Keep a context recording independently reachable when its personal
            // recording is outside this list, rather than hiding it globally.
            guard !attachedContextIDs.contains(source.id) else { return false }
            guard let expression=index.expression(for:source.id),expression.sourceIDs.count > 1 else { return true }
            return seen.insert(expression.id).inserted
        }
    }
    private var readingMaterials: [SourceRecord] { materialRows(materialFilter, catalog: recordCatalog) }
    private func materialRows(_ filter:String,catalog:[String:SourceRecord]) -> [SourceRecord] {
        let selected=model.records.filter { source in
            switch filter {
            case "回收站": return source.isTrashed
            case "已归档": return source.isArchived
            case "未读": return !source.isArchived && !source.isTrashed && (readingStates[source.id] ?? .unread) == .unread
            case "在读": return !source.isArchived && !source.isTrashed && readingStates[source.id] == .reading
            default: return !source.isArchived && !source.isTrashed
            }
        }
        let selectedIDs=Set(selected.map(\.id))
        let attachedContextIDs=Set(selected.compactMap { contextSourceID($0,catalog:catalog) }).intersection(selectedIDs)
        let entries=selected.compactMap { source -> (SourceRecord,String)? in
            guard !attachedContextIDs.contains(source.id) else { return nil }
            guard let expression=model.sourcePageIndex.expression(for:source.id),expression.sourceIDs.count > 1, Set(expression.sourceIDs).isSubset(of:selectedIDs) else { return (source,source.createdAt) }
            guard expression.sourceIDs.first == source.id else { return nil }
            return (source,expression.sourceIDs.compactMap { catalog[$0]?.createdAt }.max() ?? source.createdAt)
        }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
    }
    /// Counts ride on the filter labels; the page title carries no floating number.
    private func materialTabs(catalog:[String:SourceRecord]) -> [(filter:String,label:String)] {
        SavedViewPage.materials.filters.map { filter in
            (filter: filter, label: filter + " " + String(materialRows(filter, catalog: catalog).count))
        }
    }
    private func materialDayGroups(_ sources: [SourceRecord]) -> [MaterialDayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [SourceRecord]] = [:]
        for source in sources {
            let day = calendar.startOfDay(for: ConversationReflectionFocus.date(source.createdAt) ?? .distantPast)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(source)
        }
        return order.map { MaterialDayGroup(id: $0, label: materialDayLabel($0), sources: buckets[$0] ?? []) }
    }
    private func materialDayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }
    private func contextSourceID(_ source:SourceRecord,catalog:[String:SourceRecord]) -> String? {
        guard let pair=source.presentation?.recordingContext,pair.personalSourceID == source.id,
              let external=catalog[pair.externalSourceID],!source.localOnly,!external.localOnly,
              !source.needsTranscriptionReview,!external.needsTranscriptionReview,
              source.transcriptVersionID == pair.personalVersionID,external.transcriptVersionID == pair.externalVersionID,
              source.policyVersion == pair.personalPolicyVersion,external.policyVersion == pair.externalPolicyVersion else { return nil }
        return external.id
    }
    private var materials: some View {
        let catalog = recordCatalog
        let tabs = materialTabs(catalog: catalog)
        let rows = materialRows(materialFilter, catalog: catalog)
        return LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            HStack(alignment:.top,spacing:12) {
                WorkspaceHeading(eyebrow:"",title:"材料")
                WorkspaceHeaderMenu {
                    Button("保存当前视图",systemImage:"bookmark") { beginSavingView(.materials,filter:materialFilter) }
                }
            }
            if materialFilter == "日常材料", !todayReading.isEmpty {
                WorkspaceListSection(title:"今日阅读",subtitle:"上次停下的地方，接着读。",count:todayReading.count) {
                    ForEach(todayReading) { item in
                        WorkspaceRow(title:displayTitle(item.source.displayTitle),subtitle:chunkLabel(item),icon:"book") { go(.source(item.id)) }
                        if item.id != todayReading.last?.id { WorkspaceListDivider() }
                    }
                }
            }
            WorkspaceTabs(selection:Binding(get: { tabs.first { $0.filter == materialFilter }?.label ?? materialFilter }, set: { label in if let tab = tabs.first(where: { $0.label == label }) { materialFilter = tab.filter } }), titles:tabs.map { $0.label }, style:.filters)
            if ["已归档","回收站"].contains(materialFilter) {
                Text(materialFilter == "已归档" ? "归档材料仍可作为历史依据；打开材料可取消归档。" : "原件与历史保留，不用于当前理解；恢复后仅本机保存。Apple 提醒事项未被删除或取消。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            if rows.isEmpty {
                if materialFilter == "日常材料" {
                    WorkspaceEmptyState(title: model.records.isEmpty ? "还没有材料" : "日常材料是空的", systemImage:"tray", description: model.records.isEmpty ? "可以先记录想法，或导入一段录音、视频。" : "其他材料在已归档或回收站里，可以切换查看。") {
                        Button("添加材料") { go(.capture) }.buttonStyle(.borderedProminent)
                    }
                } else if materialFilter == "未读" {
                    WorkspaceEmptyState(title:"没有未读材料",systemImage:"eye",description:"新材料默认未读，打开后会标为在读。") {
                        Button("查看日常材料") { materialFilter="日常材料" }
                    }
                } else if materialFilter == "在读" {
                    WorkspaceEmptyState(title:"没有在读的材料",systemImage:"book",description:"打开未读材料后会自动出现在这里。") {
                        Button("查看日常材料") { materialFilter="日常材料" }
                    }
                } else {
                    WorkspaceEmptyState(title:"这里暂时没有材料",systemImage:materialFilter == "回收站" ? "trash" : "archivebox",description:materialFilter == "已归档" ? "归档材料仍可作为历史依据；打开材料可取消归档。" : "原件与历史保留；恢复后仅本机保存。") {
                        Button("查看日常材料") { materialFilter="日常材料" }
                    }
                }
            } else {
                LazyVStack(alignment:.leading,spacing:16) {
                    ForEach(materialDayGroups(rows)) { group in
                        VStack(alignment:.leading,spacing:6) {
                            WorkspaceListGroupHeader(title:group.label)
                            VStack(alignment:.leading,spacing:8) {
                                ForEach(group.sources) { source in
                                    MaterialMenuRow(revealed: materialKeyboardFocus.id == source.id) {
                                        MaterialManagementControls(model:model,source:source,style:.compact)
                                    } row: {
                                        sourceRow(source,catalog:catalog,trailingGutter: source.isArchived || source.isTrashed ? WorkspaceRowChrome.materialWideGutter : WorkspaceRowChrome.materialGutter).frame(maxWidth:.infinity,alignment:.leading).materialCard(highlighted: materialKeyboardFocus.id == source.id)
                                    }.id(source.id)
                                }
                            }
                        }
                    }
                }
            }
        }.task { await loadReadingPlans() }
    }
    private var themes: some View {
        let catalog = recordCatalog
        return LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            if let topic {
                HStack { Button("所有主题",systemImage:"arrow.left") { if path.last?.page == .themes && path.last?.topicID == nil { back() } else { topicID=nil;topicFocus=nil };creatingTopic=false;newTopicTitle="";editingTopicID=nil };Spacer(); Menu("调整主题") { Button("修改主题名称") { newTopicTitle=topic.title;editingTopicID=topic.id;creatingTopic=true };Button("重新连接当前材料") { model.queueTopicOrganization(retry:true) } } }
                WorkspaceHeading(eyebrow:"",title:topic.title,subtitle:"\(topicSources.count) 份材料")
                if let titleSource=model.sourcePageIndex.recordsByID[topic.sourceID] {
                    Button { go(.source(titleSource.id)) } label: {
                        HStack(spacing:5) {
                            Text("标题取自《" + displayTitle(titleSource.displayTitle) + "》").vosFont(WorkspaceText.meta)
                            Image(systemName:"arrow.up.forward.square").vosFont(WorkspaceText.caption.size, weight:.semibold)
                        }.foregroundStyle(palette.secondaryText).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help("打开主题标题的来源材料")
                        .accessibilityLabel("标题取自《" + displayTitle(titleSource.displayTitle) + "》，打开来源材料")
                }
                WorkspaceTabs(selection:$topicTab,titles:["概览","认识与问题","行动与结果","材料"])
                topicContent(topic)
            } else {
                HStack { WorkspaceHeading(eyebrow:"",title:"主题")
                    Spacer();Button("新建主题") { newTopicTitle="";editingTopicID=nil;creatingTopic=true }
                }
                if !model.workspaceTopics.isEmpty {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:290),spacing:16)],alignment:.leading,spacing:16) {
                        ForEach(model.workspaceTopics) { item in
                            WorkspaceTopicTile(topic:item,sourceCount:model.workspaceTopicSources[item.id]?.count ?? 0) { selectTopic(item.id) }
                        }
                    }
                }
                if model.workspaceTopics.isEmpty { Text(model.organizingTopics ? "AI 正在按内容连接主题…" : "授权材料会自动归组。也可以先建立一个你关心的问题。").foregroundStyle(.secondary) }
                let linked=Set(model.workspaceTopicSources.values.flatMap { $0 })
                let unlinked=activeMaterials.filter { !linked.contains($0.id) }
                if !unlinked.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        DisclosureGroup {
                            ForEach(distinctExpressions(unlinked)) { source in
                                sourceRow(source,catalog:catalog,reason:source.topicAssignmentReason(in:catalog))
                            }
                        } label: {
                            HStack(spacing:10) {
                                Text("尚未归入主题的材料（\(unlinked.count)）").vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.secondaryText).accessibilityAddTraits(.isHeader)
                                Spacer(minLength:8)
                                Button(model.organizingTopics ? "AI 正在归组…" : "交给 AI 归组") { model.queueTopicOrganization() }
                                    .vosFont(WorkspaceText.meta)
                                    .disabled(model.organizingTopics || !model.modelConfigured)
                                    .help(model.modelConfigured ? "让 AI 把这些材料连接到已有或新的主题" : "先配置文本模型，才能交给 AI 归组")
                            }.contentShape(Rectangle())
                        }
                        Text(unassignedTopicReasonSummary(unlinked,catalog:catalog)).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                        if !model.topicOrganizationStatus.isEmpty { Text(model.topicOrganizationStatus).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText) }
                    }
                }
            }
            if creatingTopic {
                VStack(alignment:.leading,spacing:14) {
                    TextField("你持续关心的主题或问题",text:$newTopicTitle).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("取消") { creatingTopic=false;editingTopicID=nil }
                        Button("保存主题") { Task { await saveTopic() } }.buttonStyle(.borderedProminent).disabled(newTopicTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || savingTopic)
                    }
                }.padding(18).background(palette.selection,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            }
        }
    }
    @ViewBuilder private func topicContent(_ topic:ReflectionQuestion) -> some View {
        switch topicTab {
        case "材料":
            let catalog = recordCatalog
            let expressions = distinctExpressions(topicSources)
            WorkspaceSection(title:"主题材料",subtitle:"完整原话与资料，按时间延续",icon:"books.vertical",count:topicSources.count) {
                ForEach(expressions) { source in sourceRow(source,catalog:catalog);if source.id != expressions.last?.id { Divider() } }
            }
            DisclosureGroup("关联其他材料") {
                ForEach(model.records.filter { !sourceIDs.contains($0.id) && !$0.isTrashed && !($0.transcript ?? "").isEmpty }) { source in
                    Button(displayTitle(source.displayTitle)) { Task { do { try await model.linkReflectionQuestionSource(questionID:topic.id,sourceID:source.id,linked:true);await model.refresh() } catch { self.error=error.localizedDescription } } }
                }
            }
        case "认识与问题":
            Picker("阅读方式",selection:$topicReadingMode) { Text("小主题卡片").tag("卡片");Text("材料图谱").tag("图谱");Text("周期回顾").tag("回顾") }.pickerStyle(.segmented)
            if topicReadingMode == "图谱" {
                ReflectionTimelineView(model:model,embeddedTopicID:topic.id,openSource:{ go(.source($0)) },dismiss:{},discuss:{ claim in discussClaim(claim) },reflect:{ focus,prompt in await openReflection(focus,prompt:prompt) }).frame(minHeight:620)
            } else if topicReadingMode == "回顾" { review(topic) }
            else {
                topicReading(topic,mode:"认识与问题")
                WorkspaceTopicEntry(model:model,topic:topic,sourceIDs:Array(sourceIDs))
            }
        default: topicReading(topic,mode:topicTab)
        }
    }
    private func topicReading(_ topic:ReflectionQuestion,mode:String) -> some View {
        WorkspaceTopicReadingView(model:model,topic:topic,mode:mode,focus:topicFocus,
            openSource:{ go(.source($0)) },openTopic:{ selectTopic($0) },openTask:{ go(.task($0)) },openDelivery:{ go(.delivery($0)) },
            discuss:{ prompt in Task { await toggleDiscussion(force:true,prompt:prompt) } },showActions:{ topicTab="行动与结果" },
            showUnderstanding:{ topicTab="认识与问题";topicReadingMode="卡片" })
            .id(topic.id + mode)
    }
    private func review(_ topic:ReflectionQuestion) -> some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                Picker("回顾周期",selection:$reviewPeriod) { ForEach(ReflectionPeriod.allCases,id:\.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented).frame(maxWidth:210)
                DatePicker("日期",selection:$reviewAnchor,displayedComponents:.date).labelsHidden()
            }
            Text("放在完整主题的脉络里，看这段时间的变化。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            let interval=reviewPeriod.interval(containing:reviewAnchor)
            let sources=topicSources.filter { interval.contains($0.expressedDate ?? ConversationReflectionFocus.date($0.createdAt) ?? .distantPast) }
            let catalog=recordCatalog
            ForEach(distinctExpressions(sources)) { sourceRow($0,catalog:catalog);Divider() }
            let actionIDs=Set(topicActions.map(\.id))
            let outcomes=(topicFocus?.outcomes ?? []).filter { actionIDs.contains($0.actionID) && ConversationReflectionFocus.date($0.createdAt).map { interval.contains($0) } == true }
            ForEach(outcomes) { outcome in WorkspaceRow(title:outcome.text,subtitle:"实际结果 · " + dateLabel(outcome.createdAt),icon:"leaf") { go(.task(outcome.actionID)) } }
            if sources.isEmpty && outcomes.isEmpty { Text("这段时间还没有新增材料或结果。这个主题的历史脉络仍保留在概览中。").foregroundStyle(.secondary) }
            Button("让 AI 一起回顾这个周期",systemImage:"sparkles") { Task { do { let focus=try await model.loadQuestionReflection(topic.id,interval:interval,period:reviewPeriod);_ = await openReflection(focus,prompt:reviewPeriod.reviewPrompt(dateLabel:interval.start.formatted(date:.abbreviated,time:.omitted),questionTitle:topic.title)) } catch { self.error=error.localizedDescription } } }.buttonStyle(.borderedProminent)
        }
    }
    @State private var showingClarifyQueue = false
    @State private var clarifyScope: ClarifyQueueScope = .questions
    private var actions: some View {
        let nextStepCounts=ActionRowLayout.nextStepCounts(model.actionRecords)
        let rowReads=ActionRowReads(reminderLinks:model.reminderLinks,executions:model.assistantExecutions)
        let listGroup:ActionRowGroup=actionFilter == "已完成" ? .completed : actionFilter == "历史记录" ? .history : actionFilter == "待核对" ? .needsReview : .active
        return LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            HStack(alignment:.top,spacing:12) {
                WorkspaceHeading(eyebrow:"",title:"行动")
                if model.unreadDeliveryCount > 0 {
                    Button { actionFilter = "AI 助理"; error = "" } label: {
                        HStack(spacing:6) {
                            Image(systemName:"doc.text").vosFont(WorkspaceText.meta.size, weight:.medium)
                            Text("AI 交付 \(model.unreadDeliveryCount) 份待读").vosFont(WorkspaceText.meta.size, weight:.medium)
                        }.foregroundStyle(palette.accent).padding(.horizontal,10).frame(height:30)
                            .background(palette.accent.opacity(0.12),in:Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("AI 交付 \(model.unreadDeliveryCount) 份待读，打开列表")
                }
                if actionFilter == "我的待办" {
                    Button { beginPlanningToday() } label: {
                        HStack(spacing:6) {
                            Image(systemName:"sun.max").vosFont(WorkspaceText.meta.size, weight: .medium)
                            Text("安排今天").vosFont(WorkspaceText.meta.size, weight: .medium)
                        }.foregroundStyle(palette.canvas).padding(.horizontal,12).frame(height:30)
                            .background(palette.accent,in:Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("安排今天").help("从即将与随时里挑最多 3 条加入专注")
                }
                WorkspaceHeaderMenu {
                    if ["问题","目标"].contains(actionFilter) {
                        Button("逐个澄清", systemImage:"checklist") {
                            clarifyScope = actionFilter == "目标" ? .goals : .questions
                            showingClarifyQueue=true
                        }
                    }
                    if ["全部","我的待办"].contains(actionFilter) {
                        Button(selectingActions ? "取消选择" : "选择") { if selectingActions { exitActionSelection() } else { selectingActions=true } }.disabled(batchRunning)
                    }
                    Button("保存当前视图",systemImage:"bookmark") { beginSavingView(.actions,filter:actionFilter) }
                    Button("每周回顾",systemImage:"calendar.badge.clock") { showingWeeklyReview=true }
                }
            }.sheet(isPresented:$showingClarifyQueue) { ActionClarifyQueueView(model:model, scope:clarifyScope) }
            WorkspaceTabs(selection:$actionFilter,titles:SavedViewPage.actions.filters,style:.filters)
            if let offer = localCompletionOffer {
                HStack(spacing:12) {
                    WorkspaceNoticeText(message: model.status.isEmpty ? "提醒事项不可用；可以先本地完成，稍后核对。" : model.status, severity:.warning)
                    Spacer(minLength:8)
                    Button("仅本地完成（稍后核对）") { completeLocally(offer) }
                    Button("稍后再说") { localCompletionOffer = nil }.buttonStyle(.borderless)
                }
            }
            if !model.pendingReminderSyncs.isEmpty {
                Button { showingPendingReminderSyncs = true } label: {
                    HStack(spacing:6) {
                        Image(systemName:"arrow.triangle.2.circlepath").vosFont(WorkspaceText.meta.size, weight:.medium).foregroundStyle(palette.warning)
                        Text("\(model.pendingReminderSyncs.count) 项本地完成待同步 · 稍后核对").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        Spacer(minLength:0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("本地完成待同步 \(model.pendingReminderSyncs.count) 项，打开核对")
            }
            if actionFilter == "全部" {
                let surface = ActionTimeSurface.build(actions: myTodoActions, schedules: model.scheduleIntents, links: model.reminderLinks, now: Date(), calendar: .current)
                let overdue = surface.today.filter(\.isOverdue).count
                Button { actionFilter = "我的待办" } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sun.max").vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(palette.accent)
                        Text("今天 \(surface.today.count - overdue) · 逾期 \(overdue)").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        Image(systemName: "chevron.right").vosFont(WorkspaceText.caption.size, weight: .semibold).foregroundStyle(palette.disabledText)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("今天 \(surface.today.count - overdue) 项，逾期 \(overdue) 项")
                    .accessibilityHint("切到我的待办")
                    .help("切到我的待办")
            }
            if ["目标","全部"].contains(actionFilter), !model.stalledOutcomes.isEmpty { stalledBanner }
            let visible = visibleActions
            let focusedIDs = Set(focusedActions.map(\.id))
            let listed = actionFilter == "全部" ? visible.filter { !focusedIDs.contains($0.id) } : visible
            let executions = model.sortedAssistantDeliveries(model.assistantExecutions.filter { $0.state != "cancelled" })
            let paused = model.workspacePausedTasks
            if ["全部","我的待办"].contains(actionFilter), !focusedActions.isEmpty {
                WorkspaceListSection(title:"专注",count:focusedActions.count) {
                    ActionCardList {
                        ForEach(focusedActions) { action in actionRow(action,nextStepCounts:nextStepCounts,reads:rowReads) }
                    }
                }
            }
            if actionFilter == "我的待办", !visible.isEmpty {
                let surface = ActionTimeSurface.build(actions: visible, schedules: model.scheduleIntents, links: model.reminderLinks, now: Date(), calendar: .current)
                let overdue = surface.today.filter(\.isOverdue)
                let dueToday = surface.today.filter { !$0.isOverdue }
                if !overdue.isEmpty {
                    WorkspaceListSection(title:"逾期",subtitle:"已过期限。改天需要提醒事项链接。",count:overdue.count) {
                        ActionCardList {
                            ForEach(overdue) { entry in actionRow(entry.action,timeEntry:entry,nextStepCounts:nextStepCounts,reads:rowReads) }
                        }
                    }
                }
                if !dueToday.isEmpty {
                    WorkspaceListSection(title:"今天",subtitle:"今天到期",count:dueToday.count) {
                        ActionCardList {
                            ForEach(dueToday) { entry in actionRow(entry.action,timeEntry:entry,nextStepCounts:nextStepCounts,reads:rowReads) }
                        }
                    }
                }
                if !surface.soon.isEmpty {
                    WorkspaceListSection(title:"即将",subtitle:"7 天内",count:surface.soon.count) {
                        ActionCardList {
                            ForEach(surface.soon) { entry in actionRow(entry.action,timeEntry:entry,nextStepCounts:nextStepCounts,reads:rowReads) }
                        }
                    }
                }
                if !surface.anytime.isEmpty {
                    WorkspaceListSection(title:"随时",subtitle:"没有日期或更远",count:surface.anytime.count) {
                        ActionCardList {
                            ForEach(surface.anytime) { entry in actionRow(entry.action,timeEntry:entry,nextStepCounts:nextStepCounts,reads:rowReads) }
                        }
                    }
                }
            } else if actionFilter == "AI 助理" {
                if !executions.isEmpty {
                    WorkspaceListSection(title:"AI 助理的工作",count:executions.count) { executionRows(executions) }
                }
            } else if !listed.isEmpty {
                WorkspaceListSection(title:actionFilter == "全部" ? "我的待办" : actionFilter,subtitle:actionFilter == "问题" ? "VoiceOS 先回答；想清楚了可以转成下一步。" : actionFilter == "目标" ? "你要长期达到的结果；转成待办后可提醒。" : "",count:listed.count) {
                    ActionCardList {
                        ForEach(listed) { action in actionRow(action,group:listGroup,nature:listNature,nextStepCounts:nextStepCounts,reads:rowReads) }
                    }
                }
            }
            if actionFilter == "全部", !paused.isEmpty {
                WorkspaceListSection(title:"需要核对的待办",subtitle:"打开任务查看原因。",count:paused.count) {
                    ActionCardList {
                        ForEach(paused) { action in actionRow(action,group:.needsReview,nextStepCounts:nextStepCounts,reads:rowReads) }
                    }
                    if model.pausedActionBatch == nil { PausedActionBatchControl(model:model) }
                }
            }
            let overviewQuestions = actionFilter == "全部" ? model.openQuestions : []
            if !overviewQuestions.isEmpty {
                WorkspaceListSection(title:"问题",subtitle:"VoiceOS 先回答；想清楚了可以转成下一步。",count:overviewQuestions.count) {
                    ActionCardList {
                        ForEach(overviewQuestions.prefix(3)) { action in
                            actionRow(action,nature:.question,nextStepCounts:nextStepCounts,reads:rowReads)
                        }
                    }
                    if overviewQuestions.count > 3 {
                        Button("查看全部 \(overviewQuestions.count)") { actionFilter = "问题" }
                            .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent).padding(.vertical,10)
                    }
                }
            }
            let overviewGoals = actionFilter == "全部" ? model.openGoals : []
            if !overviewGoals.isEmpty {
                WorkspaceListSection(title:"目标",subtitle:"你要长期达到的结果；转成待办后可提醒。",count:overviewGoals.count) {
                    ActionCardList {
                        ForEach(overviewGoals.prefix(3)) { action in
                            actionRow(action,nature:.goal,nextStepCounts:nextStepCounts,reads:rowReads)
                        }
                    }
                    if overviewGoals.count > 3 {
                        Button("查看全部 \(overviewGoals.count)") { actionFilter = "目标" }
                            .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent).padding(.vertical,10)
                    }
                }
            }
            if actionFilter == "目标" {
                let suggestions = model.untriagedSuggestions
                if !suggestions.isEmpty {
                    WorkspaceListSection(title:"系统整理的建议",subtitle:"VoiceOS 还拿不准类别；可以逐条归类。",count:suggestions.count,collapsible:true) {
                        ForEach(suggestions) { action in
                            suggestionRow(action)
                            if action.id != suggestions.last?.id { WorkspaceListDivider() }
                        }
                    }
                }
            }
            let pendingOutcomes = model.visibleOutcomeFollowups.count
            if pendingOutcomes > 0 {
                WorkspaceListSection(title:"完成后的结果",count:pendingOutcomes,badge:"\(pendingOutcomes) 项待填结果",collapsible:true,initiallyExpanded:true) {
                    HStack(spacing:12) {
                        Button("记录结果…") { showingOutcome=true }.buttonStyle(.bordered)
                        Button("显示已跳过") { model.showSkippedOutcomes() }
                        Spacer(minLength:0)
                    }.padding(.vertical,10)
                }
            }
            if actionFilter == "全部", !executions.isEmpty {
                WorkspaceListSection(title:"AI 助理的工作",count:executions.count,collapsible:true) { executionRows(executions) }
            }
            if model.pausedActionBatch != nil {
                WorkspaceListSection(title:"批量重新识别") { PausedActionBatchControl(model:model) }
            }
            if visible.isEmpty && (actionFilter == "AI 助理" || actionFilter == "全部" ? executions.isEmpty : true)
                && !(actionFilter == "全部" && (!paused.isEmpty || !overviewQuestions.isEmpty || !overviewGoals.isEmpty))
                && !(actionFilter == "目标" && !model.untriagedSuggestions.isEmpty) {
                WorkspaceEmptyState(title:actionEmptyTitle,systemImage:"checkmark.circle",description:actionEmptyDescription) {
                    HStack {
                        Button("记录想法") { go(.capture) }
                        if actionFilter != "问题" { Button("查看问题") { actionFilter="问题" } }
                        if actionFilter != "目标" { Button("查看目标") { actionFilter="目标" } }
                    }
                }
            }
            if actionFilter == "待核对" { processingIssues }
            if ["全部","我的待办"].contains(actionFilter), !visible.isEmpty {
                Text("↑↓ 选择 · ↵ 打开 · x 完成 · z 不再跟进 · ⌥⌘Z 撤销上一次变更").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            }
            HStack { Button("同步提醒事项") { Task { await model.refreshTaskReminders() } }.disabled(model.reminderAccess?.enabled != true || model.remindersBusy);Spacer();Text(model.reminderSyncStatus).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText).lineLimit(2) }
        }.task(id: focusRefreshKey) { focusedActionIDs = await model.focusedActionIDs() }
            .sheet(item:$nextActionOutcome) { outcome in
                NextActionFormSheet(model:model,outcome:outcome,onAdded:{ _ in toastMessage="已添加下一步" })
            }
            .alert("标记这个目标已达成？", isPresented: completingOutcomeAlertPresented) {
                Button("标记达成") {
                    guard let outcome=completingOutcome else { return }
                    completingOutcome=nil
                    Task {
                        if await model.completeOutcome(outcome) { error="";toastMessage="已标记达成" }
                        else { error=model.status }
                    }
                }
                Button("取消", role: .cancel) { completingOutcome=nil }
            } message: {
                Text("目标会移到已完成，已经添加的下一步不受影响。")
            }
    }
    private var actionEmptyTitle: String {
        switch actionFilter {
        case "历史记录": "还没有历史任务记录"
        case "已完成": "还没有已完成的事项"
        case "AI 助理": "还没有 AI 代办"
        case "待核对": "没有待核对的行动"
        case "问题": "还没有问题"
        case "目标": "还没有目标"
        default: "目前没有可执行的待办"
        }
    }
    private var actionEmptyDescription: String {
        switch actionFilter {
        case "AI 助理": "在一项待办中选择“交给 AI”，编辑要求后开始执行。"
        case "待核对": "下方处理问题里的事项仍需要查看。"
        case "问题": "记录一个问题，VoiceOS 会先试着回答；想清楚了可以加下一步。"
        case "目标": "这里是你长期要达到的结果；转成待办后可提醒。"
        default: "已暂停的历史、问题与目标分别保留，可通过上方分类查看。"
        }
    }
    private var listNature: ActionNature? {
        switch actionFilter {
        case "问题": .question
        case "目标": .goal
        default: nil
        }
    }
    private func suggestionRow(_ action:ActionRecord) -> some View {
        let tagged=StatementTagParser.split(action.title)
        return HStack(alignment:.center,spacing:8) {
            WorkspaceRow(title:tagged.text,subtitle:"VoiceOS 还拿不准；可以归为问题、目标，或标记为旁白。",icon:"sparkles") { go(.task(action.id)) }
            Menu {
                Button("归为问题") { classifySuggestion(action,.question) }
                Button("归为目标") { classifySuggestion(action,.goal) }
                Button("是旁白") { classifySuggestion(action,.narration) }
            } label: {
                Image(systemName:"ellipsis.circle").vosFont(WorkspaceText.meta.size,weight:.semibold)
                    .foregroundStyle(palette.secondaryText).frame(width:30,height:30).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("归类这条建议").accessibilityLabel("归类：" + tagged.text)
        }
    }
    private func classifySuggestion(_ action:ActionRecord,_ nature:ActionNature) {
        Task {
            guard let store=model.store, !model.savingAction else { error="正在保存其他更改，请稍后重试"; return }
            model.savingAction=true
            defer { model.savingAction=false }
            do {
                _ = try await store.setActionNature(id:action.id,expectedVersion:action.version,nature:nature,
                                                    commandID:"workspace-nature:" + action.id + ":" + nature.rawValue + ":" + String(action.version))
                await model.refresh()
                guard model.actionRecords.first(where: { $0.id == action.id })?.nature == nature.rawValue else { throw VoiceOSError("归类未能保存，请重试") }
                error=""
                toastMessage=nature == .narration ? "已移出问题与目标" : nature == .question ? "已归为问题" : "已归为目标"
            } catch {
                self.error=error.localizedDescription
                await model.refresh()
            }
        }
    }
    @ViewBuilder private func executionRows(_ executions: [AssistantExecutionRecord]) -> some View {
        ForEach(executions) { execution in
            let unread = model.isDeliveryUnread(execution)
            WorkspaceRow(title:execution.title,
                         subtitle:(unread ? "未读 · " : "") + assistantExecutionLabel(execution),
                         icon:execution.state == "completed" ? "doc.text" : "sparkles",
                         iconTint:unread ? palette.accent : nil,
                         trailing:unread ? "未读 · 阅读结果" : (execution.state == "completed" ? "阅读结果" : "查看进度"),
                         trailingStyle:unread ? .status(palette.accent) : .link) { go(.delivery(execution.id)) }
            if execution.id != executions.last?.id { WorkspaceListDivider() }
        }
    }
    private var focusedActions: [ActionRecord] {
        Array(model.actionRecords.filter { focusedActionIDs.contains($0.id) && $0.state == "open" && $0.validity == "current" }.prefix(3))
    }
    private var focusRefreshKey: String {
        model.actionRecords.map { $0.id + String($0.version) + $0.state + $0.validity }.joined(separator: "|")
    }
    private var myTodoActions: [ActionRecord] {
        model.actionRecords.filter { $0.kind == "task" && $0.state == "open" && $0.validity == "current" && !model.sourcePageIndex.requiresReview($0.id) }
    }
    private var visibleActions: [ActionRecord] {
        switch actionFilter {
        case "已完成":
            return model.actionRecords.filter { $0.state == "completed" }.sorted { left, right in
                let leftDate = left.completedAt ?? left.createdAt, rightDate = right.completedAt ?? right.createdAt
                return leftDate == rightDate ? left.id > right.id : leftDate > rightDate
            }
        case "历史记录":
            return model.actionRecords.filter { $0.state == "dismissed" || ($0.validity != "current" && !model.sourcePageIndex.requiresReview($0.id)) }
        case "待核对":
            return model.actionRecords.filter { model.sourcePageIndex.requiresReview($0.id) || $0.validity == "current" && ($0.intent?.uncertain == true || $0.intent?.followupState == "needs_review") }
        case "问题":
            return model.actionRecords.filter { $0.kind == "opportunity" && $0.nature == ActionNature.question.rawValue && $0.state == "open" && $0.validity == "current" }
        case "目标":
            return model.actionRecords.filter { $0.kind == "opportunity" && $0.nature == ActionNature.goal.rawValue && $0.state == "open" && $0.validity == "current" }
        default:
            return myTodoActions
        }
    }
    private var search: some View {
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        return LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            WorkspaceHeading(eyebrow:"",title:"搜索")
            WorkspaceSearchField(text:$query,placeholder:"搜索标题、原话、理解、主题或行动",focus:$searchFocused,submit:{ openSearchSelection() })
                .task {
                    // Wait until the lazy field is attached to its native window.
                    do { try await Task.sleep(for:.milliseconds(100)); searchFocused = true } catch {}
                }
            if term.count >= 2, !searchSuggestions.isEmpty {
                searchSuggestionList(term)
            }
            if term.isEmpty {
                if !recentSearches.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        sectionTitle("最近搜索")
                        recentSearchChips
                    }
                }
                let sources=model.records.filter { !$0.isTrashed }
                if !sources.isEmpty { sectionTitle("材料与原话 · \(sources.count)") }
                let catalog=recordCatalog
                ForEach(sources) { sourceRow($0,catalog:catalog);Divider() }
            } else {
                searchResults
            }
        }
        .task(id: term) { await loadSearchHits(term) }
        .onChange(of:term) { _, _ in searchKeyboardFocus.id=nil;searchExpandedKinds=[] }
    }
    @ViewBuilder private var searchResults: some View {
        if searchBusy && searchHits.isEmpty { ProgressView("正在检索…").controlSize(.small) }
        if searchFailed { WorkspaceNoticeText(message:model.status,severity:.danger) }
        let sections = searchSections
        if !sections.isEmpty {
            VStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
                ForEach(sections) { section in
                    let expand: (() -> Void)? = section.hasMore ? { expandSearchKind(section.kind) } : nil
                    WorkspaceSection(title:section.title,icon:section.icon,count:section.count,actionTitle:section.hasMore ? "显示全部" : "",action:expand) {
                        ForEach(section.rows) { row in
                            SearchResultRow(title:row.title,subtitle:row.subtitle,icon:row.icon) { row.open() }
                                .background(searchKeyboardFocus.id == row.id ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                                .overlay { if searchKeyboardFocus.id == row.id { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.focusRing,lineWidth:1) } }
                                .id(row.id)
                            if row.id != section.rows.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        if !searchBusy && !searchFailed && sections.isEmpty {
            WorkspaceEmptyState(title:"没有找到相关内容",systemImage:"magnifyingglass",description:"换个关键词，或清空搜索查看全部材料。") {
                if !recentSearches.isEmpty { recentSearchChips }
                Button("清空搜索") { query="";searchFocused=true }
            }
        }
    }
    private var searchSections: [WorkspaceSearchSection] {
        let catalog = recordCatalog
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        let tokens = term.split(whereSeparator: \.isWhitespace).map(String.init)
        func row(_ id:String,_ title:String,_ subtitle:String,_ icon:String,action:@escaping () -> Void) -> WorkspaceSearchRow {
            WorkspaceSearchRow(id:id,title:highlighted(title,tokens:tokens),subtitle:highlighted(subtitle,tokens:tokens),icon:icon) {
                rememberSearch(term)
                action()
            }
        }
        let materials = searchHits.filter { hit in
            guard hit.kind == .material, let source = catalog[hit.refID] else { return false }
            return !source.isTrashed
        }.map { hit in
            row("material:" + hit.refID,displayTitle(hit.title),hit.snippet,"doc.text") { go(.source(hit.refID)) }
        }
        let claims = searchHits.filter { hit in
            hit.kind == .claim && model.claims.contains { $0.id == hit.refID && $0.validity == "current" && $0.reviewState != "rejected" }
        }.map { hit in
            row("claim:" + hit.refID,hit.title,hit.snippet,"lightbulb") {
                guard let claim=model.sourcePageIndex.claim(for: hit.refID) else { return }
                openClaimSource(claim)
            }
        }
        let topics = searchHits.filter { hit in
            hit.kind == .topic && model.workspaceTopics.contains { $0.id == hit.refID }
        }.map { hit in
            row("topic:" + hit.refID,hit.title,hit.snippet,"circle.hexagongrid") { selectTopic(hit.refID) }
        }
        let actions = searchHits.filter { $0.kind == .action }.map { hit in
            row("action:" + hit.refID,hit.title,hit.snippet,"checkmark.circle") { go(.task(hit.refID)) }
        }
        let materialTotal=searchTotals[.material] ?? materials.count
        let topicTotal=searchTotals[.topic] ?? topics.count
        let claimTotal=searchTotals[.claim] ?? claims.count
        let actionTotal=searchTotals[.action] ?? actions.count
        var sections:[WorkspaceSearchSection]=[]
        if !materials.isEmpty { sections.append(WorkspaceSearchSection(id:"materials",title:"材料",icon:"books.vertical",count:materialTotal,rows:materials,kind:.material,hasMore:materialTotal>materials.count && !searchExpandedKinds.contains(.material))) }
        if !topics.isEmpty { sections.append(WorkspaceSearchSection(id:"topics",title:"主题",icon:"circle.hexagongrid",count:topicTotal,rows:topics,kind:.topic,hasMore:topicTotal>topics.count && !searchExpandedKinds.contains(.topic))) }
        if !claims.isEmpty { sections.append(WorkspaceSearchSection(id:"claims",title:"观点",icon:"lightbulb",count:claimTotal,rows:claims,kind:.claim,hasMore:claimTotal>claims.count && !searchExpandedKinds.contains(.claim))) }
        if !actions.isEmpty { sections.append(WorkspaceSearchSection(id:"actions",title:"行动",icon:"checkmark.circle",count:actionTotal,rows:actions,kind:.action,hasMore:actionTotal>actions.count && !searchExpandedKinds.contains(.action))) }
        return sections
    }
    private func loadSearchHits(_ term:String) async {
        guard !term.isEmpty else {
            searchHits=[];searchTotals=[:];searchFailed=false;searchBusy=false;searchKeyboardFocus.id=nil;searchExpandedKinds=[]
            return
        }
        searchBusy=true
        defer { searchBusy=false }
        do { try await Task.sleep(for:.milliseconds(180)) } catch { return }
        guard !Task.isCancelled else { return }
        let results=await model.searchAll(term, perKindLimit: searchExpandedKinds.isEmpty ? 20 : 200)
        guard term == query.trimmingCharacters(in:.whitespacesAndNewlines) else { return }
        if let results {
            searchHits=cappedSearchHits(results.hits);searchTotals=results.totals;searchFailed=false
        } else {
            searchHits=[];searchTotals=[:];searchFailed=true
        }
    }
    private func expandSearchKind(_ kind: SearchHit.Kind) {
        searchExpandedKinds.insert(kind)
        Task { await loadSearchHits(query.trimmingCharacters(in:.whitespacesAndNewlines)) }
    }
    private func cappedSearchHits(_ hits: [SearchHit]) -> [SearchHit] {
        guard !searchExpandedKinds.isEmpty else { return hits }
        var counts: [SearchHit.Kind: Int] = [:]
        return hits.filter { hit in
            if searchExpandedKinds.contains(hit.kind) { return true }
            counts[hit.kind, default: 0] += 1
            return counts[hit.kind, default: 0] <= 20
        }
    }
    private var searchSuggestions: [WorkspaceSearchSuggestion] {
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        let key = term.lowercased()
        func prefixed(_ text: String) -> Bool { !text.isEmpty && text.lowercased().hasPrefix(key) }
        let materials = model.records.filter { !$0.isTrashed && prefixed(displayTitle($0.name)) }.map { source in
            WorkspaceSearchSuggestion(id:"suggestion:material:" + source.id,title:displayTitle(source.name),subtitle:"材料",icon:"doc.text") { go(.source(source.id)) }
        }
        let topics = model.workspaceTopics.filter { prefixed($0.title) }.map { topic in
            WorkspaceSearchSuggestion(id:"suggestion:topic:" + topic.id,title:topic.title,subtitle:"主题",icon:"circle.hexagongrid") { selectTopic(topic.id) }
        }
        let tasks = model.actionRecords.filter { $0.kind == "task" && $0.state == "open" && $0.validity == "current" && prefixed($0.title) }.map { action in
            WorkspaceSearchSuggestion(id:"suggestion:task:" + action.id,title:action.title,subtitle:"开放任务",icon:"checkmark.circle") { go(.task(action.id)) }
        }
        let claims = model.claims.filter { $0.validity == "current" && $0.reviewState != "rejected" && prefixed($0.statement) }.map { claim in
            WorkspaceSearchSuggestion(id:"suggestion:claim:" + claim.id,title:claim.statement,subtitle:"观点",icon:"lightbulb") { openClaimSource(claim) }
        }
        var picked:[WorkspaceSearchSuggestion] = []
        var depth = 0
        while picked.count < 5 {
            let before = picked.count
            for bucket in [materials,topics,tasks,claims] where depth < bucket.count {
                picked.append(bucket[depth])
                if picked.count == 5 { break }
            }
            guard picked.count > before else { break }
            depth += 1
        }
        return picked
    }
    private func searchSuggestionList(_ term: String) -> some View {
        let suggestions = searchSuggestions
        return VStack(alignment:.leading,spacing:0) {
            ForEach(Array(suggestions.enumerated()),id:\.element.id) { index,suggestion in
                SearchResultRow(title:AttributedString(suggestion.title),subtitle:AttributedString(suggestion.subtitle),icon:suggestion.icon) {
                    rememberSearch(term)
                    suggestion.open()
                }
                if index < suggestions.count - 1 { Divider() }
            }
        }
        .background(palette.surface,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border,lineWidth:1) }
    }
    private func openClaimSource(_ claim: CandidateClaim) {
        guard let reference=claim.references.first else { return }
        let spanExists=model.sourcePageIndex.recordsByID[reference.sourceID]?.spans.contains(where: { $0.id == reference.spanID }) == true
        if spanExists { sourceScrollPositions[reference.sourceID]=ScrollPosition(id:"source-span-"+reference.spanID) }
        go(.source(reference.sourceID))
    }
    private var recentSearchChips: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:8) {
                ForEach(Array(recentSearches.prefix(8)),id:\.self) { term in
                    RecentSearchChip(term:term) {
                        query=term;searchFocused=true
                    } remove: {
                        removeRecentSearch(term)
                    }
                }
            }
        }
    }
    private func removeRecentSearch(_ term:String) {
        recentSearches.removeAll { $0 == term }
        UserDefaults.standard.set(recentSearches,forKey:recentSearchDefaultsKey)
    }
    private func rememberSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        recentSearches = Array(list.prefix(8))
        UserDefaults.standard.set(recentSearches, forKey: recentSearchDefaultsKey)
    }
    private func highlighted(_ text: String, tokens: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        guard !text.isEmpty, !tokens.isEmpty else { return attributed }
        for token in tokens where !token.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: token, options: .caseInsensitive, range: searchRange) {
                if let lower = AttributedString.Index(found.lowerBound, within: attributed),
                   let upper = AttributedString.Index(found.upperBound, within: attributed) {
                    attributed[lower..<upper].backgroundColor = palette.accent.opacity(0.22)
                }
                searchRange = found.upperBound..<text.endIndex
                if searchRange.isEmpty { break }
            }
        }
        return attributed
    }
    private var settings: some View {
        VStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            WorkspaceHeading(eyebrow:"",title:"设置")
            sectionTitle("外观")
            HStack(spacing:12) {
                ForEach(WorkspaceTheme.allCases) { option in
                    WorkspaceThemeOption(theme:option,selected:theme == option) { theme=option }
                }
            }.frame(maxWidth:560)
            Picker("文字大小",selection:Binding(get:{ model.textSize },set:{ model.setTextSize($0) })) {
                ForEach(AppTextSize.allCases) { option in Text(option.label).tag(option) }
            }.pickerStyle(.segmented).frame(maxWidth:360)
            Text("配色即时生效，并在下次打开时沿用。").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
            Divider()
            sectionTitle("键盘快捷键")
            VStack(alignment:.leading,spacing:6) {
                Text("↑↓ 选择 · 列表聚焦时")
                Text("↵ 打开 · 列表聚焦时")
                Text("x 完成 · 列表聚焦时")
                Text("z 不再跟进 · 列表聚焦时")
                Text("任务详情：x 或空格 完成 · s 改期 · f 记结果")
                Text("⌥⌘Z 撤销 · 仅本次运行")
                Text("撤销只对当前会话有效")
                Text("口述、剪贴板、速记、导入与页面切换在菜单栏的「记录」与「显示」菜单。")
            }.vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
            if model.dictationHotKeyConflict {
                Text("快捷键 ⌥⌘D 被其它应用占用；口述仍可从菜单栏开始。请在系统设置 › 键盘 › 键盘快捷键中查看冲突，或退出占用它的应用后重启 VoiceOS。")
                    .vosFont(WorkspaceText.caption).foregroundStyle(palette.warning)
            }
            Button("再看一次引导") { model.onboardingRequested = true }
            Divider()
            sectionTitle("模型与服务")
            WorkspaceRow(title:"语音转文字",subtitle:model.speechSummary,icon:"waveform") { model.chooseLocalSpeech() }
            WorkspaceRow(title:"理解、核对与 AI 助理",subtitle:model.textModelConfigured ? (model.modelConfigurationName ?? model.modelSummary) : "尚未配置文本模型",icon:"sparkles") { model.chooseTextModel() }
                .help(model.modelConfigurationPath ?? "选择本地的 .env 或模型 JSON 配置文件；配置后这里显示文件名")
                .contextMenu {
                    Button("更换配置…") { model.chooseTextModel() }
                    Button("清除配置", role: .destructive) { model.clearTextModel() }.disabled(!model.modelConfigured)
                }
            sectionTitle("连接与自动入口")
            WorkspaceRow(title:"自动接收录音",subtitle:"VoiceOS 收件箱与语音备忘录",icon:"tray.and.arrow.down") { go(.tool("自动入口")) }
            WorkspaceRow(title:"Apple 提醒事项",subtitle:model.remindersPermissionDenied ? "系统权限已拒绝，需要在系统设置中允许后重试" : model.reminderCalendarTitle,icon:"checklist") { Task { await model.connectReminders() } }
            if model.remindersPermissionDenied { Button("打开系统设置") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!) } }
            if model.reminderAccess?.enabled == true { Button("暂停提醒事项连接") { Task { await model.disconnectReminders() } } }
            WorkspaceRow(title:"系统通知",subtitle:model.noticeAuthorizationDetail,icon:"bell") { model.openNoticeSettings() }
                .task { await model.refreshNoticeAuthorization() }
            if model.noticeAuthorization == .denied { Button("打开系统通知设置") { model.openNoticeSettings() } }
            Toggle("登录时启动", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch).frame(maxWidth: 360, alignment: .leading)
            Text(model.launchAtLoginStatus).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            sectionTitle("资料与历史")
            HStack(spacing:12) {
                Button("导出结构化资料") { model.export(includeMedia:false) }
                Button("导出资料与原件") { model.export(includeMedia:true) }
                if model.exporting { ProgressView().controlSize(.small) }
            }.disabled(model.exporting)
            HStack(spacing:12) {
                Text(model.backupStatusText.isEmpty ? "尚未生成备份" : model.backupStatusText).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                Button("重试备份") { model.retryBackup() }.vosFont(WorkspaceText.meta)
                Button("在访达中显示") { model.revealBackups() }.vosFont(WorkspaceText.meta)
            }
            HStack(spacing:12) {
                Text("保留份数").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                Picker("保留份数", selection: $backupRetention) {
                    Text("3 份").tag(3); Text("7 份").tag(7); Text("14 份").tag(14)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Button(model.backupPruning ? "正在清理…" : "立即清理旧备份") { model.cleanupOldBackups(retain: backupRetention) }
                    .vosFont(WorkspaceText.meta).disabled(model.backupPruning || model.libraryRoot == nil)
            }
            Text("保留份数在下次备份或立即清理时生效。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            if !model.backupCleanupStatus.isEmpty {
                Text(model.backupCleanupStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            HStack(spacing:12) {
                Button(model.checkingLibraryHealth ? "正在检查资料库…" : "检查资料库") { model.checkLibraryHealth() }.vosFont(WorkspaceText.meta).disabled(model.checkingLibraryHealth || model.libraryRoot == nil)
                Button("从最近备份新建资料库") { showingBackupRestore = true }.vosFont(WorkspaceText.meta).disabled(model.lastBackupAt == nil || model.libraryRoot == nil)
            }
            if !model.libraryHealthText.isEmpty {
                Text(model.libraryHealthText).vosFont(WorkspaceText.meta)
                    .foregroundStyle(model.libraryHealthProblem ? palette.warning : palette.secondaryText)
                    .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            }
            HStack { Button("打开已有资料库") { chooseLibrary() };Button("从迁移包恢复") { go(.tool("恢复资料")) } }
            sectionTitle("存储与清理")
            VStack(alignment:.leading,spacing:7) {
                storageLine("资料库（含 WAL）", model.storageUsage?.databaseBytes)
                storageLine("原件", model.storageUsage?.assetsBytes)
                storageLine("备份", model.storageUsage?.backupBytes, detail: model.storageUsage.map { "\($0.backupCount) 份" })
                storageLine("本地语音模型", model.storageUsage?.localSpeechBytes)
                storageLine("镜像", model.storageUsage?.mirrorBytes)
                Divider().frame(maxWidth:420)
                storageLine("合计", model.storageUsage?.totalBytes, emphasized:true)
            }
            if model.storageScanBusy { ProgressView().controlSize(.small) }
            HStack(spacing:12) {
                Button("在访达中显示资料库") { model.revealLibraryRoot() }
                Button(model.localSpeechDeleting ? "正在删除…" : "删除本地语音模型") { confirmingLocalSpeechDelete = true }
                    .disabled(model.localSpeechDeleting || model.speechModelBusy || (model.storageUsage?.localSpeechBytes ?? 0) == 0)
                    .help(model.speechModelBusy ? "转录或录音进行中，结束后再删除" : "删除 LocalSpeech 中的本地 Qwen 模型文件")
            }
            if !model.localSpeechDeleteStatus.isEmpty {
                Text(model.localSpeechDeleteStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            sectionTitle("回顾与查找")
            WorkspaceRow(title:"静默回顾",subtitle:"看到相关原文",icon:"text.bubble") { go(.tool("静默回顾")) }
            WorkspaceRow(title:"查找历史文字",subtitle:"按关键词查找",icon:"text.magnifyingglass") { go(.tool("查找历史文字")) }
            WorkspaceRow(title:"英文表达反馈",subtitle:"英文原话反馈",icon:"character.book.closed") { go(.tool("英文表达反馈")) }
            DisclosureGroup("其他工作与维护") {
                VStack(alignment:.leading,spacing:15) {
                    Button("思想关联、目标下一步与英语反馈") { go(.tool("思想与下一步")) }
                    Button("纠错后的行动影响") { go(.tool("纠错影响")) }
                    Button("表达处理与重试") { go(.tool("处理情况")) }
                    Button("重新整理主题与简报") { model.queueTopicOrganization(retry:true) }
                    Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.top,15)
            }
        }
        .onAppear {
            model.refreshStorageUsage()
            model.refreshLaunchAtLogin()
        }
        .alert("删除本地语音模型？", isPresented:$confirmingLocalSpeechDelete) {
            Button("取消", role:.cancel) {}
            Button("删除", role:.destructive) { model.deleteLocalSpeechModel() }
        } message: {
            Text("将删除 LocalSpeech 目录中的本地 Qwen 模型文件（当前 " + (model.storageUsage.map { sizeText($0.localSpeechBytes) } ?? "统计中") + "）。删除后本地 Qwen 语音停用，需要重新下载模型才能继续转写；已有录音、原件与逐字稿不受影响。")
        }
    }
    @ViewBuilder private var processingIssues: some View {
        let catalog=recordCatalog
        ForEach(model.assistantAssessmentIssues) { issue in
            VStack(alignment:.leading,spacing:8) { Text(issue.title);Text(issue.error).vosFont(WorkspaceText.meta).foregroundStyle(.secondary);Button("重新识别 AI 委托") { Task { await model.retryAssistantAssessment(issue) } }.accessibilityLabel("重新识别 AI 委托：" + issue.title) }
        }
        ForEach(model.recordingFollowups.filter { $0.state == "failed" }) { receipt in
            let title=displayTitle(model.sourcePageIndex.recordsByID[receipt.sourceID]?.displayTitle ?? "资料跟进")
            VStack(alignment:.leading,spacing:8) { Text(title);Button("重试思想与下一步") { model.refreshFollowup(receipt.sourceID) }.accessibilityLabel("重试思想与下一步：" + title) }
        }
        ForEach(activeMaterials.filter { ["failed","blocked"].contains($0.jobState ?? "") }) { source in sourceRow(source,catalog:catalog) }
        ForEach(model.processingIntents.filter { [.blocked,.unknown].contains($0.state) }) { intent in
            Text("表达处理：" + workspaceStateLabel(intent.state.rawValue)).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
        }
        ReverifyControls(model:model)
    }
    @ViewBuilder private func tool(_ name:String) -> some View {
        switch name {
        case "导入录音": if let input=model.fullRecordingInput { FullRecordingView(model:model,input:input,embedded:true) { model.fullRecordingInput=nil;go(.actions) }.frame(maxWidth:.infinity,maxHeight:.infinity) }
        case "自动入口": RecordingInboxView(inbox:model.recordingInbox,model:model,embedded:true,dismiss:back)
        case "思想与下一步": RecordingFollowupView(model:model,embedded:true,dismiss:openSelectedSource)
        case "纠错影响": CorrectionImpactView(model:model,embedded:true,dismiss:openSelectedSource)
        case "静默回顾": CognitiveFeedbackView(model:model,embedded:true,dismiss:openSelectedSource).task { model.quietAssociationSourceID=nil; await model.refreshQuietFeedback() }
        case "查找历史文字": HistorySearchView(model:model,embedded:true,dismiss:openSelectedSource)
        case "英文表达反馈": EnglishPracticeView(model:model,embedded:true,dismiss:back,openCapture:{ go(.capture) })
        case "恢复资料": PackageRestoreView(dismiss:back).frame(maxWidth:.infinity,maxHeight:.infinity)
        default: WorkspaceProcessingView(model:model,inbox:model.recordingInbox,openSource:{ go(.source($0)) },openSettings:{ go(.settings) },openInbox:{ go(.tool("自动入口")) },openMonitor:{ go(.monitor) })
        }
    }
    private func sectionTitle(_ title:String) -> some View { Text(title).vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.secondaryText).accessibilityAddTraits(.isHeader) }
    private func sizeText(_ bytes:Int64) -> String { ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
    private func storageLine(_ label:String,_ bytes:Int64?,detail:String? = nil,emphasized:Bool = false) -> some View {
        HStack(spacing:8) {
            Text(label + (detail.map { " · " + $0 } ?? ""))
                .vosFont(emphasized ? WorkspaceText.rowTitle : WorkspaceText.body)
                .foregroundStyle(emphasized ? palette.text : palette.secondaryText)
            Spacer(minLength:12)
            Text(bytes.map(sizeText) ?? "统计中…").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
        }.frame(maxWidth:420,alignment:.leading)
    }
    private func sourceNavigationTitle(_ id:String) -> String {
        let pageIndex=model.sourcePageIndex
        let catalog=pageIndex.recordsByID
        guard let source=catalog[id] else { return "材料" }
        if let expression=pageIndex.expression(for:id),expression.sourceIDs.count > 1,
           let index=expression.sourceIDs.firstIndex(of:id) { return expression.displayTitle(in:catalog)+" / 第 \(index+1) 段原文" }
        return displayTitle(source.displayTitle)
    }
    private var todayReading: [TodayReadingItem] {
        let catalog=recordCatalog
        let items=readingPlans.compactMap { plan -> TodayReadingItem? in
            guard let source=catalog[plan.sourceID],!source.isArchived,!source.isTrashed else { return nil }
            if let updated=ConversationReflectionFocus.date(plan.updatedAt),Calendar.current.isDateInToday(updated) { return nil }
            return TodayReadingItem(plan:plan,source:source,chunks:ReadingChunks.split(text:source.transcript ?? "",spans:source.spans,targetSize:plan.chunkSize).count)
        }
        return Array(items.sorted { (ConversationReflectionFocus.date($0.plan.updatedAt) ?? .distantPast) > (ConversationReflectionFocus.date($1.plan.updatedAt) ?? .distantPast) }.prefix(3))
    }
    private func chunkLabel(_ item:TodayReadingItem) -> String {
        guard item.chunks > 0 else { return "第 \(item.plan.currentChunk + 1) 块" }
        return "第 \(min(item.plan.currentChunk + 1, item.chunks))/\(item.chunks) 块"
    }
    private func loadReadingPlans() async {
        guard let store=model.store else { return }
        readingPlans=(try? await store.incrementalPlans()) ?? []
    }
    private var recordCatalog: [String:SourceRecord] { model.sourcePageIndex.recordsByID }
    private func sourceRow(_ source:SourceRecord,catalog:[String:SourceRecord],trailingGutter:CGFloat = 0,reason:String? = nil) -> some View {
        let expression=model.sourcePageIndex.expression(for:source.id)
        let combined=(expression?.sourceIDs.count ?? 0) > 1
        let first=combined ? expression!.sourceIDs.first.flatMap { catalog[$0] } ?? source : source
        let origin=source.origin == "ai" ? "AI 交付" : source.origin == "user" ? "我的表达" : "外部资料"
        let issues=source.unresolvedTranscriptionIssueCount
        let reading:(text:String,color:Color)? = issues > 0 ? ("疑点 \(issues)",palette.warning) : materialReadingStatus(source.id)
        let groupNote=reason ?? (model.sourcePageIndex.expressionIssue(for: source.id) != nil ? "分组待重新判断" : nil)
        return WorkspaceRow(title:displayTitle(combined ? expression!.displayTitle(in:catalog) : source.displayTitle),subtitle:first.recordingDateLabel + " · " + origin + (source.localOnly ? " · 仅本地" : "") + (groupNote.map { " · " + $0 } ?? ""),icon:source.kind.contains("text") ? "doc.text" : "waveform",trailing:"",trailingStyle:reading.map { WorkspaceRow.TrailingStyle.dot($0.color) } ?? .secondary,statusAccessibility:reading?.text ?? "",trailingGutter:trailingGutter) { go(.source(source.id)) }
            .contextMenu {
                Button("标为未读") { setMaterialReading(source.id,.unread) }
                Button("标为在读") { setMaterialReading(source.id,.reading) }
                Button("标为已读") { setMaterialReading(source.id,.read) }
                if let saved=source.presentation?.expression, saved.sourceIDs.count > 1 {
                    Divider()
                    Button("拆为独立录音") { splitMaterialExpression(saved.sourceIDs) }
                    Button("重新判断连续表达") { rejudgeMaterialExpressions(saved.sourceIDs) }
                        .disabled(model.fullRecordingBusy || model.understandingSource != nil)
                }
            }
    }
    private func unassignedTopicReasonSummary(_ sources:[SourceRecord],catalog:[String:SourceRecord]) -> String {
        var counts:[String:Int]=[:]
        for source in distinctExpressions(sources) { counts[source.topicAssignmentReason(in:catalog),default:0] += 1 }
        return counts.sorted { $0.value > $1.value }.prefix(3).map { "\($0.value) 份 · \($0.key)" }.joined(separator:"；")
    }
    private func splitMaterialExpression(_ ids:[String]) {
        Task {
            do {
                let count=try await model.splitRecordingExpression(sourceIDs:Set(ids))
                toastMessage="已拆成 \(count) 段独立录音"
            } catch { self.error=error.localizedDescription }
        }
    }
    private func rejudgeMaterialExpressions(_ ids:[String]) {
        Task {
            do {
                let groups=try await model.rejudgeRecordingExpressions(sourceIDs:Set(ids))
                toastMessage="已重新判断连续表达 · \(groups) 组"
            } catch { self.error=error.localizedDescription }
        }
    }
    private func materialReadingStatus(_ id:String) -> (text:String,color:Color)? {
        switch readingStates[id] ?? .unread {
        case .unread: return nil
        case .reading: return ("在读",palette.accent)
        case .read: return ("已读",palette.tertiaryText)
        }
    }
    private func setMaterialReading(_ id:String,_ state:SourceReadingState) {
        Task {
            if await model.setReadingState(sourceID:id,state:state) { readingStates[id]=state }
            else { error=model.status }
        }
    }
    /// One fold per action-page body: reminder links and analysis runs are read
    /// per row, so index them by action instead of scanning the arrays again.
    private struct ActionRowReads {
        let linkedReminderByActionID: [String: ReminderLink]
        let dueByActionID: [String: ReminderDueDate]
        let latestAnalysisStateByActionID: [String: String]
        init(reminderLinks: [ReminderLink], executions: [AssistantExecutionRecord]) {
            var linked: [String: ReminderLink] = [:]
            var due: [String: ReminderDueDate] = [:]
            for link in reminderLinks where link.state == "linked" {
                if linked[link.actionID] == nil { linked[link.actionID] = link }
                if let date = link.remoteDueDate, date != .none, due[link.actionID] == nil { due[link.actionID] = date }
            }
            var states: [String: String] = [:]
            var newest: [String: String] = [:]
            for execution in executions where execution.mode == .analysis && execution.validity == "current" {
                if let current = newest[execution.actionID], current >= execution.updatedAt { continue }
                newest[execution.actionID] = execution.updatedAt
                states[execution.actionID] = execution.state
            }
            linkedReminderByActionID = linked
            dueByActionID = due
            latestAnalysisStateByActionID = states
        }
    }
    private func actionRowStatus(_ action:ActionRecord,timeEntry:ActionTimeEntry? = nil,group:ActionRowGroup,nature:ActionNature? = nil,nextStepCount:Int,reads:ActionRowReads) -> ActionRowStatus {
        var due=""
        var localUnsynced=false
        if let entry=timeEntry,entry.source == .localSchedule {
            if let date=entry.due { due=(entry.isOverdue ? "已逾期 " : "到期 ") + date.summary }
            localUnsynced=entry.needsLocalSyncLabel
        } else if action.state == "open", action.validity == "current", let date=reads.dueByActionID[action.id] {
            due=(reminderDueIsPast(date) ? "已逾期 " : "到期 ") + date.summary
        }
        var facts=ActionRowFacts()
        facts.isGoal=nature.map { $0 == .goal } ?? (action.kind != "task")
        facts.isQuestion=nature == .question
        facts.answerState=nature == .question ? (reads.latestAnalysisStateByActionID[action.id] ?? "") : ""
        facts.group=group
        facts.state=action.state
        facts.validity=action.validity
        facts.due=due
        facts.sourceTitle=actionSourceTitle(action)
        facts.nextStepCount=nextStepCount
        facts.completedAt=group == .completed ? action.completedAt.map { "完成于 " + dateLabel($0) } ?? "" : ""
        facts.requiresReview=model.sourcePageIndex.requiresReview(action.id)
        facts.externalCompletion=model.workspaceExternalCompletionNote(action) != nil
        facts.withdrawn=action.intent?.followupState == "withdrawn"
        facts.localUnsynced=localUnsynced
        return ActionRowLayout.status(facts)
    }
    private func actionRowToneColor(_ tone:ActionRowTone) -> Color {
        switch tone {
        case .secondary: return palette.secondaryText
        case .warning: return palette.warning
        case .success: return palette.success
        case .tertiary: return palette.tertiaryText
        }
    }
    private func typeIcon(_ tag:StatementTag?) -> String {
        switch tag {
        case .question?: return "questionmark.circle"
        case .goal?: return "target"
        case .idea?, .insight?: return "lightbulb"
        case .recordingActivity?: return "waveform"
        case .review?: return "checkmark.seal"
        case nil: return "circle"
        }
    }
    private func actionSourceTitle(_ action:ActionRecord) -> String? {
        guard let claim=model.sourcePageIndex.claim(for: action.claimID) else { return nil }
        for reference in claim.references {
            guard let source=model.sourcePageIndex.recordsByID[reference.sourceID] else { continue }
            let title=displayTitle(source.displayTitle).trimmingCharacters(in:.whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }
    private func reminderDueIsPast(_ due:ReminderDueDate) -> Bool {
        switch due {
        case .none: return false
        case let .dateOnly(localDate, _):
            let formatter=DateFormatter()
            formatter.locale=Locale(identifier:"en_US_POSIX")
            formatter.calendar=Calendar(identifier:.gregorian)
            formatter.timeZone = .current
            formatter.dateFormat="yyyy-MM-dd"
            return localDate < formatter.string(from:Date())
        case let .instant(utc, _):
            let formatter=ISO8601DateFormatter()
            formatter.timeZone=TimeZone(secondsFromGMT:0)
            formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            if let date=formatter.date(from:utc) { return date < Date() }
            formatter.formatOptions=[.withInternetDateTime]
            guard let date=formatter.date(from:utc) else { return false }
            return date < Date()
        }
    }
    private var stalledBanner: some View {
        let goals = model.stalledOutcomes
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(palette.warning).accessibilityHidden(true)
            Text("\(goals.count) 个目标还没有下一步").vosFont(WorkspaceText.body)
            Spacer(minLength: 0)
            if let first = goals.first {
                Button("打开第一条") { go(.task(first.id)) }
                    .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                    .accessibilityLabel("打开第一个没有下一步的目标：" + first.title)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
    }
    @ViewBuilder private func actionMenuItems(_ action:ActionRecord,focused:Bool,canChangeDay:Bool,canTransition:Bool) -> some View {
        if model.workspaceExternalCompletion(action) != nil {
            Button("确认外部已完成") { confirmExternalCompletionFromRow(action) }
                .accessibilityLabel("确认外部已完成：" + action.title)
        }
        if action.canPromoteToTask {
            Button("添加下一步") { nextActionOutcome=action }
                .accessibilityLabel("添加下一步：" + action.title)
            Button("标记达成") { completingOutcome=action }
                .accessibilityLabel("标记达成：" + action.title)
        }
        Button("改天") { openReminderSettings(action) }.disabled(!canChangeDay)
        Button("不再跟进") { dismissAction(action) }.disabled(!canTransition)
        Button(focused ? "移出专注" : "加入专注") { toggleFocus(action.id) }.disabled(!canTransition)
    }
    private func actionRow(_ action:ActionRecord,timeEntry:ActionTimeEntry? = nil,group:ActionRowGroup = .active,nature:ActionNature? = nil,nextStepCounts:[String:Int],reads:ActionRowReads) -> some View {
        let selectable=action.state == "open" && action.validity == "current"
        let actionable=selectable && !selectingActions
        let selected=selectedActionIDs.contains(action.id)
        let keyboardHighlighted=page == .actions && !selectingActions && actionKeyboardHighlightID == action.id
        let focused=focusedActionIDs.contains(action.id)
        let canChangeDay=actionable && reads.linkedReminderByActionID[action.id] != nil && !model.savingAction && !model.remindersBusy
        let canComplete=actionable && action.kind == "task"
        let externalCompletion=model.workspaceExternalCompletion(action) != nil
        let layout=actionRowStatus(action,timeEntry:timeEntry,group:group,nature:nature,nextStepCount:nextStepCounts[action.id] ?? 0,reads:reads)
        let tagged=StatementTagParser.split(action.title)
        let marksSelected=selectingActions && selected
        let trailingStyle:WorkspaceRow.TrailingStyle=marksSelected ? .status(palette.accent) : (layout.status.isEmpty ? .secondary : .status(actionRowToneColor(layout.tone)))
        let icon:String=selectingActions ? (selectable ? (selected ? "checkmark.circle.fill" : "circle") : "circle") : action.state == "completed" ? "checkmark.circle" : action.state == "dismissed" ? "minus.circle" : nature == .question ? "questionmark.circle" : nature == .goal ? "target" : typeIcon(tagged.tag)
        let showsCompletion = !selectingActions && action.kind == "task" && action.state == "open" && action.validity == "current"
        return WorkspaceActionRowChrome(action:action,
            canTransition:actionable || externalCompletion,
            revealed:keyboardHighlighted,
            menuItems:{ actionMenuItems(action,focused:focused,canChangeDay:canChangeDay,canTransition:actionable) },
            row:{
                WorkspaceRow(title:tagged.text,subtitle:layout.meta,icon:icon,
                    iconTint:selectingActions && selected ? palette.accent : palette.secondaryText,
                    trailing:marksSelected ? "已选" : layout.status,
                    trailingStyle:trailingStyle,
                    statusAccessibility:layout.status,
                    trailingGutter:WorkspaceRowChrome.actionGutter,
                    completion:showsCompletion ? WorkspaceRow.CompletionControl(enabled:canComplete && !model.savingAction,complete:{ applyActionState(action,to:.completed) }) : nil) {
                    if selectingActions {
                        guard selectable else { return }
                        if selected { selectedActionIDs.remove(action.id) } else { selectedActionIDs.insert(action.id) }
                    } else { go(.task(action.id)) }
                }
            })
            .materialCard(highlighted: keyboardHighlighted)
            .contextMenu {
                actionMenuItems(action,focused:focused,canChangeDay:canChangeDay,canTransition:actionable)
            }
    }
    private func toggleFocus(_ id:String) {
        Task {
            guard let next = await model.toggleActionFocus(actionID: id) else { error = model.status; return }
            focusedActionIDs = next
            error = ""
        }
    }
    private func openReminderSettings(_ action:ActionRecord) {
        Task {
            if let snapshot = await model.loadReminderSettings(action) {
                reminderSettingsTarget=WorkspaceReminderSettingsTarget(action:action,snapshot:snapshot)
            } else { error=model.status }
        }
    }
    private func dismissAction(_ action:ActionRecord) {
        applyActionState(action,to:.dismissed)
    }
    private func confirmExternalCompletionFromRow(_ action:ActionRecord) {
        guard let candidate=model.workspaceExternalCompletion(action) else {
            error="提醒事项关联或最新回读已变化，请查看最新状态"; return
        }
        Task {
            if await model.confirmExternalCompletion(candidate) {
                error=""
                actionUndo=ActionUndoState(actionID:action.id,message:"已确认外部完成",token:UUID(),kind:.externalCompletion(expectedVersion:candidate.expectedVersion + 1))
            } else { error=model.status }
        }
    }
    private func applyActionState(_ action:ActionRecord,to state:LocalActionState,nextHighlight:String? = nil) {
        Task {
            await model.changeAction(action,state:state)
            guard model.actionRecords.first(where: { $0.id == action.id })?.state == state.rawValue else {
                if state == .completed, model.canCompleteLocally(action) {
                    localCompletionOffer = action
                    error = ""
                } else {
                    error=model.status.isEmpty ? "状态未能更新，请稍后重试。" : model.status
                }
                return
            }
            localCompletionOffer = nil
            error=""
            switch state {
            case .completed:
                let message = model.pendingReminderSync(for: action.id) != nil ? "已本地完成，连接恢复前不会同步到提醒事项" : "已完成"
                showActionUndo(action.id,message:message,resultActionID:action.id)
            case .dismissed: showActionUndo(action.id,message:"已放下")
            case .someday: showActionUndo(action.id,message:"已留到以后")
            case .open: actionUndo=nil
            }
            if let nextHighlight { actionKeyboardHighlightID=nextHighlight }
        }
    }
    private func showActionUndo(_ id:String,message:String,resultActionID:String? = nil) {
        actionUndo=ActionUndoState(actionID:id,message:message,token:UUID(),resultActionID:resultActionID)
    }
    private func completeLocally(_ action:ActionRecord) {
        Task {
            if await model.completeActionLocally(action) {
                localCompletionOffer=nil;error=""
                showActionUndo(action.id,message:"已本地完成，连接恢复前不会同步到提醒事项",resultActionID:action.id)
            } else { error=model.status }
        }
    }
    private func undoActionChange() {
        guard let undo=actionUndo else { return }
        Task {
            switch undo.kind {
            case .stateChange:
                if await model.undoActionState(actionID:undo.actionID) { actionUndo=nil;error="" }
                else { error=model.status.isEmpty ? "未能撤销，请稍后重试。" : model.status }
            case .externalCompletion(let expectedVersion):
                guard let store=model.store else { error="资料库尚未打开"; return }
                do {
                    _ = try await store.revertExternalCompletion(actionID:undo.actionID,expectedVersion:expectedVersion,
                                                                 commandID:"workspace-undo-external:" + undo.actionID + ":" + String(expectedVersion))
                    await model.refresh()
                    actionUndo=nil;error=""
                } catch {
                    self.error=error.localizedDescription
                    await model.refresh()
                }
            }
        }
    }
    private var planRemainingSlots: Int { max(0,3 - focusedActions.count) }
    private var planCandidates: [ActionTimeEntry] {
        let surface=ActionTimeSurface.build(actions:visibleActions,schedules:model.scheduleIntents,links:model.reminderLinks,now:Date(),calendar:.current)
        let focused=Set(focusedActions.map(\.id))
        return (surface.soon + surface.anytime).filter { !focused.contains($0.action.id) }
    }
    private func beginPlanningToday() {
        planSelection=[];planLimitHint="";showingPlanToday=true
    }
    private func togglePlanSelection(_ id:String) {
        if let index=planSelection.firstIndex(of:id) { planSelection.remove(at:index);planLimitHint="";return }
        guard planSelection.count < planRemainingSlots else {
            planLimitHint="专注最多 3 条，先移出一条再选。"
            return
        }
        planSelection.append(id);planLimitHint=""
    }
    private func confirmPlanToday() async {
        guard !planningToday, !planSelection.isEmpty else { return }
        planningToday=true
        defer { planningToday=false }
        let current=await model.focusedActionIDs()
        var failure=""
        for id in planSelection where !current.contains(id) {
            guard let next=await model.toggleActionFocus(actionID:id) else { failure=model.status;break }
            focusedActionIDs=next
        }
        focusedActionIDs=await model.focusedActionIDs()
        if failure.isEmpty { showingPlanToday=false;planSelection=[];planLimitHint="";error="" }
        else { planLimitHint=failure }
    }
    private var planTodaySheet: some View {
        let candidates=planCandidates
        return VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.top,spacing:12) {
                VStack(alignment:.leading,spacing:6) {
                    Text("安排今天").vosFont(WorkspaceText.sectionTitle)
                    Text("从即将与随时里挑选，最多 3 条进入专注。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
                Spacer(minLength:8)
                Button("取消") { showingPlanToday=false }
            }
            if !focusedActions.isEmpty {
                Text("已在专注").vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                ForEach(focusedActions) { action in
                    HStack(spacing:10) {
                        Image(systemName:"pin").foregroundStyle(palette.accent).frame(width:22,alignment:.leading)
                        Text(action.title).vosFont(WorkspaceText.rowTitle).lineLimit(2)
                        Spacer(minLength:8)
                        Text("已专注").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    }.padding(.vertical,5)
                }
            }
            Text("即将与随时").vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            if candidates.isEmpty {
                Text("没有可安排的任务。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing:0) {
                        ForEach(candidates) { entry in
                            planCandidateRow(entry)
                            if entry.id != candidates.last?.id { Divider() }
                        }
                    }
                }.frame(minHeight:160,maxHeight:.infinity)
            }
            if planRemainingSlots == 0 { WorkspaceNoticeText(message:"专注已有 3 条，先移出一条再安排。",severity:.warning) }
            else if !planLimitHint.isEmpty { WorkspaceNoticeText(message:planLimitHint,severity:.warning) }
            HStack {
                Text("已选 \(planSelection.count) 条").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                Spacer()
                Button(planningToday ? "正在安排…" : "加入专注") { Task { await confirmPlanToday() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(planSelection.isEmpty || planningToday)
            }
        }.padding(24).frame(minWidth:560,idealWidth:560,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
    private func planCandidateRow(_ entry:ActionTimeEntry) -> some View {
        let selected=planSelection.contains(entry.action.id)
        return Button { togglePlanSelection(entry.action.id) } label: {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:selected ? "checkmark.circle.fill" : "circle")
                    .vosFont(WorkspaceText.rowTitle.size).foregroundStyle(selected ? palette.accent : Color.secondary).padding(.top,2).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:4) {
                    Text(entry.action.title).vosFont(WorkspaceText.rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                    if let due=entry.due { Text(due.summary).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                }
                Spacer(minLength:8)
            }.padding(.vertical,9).contentShape(Rectangle())
                .accessibilityElement(children:.combine)
        }.buttonStyle(.plain).accessibilityValue(selected ? "已选" : "未选")
    }
    private var actionKeyboardOrder: [ActionRecord] {
        var rows:[ActionRecord]=[]
        var seen=Set<String>()
        func add<S:Sequence>(_ actions:S) where S.Element == ActionRecord {
            for action in actions where seen.insert(action.id).inserted { rows.append(action) }
        }
        if ["全部","我的待办"].contains(actionFilter) { add(focusedActions) }
        if actionFilter == "我的待办" {
            let surface=ActionTimeSurface.build(actions:visibleActions,schedules:model.scheduleIntents,links:model.reminderLinks,now:Date(),calendar:.current)
            add(surface.today.map(\.action))
            add(surface.soon.map(\.action))
            add(surface.anytime.map(\.action))
        } else if actionFilter != "AI 助理" {
            add(visibleActions)
        }
        if actionFilter == "全部" {
            add(model.workspacePausedTasks)
            add(model.openQuestions.prefix(3))
            add(model.openGoals.prefix(3))
        }
        return rows
    }
    private func handleActionListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .actions, actionListFocused, !selectingActions,
              press.modifiers.isDisjoint(with: [.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let order=actionKeyboardOrder
        switch press.key {
        case .downArrow, .upArrow:
            guard !order.isEmpty else { return .ignored }
            let current=actionKeyboardHighlightID.flatMap { id in order.firstIndex { $0.id == id } }
            let next: Int
            if press.key == .upArrow { next=current.map { max(0,$0 - 1) } ?? order.count - 1 }
            else { next=current.map { min(order.count - 1,$0 + 1) } ?? 0 }
            actionKeyboardHighlightID=order[next].id
            return .handled
        case .return:
            guard let id=actionKeyboardHighlightID,order.contains(where: { $0.id == id }) else { return .ignored }
            go(.task(id))
            return .handled
        default:
            break
        }
        guard let id=actionKeyboardHighlightID,
              let index=order.firstIndex(where: { $0.id == id }),
              order[index].state == "open", order[index].validity == "current" else { return .ignored }
        let action=order[index]
        let nextHighlight:String?=order.indices.contains(index + 1) ? order[index + 1].id : (index > 0 ? order[index - 1].id : nil)
        switch press.characters.lowercased() {
        case "x" where action.kind == "task":
            applyActionState(action,to:.completed,nextHighlight:nextHighlight)
            return .handled
        case "z":
            applyActionState(action,to:.dismissed,nextHighlight:nextHighlight)
            return .handled
        default:
            return .ignored
        }
    }
    private func requestActionListFocus() {
        Task {
            try? await Task.sleep(for:.milliseconds(100))
            guard page == .actions, !selectingActions, !showingPlanToday else { return }
            actionListFocused=true
        }
    }
    private func requestMaterialListFocus() {
        Task {
            try? await Task.sleep(for:.milliseconds(100))
            guard page == .materials else { return }
            materialListFocused=true
        }
    }
    private func handleMaterialListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .materials, materialListFocused,
              press.modifiers.isDisjoint(with: [.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let ids=readingMaterials.map(\.id)
        switch press.key {
        case .downArrow, .upArrow:
            guard materialKeyboardFocus.step(up: press.key == .upArrow, over: ids) else { return .ignored }
            return .handled
        case .return:
            guard let id=materialKeyboardFocus.id, ids.contains(id) else { return .ignored }
            go(.source(id))
            return .handled
        default:
            return .ignored
        }
    }
    private func handleSearchListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .search, searchListFocused,
              press.modifiers.isDisjoint(with: [.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let rows=searchSections.flatMap(\.rows)
        switch press.key {
        case .downArrow, .upArrow:
            guard searchKeyboardFocus.step(up: press.key == .upArrow, over: rows.map(\.id)) else { return .ignored }
            return .handled
        case .return:
            guard !rows.isEmpty else { return .ignored }
            openSearchSelection()
            return .handled
        default:
            return .ignored
        }
    }
    private func openSearchSelection() {
        let rows=searchSections.flatMap(\.rows)
        if let row=rows.first(where: { $0.id == searchKeyboardFocus.id }) { row.open(); return }
        if let suggestion=searchSuggestions.first { rememberSearch(query.trimmingCharacters(in:.whitespacesAndNewlines)); suggestion.open(); return }
        rows.first?.open()
    }
    private func installSearchArrowMonitor() {
        guard searchArrowMonitor == nil else { return }
        searchArrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { moveSearchSelection(with: event) }
            return handled ? nil : event
        }
    }
    private func removeSearchArrowMonitor() {
        guard let monitor = searchArrowMonitor else { return }
        NSEvent.removeMonitor(monitor)
        searchArrowMonitor = nil
    }
    private func moveSearchSelection(with event: NSEvent) -> Bool {
        guard page == .search, searchFocused, !searchListFocused,
              event.window?.isKeyWindow == true, event.window?.sheetParent == nil,
              event.specialKey == NSEvent.SpecialKey.upArrow || event.specialKey == NSEvent.SpecialKey.downArrow,
              event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty else { return false }
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let ids=searchSections.flatMap(\.rows).map(\.id)
        return searchKeyboardFocus.step(up: event.specialKey == NSEvent.SpecialKey.upArrow, over: ids)
    }
    private func batchActions(for state:LocalActionState) -> [ActionRecord] {
        let ids=selectedActionIDs
        return model.actionRecords.filter { ids.contains($0.id) && $0.state == "open" && $0.validity == "current" && (state != .completed || $0.kind == "task") }
    }
    private var batchConfirmTitle: String {
        let count = pendingBatchState.map { batchActions(for: $0).count } ?? 0
        return (pendingBatchState == .dismissed ? "不再跟进 " : "标为完成 ") + "\(count) 条行动？"
    }
    private var batchConfirmMessage: String {
        "只更新仍为待办且有效的行动。问题与目标只支持不再跟进，失败的会合并成一条提示。"
    }
    private func exitActionSelection() {
        selectingActions=false;selectedActionIDs=[]
    }
    private func applyActionBatch(_ state:LocalActionState) async {
        guard !batchRunning else { return }
        batchRunning=true
        defer { batchRunning=false }
        var failures=0
        for record in batchActions(for: state) {
            await model.changeAction(record,state:state)
            if model.actionRecords.first(where: { $0.id == record.id })?.state != state.rawValue { failures += 1 }
        }
        exitActionSelection()
        error=failures == 0 ? "" : "有 \(failures) 条行动未能更新，请稍后重试。"
    }
    private var actionSelectionBar: some View {
        HStack(spacing:12) {
            Text(batchRunning ? "正在更新…" : "已选 \(selectedActionIDs.count) 条").vosFont(WorkspaceText.meta.size, weight: .medium)
            Button("标为完成") { pendingBatchState = .completed }.buttonStyle(.borderedProminent).disabled(batchRunning || batchActions(for: .completed).isEmpty)
            Button("不再跟进") { pendingBatchState = .dismissed }.buttonStyle(.bordered).disabled(batchRunning || batchActions(for: .dismissed).isEmpty)
            Button("取消") { exitActionSelection() }.buttonStyle(.borderless).disabled(batchRunning)
        }.padding(.horizontal,18).padding(.vertical,11)
            .background(palette.surface,in:Capsule())
            .overlay(Capsule().strokeBorder(palette.selection,lineWidth:1))
            .shadow(color:.black.opacity(0.18),radius:14,y:6)
            .padding(.bottom,16)
    }
    private var actionUndoBar: some View {
        HStack(spacing:12) {
            Text(actionUndo?.message ?? "").vosFont(WorkspaceText.meta.size, weight: .medium)
            if let id = actionUndo?.resultActionID,
               let action = model.actionRecords.first(where: { $0.id == id && $0.state == LocalActionState.completed.rawValue }) {
                Button("记一句结果") { resultFeedbackTarget = action }
            }
            Button("撤销") { undoActionChange() }
        }.padding(.horizontal,16).padding(.vertical,10)
            .background(palette.surface,in:Capsule())
            .overlay { Capsule().strokeBorder(palette.border,lineWidth:1) }
            .shadow(color:.black.opacity(0.18),radius:14,y:6)
            .padding(.bottom,16)
    }
    private var pendingReminderSyncSheet: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("本地完成待同步").vosFont(WorkspaceText.sectionTitle)
            Text("这些变更只保存在 VoiceOS。恢复提醒事项连接并授权后，会自动写入 Apple 提醒事项并回读。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            if model.pendingReminderSyncList.isEmpty {
                Text("没有待同步的本地变更。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            } else {
                ForEach(model.pendingReminderSyncList) { entry in
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:"clock.arrow.circlepath").foregroundStyle(palette.warning).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:4) {
                            Text(entry.title).vosFont(WorkspaceText.rowTitle).lineLimit(2)
                            Text(entry.desiredState == LocalActionState.completed.rawValue ? "已在 VoiceOS 完成" : "已在 VoiceOS 撤销完成").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:8)
                    }.padding(.vertical,8)
                    if entry.id != model.pendingReminderSyncList.last?.id { Divider() }
                }
            }
            if !model.status.isEmpty { Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
            HStack {
                Button("关闭") { showingPendingReminderSyncs=false }
                Spacer()
                Button("现在核对") { Task { await model.retryPendingReminderSyncs() } }
                    .disabled(model.remindersBusy || model.pendingReminderSyncs.isEmpty)
            }
        }.padding(24).frame(width:520)
    }
    private func thoughtRow(_ claim:CandidateClaim) -> some View { WorkspaceRow(title:claim.statement,subtitle:claim.ownership == "ai_candidate" ? "AI 分析 · 不代表我的观点" : claim.ownership == "external" ? "外部观点" : "从我的表达中整理",icon:"lightbulb") { if let id=claim.references.first?.sourceID { go(.source(id)) } } }
    private func dateLabel(_ text:String) -> String { ConversationReflectionFocus.date(text)?.formatted(date:.abbreviated,time:.omitted) ?? text }
    private var navigationEntry: WorkspaceNavigationEntry { .init(page:page,topicID:topicID,topicTab:topicTab,topicReadingMode:topicReadingMode) }
    private func go(_ next:WorkspacePage) {
        if page != next { path.append(navigationEntry);if next.isTopLevel { scrollPositions.removeAll() };page=next }
        error=""
        if case .source(let id)=next { markSourceOpened(id) }
    }
    private func markSourceOpened(_ id:String) {
        Task {
            let states=await model.readingStates()
            let current=states[id] ?? .unread
            readingStates[id]=current
            guard current == .unread else { return }
            if await model.setReadingState(sourceID:id,state:.reading) { readingStates[id] = .reading }
            else { error=model.status }
        }
    }
    private func back() {
        if let entry=path.popLast() {
            topicID=entry.topicID;topicTab=entry.topicTab;topicReadingMode=entry.topicReadingMode;page=entry.page
        } else { page = .home }
        topicFocus=nil;error=""
    }
    private var sourceRailRows: [SourceRecord] {
        let index=model.sourcePageIndex
        var seen=Set<String>()
        return model.records.filter { source in
            guard !source.isArchived,!source.isTrashed else { return false }
            guard let expression=index.expression(for:source.id),expression.sourceIDs.count > 1 else { return true }
            return seen.insert(expression.id).inserted
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private func sourceRail(selectedID:String) -> some View {
        let rows=sourceRailRows
        return VStack(alignment:.leading,spacing:0) {
            HStack(spacing:8) {
                Text("材料").vosFont(WorkspaceText.meta.size, weight:.semibold).foregroundStyle(palette.secondaryText)
                Text(String(rows.count)).vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                Spacer(minLength:0)
                WorkspaceIconButton(systemImage:"chevron.left",label:"收起材料列表") { sourceRailVisible=false }
                    .accessibilityIdentifier("sourceRail.toggle")
            }.padding(.horizontal,10).padding(.top,12).padding(.bottom,6)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:2) {
                    ForEach(rows) { source in
                        WorkspaceListRow(density:.compact,title:displayTitle(source.displayTitle),subtitle:source.recordingDateLabel,icon:source.kind.contains("text") ? "doc.text" : "waveform",highlighted:source.id == selectedID) { selectSource(source.id) }
                            .help(displayTitle(source.displayTitle))
                            .accessibilityIdentifier("sourceRail.item." + source.id)
                    }
                }.padding(.horizontal,8).padding(.bottom,12)
            }
        }.frame(width:248).background(palette.sidebar)
    }
    private var collapsedSourceRail: some View {
        VStack(spacing:0) {
            WorkspaceIconButton(systemImage:"chevron.right",label:"展开材料列表") { sourceRailVisible=true }
                .accessibilityIdentifier("sourceRail.toggle")
                .padding(.top,12)
            Spacer(minLength:0)
        }.frame(width:28).background(palette.sidebar)
    }
    // A material switch replaces the page under the same back stack, so 返回 still lands where the first material was opened from.
    private func selectSource(_ id:String) {
        guard case .source(let current)=page else { go(.source(id)); return }
        guard current != id else { return }
        page = .source(id)
        error=""
        markSourceOpened(id)
    }
    private func selectTopic(_ id:String) {
        if page == .themes { path.append(navigationEntry) }
        go(.themes);topicID=id;topicTab="概览";topicReadingMode="卡片";topicFocus=nil;creatingTopic=false;newTopicTitle="";editingTopicID=nil
    }
    private func saveTopic() async {
        guard !savingTopic else { return }
        savingTopic = true
        defer { savingTopic = false }
        do {
            if let editingTopicID, creatingTopic, !newTopicTitle.isEmpty { try await model.renameReflectionQuestion(editingTopicID,title:newTopicTitle,allowCloud:true) }
            else { let created=try await model.createReflectionQuestion(newTopicTitle,allowCloud:true);topicID=created.id }
            creatingTopic=false;newTopicTitle="";self.editingTopicID=nil;model.queueTopicOrganization()
        } catch { self.error=error.localizedDescription }
    }
    private var trimmedNewViewName: String { newViewName.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var canSaveView: Bool {
        !trimmedNewViewName.isEmpty && trimmedNewViewName.count <= ControlCenter.savedViewNameLimit
            && savedViews.count < ControlCenter.savedViewsLimit
            && !savedViews.contains { $0.name == trimmedNewViewName }
    }
    private func beginSavingView(_ page:SavedViewPage,filter:String) {
        saveViewPage=page;saveViewFilter=filter;newViewName="";showingSaveView=true
    }
    private func saveView() async {
        guard canSaveView, !savingView else { return }
        savingView=true
        defer { savingView=false }
        if let views=await model.saveWorkspaceView(name:trimmedNewViewName,page:saveViewPage,filter:saveViewFilter) {
            savedViews=views;showingSaveView=false;error="";toastMessage="已保存视图「\(trimmedNewViewName)」"
        } else { error="视图未能保存，请稍后重试。" }
    }
    private func deleteSavedView(_ view:SavedWorkspaceView) {
        Task {
            if let views=await model.deleteWorkspaceView(id:view.id) { savedViews=views;error="";toastMessage="已删除视图「\(view.name)」" }
            else { error="视图未能删除，请稍后重试。" }
        }
    }
    private func openSavedView(_ view:SavedWorkspaceView) {
        path=[]
        scrollPositions.removeAll()
        switch view.page {
        case .materials: materialFilter=view.filter;page = .materials
        case .actions: actionFilter=view.filter;page = .actions
        }
        error=""
    }
    private func consumePendingNavigation() {
        if let route = model.pendingWorkspaceRoute {
            model.pendingWorkspaceRoute = nil
            switch route {
            case .actions: go(.actions)
            case .search: if page == .search { searchFocused = true } else { go(.search) }
            case .settings: go(.settings)
            case .discussion: Task { await toggleDiscussion() }
            case .weeklyReview: showingWeeklyReview = true
            }
        }
        if let id = model.pendingWorkspaceTaskID {
            model.pendingWorkspaceTaskID = nil
            go(.task(id))
        }
    }
    private func routeExternalURL(_ url:URL) {
        if CaptureLink.isCapture(url) { Task { await model.acceptCaptureURL(url) } }
        else if url.scheme?.lowercased() == "voiceos", let host=url.host?.lowercased(), ["action","source","topic"].contains(host) {
            let id=url.lastPathComponent
            guard !id.isEmpty else { error="链接缺少条目身份"; return }
            if host == "topic" {
                guard model.workspaceTopics.contains(where: { $0.id == id }) else { error="这个主题已不在当前资料库"; return }
                selectTopic(id)
            } else if host == "action" {
                guard model.actionRecords.contains(where: { $0.id == id }) else { error="这条行动已不在当前资料库"; return }
                go(.task(id))
            } else {
                guard model.records.contains(where: { $0.id == id }) else { error="这份材料已不在当前资料库"; return }
                go(.source(id))
            }
        }
        else { openReminder(url) }
    }
    private func openReminder(_ url:URL) { Task { if await model.focusReminder(url) { if let id=model.focusedTaskID { go(.task(id)) } else { go(.actions) } } else { error = model.status.isEmpty ? "这条提醒无法定位到当前资料库" : model.status } } }
    private func chooseLibrary() {
        let panel=NSOpenPanel();panel.title="打开已有 VoiceOS 资料库";panel.canChooseDirectories=true;panel.canChooseFiles=false
        panel.begin { response in guard response == .OK,let url=panel.url else { return };guard FileManager.default.fileExists(atPath:url.appendingPathComponent("voiceos.sqlite").path) else { error="所选目录不是 VoiceOS 资料库";return };openWindow(id:"restored-library",value:url.path) }
    }
    private var discussionKey: String { page == .themes ? "topic:" + (topicID ?? "all") : String(describing: page) }
    private func openSelectedSource() { if let id=model.selected { go(.source(id)) } else { back() } }
    private func presentDiscussion(for key: String, prompt: String = "") {
        guard key == discussionKey, let id = model.discussionSession?.id else { return }
        if let previous = discussionDraftSessionID { discussionDrafts[previous] = discussionDraft }
        discussionDraftSessionID = id
        discussionContext = key
        let savedDraft = discussionDrafts[id] ?? ""
        discussionDraft = prompt.isEmpty || savedDraft == prompt ? savedDraft : savedDraft.isEmpty ? prompt : savedDraft + "\n\n" + prompt
        showingDiscussion = true
    }
    private func openPanoramaDiscussion(snapshotID: String, selection: PanoramaSelection) async {
        let key = discussionKey
        guard let draft = await model.beginPanoramaDiscussion(snapshotID: snapshotID, selection: selection) else {
            if key == discussionKey { error = model.status }
            return
        }
        presentDiscussion(for: key, prompt: draft)
    }
    private func openSavedDiscussion(_ id: String) async {
        let key = discussionKey
        guard await model.openDiscussion(id) else { if key == discussionKey { error = model.discussionStatus }; return }
        presentDiscussion(for: key)
    }
    private func discussClaim(_ claim:CandidateClaim) {
        let key = discussionKey
        Task { if await model.beginThoughtDiscussion(claim) { presentDiscussion(for: key) } }
    }
    private func openReflection(_ focus:ConversationReflectionFocus,prompt:String) async -> Bool {
        let key = discussionKey
        guard await model.beginReflectionDiscussion(focus) else { if key == discussionKey { error=model.status };return false }
        guard key == discussionKey else { return false }
        presentDiscussion(for:key,prompt:prompt);return true
    }
    private var homeCanDiscuss: Bool {
        guard page == .home else { return true }
        if homeShowsPanorama { return model.panorama.state?.snapshot != nil && model.panorama.selection != nil }
        return model.homeSnapshot.days.contains { day in
            day.items.contains { $0.kind == .material && !$0.sourceIDs.isEmpty }
        }
    }
    private var discussionEntry: DiscussionEntryToken? {
        switch page {
        case .materials: materialKeyboardFocus.id.map { DiscussionEntryToken(kind: .material, id: $0) }
        case .actions: actionKeyboardHighlightID.map { DiscussionEntryToken(kind: .action, id: $0) }
        case .search: searchKeyboardFocus.id.flatMap { DiscussionEntryToken(raw: $0) }
        default: nil
        }
    }
    private var discussionEntryAvailable: Bool {
        switch page {
        case .home: homeCanDiscuss
        case .source, .task, .delivery: true
        case .themes: topic != nil
        case .materials: discussionEntry != nil
        case .actions: !selectingActions && discussionEntry != nil
        case .search: discussionEntry != nil
        default: false
        }
    }
    private var discussionEntryHint: String {
        switch page {
        case .home: homeCanDiscuss ? "讨论" : "先选择一条材料或全景中的问题"
        case .themes: topic == nil ? "先在主题列表中选择一个主题，再开始讨论" : "讨论"
        case .materials: discussionEntry == nil ? "先选中一条材料，再开始讨论" : "讨论"
        case .actions: selectingActions ? "批量选择中不能开始讨论；先结束选择" : (discussionEntry == nil ? "先选中一条行动，再开始讨论" : "讨论")
        case .search: discussionEntry == nil ? "先选中一条搜索结果，再开始讨论" : "讨论"
        case .source, .task, .delivery: "讨论"
        default: "这个页面没有可讨论的选中项；请从材料、行动或搜索结果进入"
        }
    }
    private func toggleDiscussion(force:Bool=false,prompt:String="") async {
        let key = discussionKey
        if discussionIsPresented && !force { showingDiscussion=false;return }
        guard discussionEntryAvailable else { error=discussionEntryHint;return }
        if discussionContext == discussionKey, discussionDraftSessionID == model.discussionSession?.id, model.discussionSession?.validity == "current", model.discussionSession?.state == "active" {
            if !prompt.isEmpty && prompt != discussionDraft { discussionDraft = discussionDraft.isEmpty ? prompt : discussionDraft + "\n\n" + prompt }
            showingDiscussion=true;return
        }
        let opened:Bool
        switch page {
        case .home:
            if homeShowsPanorama {
                guard let snapshot = model.panorama.state?.snapshot, let selection = model.panorama.selection else { return }
                await openPanoramaDiscussion(snapshotID: snapshot.id, selection: selection)
                return
            }
            let items = model.homeSnapshot.days.flatMap(\.items)
            let picked = RecentContentHomeSelection.shared.itemID.flatMap { id in items.first { $0.id == id } }
                ?? items.first { !$0.thoughts.isEmpty } ?? items.first
            guard let picked, picked.kind == .material,
                  let sourceID = picked.sourceIDs.first,
                  let record = model.sourcePageIndex.recordsByID[sourceID] else { return }
            opened = await model.beginDiscussion(record)
        case .source(let id): opened = if let source=model.sourcePageIndex.recordsByID[id] { await model.beginDiscussion(source) } else { false }
        case .task(let id): opened = if let action=model.sourcePageIndex.allAction(for: id) { await model.beginActionDiscussion(action) } else { false }
        case .delivery(let id): opened = if let execution=model.assistantExecutions.first(where: { $0.id == id }) { await model.beginAssistantDiscussion(execution) } else { false }
        case .themes:
            guard let topic else { error="请先选择一个主题，再开始讨论。"; return }
            do {
                let focus=try await model.loadTopicReflection(topic.id)
                guard key == discussionKey else { return }
                topicFocus=focus;opened=await model.beginReflectionDiscussion(focus)
            } catch { if key == discussionKey { self.error=error.localizedDescription };return }
        case .materials:
            guard let entry=discussionEntry, let record=model.sourcePageIndex.recordsByID[entry.id] else { error="先选中一条材料，再开始讨论。"; return }
            opened = await model.beginDiscussion(record)
        case .actions:
            guard let entry=discussionEntry, let action=model.sourcePageIndex.allAction(for: entry.id) else { error="先选中一条行动，再开始讨论。"; return }
            opened = await model.beginActionDiscussion(action)
        case .search:
            guard let entry=discussionEntry else { error="先选中一条搜索结果，再开始讨论。"; return }
            switch entry.kind {
            case .material:
                guard let record=model.sourcePageIndex.recordsByID[entry.id] else { error="这份材料已不在当前资料库。"; return }
                opened = await model.beginDiscussion(record)
            case .action:
                guard let action=model.sourcePageIndex.allAction(for: entry.id) else { error="这条行动已不在当前资料库。"; return }
                opened = await model.beginActionDiscussion(action)
            case .claim:
                guard let claim=model.sourcePageIndex.claim(for: entry.id) else { error="这条观点已不在当前资料库。"; return }
                discussClaim(claim)
                return
            case .topic:
                guard model.workspaceTopics.contains(where: { $0.id == entry.id }) else { error="这个主题已不在当前资料库。"; return }
                selectTopic(entry.id)
                await toggleDiscussion(force:true,prompt:prompt)
                return
            }
        default:
            error="这个页面没有可讨论的选中项；全时段回顾请从主题的回顾页进入。"
            return
        }
        if opened { presentDiscussion(for:key,prompt:prompt) }
        else if key == discussionKey { error=model.status }
    }
}

private struct WorkspaceTopicEntry: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model:ControlCenter
    let topic:ReflectionQuestion
    let sourceIDs:[String]
    @State private var kind=ReflectionQuestionEntryKind.observation
    @State private var text=""
    @State private var saving=false
    @State private var error=""
    var body:some View {
        DisclosureGroup("留下认识、实践或结果") {
            VStack(alignment:.leading,spacing:13) {
                Picker("记录类型",selection:$kind) { ForEach(ReflectionQuestionEntryKind.allCases,id:\.self) { Text($0.label).tag($0) } }.pickerStyle(.menu)
                TextEditor(text:$text).frame(minHeight:100).padding(8).background(palette.surface,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                Button("保存并接回主题") { saving=true;Task { do { try await model.saveReflectionQuestionEntry(questionID:topic.id,kind:kind,text:text,sourceIDs:sourceIDs,allowCloud:true);text="";error="" } catch { self.error=error.localizedDescription };saving=false } }.disabled(saving || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if !error.isEmpty { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger) }
            }.padding(.top,12)
        }
    }
}

private struct WorkspaceKeySelection {
    var id: String?
    mutating func step(up: Bool, over ids: [String]) -> Bool {
        guard !ids.isEmpty else { return false }
        let current = id.flatMap { ids.firstIndex(of: $0) }
        let next: Int
        if up { next = current.map { max(0,$0 - 1) } ?? ids.count - 1 }
        else { next = current.map { min(ids.count - 1,$0 + 1) } ?? 0 }
        id = ids[next]
        return true
    }
}

private struct ActionUndoState: Equatable {
    enum Kind: Equatable {
        case stateChange
        case externalCompletion(expectedVersion: Int)
    }
    let actionID: String
    let message: String
    let token: UUID
    var kind: Kind = .stateChange
    var resultActionID: String? = nil
}

private struct WorkspaceSearchSuggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let open: () -> Void
}

private struct RecentSearchChip: View {
    @Environment(\.workspacePalette) private var palette
    let term: String
    let open: () -> Void
    let remove: () -> Void
    @State private var hovered = false
    var body: some View {
        HStack(spacing:4) {
            Button(action:open) {
                Text(term).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(1)
                    .frame(maxHeight:.infinity)
            }.buttonStyle(.plain)
                .help("搜索「" + term + "」").accessibilityLabel("搜索「" + term + "」")
            Button(action:remove) {
                Image(systemName:"xmark").vosFont(WorkspaceText.caption.size, weight: .semibold)
                    .foregroundStyle(palette.secondaryText)
                    .frame(width:14,height:14).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help("删除这条最近搜索").accessibilityLabel("删除最近搜索：" + term)
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
        }
        .padding(.horizontal,10).frame(height:WorkspaceMetrics.fieldHeight)
        .background(palette.surface,in:Capsule())
        .overlay { Capsule().strokeBorder(palette.border,lineWidth:1) }
        .onHover { hovered=$0 }
        .contextMenu { Button("删除这条最近搜索",role:.destructive,action:remove) }
        .animation(.easeOut(duration:0.12),value:hovered)
    }
}

private struct WorkspaceSearchRow: Identifiable {
    let id: String
    let title: AttributedString
    let subtitle: AttributedString
    let icon: String
    let open: () -> Void
}

private struct WorkspaceSearchSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    let count: Int
    let rows: [WorkspaceSearchRow]
    let kind: SearchHit.Kind
    let hasMore: Bool
}

private struct SearchResultRow: View {
    @Environment(\.workspacePalette) private var palette
    @State private var hovered = false
    let title: AttributedString
    let subtitle: AttributedString
    let icon: String
    let open: () -> Void
    private var titleText: String { String(title.characters) }
    private var subtitleText: String { String(subtitle.characters) }
    var body: some View {
        Button(action: open) {
            HStack(alignment:.top,spacing:14) {
                Image(systemName:icon).vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                    .frame(width:30,height:30).background(palette.selection.opacity(0.6),in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    .accessibilityHidden(true)
                VStack(alignment:.leading,spacing:3) {
                    Text(title).vosFont(WorkspaceText.rowTitle).lineSpacing(3).lineLimit(3).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).help(titleText)
                    if !subtitle.characters.isEmpty {
                        Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3).lineLimit(2).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).help(subtitleText)
                    }
                }
                Spacer(minLength:8)
            }.padding(.vertical,10).padding(.horizontal,10)
                .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                .background(hovered ? palette.selection.opacity(0.5) : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                .accessibilityElement(children:.combine)
        }.buttonStyle(.plain).onHover { hovered=$0 }
            .accessibilityLabel(subtitleText.isEmpty ? titleText : titleText + " · " + subtitleText)
    }
}

private struct MaterialCard: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let highlighted: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius)
        content
            .background(highlighted ? palette.selection : palette.surface,in:shape)
            .overlay { shape.strokeBorder(highlighted ? palette.focusRing : palette.border,lineWidth:1) }
    }
}

private extension View {
    func materialCard(highlighted: Bool) -> some View { modifier(MaterialCard(highlighted: highlighted)) }
}

private struct MaterialMenuRow<Row: View, MenuContent: View>: View {
    @Environment(\.workspacePalette) private var palette
    var revealed: Bool = false
    @ViewBuilder let menu: () -> MenuContent
    @ViewBuilder let row: () -> Row
    @State private var hovered = false

    private var menuVisible: Bool { hovered || revealed }

    var body: some View {
        row()
            .overlay(alignment:.trailing) {
                menu()
                    .vosFont(WorkspaceText.meta)
                    .padding(.horizontal,8).padding(.vertical,4)
                    .background(palette.surface,in:Capsule())
                    .overlay { Capsule().strokeBorder(palette.border,lineWidth:1) }
                    .padding(.trailing,12)
                    .opacity(menuVisible ? 1 : 0)
                    .allowsHitTesting(menuVisible)
            }
            .onHover { hovered=$0 }
            .animation(.easeOut(duration:0.12),value:menuVisible)
    }
}

private struct ActionCardList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVStack(alignment:.leading,spacing:8) {
            content()
        }.padding(.top,8)
    }
}

private struct WorkspaceActionRowChrome<Row: View, MenuItems: View>: View {
    @Environment(\.workspacePalette) private var palette
    let action: ActionRecord
    let canTransition: Bool
    var revealed: Bool = false
    @ViewBuilder let menuItems: () -> MenuItems
    @ViewBuilder let row: () -> Row
    @State private var hovered = false
    @FocusState private var menuFocused: Bool

    private var menuVisible: Bool { hovered || revealed || menuFocused }

    var body: some View {
        row()
            .overlay(alignment:.trailing) {
                if canTransition {
                    Menu {
                        menuItems()
                    } label: {
                        Image(systemName:"ellipsis").vosFont(WorkspaceText.meta.size, weight: .semibold)
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: WorkspaceMetrics.rowActionMinHeight, height: WorkspaceMetrics.rowActionMinHeight)
                            .contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .focused($menuFocused)
                        .help("更多操作")
                        .accessibilityLabel("更多操作：" + action.title)
                        .padding(.horizontal,6).padding(.vertical,3)
                        .background(palette.surface,in:Capsule())
                        .overlay { Capsule().strokeBorder(palette.border,lineWidth:1) }
                        .padding(.trailing,12)
                        .opacity(menuVisible ? 1 : 0)
                        .allowsHitTesting(menuVisible)
                }
            }
            .onHover { hovered=$0 }
            .animation(.easeOut(duration:0.12),value:menuVisible)
    }
}
