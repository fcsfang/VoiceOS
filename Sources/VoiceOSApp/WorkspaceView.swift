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
private struct TopicLoadKey: Hashable {
    let topicID: String?
    let updatedAt: String?
    let recentOutcomeCount: Int
    let actionKeys: [String]
    var token: Int = 0
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
private struct TopicListing: Identifiable {
    let topic: ReflectionQuestion
    let materialCount: Int
    let distinctDays: Int
    let latestMaterialDate: Date?
    var id: String { topic.id }
    var level: TopicLevel {
        TopicLevel.classify(materialCount: materialCount, distinctDays: distinctDays, manual: topic.isAIOrganized == false)
    }
    var latestActivity: Date {
        latestMaterialDate ?? ConversationReflectionFocus.date(topic.updatedAt) ?? .distantPast
    }
}
private struct TopicMergeOption: Identifiable {
    let topic: ReflectionQuestion
    let materialCount: Int
    var id: String { topic.id }
}
private enum MaterialDayFormatting {
    static let currentYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
    static let otherYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
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
        WorkspacePageHeading(eyebrow: eyebrow, title: title, subtitle: subtitle)
            .textSelection(.enabled)
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
fileprivate func displayTitle(_ raw:String) -> String { MaterialNaming.displayName(MarkdownDocument.plainTitle(raw)) }
fileprivate func fittedDisplayTitle(_ raw:String) -> String { WorkspaceTitleFit.present(displayTitle(raw)).title }
fileprivate let recentSearchDefaultsKey = "voiceos.recentSearches.v1"
/// Fixed widths and icon boxes follow the reading size up to 1.3, so 特大 still fits a desktop window.
func vosLayoutScale(_ scale: CGFloat) -> CGFloat { min(max(scale, 1), 1.3) }
struct WorkspaceRow: View {
    enum TrailingStyle {
        case secondary
        case status(Color)
        case link
        case dot(Color)
        case badge(WorkspaceBadge.Tone)
    }
    struct CompletionControl {
        let enabled: Bool
        let complete: () -> Void
    }
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    let title: String
    let subtitle: String
    /// Colors the second line without changing its type; reminder exceptions read in warning.
    var subtitleTone: Color? = nil
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
            // The open button fills the row so hover and click share one area.
            // The completion switch stacks above it in the leading slot.
            ZStack(alignment:.topLeading) {
                Button(action:completion.complete) {
                    Image(systemName:"circle").vosFont(21)
                        .foregroundStyle(completion.enabled ? palette.accent : palette.disabledText)
                        .frame(width:30 * vosLayoutScale(textScale),height:30 * vosLayoutScale(textScale),alignment:.top)
                        .padding(.leading,10).padding(.top,10).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!completion.enabled)
                    .help("标为完成").accessibilityLabel("标为完成：" + title)
                    .zIndex(1)
                Button(action:open) {
                    HStack(alignment:.top,spacing:14) {
                        Color.clear.frame(width:30 * vosLayoutScale(textScale),height:30 * vosLayoutScale(textScale))
                        titleAndTrailing
                    }
                    .padding(.vertical,10).padding(.horizontal,10).padding(.trailing,trailingGutter)
                    .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                    .accessibilityElement(children:.combine)
                }.buttonStyle(.plain).accessibilityLabel(accessibilityText)
                    .zIndex(0)
            }
            .background(hovered ? palette.hover : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .onHover { hovered=$0 }
            .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
        } else {
            Button(action:open) {
                HStack(alignment:.top,spacing:14) {
                    Image(systemName:icon).vosFont(WorkspaceText.rowTitle.size).foregroundStyle(iconTint ?? palette.accent)
                        .frame(width:30 * vosLayoutScale(textScale),height:30 * vosLayoutScale(textScale)).background(palette.selection.opacity(0.6),in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                        .accessibilityHidden(true)
                    titleAndTrailing
                }.padding(.vertical,10).padding(.horizontal,10).padding(.trailing,trailingGutter)
                    .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                    .background(hovered ? palette.hover : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                    .accessibilityElement(children:.combine)
            }.buttonStyle(.plain).onHover { hovered=$0 }
                .accessibilityLabel(accessibilityText)
                .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
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
                Text(title).vosFont(WorkspaceText.rowTitle).lineSpacing(3).lineLimit(textScale >= 1.3 ? 3 : 2).fixedSize(horizontal:false,vertical:true).help(title)
                if !subtitle.isEmpty { Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(subtitleTone ?? palette.secondaryText).lineSpacing(3).lineLimit(textScale >= 1.3 ? 3 : 2).fixedSize(horizontal:false,vertical:true).help(subtitle) }
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
            Text(trailing).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(1).help(trailing).padding(.top,3)
        case .status(let color):
            Text(trailing).vosFont(WorkspaceText.meta).foregroundStyle(color).lineLimit(1).help(trailing).padding(.top,3)
        case .link:
            HStack(spacing:3) {
                Text(trailing).vosFont(WorkspaceText.meta).lineLimit(1)
                Image(systemName:"chevron.right").vosFont(WorkspaceText.caption.size, weight: .semibold)
            }.foregroundStyle(palette.accent).padding(.top,3)
        case .dot(let color):
            HStack(spacing:5) {
                Circle().fill(color).frame(width:6,height:6).accessibilityHidden(true)
                if !trailing.isEmpty { Text(trailing).vosFont(WorkspaceText.meta).foregroundStyle(color).lineLimit(1) }
            }.padding(.top,3).help(trailing)
        case .badge(let tone):
            WorkspaceBadge(text:trailing, tone:tone).padding(.top,1).help(trailing)
        }
    }
}
private struct WorkspaceAttentionDot: View {
    @ObservedObject var model: ControlCenter
    @ObservedObject var inbox: RecordingInbox
    let open: () -> Void
    @Environment(\.workspacePalette) private var palette
    var body: some View {
        let attention = model.workspaceAttentionSnapshot
        let count = attention.count
        let inboxNeedsAttention = inbox.pendingItems.contains(where: { $0.state == .needsAttention }) || !inbox.folderErrors.isEmpty
        if count > 0 || inboxNeedsAttention {
            let parts = [attention.transcriptIssueCount > 0 ? "转写疑点 \(attention.transcriptIssueCount)" : nil,
                         attention.otherCount > 0 ? "其他 \(attention.otherCount)" : nil].compactMap { $0 }
            let title = count > 0 ? "需要查看" + (parts.isEmpty ? "" : " · " + parts.joined(separator:" · ")) : "有事项需要查看"
            Button(action:open) {
                HStack(alignment:.firstTextBaseline,spacing:6) {
                    Circle().fill(attention.transcriptIssueCount > 0 ? palette.warning : palette.accent)
                        .frame(width:6,height:6).offset(y:-1).accessibilityHidden(true)
                    Text(title).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
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
    @Environment(\.vosTextScale) private var textScale
    private var palette: WorkspacePalette { WorkspacePalette(theme: theme) }
    private var brandImage: NSImage? { AppBrand.image(for: colorScheme) }
    @State private var page: WorkspacePage = .home
    @State private var homeShowsPanorama = false
    @State private var path: [WorkspaceNavigationEntry] = []
    @State private var scrollPositions: [WorkspaceNavigationEntry: ScrollPosition] = [:]
    @State private var sourceScrollPositions: [String: ScrollPosition] = [:]
    @State private var sourceFoldStates: [String: SourceFoldState] = [:]
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
    @State private var themeKeyboardFocus = WorkspaceKeySelection()
    @FocusState private var themeListFocused: Bool
    @State private var clueKeyboardFocus = WorkspaceKeySelection()
    @FocusState private var clueListFocused: Bool
    @State private var unlinkedKeyboardFocus = WorkspaceKeySelection()
    @FocusState private var unlinkedListFocused: Bool
    @State private var topicMaterialKeyboardFocus = WorkspaceKeySelection()
    @FocusState private var topicMaterialListFocused: Bool
    @State private var topicReviewKeyboardFocus = WorkspaceKeySelection()
    @FocusState private var topicReviewListFocused: Bool
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
    @FocusState private var summaryPendingFocus: Bool
    @FocusState private var summaryTodayFocus: Bool
    @State private var searchHits: [SearchHit] = []
    @State private var searchTotals: [SearchHit.Kind: Int] = [:]
    @State private var searchExpandedKinds: Set<SearchHit.Kind> = []
    @State private var searchFailed = false
    @State private var searchBusy = false
    @State private var showSlowSearch = false
    @State private var searchGeneration = 0
    @State private var lastSearchAnnouncement = ""
    @State private var searchHovered = false
    @State private var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: recentSearchDefaultsKey) ?? []
    @State private var searchArrowMonitor: Any?
    @State private var taskFeedbackDrafts: [String: TaskFeedbackDraft] = [:]
    @State private var creatingTopic = false
    @State private var savingTopic = false
    @State private var newTopicTitle = ""
    @State private var editingTopicID: String? = nil
    @State private var mergingTopicID: String?
    @State private var mergeTargetID = ""
    @State private var mergingTopic = false
    @State private var topicFocus: ConversationReflectionFocus?
    @State private var topicQuery = ""
    @State private var showingClues = false
    @State private var reviewPeriod = ReflectionPeriod.week
    @State private var reviewAnchor = Date()
    @State private var error = ""
    @State private var errorRetry: (message: String, action: () -> Void)?
    @State private var topicLoadToken = 0
    @State private var topicFocusTopicID: String?
    @State private var topicLoadError = ""
    @State private var showStartupProgress = false
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
    private var panoramaTopicLinks: [PanoramaTopicLink] {
        model.workspaceTopics.map { PanoramaTopicLink(id: $0.id, title: $0.title, sourceIDs: Set(model.workspaceTopicSources[$0.id] ?? [])) }
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
                else if page == .search {
                    if !query.isEmpty { query="";searchFocused=true;searchKeyboardFocus.id=nil }
                    else { back() }
                }
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
                guard page == .themes, let id=topicID else {
                    topicFocus=nil;topicFocusTopicID=nil
                    if !topicLoadError.isEmpty {
                        if error == topicLoadError { error="" }
                        if errorRetry?.message == topicLoadError { errorRetry=nil }
                    }
                    topicLoadError=""
                    return
                }
                do {
                    let focus=try await model.loadTopicReflection(id)
                    guard topicID == id, !Task.isCancelled else { return }
                    topicFocus=focus;topicFocusTopicID=id
                    if !topicLoadError.isEmpty, error == topicLoadError { error="";errorRetry=nil }
                    topicLoadError=""
                } catch {
                    guard topicID == id, !Task.isCancelled else { return }
                    if topicFocusTopicID != id { topicFocus=nil;topicFocusTopicID=nil }
                    topicLoadError=error.localizedDescription
                    fail(topicLoadError, retry:{ topicLoadToken += 1 })
                }
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
                    Text("选择提醒事项清单").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                    ForEach(model.reminderCalendars) { calendar in Button(calendar.title) { Task { model.proposedReminderCalendarID=calendar.id; await model.saveReminderConnection() } }.disabled(model.remindersBusy) }
                    if !model.status.isEmpty { Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                    HStack {
                        Button("取消") { model.choosingReminderCalendar=false }.buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                        Spacer()
                    }
                }.padding(24)
                    .frame(minWidth:440,idealWidth:440,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                    .workspaceModalSurface()
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
                    onOpenActions:{ go(.actions) },
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
            .sheet(isPresented: mergeTopicSheetPresented) { mergeTopicSheet }
            .environment(\.workspacePalette, palette)
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
            Text("保存当前视图").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            Text(saveViewPage == .materials ? "材料 · " + saveViewFilter : "行动 · " + saveViewFilter).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            TextField("视图名称",text:$newViewName).workspaceFieldSurface()
                .onChange(of:newViewName) { _, value in if value.count > ControlCenter.savedViewNameLimit { newViewName = String(value.prefix(ControlCenter.savedViewNameLimit)) } }
            if savedViews.count >= ControlCenter.savedViewsLimit {
                Text("最多保存 \(ControlCenter.savedViewsLimit) 个视图，可先删除一个。").vosFont(WorkspaceText.meta).foregroundStyle(palette.danger)
            } else if savedViews.contains(where: { $0.name == trimmedNewViewName }) {
                Text("已有同名视图，请换一个名称。").vosFont(WorkspaceText.meta).foregroundStyle(palette.danger)
            }
            HStack {
                Button("取消") { showingSaveView=false }.buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { Task { await saveView() } }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(!canSaveView || savingView)
            }
        }.padding(24).frame(width:400)
            .workspaceModalSurface()
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
            WorkspaceListDivider()
            workspaceErrorBanner
            Group {
                if !model.startupIssue.isEmpty {
                    ContentUnavailableView {
                        Label("资料库尚未打开",systemImage:"exclamationmark.triangle")
                    } description: {
                        Text(model.startupIssue).textSelection(.enabled)
                    } actions: {
                        Button("重试打开资料库") { Task { await model.start() } }.buttonStyle(.workspacePrimary)
                        Button("打开其他资料库",action:chooseLibrary).buttonStyle(.workspaceSecondary)
                    }
                } else if workspaceStarting {
                    if showStartupProgress {
                        ProgressView("正在打开资料库…").controlSize(.small).frame(maxWidth:.infinity,maxHeight:.infinity)
                    } else { Color.clear }
                } else { pageContent }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            if !error.isEmpty, error != model.workspaceLastError {
                HStack(alignment:.firstTextBaseline,spacing:10) {
                    WorkspaceNoticeText(message:error,severity:.danger)
                    if let retry = errorRetry, retry.message == error { Button("重试") { retry.action() } }
                    Button { error="";errorRetry=nil } label: { Image(systemName:"xmark").vosFont(WorkspaceText.caption) }
                        .buttonStyle(.plain).accessibilityLabel("关闭错误提示")
                }.padding(.horizontal,20).padding(.vertical,10)
            }
            if model.workspaceProcessingBarVisible, page != .tool("处理情况") {
                WorkspaceProcessingBar(model: model) { go(.tool("处理情况")) }
            }
        }.frame(minWidth:440)
            .workspaceSlowLoading(workspaceStarting, into: $showStartupProgress)
    }
    private var workspaceStarting: Bool { !model.initialized || !model.workspaceLoaded }
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
    private var topicLoadKey: TopicLoadKey {
        guard page == .themes, let id = topicID else {
            return TopicLoadKey(topicID: nil, updatedAt: nil, recentOutcomeCount: 0, actionKeys: [], token: topicLoadToken)
        }
        let actionIDs = Set(topic?.organization?.sections?.flatMap(\.actionIDs) ?? [])
        return TopicLoadKey(topicID: id, updatedAt: topic?.updatedAt,
                            recentOutcomeCount: model.recentOutcomes.count,
                            actionKeys: model.sourcePageIndex.currentActionKeys(for: actionIDs),
                            token: topicLoadToken)
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:28) {
            HStack(spacing:9) {
                if let brandImage {
                    Image(nsImage: brandImage).resizable().interpolation(.high).frame(width: 26 * vosLayoutScale(textScale), height: 26 * vosLayoutScale(textScale))
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
                            let selected=(view.page == .materials && page == .materials && materialFilter == view.filter) || (view.page == .actions && page == .actions && actionFilter == view.filter)
                            Button { openSavedView(view) } label: {
                                Label(view.name,systemImage:view.page == .materials ? "books.vertical" : "checkmark.circle")
                                    .vosFont(WorkspaceText.body).lineLimit(textScale >= 1.3 ? 2 : 1)
                                    .frame(maxWidth:.infinity,alignment:.leading)
                                    .padding(.horizontal,9).padding(.vertical,7)
                                    .background(selected ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .help(view.page == .materials ? "材料：" + view.filter : "行动：" + view.filter)
                                .contextMenu { Button("删除视图",role:.destructive) { pendingDeleteView = view } }
                                .accessibilityLabel("打开视图：" + view.name)
                                .accessibilityIdentifier("workspace.savedView." + view.name)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
            }
            Spacer()
            VStack(alignment:.leading,spacing: WorkspaceMetrics.rowGap) {
                HStack(spacing:7) {
                    if model.organizingTopics || model.assistantBusy || model.followupBusy {
                        ProgressView().controlSize(.mini)
                            .accessibilityHidden(model.organizingTopics)
                            .accessibilityLabel("正在处理")
                    }
                    if model.organizingTopics { Text("AI 正在连接主题").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                }
                if page != .tool("处理情况") {
                    WorkspaceAttentionDot(model: model, inbox: model.recordingInbox) { go(.tool("处理情况")) }
                }
                Button { go(.settings);showingDiscussion=false } label: {
                    Label("设置",systemImage:"slider.horizontal.3").foregroundStyle(.secondary)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,11)
                        .background(page == .settings ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("nav.settings")
                    .accessibilityAddTraits(page == .settings ? .isSelected : [])
            }.padding(.horizontal,8)
                .onChange(of:model.pendingWorkspacePageRequest) { _, request in
                    guard let request else { return }
                    model.pendingWorkspacePageRequest = nil
                    switch request {
                    case .home: path=[];page = .home;error=""
                    case .themes: path=[];page = .themes;topicID=nil;topicFocus=nil;error=""
                    case .materials: path=[];page = .materials;error=""
                    case .actions: path=[];page = .actions;error=""
                    case .monitor: path=[];page = .monitor;error=""
                    case .initiate: path=[];page = .initiate;error=""
                    case .processing: path=[];page = .tool("处理情况");error=""
                    case .back: back()
                    }
                }
        }.padding(.horizontal,13).padding(.vertical,28).frame(width: 172 * vosLayoutScale(textScale)).background(palette.sidebar)
            .onAppear { AppBrand.applyApplicationIcon() }
            .onChange(of: colorScheme) { _, _ in AppBrand.applyApplicationIcon() }
    }
    private func nav(_ title:String,icon:String,target:WorkspacePage,id:String,badge:Int = 0,badgeAccessibility:String? = nil) -> some View {
        Button { path=[];page=target;if target == .themes { topicID=nil;topicFocus=nil };error="" } label: {
            HStack(spacing:8) {
                Label(title,systemImage:icon).vosFont(WorkspaceText.body.size, weight: section == title ? .semibold : .regular).lineLimit(textScale >= 1.3 ? 2 : 1)
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
                }.padding(.horizontal, WorkspaceMetrics.pagePadding).padding(.top, 12).padding(.bottom, 2)
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
                        revealSourceSpan(sourceID, spanID: spanID)
                        go(.source(sourceID))
                    }, openTask: { go(.task($0)) }, capture: { go(.capture) })
                }
            }
        case .themes:
            ScrollViewReader { proxy in
                scrolled { themes(proxy: proxy) }.id(navigationEntry)
            }
        case .materials:
            ScrollViewReader { proxy in
                scrolled { materials }
                    .focusable()
                    .focused($materialListFocused)
                    .focusEffectDisabled()
                    .onKeyPress { handleMaterialListKey($0) }
                    .onChange(of:materialKeyboardFocus.id) { _, id in guard let id else { return };proxy.scrollTo(id,anchor:.center) }
                    .onAppear {
                        requestMaterialListFocus()
                        restoreKeyboardScroll(proxy: proxy, id: materialKeyboardFocus.id)
                    }
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
                    .onChange(of:showingSaveView) { _, shown in if !shown { requestActionListFocus() } }
                    .onChange(of:reminderSettingsTarget?.id) { _, id in if id == nil { requestActionListFocus() } }
                    .onChange(of:resultFeedbackTarget?.id) { _, id in if id == nil { requestActionListFocus() } }
                    .onAppear {
                        requestActionListFocus()
                        restoreKeyboardScroll(proxy: proxy, id: actionKeyboardHighlightID)
                    }
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
                            },openFollowups:{ go(.tool("思想与下一步")) },scroll:sourceScrollBinding(id),folds:sourceFoldBinding(id,transcript:source.transcript))
                                .id(id)
                        }
                    } else { unavailable("这份材料暂时不可用",description:"可以搜索其他材料，或回到主题。",actionTitle:"回到主题") { go(.themes) } }
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
                        }.buttonStyle(.workspacePrimary).disabled(model.dictationBusy || model.fullRecordingBusy || (!model.dictationActive && model.recordingModelIssue != nil))
                        Button("导入音频 / 视频") { model.chooseFullRecording() }.buttonStyle(.workspaceSecondary)
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
                    .onAppear {
                        installSearchArrowMonitor()
                        restoreKeyboardScroll(proxy: proxy, id: searchKeyboardFocus.id)
                    }
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
        // With no topic open the themes list must not inherit a topic's tab or mode.
        let browsingTopics = page == .themes && topicID == nil
        var entry = WorkspaceNavigationEntry(
            page: page, topicID: topicID,
            topicTab: browsingTopics ? "" : topicTab,
            topicReadingMode: browsingTopics ? "" : topicReadingMode)
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
    private func sourceFoldBinding(_ id:String,transcript:String?) -> Binding<SourceFoldState> {
        Binding(get: { sourceFoldStates[id] ?? SourceFoldState.initial(transcript:transcript) }, set: { sourceFoldStates[id] = $0 })
    }
    private func unavailable(_ title:String,description:String,actionTitle:String = "回到行动",action: (() -> Void)? = nil) -> some View {
        WorkspaceEmptyState(title:title,systemImage:"leaf",description:description) {
            Button(actionTitle) { if let action { action() } else { go(.actions) } }.buttonStyle(.workspacePrimary)
        }.frame(maxWidth:.infinity)
    }
    private func distinctExpressions(_ sources:[SourceRecord]) -> [SourceRecord] {
        let index=model.sourcePageIndex
        let catalog=index.recordsByID
        let attachedContextIDs=Set(sources.compactMap { $0.pairedContextSourceID(in: catalog) })
        var seen=Set<String>()
        return sources.filter { source in
            // Keep a context recording independently reachable when its personal
            // recording is outside this list, rather than hiding it globally.
            guard !attachedContextIDs.contains(source.id) else { return false }
            guard let expression=index.expression(for:source.id),expression.sourceIDs.count > 1 else { return true }
            return seen.insert(expression.id).inserted
        }
    }
    private var readingMaterials: [SourceRecord] { materialPage.rows }
    private var materialPage: MaterialReadingPage {
        MaterialReadingPage(records: model.records, filter: materialFilter,
                            filters: SavedViewPage.materials.filters,
                            readingStates: readingStates, catalog: recordCatalog,
                            expressions: model.sourcePageIndex.expressionsBySourceID)
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
        let formatter = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? MaterialDayFormatting.currentYear : MaterialDayFormatting.otherYear
        return formatter.string(from: date)
    }
    private var materials: some View {
        let catalog = recordCatalog
        let page = materialPage
        // Counts stay on the tabs as a quiet number; the page title carries no floating total.
        let tabs = SavedViewPage.materials.filters.map { filter in
            WorkspaceFilterTabItem(filter: filter, title: filter, count: String(page.counts[filter] ?? 0),
                                   help: filter == "回收站" ? "Apple 提醒事项未被删除或取消。" : "")
        }
        let rows = page.rows
        return LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            WorkspacePageHeading(title:"材料") {
                WorkspaceHeaderMenu {
                    Button("保存当前视图",systemImage:"bookmark") { beginSavingView(.materials,filter:materialFilter) }
                }
            }
            if materialFilter == "日常材料", !todayReading.isEmpty {
                WorkspaceListSection(title:"今日阅读",subtitle:"上次停下的地方，接着读。",count:todayReading.count) {
                    VStack(alignment:.leading,spacing: WorkspaceMetrics.rowGap) {
                        ForEach(todayReading) { item in
                            WorkspaceRow(title:displayTitle(item.source.displayTitle),subtitle:chunkLabel(item),icon:"book") { go(.source(item.id)) }
                                .materialCard(highlighted:false)
                        }
                    }
                }
            }
            WorkspaceFilterTabs(items: tabs, selection: materialFilter, onSelect: { materialFilter = $0 })
            if !rows.isEmpty, ["已归档","回收站"].contains(materialFilter) {
                Text(materialFilter == "已归档" ? "归档材料仍可作为历史依据；打开材料可取消归档。" : "原件与历史保留；恢复后仅本机保存。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            if rows.isEmpty {
                if materialFilter == "日常材料" {
                    WorkspaceEmptyState(title: model.records.isEmpty ? "还没有材料" : "日常材料是空的", systemImage:"tray", description: model.records.isEmpty ? "可以先记录想法，或导入一段录音、视频。" : "其他材料在已归档或回收站里，可以切换查看。") {
                        Button("添加材料") { go(.capture) }.buttonStyle(.workspacePrimary)
                    }
                } else if materialFilter == "未读" {
                    WorkspaceEmptyState(title:"没有未读材料",systemImage:"eye") {
                        Button("查看日常材料") { materialFilter="日常材料" }.buttonStyle(.workspaceSecondary)
                    }
                } else if materialFilter == "在读" {
                    WorkspaceEmptyState(title:"没有在读的材料",systemImage:"book") {
                        Button("查看日常材料") { materialFilter="日常材料" }.buttonStyle(.workspaceSecondary)
                    }
                } else {
                    WorkspaceEmptyState(title:"这里暂时没有材料",systemImage:materialFilter == "回收站" ? "trash" : "archivebox",description:materialFilter == "已归档" ? "归档材料仍可作为历史依据；打开材料可取消归档。" : "原件与历史保留；恢复后仅本机保存。") {
                        Button("查看日常材料") { materialFilter="日常材料" }.buttonStyle(.workspaceSecondary)
                    }
                }
            } else {
                LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.groupGap) {
                    ForEach(materialDayGroups(rows)) { group in
                        VStack(alignment:.leading,spacing:0) {
                            WorkspaceListGroupHeader(title:group.label)
                            VStack(alignment:.leading,spacing: WorkspaceMetrics.rowGap) {
                                ForEach(group.sources) { source in
                                    MaterialMenuRow(revealed: materialKeyboardFocus.id == source.id) {
                                        MaterialManagementControls(model:model,source:source,style:.compact,
                                            onSetReadingState:{ setMaterialReading(source.id,$0) },
                                            onSplitExpression:{ splitMaterialExpression(model.sourcePageIndex.expression(for: source.id)?.sourceIDs ?? [source.id]) },
                                            onRejudgeExpressions:{ rejudgeMaterialExpressions(source.presentation?.expression?.sourceIDs ?? [source.id]) })
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
    private var currentTopicReading: TopicReadingData? {
        guard let topic else { return nil }
        return TopicReadingData(topic: topic, sourceIDs: sourceIDs,
                                records: model.records, claims: model.claims,
                                actions: model.actionRecords)
    }
    private var visibleTopicListings: [TopicListing] {
        let catalog = recordCatalog
        let filter = topicQuery.trimmingCharacters(in:.whitespacesAndNewlines)
        let listings = model.workspaceTopics.map { topicListing($0, catalog: catalog) }
            .sorted { left, right in
                if left.latestActivity != right.latestActivity { return left.latestActivity > right.latestActivity }
                return left.topic.title.localizedStandardCompare(right.topic.title) == .orderedAscending
            }
        guard !filter.isEmpty else { return listings }
        return listings.filter {
            $0.topic.title.localizedCaseInsensitiveContains(filter) || ($0.topic.organization?.summary ?? "").localizedCaseInsensitiveContains(filter)
        }
    }
    private var unlinkedTopicMaterials: [SourceRecord] {
        let linked = Set(model.workspaceTopicSources.values.flatMap { $0 })
        return distinctExpressions(activeMaterials.filter { !linked.contains($0.id) })
    }
    private var reviewInterval: DateInterval { reviewPeriod.interval(containing: reviewAnchor) }
    private func reviewSources(for reading: TopicReadingData) -> [SourceRecord] {
        let interval = reviewInterval
        return reading.sources.filter { interval.contains($0.expressedDate ?? ConversationReflectionFocus.date($0.createdAt) ?? .distantPast) }
    }
    private func themes(proxy: ScrollViewProxy) -> some View {
        let catalog = recordCatalog
        let reading = currentTopicReading
        return LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            if let topic, let reading {
                HStack { Button("所有主题",systemImage:"arrow.left") { if path.last?.page == .themes && path.last?.topicID == nil { back() } else { topicID=nil;topicFocus=nil };creatingTopic=false;newTopicTitle="";editingTopicID=nil };Spacer(); Menu("调整主题") {
                    if topicListing(topic, catalog: catalog).level == .clue { Button("升为主题") { Task { await promoteTopic(topic) } } }
                    Button("修改主题名称") { newTopicTitle=topic.title;editingTopicID=topic.id;creatingTopic=true }
                    Button("合并到其他主题…") { beginMergingTopic(topic) }
                    Button("重新连接当前材料") { model.queueTopicOrganization(retry:true) }
                } }
                WorkspaceHeading(eyebrow:"",title:topic.title,subtitle:"\(reading.sources.count) 份材料")
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
                topicContent(topic, reading: reading, proxy: proxy)
            } else {
                let filter = topicQuery.trimmingCharacters(in:.whitespacesAndNewlines)
                let visibleListings = visibleTopicListings
                let themeListings = visibleListings.filter { $0.level == .theme }
                let clueListings = visibleListings.filter { $0.level == .clue }
                HStack { WorkspaceHeading(eyebrow:"",title:"主题")
                    Spacer();Button("新建主题") { newTopicTitle="";editingTopicID=nil;creatingTopic=true }
                }
                WorkspaceSearchField(text:$topicQuery,placeholder:"搜索主题标题或摘要")
                    .accessibilityIdentifier("topics.search")
                if !themeListings.isEmpty {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:290),spacing: WorkspaceMetrics.groupGap)],alignment:.leading,spacing: WorkspaceMetrics.groupGap) {
                        ForEach(themeListings) { listing in
                            WorkspaceTopicTile(topic:listing.topic,sourceCount:listing.materialCount,highlighted:themeKeyboardFocus.id == listing.id) { selectTopic(listing.topic.id) }
                                .id(listing.id)
                        }
                    }
                    .focusable()
                    .focused($themeListFocused)
                    .focusEffectDisabled()
                    .onKeyPress { handleThemeListKey($0) }
                    .onChange(of:themeKeyboardFocus.id) { _, id in guard let id else { return };proxy.scrollTo(id,anchor:.center) }
                    .onAppear {
                        requestThemeListFocus()
                        restoreKeyboardScroll(proxy: proxy, id: themeKeyboardFocus.id)
                    }
                }
                if filter.isEmpty && model.workspaceTopics.isEmpty {
                    HStack(spacing:8) {
                        if model.organizingTopics { ProgressView().controlSize(.small).accessibilityHidden(true) }
                        Text(model.organizingTopics ? "AI 正在按内容连接主题…" : "授权材料会自动归组。也可以先建立一个你关心的问题。")
                    }.foregroundStyle(.secondary)
                } else if filter.isEmpty && themeListings.isEmpty {
                    Text("还没有达到主题判据的关切。线索会随材料积累成为主题。").foregroundStyle(.secondary)
                }
                if !clueListings.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        DisclosureGroup(isExpanded: Binding(get: { showingClues || !filter.isEmpty }, set: { showingClues = $0 })) {
                            VStack(alignment:.leading,spacing:0) {
                                ForEach(clueListings) { listing in
                                    WorkspaceRow(title:listing.topic.title,subtitle:"\(listing.materialCount) 份材料 · 最近 " + clueDateLabel(listing.latestMaterialDate),icon:"circle.dotted",trailing:"查看") { selectTopic(listing.topic.id) }
                                        .workspaceSelectionHighlight(clueKeyboardFocus.id == listing.id)
                                        .id(listing.id)
                                    if listing.id != clueListings.last?.id { WorkspaceListDivider() }
                                }
                            }
                            .padding(.top,8)
                            .focusable()
                            .focused($clueListFocused)
                            .focusEffectDisabled()
                            .onKeyPress { handleClueListKey($0) }
                            .onChange(of:clueKeyboardFocus.id) { _, id in guard let id else { return };proxy.scrollTo(id,anchor:.center) }
                        } label: {
                            VStack(alignment:.leading,spacing:0) {
                                WorkspaceSectionHeading("线索", count:"\(clueListings.count)").padding(.bottom,16)
                                WorkspaceListDivider()
                            }.contentShape(Rectangle())
                        }
                    }
                }
                if !filter.isEmpty && visibleListings.isEmpty { Text("没有匹配的主题").foregroundStyle(.secondary) }
                let linked=Set(model.workspaceTopicSources.values.flatMap { $0 })
                let unlinked=activeMaterials.filter { !linked.contains($0.id) }
                if !unlinked.isEmpty {
                    let expressions=unlinkedTopicMaterials
                    VStack(alignment:.leading,spacing:8) {
                        DisclosureGroup {
                            VStack(alignment:.leading,spacing:0) {
                                ForEach(expressions) { source in
                                    sourceRow(source,catalog:catalog,reason:source.topicAssignmentReason(in:catalog))
                                        .workspaceSelectionHighlight(unlinkedKeyboardFocus.id == source.id)
                                        .id(source.id)
                                    if source.id != expressions.last?.id { WorkspaceListDivider() }
                                }
                            }
                            .padding(.top,8)
                            .focusable()
                            .focused($unlinkedListFocused)
                            .focusEffectDisabled()
                            .onKeyPress { handleUnlinkedListKey($0) }
                            .onChange(of:unlinkedKeyboardFocus.id) { _, id in guard let id else { return };proxy.scrollTo(id,anchor:.center) }
                        } label: {
                            VStack(alignment:.leading,spacing:0) {
                                WorkspaceSectionHeading(title:"尚未归入主题的材料", count:"\(expressions.count)") {
                                    Button(model.organizingTopics ? "AI 正在归组…" : "交给 AI 归组") { model.queueTopicOrganization() }
                                        .vosFont(WorkspaceText.meta)
                                        .disabled(model.organizingTopics || !model.modelConfigured)
                                        .help(model.modelConfigured ? "让 AI 把这些材料连接到已有或新的主题" : "先配置文本模型，才能交给 AI 归组")
                                }.padding(.bottom,16)
                                WorkspaceListDivider()
                            }.contentShape(Rectangle())
                        }
                        Text(unassignedTopicReasonSummary(unlinked,catalog:catalog)).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                        if !model.topicOrganizationStatus.isEmpty { Text(model.topicOrganizationStatus).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText) }
                    }
                }
            }
            if creatingTopic {
                VStack(alignment:.leading,spacing:14) {
                    TextField("你持续关心的主题或问题",text:$newTopicTitle).workspaceFieldSurface()
                    HStack {
                        Button("取消") { creatingTopic=false;editingTopicID=nil }.buttonStyle(.workspaceSecondary)
                        Button("保存主题") { Task { await saveTopic() } }.buttonStyle(.workspacePrimary).disabled(newTopicTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || savingTopic)
                    }
                }.padding(18).background(palette.selection,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            }
        }
    }
    private func topicListing(_ topic: ReflectionQuestion, catalog: [String: SourceRecord]) -> TopicListing {
        let ids = model.workspaceTopicSources[topic.id] ?? []
        var days = Set<Date>()
        var latest: Date?
        for id in ids {
            guard let createdAt = catalog[id]?.createdAt, let date = ConversationReflectionFocus.date(createdAt) else { continue }
            days.insert(Calendar.current.startOfDay(for: date))
            if latest == nil || date > latest! { latest = date }
        }
        return TopicListing(topic: topic, materialCount: ids.count, distinctDays: days.count, latestMaterialDate: latest)
    }
    private func clueDateLabel(_ date: Date?) -> String {
        guard let date else { return "暂无日期" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    @ViewBuilder private func topicContent(_ topic:ReflectionQuestion, reading:TopicReadingData, proxy:ScrollViewProxy) -> some View {
        switch topicTab {
        case "材料":
            let catalog = recordCatalog
            let expressions = distinctExpressions(reading.sources)
            WorkspaceSection(title:"主题材料",subtitle:"完整原话与资料，按时间延续",icon:"books.vertical",count:reading.sources.count) {
                VStack(spacing:0) {
                    ForEach(expressions) { source in
                        sourceRow(source,catalog:catalog)
                            .workspaceSelectionHighlight(topicMaterialKeyboardFocus.id == source.id)
                            .id(source.id)
                        if source.id != expressions.last?.id { WorkspaceListDivider() }
                    }
                }
                .focusable()
                .focused($topicMaterialListFocused)
                .focusEffectDisabled()
                .onKeyPress { handleTopicMaterialListKey($0) }
                .onChange(of:topicMaterialKeyboardFocus.id) { _, id in guard let id else { return };proxy.scrollTo(id,anchor:.center) }
                .onAppear {
                    requestTopicMaterialListFocus()
                    restoreKeyboardScroll(proxy: proxy, id: topicMaterialKeyboardFocus.id)
                }
            }
            DisclosureGroup("关联其他材料") {
                ForEach(reading.unlinkedSources) { source in
                    Button(displayTitle(source.displayTitle)) { Task { do { try await model.linkReflectionQuestionSource(questionID:topic.id,sourceID:source.id,linked:true);await model.refresh() } catch { self.error=error.localizedDescription } } }
                }
            }
        case "认识与问题":
            Picker("阅读方式",selection:$topicReadingMode) { Text("小主题卡片").tag("卡片");Text("材料图谱").tag("图谱");Text("周期回顾").tag("回顾") }.pickerStyle(.segmented)
            if topicReadingMode == "图谱" {
                ReflectionTimelineView(model:model,embeddedTopicID:topic.id,openSource:{ go(.source($0)) },dismiss:{},discuss:{ claim in discussClaim(claim) },reflect:{ focus,prompt in await openReflection(focus,prompt:prompt) }).frame(minHeight:620)
            } else if topicReadingMode == "回顾" { review(topic, reading: reading, proxy: proxy) }
            else {
                topicReading(topic,mode:"认识与问题",reading:reading)
                WorkspaceTopicEntry(model:model,topic:topic,sourceIDs:Array(reading.sourceIDs))
            }
        default: topicReading(topic,mode:topicTab,reading:reading)
        }
    }
    private func topicReading(_ topic:ReflectionQuestion,mode:String,reading:TopicReadingData) -> some View {
        let level = topicListing(topic, catalog: recordCatalog).level
        return WorkspaceTopicReadingView(model:model,topic:topic,mode:mode,focus:topicFocus,reading:reading,level:level,
            openSource:{ go(.source($0)) },openTopic:{ selectTopic($0) },openTask:{ go(.task($0)) },openDelivery:{ go(.delivery($0)) },
            discuss:{ prompt in Task { await toggleDiscussion(force:true,prompt:prompt) } },showActions:{ topicTab="行动与结果" },
            showUnderstanding:{ topicTab="认识与问题";topicReadingMode="卡片" })
            .id(topic.id + mode)
    }
    private func review(_ topic:ReflectionQuestion, reading:TopicReadingData, proxy:ScrollViewProxy) -> some View {
        VStack(alignment:.leading,spacing: WorkspaceMetrics.groupGap) {
            HStack {
                Picker("回顾周期",selection:$reviewPeriod) { ForEach(ReflectionPeriod.allCases,id:\.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented).frame(maxWidth:210)
                DatePicker("日期",selection:$reviewAnchor,displayedComponents:.date).labelsHidden()
            }
            let interval=reviewInterval
            let sources=reviewSources(for: reading)
            let catalog=recordCatalog
            let expressions=distinctExpressions(sources)
            VStack(spacing:0) {
                ForEach(expressions) { source in
                    sourceRow(source,catalog:catalog)
                        .workspaceSelectionHighlight(topicReviewKeyboardFocus.id == source.id)
                        .id(source.id)
                    if source.id != expressions.last?.id { WorkspaceListDivider() }
                }
            }
            .focusable()
            .focused($topicReviewListFocused)
            .focusEffectDisabled()
            .onKeyPress { handleTopicReviewListKey($0) }
            .onChange(of:topicReviewKeyboardFocus.id) { _, id in guard let id else { return };proxy.scrollTo(id,anchor:.center) }
            .onAppear {
                requestTopicReviewListFocus()
                restoreKeyboardScroll(proxy: proxy, id: topicReviewKeyboardFocus.id)
            }
            let actionIDs=reading.actionIDs
            let outcomes=(topicFocus?.outcomes ?? []).filter { actionIDs.contains($0.actionID) && ConversationReflectionFocus.date($0.createdAt).map { interval.contains($0) } == true }
            ForEach(outcomes) { outcome in WorkspaceRow(title:outcome.text,subtitle:"实际结果 · " + dateLabel(outcome.createdAt),icon:"leaf") { go(.task(outcome.actionID)) } }
            if sources.isEmpty && outcomes.isEmpty { Text("这段时间还没有新增材料或结果。这个主题的历史脉络仍保留在概览中。").foregroundStyle(.secondary) }
            Button("让 AI 一起回顾这个周期",systemImage:"sparkles") { Task { do { let focus=try await model.loadQuestionReflection(topic.id,interval:interval,period:reviewPeriod);_ = await openReflection(focus,prompt:reviewPeriod.reviewPrompt(dateLabel:interval.start.formatted(date:.abbreviated,time:.omitted),questionTitle:topic.title)) } catch { self.error=error.localizedDescription } } }.buttonStyle(.workspacePrimary)
        }
    }
    @State private var showingClarifyQueue = false
    @State private var clarifyScope: ClarifyQueueScope = .questions
    private var actions: some View {
        let nextStepCounts = model.sourcePageIndex.nextStepCounts
        let rowReads=ActionRowReads(reminderLinks:model.reminderLinks,executions:model.assistantExecutions)
        let listGroup:ActionRowGroup=actionFilter == "已完成" ? .completed : actionFilter == "历史记录" ? .history : actionFilter == "待核对" ? .needsReview : .active
        let todoActions = myTodoActions
        let timeSurface: ActionTimeSurface? = ["全部","我的待办"].contains(actionFilter)
            ? ActionTimeSurface.build(actions: todoActions, schedules: model.scheduleIntents,
                                      links: model.reminderLinks, now: Date(), calendar: .current)
            : nil
        return LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            WorkspacePageHeading(title:"行动") {
                HStack(spacing:8) {
                    if model.unreadDeliveryCount > 0 {
                        Button { actionFilter = "AI 助理"; error = "" } label: {
                            WorkspaceBadge(text:"AI 交付 \(model.unreadDeliveryCount) 份待读", tone:.neutral)
                                .frame(minHeight: WorkspaceMetrics.rowActionMinHeight)
                                .padding(.horizontal, 6)
                                .contentShape(Capsule())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("AI 交付 \(model.unreadDeliveryCount) 份待读，打开列表")
                    }
                    if actionFilter == "我的待办" {
                        Button { beginPlanningToday() } label: {
                            Label("安排今天", systemImage:"sun.max")
                        }.buttonStyle(.workspacePrimary)
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
                }
            }.sheet(isPresented:$showingClarifyQueue) { ActionClarifyQueueView(model:model, scope:clarifyScope) }
            WorkspaceFilterTabs(items: SavedViewPage.actions.filters.map { WorkspaceFilterTabItem(filter: $0, title: $0) }, selection: actionFilter, onSelect: { actionFilter = $0 })
            if let offer = localCompletionOffer {
                HStack(spacing:12) {
                    WorkspaceNoticeText(message: model.status.isEmpty ? "提醒事项不可用；可以先本地完成，稍后核对。" : model.status, severity:.warning)
                    Spacer(minLength:8)
                    Button("仅本地完成（稍后核对）") { completeLocally(offer) }.buttonStyle(.workspaceSecondary)
                    Button("稍后再说") { localCompletionOffer = nil }.buttonStyle(.workspaceQuietCompact)
                }
            }
            if !model.pendingReminderSyncs.isEmpty {
                Button { showingPendingReminderSyncs = true } label: {
                    HStack(spacing:6) {
                        Image(systemName:"arrow.triangle.2.circlepath").vosFont(WorkspaceText.meta.size, weight:.medium).foregroundStyle(palette.warning)
                        Text("\(model.pendingReminderSyncs.count) 项本地完成待同步 · 稍后核对").vosFont(WorkspaceText.meta, monospacedDigit: true).foregroundStyle(palette.secondaryText)
                        Spacer(minLength:0)
                    }.frame(minHeight: WorkspaceMetrics.rowActionMinHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .focused($summaryPendingFocus).focusEffectDisabled()
                    .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.controlRadius)
                    .workspaceFocusRing(summaryPendingFocus, radius: WorkspaceMetrics.controlRadius)
                    .accessibilityLabel("本地完成待同步 \(model.pendingReminderSyncs.count) 项，打开核对")
            }
            if actionFilter == "全部", let surface = timeSurface {
                let overdue = surface.today.filter(\.isOverdue).count
                Button { actionFilter = "我的待办" } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sun.max").vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(palette.accent)
                        Text("今天 \(surface.today.count - overdue) · 逾期 \(overdue)").monospacedDigit().vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        Image(systemName: "chevron.right").vosFont(WorkspaceText.caption.size, weight: .semibold).foregroundStyle(palette.disabledText)
                        Spacer(minLength: 0)
                    }.frame(minHeight: WorkspaceMetrics.rowActionMinHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .focused($summaryTodayFocus).focusEffectDisabled()
                    .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.controlRadius)
                    .workspaceFocusRing(summaryTodayFocus, radius: WorkspaceMetrics.controlRadius)
                    .accessibilityLabel("今天 \(surface.today.count - overdue) 项，逾期 \(overdue) 项")
                    .accessibilityHint("切到我的待办")
                    .help("切到我的待办")
            }
            if ["目标","全部"].contains(actionFilter), !model.stalledOutcomes.isEmpty { stalledBanner }
            let visible = ["全部","我的待办"].contains(actionFilter) ? todoActions : visibleActions
            let focusedIDs = Set(focusedActions.map(\.id))
            let listed = actionFilter == "全部" ? todoOrder(visible, surface: timeSurface).filter { !focusedIDs.contains($0.id) } : visible
            let timeEntries: [String: ActionTimeEntry] = timeSurface.map { surface in
                Dictionary(uniqueKeysWithValues: (surface.today + surface.soon + surface.anytime).map { ($0.id, $0) })
            } ?? [:]
            let executions = model.sortedAssistantDeliveries(model.assistantExecutions.filter { $0.state != "cancelled" })
            let paused = model.workspacePausedTasks
            if ["全部","我的待办"].contains(actionFilter), !focusedActions.isEmpty {
                WorkspaceListSection(title:"专注",count:focusedActions.count) {
                    ActionCardList {
                        ForEach(focusedActions) { action in actionRow(action,nextStepCounts:nextStepCounts,reads:rowReads) }
                    }
                }
            }
            if actionFilter == "我的待办", !visible.isEmpty, let surface = timeSurface {
                let overdue = surface.today.filter(\.isOverdue)
                let dueToday = surface.today.filter { !$0.isOverdue }
                if !overdue.isEmpty {
                    WorkspaceListSection(title:"逾期",subtitle:"已过期限。改期需要提醒事项链接。",count:overdue.count) {
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
                        ForEach(listed) { action in actionRow(action,timeEntry:timeEntries[action.id],group:listGroup,nature:listNature,nextStepCounts:nextStepCounts,reads:rowReads) }
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
                WorkspaceListSection(title:"问题",subtitle:"VoiceOS 先回答；想清楚了可以转成下一步。",count:overviewQuestions.count,collapsible:true) {
                    ActionCardList {
                        ForEach(overviewQuestions.prefix(3)) { action in
                            actionRow(action,nature:.question,nextStepCounts:nextStepCounts,reads:rowReads)
                        }
                    }
                    if overviewQuestions.count > 3 {
                        Button("查看全部 \(overviewQuestions.count)") { actionFilter = "问题" }
                            .buttonStyle(.workspaceQuietCompact).padding(.vertical,6)
                    }
                }
            }
            let overviewGoals = actionFilter == "全部" ? model.openGoals : []
            if !overviewGoals.isEmpty {
                WorkspaceListSection(title:"目标",subtitle:"你要长期达到的结果；转成待办后可提醒。",count:overviewGoals.count,collapsible:true) {
                    ActionCardList {
                        ForEach(overviewGoals.prefix(3)) { action in
                            actionRow(action,nature:.goal,nextStepCounts:nextStepCounts,reads:rowReads)
                        }
                    }
                    if overviewGoals.count > 3 {
                        Button("查看全部 \(overviewGoals.count)") { actionFilter = "目标" }
                            .buttonStyle(.workspaceQuietCompact).padding(.vertical,6)
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
                WorkspaceListSection(title:"完成后的结果",count:pendingOutcomes,badge:"\(pendingOutcomes) 项待填结果",collapsible:true) {
                    HStack(spacing:12) {
                        Button("记录结果…") { showingOutcome=true }.buttonStyle(.workspaceSecondary)
                        Button("显示已跳过") { model.showSkippedOutcomes() }.buttonStyle(.workspaceQuietCompact)
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
                        Button("记录想法") { go(.capture) }.buttonStyle(.workspacePrimary)
                        if actionFilter != "问题" { Button("查看问题") { actionFilter="问题" }.buttonStyle(.workspaceSecondary) }
                        if actionFilter != "目标" { Button("查看目标") { actionFilter="目标" }.buttonStyle(.workspaceSecondary) }
                    }
                }
            }
            if actionFilter == "待核对" { processingIssues }
            HStack { Button("同步提醒事项") { Task { await model.refreshTaskReminders() } }.buttonStyle(.workspaceSecondary).disabled(model.reminderAccess?.enabled != true || model.remindersBusy);Spacer();Text(model.reminderSyncStatus).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText).lineLimit(2) }
        }
        .help("↑↓ 选择 · ↵ 打开 · x 完成 · z 不再跟进 · ⌥⌘Z 撤销上一次变更")
        .task(id: focusRefreshKey) { focusedActionIDs = await model.focusedActionIDs() }
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
    private var focusRefreshKey: String { model.sourcePageIndex.actionRevisionKey }
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
    /// 「全部」reads like an agenda: overdue first, then today, the coming week,
    /// and the undated tail newest first. The time surface already orders the
    /// dated groups; only the undated tail needs its own order.
    private func todoOrder(_ actions: [ActionRecord], surface: ActionTimeSurface?) -> [ActionRecord] {
        guard let surface else { return actions }
        let anytime: [ActionRecord] = surface.anytime.map(\.action).sorted { (left: ActionRecord, right: ActionRecord) -> Bool in
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id > right.id
        }
        let due: [ActionRecord] = surface.today.map(\.action)
        let soon: [ActionRecord] = surface.soon.map(\.action)
        var ordered: [ActionRecord] = []
        ordered.reserveCapacity(due.count + soon.count + anytime.count)
        ordered.append(contentsOf: due)
        ordered.append(contentsOf: soon)
        ordered.append(contentsOf: anytime)
        return ordered
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
                let sources=distinctExpressions(model.records.filter { !$0.isTrashed })
                if !sources.isEmpty { sectionTitle("材料与原话 · \(sources.count)") }
                let catalog=recordCatalog
                ForEach(sources) { source in
                    let rowID="material:" + source.id
                    MaterialMenuRow(revealed: searchKeyboardFocus.id == rowID) {
                        MaterialManagementControls(model:model,source:source,style:.compact,
                            onSetReadingState:{ setMaterialReading(source.id,$0) },
                            onSplitExpression:{ splitMaterialExpression(model.sourcePageIndex.expression(for: source.id)?.sourceIDs ?? [source.id]) },
                            onRejudgeExpressions:{ rejudgeMaterialExpressions(source.presentation?.expression?.sourceIDs ?? [source.id]) })
                    } row: {
                        sourceRow(source,catalog:catalog,trailingGutter: WorkspaceRowChrome.materialGutter)
                    }
                        .background(searchKeyboardFocus.id == rowID ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                        .workspaceFocusRing(searchKeyboardFocus.id == rowID, radius: WorkspaceMetrics.panelRadius)
                        .id(rowID)
                    if source.id != sources.last?.id { WorkspaceListDivider() }
                }
            } else {
                searchResults
            }
        }
        .task(id: term) { await loadSearchHits(term) }
        .onChange(of:term) { _, _ in
            searchKeyboardFocus.id=nil;searchExpandedKinds=[]
            // A new query lists new rows; the old viewport would point into them.
            scrollPositions[scrollKey] = ScrollPosition(edge: .top)
        }
        .workspaceSlowLoading(searchBusy && searchHits.isEmpty, into: $showSlowSearch)
    }
    @ViewBuilder private var searchResults: some View {
        if showSlowSearch { ProgressView("正在检索…").controlSize(.small) }
        if searchFailed {
            let term=query.trimmingCharacters(in:.whitespacesAndNewlines)
            HStack(alignment:.top,spacing:10) {
                WorkspaceNoticeText(message:model.status,severity:.danger)
                Button("重试检索") { Task { await loadSearchHits(term) } }.controlSize(.small)
            }
        }
        let sections = searchSections
        if !sections.isEmpty {
            VStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
                ForEach(sections) { section in
                    let expand: (() -> Void)? = section.hasMore ? { expandSearchKind(section.kind) } : nil
                    WorkspaceSection(title:section.title,icon:section.icon,count:section.count,actionTitle:section.hasMore ? "显示全部" : "",action:expand) {
                        ForEach(section.rows) { row in
                            SearchResultRow(title:row.title,subtitle:row.subtitle,icon:row.icon) { row.open() }
                                .background(searchKeyboardFocus.id == row.id ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                                .workspaceFocusRing(searchKeyboardFocus.id == row.id, radius: WorkspaceMetrics.panelRadius)
                                .id(row.id)
                            if row.id != section.rows.last?.id { WorkspaceListDivider() }
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
            row("material:" + hit.refID,hit.title,hit.snippet,"doc.text") { go(.source(hit.refID)) }
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
        searchGeneration += 1
        let generation = searchGeneration
        guard !term.isEmpty else {
            searchHits=[];searchTotals=[:];searchFailed=false;searchBusy=false;searchKeyboardFocus.id=nil;searchExpandedKinds=[]
            lastSearchAnnouncement=""
            return
        }
        searchBusy=true
        defer { if generation == searchGeneration { searchBusy=false } }
        do { try await Task.sleep(for:.milliseconds(180)) } catch { return }
        guard generation == searchGeneration, !Task.isCancelled else { return }
        let results=await model.searchAll(term, perKindLimit: searchExpandedKinds.isEmpty ? 20 : 200)
        guard generation == searchGeneration, term == query.trimmingCharacters(in:.whitespacesAndNewlines) else { return }
        if let results {
            searchHits=cappedSearchHits(results.hits);searchTotals=results.totals;searchFailed=false
            let total = results.totals.values.reduce(0, +)
            let signature = term + "|" + String(total)
            if signature != lastSearchAnnouncement {
                lastSearchAnnouncement = signature
                AccessibilityNotification.Announcement("检索完成，\(total) 条").post()
            }
        } else {
            searchHits=[];searchTotals=[:];searchFailed=true
            if lastSearchAnnouncement != "failed|" + term {
                lastSearchAnnouncement = "failed|" + term
                AccessibilityNotification.Announcement("检索失败").post()
            }
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
        let materials = model.records.compactMap { source -> WorkspaceSearchSuggestion? in
            guard !source.isTrashed else { return nil }
            let title = displayTitle(source.displayTitle)
            guard prefixed(title) else { return nil }
            return WorkspaceSearchSuggestion(id:"suggestion:material:" + source.id,title:title,subtitle:"材料",icon:"doc.text") { go(.source(source.id)) }
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
                .background(searchKeyboardFocus.id == suggestion.id ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                .workspaceFocusRing(searchKeyboardFocus.id == suggestion.id, radius: WorkspaceMetrics.panelRadius)
                .id(suggestion.id)
                if index < suggestions.count - 1 { WorkspaceListDivider() }
            }
        }
        .background(palette.surface,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border,lineWidth:1) }
    }
    private func openClaimSource(_ claim: CandidateClaim) {
        guard let reference=claim.references.first else { return }
        let spanExists=model.sourcePageIndex.recordsByID[reference.sourceID]?.spans.contains(where: { $0.id == reference.spanID }) == true
        if spanExists { revealSourceSpan(reference.sourceID, spanID: reference.spanID) }
        go(.source(reference.sourceID))
    }
    /// 锚点跳转前先展开「原文与回听」，否则收起状态下面板内锚点不存在，页面会停在顶部。
    private func revealSourceSpan(_ sourceID: String, spanID: String) {
        sourceScrollPositions[sourceID] = ScrollPosition(id: "source-span-" + spanID)
        var state = sourceFoldStates[sourceID] ?? SourceFoldState.initial(transcript: nil)
        state.original = true
        sourceFoldStates[sourceID] = state
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
    private var reminderConnectionStatus: String {
        switch model.reminderPermission {
        case .notDetermined: "需要授权"
        case .denied: "系统已拒绝"
        case .granted: model.reminderAccess?.enabled == true ? model.reminderCalendarTitle : "未连接"
        }
    }
    private var reminderReviewCount: Int? {
        let anomalies = model.reminderSyncAnomalies
        let total = anomalies.total + anomalies.failureTotal
        return total > 0 ? total : nil
    }
    private var microphoneStatus: String {
        switch model.microphoneAuthorization {
        case .notDetermined: "尚未授权 · 口述与录音需要麦克风"
        case .denied: "已拒绝 · 录音前需要到系统设置允许"
        case .granted: "已允许 · 口述与录音可用"
        }
    }
    private var settings: some View {
        VStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            WorkspacePageHeading(title:"设置")
            VStack(alignment:.leading,spacing: WorkspaceMetrics.controlPadding) {
                sectionTitle("模型与服务")
                WorkspaceRow(title:"语音转文字",subtitle:model.speechSummary,icon:"waveform") { model.chooseLocalSpeech() }
                WorkspaceRow(title:"理解、核对与 AI 助理",subtitle:model.textModelConfigured ? model.modelSummary : "尚未配置文本模型",icon:"sparkles") { model.chooseTextModel() }
                    .help(model.modelConfigurationPath ?? "选择本地的 .env 或模型 JSON 配置文件；配置后这里显示文件名")
                    .contextMenu {
                        Button("更换配置…") { model.chooseTextModel() }
                        Button("清除配置", role: .destructive) { model.clearTextModel() }.disabled(!model.modelConfigured)
                    }
            }
            VStack(alignment:.leading,spacing: WorkspaceMetrics.controlPadding) {
                sectionTitle("隐私与云端")
                VStack(alignment: .leading, spacing: 8) {
                    Text("只在本机：录音与原件、资料库、模型密钥、QQ 密钥文件")
                        .vosFont(WorkspaceText.body)
                    Text("会发送给模型：转写与材料文本；监测原文仅在授权后；英文反馈仅所选文字；任务发起仅那段文字")
                        .vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                    DisclosureGroup("详细说明") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("录音、原件与资料库保存在本机，不上传。")
                            Text("模型密钥只在本机读取，不随材料发送；整个资料库不会发送。")
                            Text("QQ 密钥文件只保存路径；内容不复制、不进日志或模型。")
                            Text("转写与材料文本会发送给已配置的文本模型做理解、核对与整理。")
                            Text("监测原文默认不发送；开启「允许云端分析监测内容」后才发送所选来源的新增原文。")
                            Text("英文反馈只发送你选中的那段文字；任务发起只发送任务描述那段文字。")
                        }
                        .vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                        .padding(.top, 8)
                    }
                    .vosFont(WorkspaceText.meta)
                }
                .frame(maxWidth: 620, alignment: .leading)
            }
            VStack(alignment:.leading,spacing: WorkspaceMetrics.controlPadding) {
                sectionTitle("连接与自动入口")
                WorkspaceRow(title:"自动接收录音",subtitle:"VoiceOS 收件箱与语音备忘录",icon:"tray.and.arrow.down") { go(.tool("自动入口")) }
                WorkspaceRow(title:"消息监测",subtitle:"QQ 群与学院官网 · 检查时间、推送与依赖",icon:"antenna.radiowaves.left.and.right") { model.monitorSettingsRequested = true; go(.monitor) }
                WorkspaceRow(title:"Apple 提醒事项",subtitle:reminderConnectionStatus,icon:"checklist") { Task { await model.connectReminders() } }
                if !model.reminderLastError.isEmpty {
                    WorkspaceNoticeText(message:"最近一次提醒事项操作失败：" + model.reminderLastError,severity:.warning)
                }
                if model.remindersPermissionDenied { Button("打开系统设置") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!) }.buttonStyle(.workspaceSecondary) }
                if model.reminderAccess?.enabled == true { Button("暂停提醒事项连接") { Task { await model.disconnectReminders() } }.buttonStyle(.workspaceSecondary) }
                if let reminderReviewCount {
                    Button { go(.tool("处理情况")) } label: {
                        HStack(spacing:12) {
                            WorkspaceBadge(text:"\(reminderReviewCount) 条提醒待核对", tone:.warning)
                            Text("去核对")
                        }
                    }
                    .buttonStyle(.workspaceQuietCompact)
                    .accessibilityLabel("\(reminderReviewCount) 条提醒待核对，去核对")
                }
                VStack(alignment:.leading,spacing:6) {
                    Label("麦克风",systemImage:"mic").vosFont(WorkspaceText.rowTitle)
                    Text(microphoneStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
                .task { model.refreshMicrophoneAuthorization() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshMicrophoneAuthorization()
                }
                if model.microphoneAuthorization == .notDetermined {
                    Button("授权麦克风") { Task { _ = await model.requestMicrophoneAccess() } }.buttonStyle(.workspacePrimary)
                } else if model.microphoneAuthorization == .denied {
                    Button("打开系统设置") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }.buttonStyle(.workspaceSecondary)
                }
                WorkspaceRow(title:"系统通知",subtitle:model.noticeAuthorizationDetail,icon:"bell") { model.openNoticeSettings() }
                    .task { await model.refreshNoticeAuthorization() }
                if model.noticeAuthorization == .denied { Button("打开系统通知设置") { model.openNoticeSettings() }.buttonStyle(.workspaceSecondary) }
                Toggle("登录时启动", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).frame(maxWidth: 360, alignment: .leading)
                Text(model.launchAtLoginStatus).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            }
            VStack(alignment:.leading,spacing: WorkspaceMetrics.controlPadding) {
                sectionTitle("外观")
                HStack(spacing:12) {
                    ForEach(WorkspaceTheme.allCases) { option in
                        WorkspaceThemeOption(theme:option,selected:theme == option) { theme=option }
                    }
                }.frame(maxWidth:560)
                Picker("文字大小",selection:Binding(get:{ model.textSize },set:{ model.setTextSize($0) })) {
                    ForEach(AppTextSize.allCases) { option in Text(option.label).tag(option) }
                }.pickerStyle(.segmented).frame(maxWidth:360)
            }
            VStack(alignment:.leading,spacing: WorkspaceMetrics.controlPadding) {
                sectionTitle("键盘快捷键")
                VStack(alignment:.leading,spacing:8) {
                    Text("列表聚焦时：↑↓ 选择 · ↵ 打开 · x 完成 · z 不再跟进")
                    Text("任务详情：x 或空格 完成 · s 改期 · f 记结果")
                    Text("⌥⌘Z 撤销 · 仅本次运行")
                    Text("口述、剪贴板、速记、导入与页面切换在菜单栏的「记录」与「显示」菜单。")
                }.vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                if model.dictationHotKeyConflict {
                    Text("快捷键 ⌥⌘D 被其它应用占用；口述仍可从菜单栏开始。请在系统设置 › 键盘 › 键盘快捷键中查看冲突，或退出占用它的应用后重启 VoiceOS。")
                        .vosFont(WorkspaceText.caption).foregroundStyle(palette.warning)
                }
                Button("再看一次引导") { model.onboardingRequested = true }.buttonStyle(.workspaceSecondary)
            }
            VStack(alignment:.leading,spacing: WorkspaceMetrics.controlPadding) {
                sectionTitle("资料与历史")
                HStack(spacing:12) {
                    Button("导出结构化资料") { model.export(includeMedia:false) }.buttonStyle(.workspaceSecondary)
                    Button("导出资料与原件") { model.export(includeMedia:true) }.buttonStyle(.workspaceSecondary)
                    if model.exporting { ProgressView("正在导出…").controlSize(.small) }
                }.disabled(model.exporting)
                HStack(spacing:12) {
                    Text(model.backupStatusText.isEmpty ? "尚未生成备份" : model.backupStatusText).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    Button(model.backupRunning ? "正在备份…" : "重试备份") { model.retryBackup() }
                        .buttonStyle(.workspaceSecondaryCompact)
                        .disabled(model.backupRunning || model.libraryRoot == nil)
                    if model.backupRunning { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                    Button("在访达中显示") { model.revealBackups() }.buttonStyle(.workspaceQuietCompact)
                }
                HStack(spacing:12) {
                    Text("保留份数").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    Picker("保留份数", selection: $backupRetention) {
                        Text("3 份").tag(3); Text("7 份").tag(7); Text("14 份").tag(14)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    Button(model.backupPruning ? "正在清理…" : "立即清理旧备份") { model.cleanupOldBackups(retain: backupRetention) }
                        .buttonStyle(.workspaceSecondaryCompact).disabled(model.backupPruning || model.libraryRoot == nil)
                }.help("保留份数在下次备份或立即清理时生效。")
                if !model.backupCleanupStatus.isEmpty {
                    Text(model.backupCleanupStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
                HStack(spacing:12) {
                    Button(model.checkingLibraryHealth ? "正在检查资料库…" : "检查资料库") { model.checkLibraryHealth() }.buttonStyle(.workspaceSecondary).disabled(model.checkingLibraryHealth || model.libraryRoot == nil)
                    Button("从最近备份新建资料库") { showingBackupRestore = true }.buttonStyle(.workspaceSecondary).disabled(model.lastBackupAt == nil || model.libraryRoot == nil)
                }
                if !model.libraryHealthText.isEmpty {
                    Text(model.libraryHealthText).vosFont(WorkspaceText.meta)
                        .foregroundStyle(model.libraryHealthProblem ? palette.warning : palette.secondaryText)
                        .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                }
                HStack { Button("打开已有资料库") { chooseLibrary() }.buttonStyle(.workspaceSecondary);Button("从迁移包恢复") { go(.tool("恢复资料")) }.buttonStyle(.workspaceSecondary) }
            }
            VStack(alignment:.leading,spacing: WorkspaceMetrics.controlPadding) {
                sectionTitle("存储与清理")
                VStack(alignment:.leading,spacing:8) {
                    storageLine("资料库（含 WAL）", storageReadout { $0.databaseBytes })
                    storageLine("原件", storageReadout { $0.assetsBytes })
                    storageLine("备份", storageReadout { $0.backupBytes },
                                detail: model.storageUsage.flatMap { $0.backupBytes == nil ? nil : "\($0.backupCount) 份" })
                    storageLine("本地语音模型", storageReadout { $0.localSpeechBytes })
                    storageLine("镜像", storageReadout { $0.mirrorBytes })
                    WorkspaceListDivider().frame(maxWidth:420)
                    storageLine("合计", storageReadout { $0.totalBytes }, emphasized:true)
                }
                if model.storageScanBusy { ProgressView("正在统计存储…").controlSize(.small) }
                HStack(spacing:12) {
                    Button("在访达中显示资料库") { model.revealLibraryRoot() }.buttonStyle(.workspaceQuietCompact)
                    Button(model.localSpeechDeleting ? "正在删除…" : "删除本地语音模型") { confirmingLocalSpeechDelete = true }
                        .buttonStyle(.workspaceDestructive)
                        .disabled(model.localSpeechDeleting || model.speechModelBusy || (model.storageUsage?.localSpeechBytes ?? 0) == 0)
                        .help(model.speechModelBusy ? "转录或录音进行中，结束后再删除" : "删除 LocalSpeech 中的本地 Qwen 模型文件")
                }
                if !model.localSpeechDeleteStatus.isEmpty {
                    Text(model.localSpeechDeleteStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
            }
            VStack(alignment:.leading,spacing: WorkspaceMetrics.controlPadding) {
                sectionTitle("回顾与查找")
                WorkspaceRow(title:"静默回顾",subtitle:"看到相关原文",icon:"text.bubble") { go(.tool("静默回顾")) }
                WorkspaceRow(title:"查找历史文字",subtitle:"按关键词查找",icon:"text.magnifyingglass") { go(.tool("查找历史文字")) }
                WorkspaceRow(title:"英文表达反馈",subtitle:"英文原话反馈",icon:"character.book.closed") { go(.tool("英文表达反馈")) }
                DisclosureGroup("其他工作与维护") {
                    VStack(alignment:.leading,spacing: WorkspaceMetrics.rowGap) {
                        Button("思想关联、目标下一步与英语反馈") { go(.tool("思想与下一步")) }.buttonStyle(.workspaceQuietCompact)
                        Button("纠错后的行动影响") { go(.tool("纠错影响")) }.buttonStyle(.workspaceQuietCompact)
                        Button("表达处理与重试") { go(.tool("处理情况")) }.buttonStyle(.workspaceQuietCompact)
                        HStack(spacing:8) {
                            Button(model.organizingTopics ? "正在重新整理…" : "重新整理主题与简报") { model.queueTopicOrganization(retry:true) }
                                .buttonStyle(.workspaceQuietCompact)
                                .disabled(model.organizingTopics)
                            if model.organizingTopics { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                        }
                        Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.top,16)
                }
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
            Text("将删除 LocalSpeech 目录中的本地 Qwen 模型文件（当前 " + (model.storageUsage.map { $0.localSpeechBytes.map(sizeText) ?? "无法读取" } ?? "统计中") + "）。删除后本地 Qwen 语音停用，需要重新下载模型才能继续转写；已有录音、原件与逐字稿不受影响。")
        }
    }
    @ViewBuilder private var processingIssues: some View {
        let catalog=recordCatalog
        ForEach(model.assistantAssessmentIssues) { issue in
            VStack(alignment:.leading,spacing:8) {
                Text(issue.title);Text(issue.error).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                HStack(spacing:8) {
                    Button(model.assistantBusy ? "正在重新识别…" : "重新识别 AI 委托") { Task { await model.retryAssistantAssessment(issue) } }
                        .buttonStyle(.workspaceSecondaryCompact)
                        .disabled(model.assistantBusy)
                        .accessibilityLabel("重新识别 AI 委托：" + issue.title)
                    if model.assistantBusy { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                }
            }
        }
        ForEach(model.recordingFollowups.filter { $0.state == "failed" }) { receipt in
            let title=displayTitle(model.sourcePageIndex.recordsByID[receipt.sourceID]?.displayTitle ?? "资料跟进")
            VStack(alignment:.leading,spacing:8) {
                Text(title)
                HStack(spacing:8) {
                    Button(model.followupBusy ? "正在重试…" : "重试思想与下一步") { model.refreshFollowup(receipt.sourceID) }
                        .buttonStyle(.workspaceSecondaryCompact)
                        .disabled(model.followupBusy)
                        .accessibilityLabel("重试思想与下一步：" + title)
                    if model.followupBusy { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                }
            }
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
    private func sectionTitle(_ title:String) -> some View { WorkspaceSectionHeading(title) }
    private func sizeText(_ bytes:Int64) -> String { ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
    private enum StorageReadout {
        case scanning, unreadable, bytes(Int64)
    }
    private func storageReadout(_ field: (LibraryStorageUsage) -> Int64?) -> StorageReadout {
        guard let usage = model.storageUsage else { return .scanning }
        guard let bytes = field(usage) else { return .unreadable }
        return .bytes(bytes)
    }
    private func storageReadoutText(_ readout: StorageReadout) -> String {
        switch readout {
        case .scanning: return "" // The storage spinner row carries the scanning message.
        case .unreadable: return "无法读取"
        case .bytes(let bytes): return sizeText(bytes)
        }
    }
    private func storageLine(_ label:String,_ readout: StorageReadout,detail:String? = nil,emphasized:Bool = false) -> some View {
        HStack(spacing:8) {
            Text(label + (detail.map { " · " + $0 } ?? ""))
                .vosFont(emphasized ? WorkspaceText.rowTitle : WorkspaceText.body)
                .foregroundStyle(emphasized ? palette.text : palette.secondaryText)
            Spacer(minLength:12)
            Text(storageReadoutText(readout)).vosFont(WorkspaceText.meta, monospacedDigit: true).foregroundStyle(palette.secondaryText)
        }.frame(maxWidth:420,alignment:.leading)
    }
    private func sourceNavigationTitle(_ id:String) -> String {
        let pageIndex=model.sourcePageIndex
        let catalog=pageIndex.recordsByID
        guard let source=catalog[id] else { return "材料" }
        if let expression=pageIndex.expression(for:id),expression.sourceIDs.count > 1,
           let index=expression.sourceIDs.firstIndex(of:id) { return fittedDisplayTitle(expression.displayTitle(in:catalog))+" / 第 \(index+1) 段原文" }
        return fittedDisplayTitle(source.displayTitle)
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
        let localOnlyNote=source.localOnly ? " · 仅本地" : ""
        let metadata=origin + localOnlyNote + (groupNote.map { " · " + $0 } ?? "")
        let subtitle=first.recordingDateLabel + " · " + origin + localOnlyNote
        let openCount=model.sourcePageIndex.openActionCount(for:Set(expression?.sourceIDs ?? [source.id]))
        let trailingText=openCount > 0 ? "\(openCount) 条待办" + (issues > 0 ? " · 疑点 \(issues)" : "") : reading?.text ?? ""
        let trailingDisplay=trailingText
        let trailingStyle:WorkspaceRow.TrailingStyle = openCount > 0 ? .badge(.accent) : reading.map { WorkspaceRow.TrailingStyle.dot($0.color) } ?? .secondary
        return WorkspaceRow(title:fittedDisplayTitle(combined ? expression!.displayTitle(in:catalog) : source.displayTitle),subtitle:subtitle,icon:source.kind.contains("text") ? "doc.text" : "waveform",trailing:trailingDisplay,trailingStyle:trailingStyle,statusAccessibility:trailingText,trailingGutter:trailingGutter) { go(.source(source.id)) }
            .help(metadata)
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
    private func actionRowStatus(_ action:ActionRecord,timeEntry:ActionTimeEntry? = nil,group:ActionRowGroup,nature:ActionNature? = nil,nextStepCount:Int,reads:ActionRowReads) -> ActionRowStatus {
        var facts=ActionRowFacts()
        facts.isGoal=nature.map { $0 == .goal } ?? (action.kind != "task")
        facts.isQuestion=nature == .question
        facts.answerState=nature == .question ? (reads.latestAnalysisStateByActionID[action.id] ?? "") : ""
        facts.group=group
        facts.state=action.state
        facts.validity=action.validity
        if let entry=timeEntry,entry.source == .localSchedule,let date=entry.due {
            facts.due=ActionRowLayout.dueSummary(date,isOverdue:entry.isOverdue)
        }
        facts.sourceTitle=actionSourceTitle(action)
        facts.nextStepCount=nextStepCount
        facts.completedAt=group == .completed ? action.completedAt.map { "完成于 " + dateLabel($0) } ?? "" : ""
        facts.requiresReview=model.sourcePageIndex.requiresReview(action.id)
        facts.externalCompletion=model.workspaceExternalCompletionNote(action) != nil
        facts.withdrawn=action.intent?.followupState == "withdrawn"
        facts.localUnsynced=timeEntry?.needsLocalSyncLabel ?? false
        if action.state == "open", action.validity == "current" {
            facts.reminderLinkState=reads.reminderLinkStateByActionID[action.id]
            facts.reminderDue=reads.reminderDueByActionID[action.id]
        }
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
    private var stalledBanner: some View {
        let goals = model.stalledOutcomes
        return HStack(alignment: .center, spacing: 12) {
            WorkspaceNoticeText(message: "\(goals.count) 个目标还没有下一步", severity: .warning)
            if let first = goals.first {
                Button("打开第一条") { go(.task(first.id)) }
                    .buttonStyle(.workspaceQuietCompact)
                    .accessibilityLabel("打开第一个没有下一步的目标：" + first.title)
            }
        }
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
        let reminderException=layout.meta.contains("提醒待核对") || layout.meta.contains("提醒缺失") || layout.meta.contains("已逾期")
        let trailingStyle:WorkspaceRow.TrailingStyle=marksSelected ? .status(palette.accent) : (layout.status.isEmpty ? .secondary : .status(actionRowToneColor(layout.tone)))
        let icon:String=selectingActions ? (selectable ? (selected ? "checkmark.circle.fill" : "circle") : "circle") : action.state == "completed" ? "checkmark.circle" : action.state == "dismissed" ? "minus.circle" : nature == .question ? "questionmark.circle" : nature == .goal ? "target" : typeIcon(tagged.tag)
        let showsCompletion = !selectingActions && action.kind == "task" && action.state == "open" && action.validity == "current"
        return WorkspaceActionRowChrome(action:action,
            canTransition:actionable || externalCompletion,
            revealed:keyboardHighlighted,
            menuItems:{ actionMenuItems(action,focused:focused,canChangeDay:canChangeDay,canTransition:actionable) },
            row:{
                WorkspaceRow(title:tagged.text,subtitle:layout.meta,subtitleTone:reminderException ? palette.warning : nil,icon:icon,
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
    private func fail(_ message:String, retry:(()->Void)? = nil) {
        error = message
        errorRetry = retry.map { (message: message, action: $0) }
    }
    private func applyActionState(_ action:ActionRecord,to state:LocalActionState,nextHighlight:String? = nil) {
        Task {
            await model.changeAction(action,state:state)
            guard model.actionRecords.first(where: { $0.id == action.id })?.state == state.rawValue else {
                if state == .completed, model.canCompleteLocally(action) {
                    localCompletionOffer = action
                    error = ""
                } else {
                    fail(model.status.isEmpty ? "状态未能更新，请稍后重试。" : model.status,
                         retry: { applyActionState(action, to: state, nextHighlight: nextHighlight) })
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
                else { fail(model.status.isEmpty ? "未能撤销，请稍后重试。" : model.status, retry: { undoActionChange() }) }
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
                    Text("安排今天").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                    Text("从即将与随时里挑选，最多 3 条进入专注。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
                Spacer(minLength:8)
                Button("取消") { showingPlanToday=false }.buttonStyle(.workspaceSecondary)
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
                            if entry.id != candidates.last?.id { WorkspaceListDivider() }
                        }
                    }
                }.frame(minHeight:160,maxHeight:.infinity)
            }
            if planRemainingSlots == 0 { WorkspaceNoticeText(message:"专注已有 3 条，先移出一条再安排。",severity:.warning) }
            else if !planLimitHint.isEmpty { WorkspaceNoticeText(message:planLimitHint,severity:.warning) }
            HStack {
                Text("已选 \(planSelection.count) 条").vosFont(WorkspaceText.caption, monospacedDigit: true).foregroundStyle(.secondary)
                Spacer()
                Button(planningToday ? "正在安排…" : "加入专注") { Task { await confirmPlanToday() } }
                    .buttonStyle(.workspacePrimary)
                    .disabled(planSelection.isEmpty || planningToday)
            }
        }.padding(24).frame(minWidth:560,idealWidth:560,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .workspaceModalSurface()
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
    private func cycledFilter(_ current:String, over filters:[String], forward:Bool) -> String {
        guard !filters.isEmpty, let index=filters.firstIndex(of: current) else { return filters.first ?? current }
        return filters[(index + (forward ? 1 : -1) + filters.count) % filters.count]
    }
    private func handleActionListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .actions, actionListFocused, !selectingActions,
              press.modifiers.isDisjoint(with: [.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow,
           press.key != .leftArrow, press.key != .rightArrow { return .ignored }
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
        case .leftArrow, .rightArrow:
            let next=cycledFilter(actionFilter, over: SavedViewPage.actions.filters, forward: press.key == .rightArrow)
            guard next != actionFilter else { return .ignored }
            actionFilter=next
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
    /// Keyboard-driven scrollTo never writes back through the ScrollPosition
/// binding, so a list re-entered after navigation restores its viewport from
/// the kept keyboard selection instead of jumping to the top.
    private func restoreKeyboardScroll(proxy: ScrollViewProxy, id: String?) {
        guard let id else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(id, anchor: .center)
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
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow,
           press.key != .leftArrow, press.key != .rightArrow { return .ignored }
        let ids=readingMaterials.map(\.id)
        switch press.key {
        case .downArrow, .upArrow:
            guard materialKeyboardFocus.step(up: press.key == .upArrow, over: ids) else { return .ignored }
            return .handled
        case .leftArrow, .rightArrow:
            let next=cycledFilter(materialFilter, over: SavedViewPage.materials.filters, forward: press.key == .rightArrow)
            guard next != materialFilter else { return .ignored }
            materialFilter=next
            return .handled
        case .return:
            guard let id=materialKeyboardFocus.id, ids.contains(id) else { return .ignored }
            go(.source(id))
            return .handled
        default:
            return .ignored
        }
    }
    private func requestThemeListFocus() {
        Task {
            try? await Task.sleep(for:.milliseconds(100))
            guard page == .themes, topic == nil else { return }
            themeListFocused=true
        }
    }
    private func requestTopicMaterialListFocus() {
        Task {
            try? await Task.sleep(for:.milliseconds(100))
            guard page == .themes, topic != nil, topicTab == "材料" else { return }
            topicMaterialListFocused=true
        }
    }
    private func requestTopicReviewListFocus() {
        Task {
            try? await Task.sleep(for:.milliseconds(100))
            guard page == .themes, topic != nil, topicTab == "认识与问题", topicReadingMode == "回顾" else { return }
            topicReviewListFocused=true
        }
    }
    private func handleThemeListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .themes, topic == nil, themeListFocused,
              press.modifiers.isDisjoint(with:[.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let ids=visibleTopicListings.filter { $0.level == .theme }.map(\.id)
        switch press.key {
        case .downArrow, .upArrow:
            guard themeKeyboardFocus.step(up: press.key == .upArrow, over: ids) else { return .ignored }
            return .handled
        case .return:
            guard let id=themeKeyboardFocus.id, ids.contains(id) else { return .ignored }
            selectTopic(id)
            return .handled
        default:
            return .ignored
        }
    }
    private func handleClueListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .themes, topic == nil, clueListFocused,
              press.modifiers.isDisjoint(with:[.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let ids=visibleTopicListings.filter { $0.level == .clue }.map(\.id)
        switch press.key {
        case .downArrow, .upArrow:
            guard clueKeyboardFocus.step(up: press.key == .upArrow, over: ids) else { return .ignored }
            return .handled
        case .return:
            guard let id=clueKeyboardFocus.id, ids.contains(id) else { return .ignored }
            selectTopic(id)
            return .handled
        default:
            return .ignored
        }
    }
    private func handleUnlinkedListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .themes, topic == nil, unlinkedListFocused,
              press.modifiers.isDisjoint(with:[.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let ids=unlinkedTopicMaterials.map(\.id)
        switch press.key {
        case .downArrow, .upArrow:
            guard unlinkedKeyboardFocus.step(up: press.key == .upArrow, over: ids) else { return .ignored }
            return .handled
        case .return:
            guard let id=unlinkedKeyboardFocus.id, ids.contains(id) else { return .ignored }
            go(.source(id))
            return .handled
        default:
            return .ignored
        }
    }
    private func handleTopicMaterialListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .themes, topic != nil, topicTab == "材料", topicMaterialListFocused,
              press.modifiers.isDisjoint(with:[.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let ids=currentTopicReading.map { distinctExpressions($0.sources).map(\.id) } ?? []
        switch press.key {
        case .downArrow, .upArrow:
            guard topicMaterialKeyboardFocus.step(up: press.key == .upArrow, over: ids) else { return .ignored }
            return .handled
        case .return:
            guard let id=topicMaterialKeyboardFocus.id, ids.contains(id) else { return .ignored }
            go(.source(id))
            return .handled
        default:
            return .ignored
        }
    }
    private func handleTopicReviewListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .themes, topic != nil, topicTab == "认识与问题", topicReadingMode == "回顾", topicReviewListFocused,
              press.modifiers.isDisjoint(with:[.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let ids=currentTopicReading.map { distinctExpressions(reviewSources(for: $0)).map(\.id) } ?? []
        switch press.key {
        case .downArrow, .upArrow:
            guard topicReviewKeyboardFocus.step(up: press.key == .upArrow, over: ids) else { return .ignored }
            return .handled
        case .return:
            guard let id=topicReviewKeyboardFocus.id, ids.contains(id) else { return .ignored }
            go(.source(id))
            return .handled
        default:
            return .ignored
        }
    }
    /// The rows arrow keys walk: suggestions above the results, and the
    /// material list while the query is empty.
    private var searchKeyboardRows: [(id:String, open:()->Void)] {
        let term=query.trimmingCharacters(in:.whitespacesAndNewlines)
        if term.isEmpty {
            return distinctExpressions(model.records.filter { !$0.isTrashed }).map { source in
                (id: "material:" + source.id, open: { go(.source(source.id)) })
            }
        }
        var rows:[(id:String, open:()->Void)] = []
        if term.count >= 2 {
            rows = searchSuggestions.map { suggestion in
                (id: suggestion.id, open: { rememberSearch(term); suggestion.open() })
            }
        }
        rows.append(contentsOf: searchSections.flatMap(\.rows).map { row in (id: row.id, open: { row.open() }) })
        return rows
    }
    private func handleSearchListKey(_ press:KeyPress) -> KeyPress.Result {
        guard page == .search, searchListFocused,
              press.modifiers.isDisjoint(with: [.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let rows=searchKeyboardRows
        switch press.key {
        case .downArrow, .upArrow:
            guard searchKeyboardFocus.step(up: press.key == .upArrow, over: rows.map { $0.id }) else { return .ignored }
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
        let rows=searchKeyboardRows
        if let row=rows.first(where: { $0.id == searchKeyboardFocus.id }) { row.open(); return }
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
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
        let ids=searchKeyboardRows.map { $0.id }
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
    private func applyActionBatch(_ state:LocalActionState, records:[ActionRecord]? = nil) async {
        guard !batchRunning else { return }
        batchRunning=true
        defer { batchRunning=false }
        let targets = records ?? batchActions(for: state)
        var failures=0
        for record in targets {
            await model.changeAction(record,state:state)
            if model.actionRecords.first(where: { $0.id == record.id })?.state != state.rawValue { failures += 1 }
        }
        if records == nil { exitActionSelection() }
        if failures == 0 { error="";errorRetry=nil;return }
        let failed = targets.filter { record in
            model.actionRecords.first(where: { $0.id == record.id })?.state != state.rawValue
        }
        fail("有 \(failures) 条行动未能更新，请稍后重试。", retry: { Task { await applyActionBatch(state, records: failed) } })
    }
    private var actionSelectionBar: some View {
        HStack(spacing:12) {
            Text(batchRunning ? "正在更新…" : "已选 \(selectedActionIDs.count) 条").vosFont(WorkspaceText.meta.size, weight: .medium, monospacedDigit: true)
            Button("标为完成") { pendingBatchState = .completed }.buttonStyle(.workspacePrimary).disabled(batchRunning || batchActions(for: .completed).isEmpty)
            Button("不再跟进") { pendingBatchState = .dismissed }.buttonStyle(.workspaceSecondary).disabled(batchRunning || batchActions(for: .dismissed).isEmpty)
            Button("取消") { exitActionSelection() }.buttonStyle(.workspaceQuiet).disabled(batchRunning)
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
            Text("本地完成待同步").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            Text("这些变更只保存在 VoiceOS；恢复提醒事项连接并授权后自动写入并回读。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
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
                    if entry.id != model.pendingReminderSyncList.last?.id { WorkspaceListDivider() }
                }
            }
            if !model.status.isEmpty { Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
            HStack {
                Button("关闭") { showingPendingReminderSyncs=false }.buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button("现在核对") { Task { await model.retryPendingReminderSyncs() } }
                    .buttonStyle(.workspacePrimary)
                    .disabled(model.remindersBusy || model.pendingReminderSyncs.isEmpty)
            }
        }.padding(24).frame(minWidth:520)
            .workspaceModalSurface()
    }
    private func thoughtRow(_ claim:CandidateClaim) -> some View { WorkspaceRow(title:claim.statement,subtitle:claim.ownership == "ai_candidate" ? "AI 分析 · 不代表我的观点" : claim.ownership == "external" ? "外部观点" : "从我的表达中整理",icon:"lightbulb") { if let id=claim.references.first?.sourceID { go(.source(id)) } } }
    private func dateLabel(_ text:String) -> String { ConversationReflectionFocus.date(text)?.formatted(date:.abbreviated,time:.omitted) ?? text }
    private var navigationEntry: WorkspaceNavigationEntry { .init(page:page,topicID:topicID,topicTab:topicTab,topicReadingMode:topicReadingMode) }
    private func go(_ next:WorkspacePage) {
        if page != next { path.append(navigationEntry);page=next }
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
                        WorkspaceListRow(density:.compact,title:fittedDisplayTitle(source.displayTitle),subtitle:source.recordingDateLabel,icon:source.kind.contains("text") ? "doc.text" : "waveform",highlighted:source.id == selectedID) { selectSource(source.id) }
                            .help(fittedDisplayTitle(source.displayTitle))
                            .accessibilityIdentifier("sourceRail.item." + source.id)
                    }
                }.padding(.horizontal,8).padding(.bottom,12)
            }
        }.frame(width: 248 * vosLayoutScale(textScale)).background(palette.sidebar)
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
    private var mergeTopicSheetPresented: Binding<Bool> {
        Binding(get: { mergingTopicID != nil }, set: { if !$0 { mergingTopicID=nil;mergeTargetID="" } })
    }
    private func beginMergingTopic(_ topic: ReflectionQuestion) {
        mergeTargetID = ""
        mergingTopicID = topic.id
    }
    private func promoteTopic(_ topic: ReflectionQuestion) async {
        do {
            try await model.promoteTopic(topic.id)
            error = ""
            toastMessage = "已升为主题「\(topic.title)」"
        } catch { fail(error.localizedDescription) }
    }
    private func mergeTopic(_ source: ReflectionQuestion, into target: ReflectionQuestion) async {
        guard !mergingTopic else { return }
        mergingTopic = true
        defer { mergingTopic = false }
        do {
            try await model.mergeTopic(source.id, into: target.id)
            mergingTopicID = nil; mergeTargetID = ""
            topicID = nil; topicFocus = nil
            error = ""
            toastMessage = "已把「\(source.title)」并入「\(target.title)」"
        } catch {
            mergingTopicID = nil; mergeTargetID = ""
            fail(error.localizedDescription)
        }
    }
    private var mergeTopicSheet: some View {
        let source = mergingTopicID.flatMap { id in model.workspaceTopics.first { $0.id == id } }
        let catalog = recordCatalog
        var options: [TopicMergeOption] = []
        for candidate in model.workspaceTopics where candidate.id != source?.id {
            options.append(TopicMergeOption(topic: candidate, materialCount: topicListing(candidate, catalog: catalog).materialCount))
        }
        options.sort { left, right in
            if left.materialCount == right.materialCount {
                return left.topic.title.localizedStandardCompare(right.topic.title) == .orderedAscending
            }
            return left.materialCount > right.materialCount
        }
        let selected = options.first { $0.topic.id == mergeTargetID }?.topic
        return VStack(alignment:.leading,spacing:16) {
            if let source {
                Text("合并主题").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                if options.isEmpty { Text("还没有其他主题可合并。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText) }
                ForEach(options) { option in
                    Button { mergeTargetID = option.topic.id } label: {
                        HStack(spacing:10) {
                            VStack(alignment:.leading,spacing:2) {
                                Text(option.topic.title).vosFont(WorkspaceText.body).foregroundStyle(palette.text)
                                Text("\(option.materialCount) 份材料").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            }
                            Spacer(minLength:8)
                            if mergeTargetID == option.topic.id { Image(systemName:"checkmark.circle.fill").foregroundStyle(palette.accent) }
                        }.contentShape(Rectangle()).padding(10)
                            .background(mergeTargetID == option.topic.id ? palette.selection : Color.clear, in: RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain)
                }
                if let selected {
                    Text("会把「\(source.title)」的材料并入「\(selected.title)」并删除「\(source.title)」。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
                HStack {
                    Button("取消") { mergingTopicID=nil;mergeTargetID="" }.buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("确认合并") { if let selected { Task { await mergeTopic(source, into: selected) } } }
                        .buttonStyle(.workspacePrimary).disabled(selected == nil || mergingTopic)
                }
            }
        }.padding(24).frame(width:460)
            .workspaceModalSurface()
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
        } else { fail("视图未能保存，请稍后重试。", retry: { Task { await saveView() } }) }
    }
    private func deleteSavedView(_ view:SavedWorkspaceView) {
        Task {
            if let views=await model.deleteWorkspaceView(id:view.id) { savedViews=views;error="";toastMessage="已删除视图「\(view.name)」" }
            else { fail("视图未能删除，请稍后重试。", retry: { deleteSavedView(view) }) }
        }
    }
    private func openSavedView(_ view:SavedWorkspaceView) {
        path=[]
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
            if host == "action" {
                do {
                    if let command = try ExternalActionCommand.parse(url) {
                        switch command {
                        case let .feedback(actionID, text, kind, commandID):
                            submitExternalFeedback(actionID: actionID, text: text, kind: kind, commandID: commandID)
                        case let .complete(actionID):
                            completeExternalAction(actionID)
                        }
                        return
                    }
                } catch let failure { error = failure.localizedDescription; return }
            }
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
    private func submitExternalFeedback(actionID:String,text:String,kind:ActionFeedbackKind,commandID:String) {
        guard let action=model.actionRecords.first(where: { $0.id == actionID }) else {
            error="这条行动已不在当前资料库，反馈未写入"; return
        }
        Task {
            if await model.saveFeedback(action,kind:kind,text:text,commandID:commandID) {
                error="";toastMessage="结果已关联到「\(action.title)」"
            } else {
                error=model.status.isEmpty ? "反馈未能写入，请稍后重试。" : model.status
            }
        }
    }
    private func completeExternalAction(_ actionID:String) {
        guard let action=model.actionRecords.first(where: { $0.id == actionID }) else {
            error="这条行动已不在当前资料库，完成未写入"; return
        }
        guard action.kind == "task", action.state == "open", action.validity == "current" else {
            error="这条行动当前不能标记完成"; return
        }
        applyActionState(action,to:.completed)
    }
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
                TextEditor(text:$text).frame(minHeight:100).workspaceEditorSurface()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let term: String
    let open: () -> Void
    let remove: () -> Void
    @State private var hovered = false
    @FocusState private var removeFocused: Bool
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
                    .frame(width:WorkspaceMetrics.rowActionMinHeight,height:WorkspaceMetrics.rowActionMinHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .focused($removeFocused)
                .help("删除这条最近搜索").accessibilityLabel("删除最近搜索：" + term)
                .opacity(hovered || removeFocused ? 1 : 0).allowsHitTesting(hovered || removeFocused)
        }
        .padding(.horizontal,10).frame(height:WorkspaceMetrics.fieldHeight)
        .background(palette.surface,in:Capsule())
        .overlay { Capsule().strokeBorder(palette.border,lineWidth:1) }
        .onHover { hovered=$0 }
        .contextMenu { Button("删除这条最近搜索",role:.destructive,action:remove) }
        .animation(reduceMotion ? nil : WorkspaceMotion.hover,value:hovered || removeFocused)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
    }
}

private struct MaterialCard: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let highlighted: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius)
        content
            .background(highlighted ? palette.selection : palette.surface,in:shape)
            .overlay { shape.strokeBorder(highlighted ? palette.focusRing : palette.border,lineWidth:1) }
    }
}

private extension View {
    func materialCard(highlighted: Bool) -> some View { modifier(MaterialCard(highlighted: highlighted)) }
}

private struct WorkspaceSelectionHighlight: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let highlighted: Bool
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(highlighted ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: radius))
            .workspaceFocusRing(highlighted, radius: radius)
            .animation(reduceMotion ? nil : WorkspaceMotion.selection, value: highlighted)
    }
}

private extension View {
    func workspaceSelectionHighlight(_ highlighted: Bool, radius: CGFloat = WorkspaceMetrics.panelRadius) -> some View {
        modifier(WorkspaceSelectionHighlight(highlighted: highlighted, radius: radius))
    }
}

/// A material row's compact menu stays hidden until hover or keyboard reveal.
/// A failed operation keeps it visible so the failure note and retry never
/// disappear with the pointer.
private struct MaterialMenuRow<Row: View, MenuContent: View>: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var revealed: Bool = false
    @ViewBuilder let menu: () -> MenuContent
    @ViewBuilder let row: () -> Row
    @State private var hovered = false
    @State private var menuContentNeedsAttention = false

    private var menuVisible: Bool { hovered || revealed || menuContentNeedsAttention }

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
            .onPreferenceChange(MaterialRowFailurePreferenceKey.self) { menuContentNeedsAttention = $0 }
            .onHover { hovered=$0 }
            .animation(reduceMotion ? nil : WorkspaceMotion.hover,value:menuVisible)
    }
}

struct MaterialRowFailurePreferenceKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .animation(reduceMotion ? nil : WorkspaceMotion.hover,value:menuVisible)
    }
}

private struct WorkspaceFilterTabItem: Identifiable {
    let filter: String
    let title: String
    var count: String? = nil
    var help: String = ""
    var id: String { filter }
    var label: String { count.map { title + " " + $0 } ?? title }
}

/// One underline per selected filter: ink for the active label, accent for the rule.
/// The identifier keeps the old combined label so saved UI checks still resolve.
private struct WorkspaceFilterTabs: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [WorkspaceFilterTabItem]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                ForEach(items) { item in tab(item) }
            }.fixedSize(horizontal: true, vertical: false)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56 * vosLayoutScale(textScale)), spacing: 14)], alignment: .leading, spacing: 10) {
                ForEach(items) { item in tab(item, fill: true) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tab(_ item: WorkspaceFilterTabItem, fill: Bool = false) -> some View {
        let selected = selection == item.filter
        return Button { onSelect(item.filter) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .vosFont(WorkspaceText.meta.size, weight: selected ? .semibold : .regular)
                        .foregroundStyle(selected ? palette.text : palette.secondaryText)
                        .lineLimit(1)
                    if let count = item.count {
                        Text(count).vosFont(WorkspaceText.meta.size, monospacedDigit: true)
                            .foregroundStyle(palette.tertiaryText).lineLimit(1)
                    }
                }
                Rectangle().fill(selected ? palette.accent : Color.clear).frame(height: 2)
            }
            .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .help(item.help)
            .accessibilityIdentifier("workspace.tab." + item.label)
            .animation(reduceMotion ? nil : WorkspaceMotion.selection, value: selection)
    }
}
