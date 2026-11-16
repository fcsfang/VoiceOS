import SwiftUI
import AppKit
import AVKit
import VoiceOSCore

// One navigation state owns the workspace. Discussion is a sibling, so expanding
// it never replaces the reading view or its disclosure/scroll state.
enum WorkspacePage: Hashable {
    case home, themes, materials, actions, initiate, source(String), delivery(String), task(String), settings, capture, search, tool(String)
    var isTopLevel: Bool {
        switch self {
        case .home, .themes, .materials, .actions, .initiate, .settings: true
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
private struct ActionRowDetail {
    var meta = ""
    var status = ""
    var statusColor: Color?
}
// Mirrors the guard in ActionStore.promoteAction so the row menu and detail page share one rule.
extension ActionRecord {
    var canPromoteToTask: Bool { kind == "opportunity" && state == "open" && validity == "current" }
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
struct WorkspaceRow: View {
    enum TrailingStyle {
        case secondary
        case status(Color)
        case link
    }
    @Environment(\.workspacePalette) private var palette
    @State private var hovered = false
    let title: String
    let subtitle: String
    var icon: String = "doc.text"
    var trailing: String = ""
    var trailingStyle: TrailingStyle = .secondary
    let open: () -> Void
    var body: some View {
        Button(action:open) {
            HStack(alignment:.top,spacing:14) {
                Image(systemName:icon).vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                    .frame(width:30,height:30).background(palette.selection.opacity(0.6),in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    .accessibilityHidden(true)
                VStack(alignment:.leading,spacing:3) {
                    Text(title).vosFont(WorkspaceText.rowTitle).lineSpacing(3).lineLimit(3).fixedSize(horizontal:false,vertical:true).help(title)
                    if !subtitle.isEmpty { Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3).lineLimit(2).fixedSize(horizontal:false,vertical:true).help(subtitle) }
                }
                Spacer(minLength:8)
                if !trailing.isEmpty { trailingLabel.padding(.top,3) }
            }.padding(.vertical,10).padding(.horizontal,10).contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                .background(hovered ? palette.selection.opacity(0.5) : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                .accessibilityElement(children:.combine)
        }.buttonStyle(.plain).onHover { hovered=$0 }
            .accessibilityLabel(subtitle.isEmpty ? title : title + " · " + subtitle)
    }
    @ViewBuilder private var trailingLabel: some View {
        switch trailingStyle {
        case .secondary:
            Text(trailing).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
        case .status(let color):
            Text(trailing).vosFont(WorkspaceText.meta).foregroundStyle(color)
        case .link:
            HStack(spacing:3) {
                Text(trailing).vosFont(WorkspaceText.meta)
                Image(systemName:"chevron.right").vosFont(WorkspaceText.caption.size, weight: .semibold)
            }.foregroundStyle(palette.accent)
        }
    }
}
struct WorkspaceView: View {
    @ObservedObject var model: ControlCenter
    @AppStorage("voiceos.workspaceTheme") private var theme = WorkspaceTheme.graphite
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
    @State private var searchFailed = false
    @State private var searchBusy = false
    @State private var searchHovered = false
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
    @State private var toastMessage: String?
    @State private var showingWeeklyReview = false
    @Environment(\.openWindow) private var openWindow
    private var discussionIsPresented: Bool {
        showingDiscussion && discussionDraftSessionID != nil && discussionDraftSessionID == model.discussionSession?.id
    }
    private var topic: ReflectionQuestion? { model.workspaceTopics.first { $0.id == topicID } }
    private var sourceIDs: Set<String> { Set(topicID.flatMap { model.workspaceTopicSources[$0] } ?? []) }
    private var topicSources: [SourceRecord] { model.records.filter { sourceIDs.contains($0.id) } }
    private var topicClaims: [CandidateClaim] {
        let ids=Set(topic?.organization?.sections?.flatMap(\.claimIDs) ?? [])
        return model.claims.filter { ids.contains($0.id) && $0.validity == "current" && $0.reviewState != "rejected" }
    }
    private var topicActions: [ActionRecord] {
        let ids=Set(topic?.organization?.sections?.flatMap(\.actionIDs) ?? [])
        return model.actionRecords.filter { ids.contains($0.id) && $0.validity == "current" && $0.state != "dismissed" }
    }
    private var deliveries: [AssistantExecutionRecord] { model.assistantExecutions.filter { $0.validity == "current" && $0.state == "completed" }.sorted { $0.updatedAt > $1.updatedAt } }
    private var activeMaterials: [SourceRecord] { model.records.filter { !$0.isArchived && !$0.isTrashed } }
    private var section: String {
        switch page {
        case .themes: "主题"
        case .materials: "材料"
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
            .environment(\.workspacePalette, palette)
            .environment(\.vosTextScale, model.textSize.scale)
            .dynamicTypeSize(model.textSize.dynamicType)
            .frame(minWidth:980,minHeight:700)
            .onExitCommand {
                if selectingActions { exitActionSelection() }
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
            WorkspaceProcessingBar(model: model, inbox: model.recordingInbox) { go(.tool("处理情况")) }
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
                nav("首页",icon:"house",target:.home).keyboardShortcut("1",modifiers:.command)
                nav("主题",icon:"circle.hexagongrid",target:.themes).keyboardShortcut("2",modifiers:.command)
                nav("材料",icon:"books.vertical",target:.materials).keyboardShortcut("3",modifiers:.command)
                nav("行动",icon:"checkmark.circle",target:.actions).keyboardShortcut("4",modifiers:.command)
                nav("启动",icon:"arrow.up.forward",target:.initiate).keyboardShortcut("5",modifiers:.command)
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
                Button { go(.settings);showingDiscussion=false } label: { Label("设置",systemImage:"slider.horizontal.3").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }.padding(.horizontal,8)
        }.padding(.horizontal,13).padding(.vertical,28).frame(width:172).background(palette.sidebar)
            .onAppear { AppBrand.applyApplicationIcon() }
            .onChange(of: colorScheme) { _, _ in AppBrand.applyApplicationIcon() }
    }
    private func nav(_ title:String,icon:String,target:WorkspacePage) -> some View {
        Button { path=[];page=target;if target == .themes { topicID=nil;topicFocus=nil };error="" } label: {
            Label(title,systemImage:icon).vosFont(WorkspaceText.body.size, weight: section == title ? .semibold : .regular)
                .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,11)
                .background(section == title ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                // Plain buttons otherwise only hit-test the icon and text, leaving the padded row inert.
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("workspace.nav."+title)
    }
    private var header: some View {
        HStack(spacing:12) {
            if !path.isEmpty {
                Button(action:back) {
                    Image(systemName:"chevron.left").vosFont(WorkspaceText.body.size, weight: .medium)
                        .frame(width:44,height:44)
                        .background(palette.selection.opacity(0.5),in:RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("返回").help("返回上一页").keyboardShortcut("[",modifiers:.command)
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
                .accessibilityLabel("搜索").help("搜索全部内容（⌘F）").keyboardShortcut("f",modifiers:.command)
            WorkspaceIconButton(systemImage:"sidebar.right",label:"讨论") { Task { await toggleDiscussion() } }
                .disabled(model.discussionSaving || model.discussionSending)
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
                            panoramaSourceEditor = model.records.first { $0.id == id }
                        }, correctClaim: { id in
                            panoramaClaimEditor = model.claims.first { $0.id == id }
                        }, discuss: { snapshot, selection in
                            Task { await openPanoramaDiscussion(snapshotID: snapshot, selection: selection) }
                        }, themeReply: { briefing in
                            try await model.themeReply(briefing)
                        })
                } else {
                    RecentContentHome(model: model, openSource: { go(.source($0)) }, openTask: { go(.task($0)) }, capture: { go(.capture) })
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
            if let source=model.records.first(where: { $0.id == id }) {
                if source.isTrashed { TrashedMaterialView(model:model,source:source) }
                else {
                    WorkspaceSourceView(model:model,source:source,openTask:{ go(.task($0)) },openDelivery:{ go(.delivery($0)) },openDiscussion:{ id in Task { await openSavedDiscussion(id) } },openSource:{ go(.source($0)) },openInitiation:{ id in
                        model.initiationSourceID = id
                        model.initiationText = model.records.first(where: { $0.id == id })?.transcript ?? ""
                        go(.initiate)
                    },openFollowups:{ go(.tool("思想与下一步")) },scroll:sourceScrollBinding(id))
                        .id(id)
                }
            } else { unavailable("这份材料暂时不可用",description:"可以搜索其他材料，或回到主题。") }
        case .delivery(let id):
            if let execution=model.assistantExecutions.first(where: { $0.id == id }) {
                WorkspaceDeliveryView(model:model,execution:execution,openTask:{ go(.task($0)) },openTopic:{ selectTopic($0) },discuss:{ Task { await toggleDiscussion(force:true) } })
            } else { unavailable("交付暂时不可用",description:"可以回到行动查看当前结果。") }
        case .task(let id):
            if let action=model.actionRecords.first(where: { $0.id == id }) {
                WorkspaceTaskView(model:model,action:action,draft:Binding(
                    get: { taskFeedbackDrafts[id] ?? TaskFeedbackDraft() },
                    set: { taskFeedbackDrafts[id] = $0 }
                ),openSource:{ go(.source($0)) },openDelivery:{ go(.delivery($0)) },discuss:{ Task { await toggleDiscussion(force:true) } })
                    .id(id)
            } else { unavailable("任务暂时不可用",description:"可以回到行动查看当前事项。") }
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
        let catalog=Dictionary(uniqueKeysWithValues:model.records.map { ($0.id,$0) })
        let attachedContextIDs=Set(sources.compactMap { contextSourceID($0,catalog:catalog) })
        var seen=Set<String>()
        return sources.filter { source in
            // Keep a context recording independently reachable when its personal
            // recording is outside this list, rather than hiding it globally.
            guard !attachedContextIDs.contains(source.id) else { return false }
            guard let expression=source.recordingExpression(in:catalog),expression.sourceIDs.count > 1 else { return true }
            return seen.insert(expression.id).inserted
        }
    }
    private var readingMaterials: [SourceRecord] {
        let catalog=Dictionary(uniqueKeysWithValues:model.records.map { ($0.id,$0) })
        let selected=model.records.filter { source in
            switch materialFilter {
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
            guard let expression=source.recordingExpression(in:catalog),expression.sourceIDs.count > 1, Set(expression.sourceIDs).isSubset(of:selectedIDs) else { return (source,source.createdAt) }
            guard expression.sourceIDs.first == source.id else { return nil }
            return (source,expression.sourceIDs.compactMap { catalog[$0]?.createdAt }.max() ?? source.createdAt)
        }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
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
        let rows = readingMaterials
        let catalog = recordCatalog
        return LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            HStack(alignment:.top,spacing:12) {
                WorkspaceHeading(eyebrow:"",title:"材料")
                Text("\(rows.count) 份").vosFont(WorkspaceText.caption.size, monospacedDigit: true)
                    .foregroundStyle(palette.tertiaryText)
                    .padding(.top,10)
                    .accessibilityLabel("\(rows.count) 份材料")
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
            WorkspaceTabs(selection:$materialFilter,titles:SavedViewPage.materials.filters,style:.filters)
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
                        VStack(alignment:.leading,spacing:0) {
                            WorkspaceListGroupHeader(title:group.label)
                            ForEach(group.sources) { source in
                                MaterialMenuRow {
                                    MaterialManagementControls(model:model,source:source,style:.compact)
                                } row: {
                                    sourceRow(source,catalog:catalog,highlighted:materialKeyboardFocus.id == source.id).frame(maxWidth:.infinity,alignment:.leading)
                                }.id(source.id)
                                if source.id != group.sources.last?.id { WorkspaceListDivider() }
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
                    DisclosureGroup("尚未归入主题的材料（\(unlinked.count)）") { ForEach(distinctExpressions(unlinked)) { sourceRow($0,catalog:catalog) } }
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
            openSource:{ go(.source($0)) },openTask:{ go(.task($0)) },openDelivery:{ go(.delivery($0)) },
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
    private var actions: some View {
        LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            HStack(alignment:.top,spacing:12) {
                WorkspaceHeading(eyebrow:"",title:"行动")
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
                    if ["全部","我的待办"].contains(actionFilter) {
                        Button(selectingActions ? "取消选择" : "选择") { if selectingActions { exitActionSelection() } else { selectingActions=true } }.disabled(batchRunning)
                    }
                    Button("保存当前视图",systemImage:"bookmark") { beginSavingView(.actions,filter:actionFilter) }
                    Button("每周回顾",systemImage:"calendar.badge.clock") { showingWeeklyReview=true }
                }
            }
            WorkspaceTabs(selection:$actionFilter,titles:SavedViewPage.actions.filters,style:.filters)
            if actionFilter == "问题与目标", !model.stalledOutcomes.isEmpty { stalledBanner }
            let visible = visibleActions
            let executions = model.assistantExecutions.filter { $0.state != "cancelled" }
            let paused = model.workspacePausedTasks
            if ["全部","我的待办"].contains(actionFilter), !focusedActions.isEmpty {
                WorkspaceListSection(title:"专注",count:focusedActions.count) {
                    ForEach(focusedActions) { action in actionRow(action);if action.id != focusedActions.last?.id { WorkspaceListDivider() } }
                }
            }
            if actionFilter == "我的待办", !visible.isEmpty {
                let surface = ActionTimeSurface.build(actions: visible, schedules: model.scheduleIntents, links: model.reminderLinks, now: Date(), calendar: .current)
                let overdue = surface.today.filter(\.isOverdue)
                let dueToday = surface.today.filter { !$0.isOverdue }
                if !overdue.isEmpty {
                    WorkspaceListSection(title:"逾期",subtitle:"已过期限。改天需要提醒事项链接。",count:overdue.count) {
                        ForEach(overdue) { entry in actionRow(entry.action,timeEntry:entry);if entry.id != overdue.last?.id { WorkspaceListDivider() } }
                    }
                }
                if !dueToday.isEmpty {
                    WorkspaceListSection(title:"今天",subtitle:"今天到期",count:dueToday.count) {
                        ForEach(dueToday) { entry in actionRow(entry.action,timeEntry:entry);if entry.id != dueToday.last?.id { WorkspaceListDivider() } }
                    }
                }
                if !surface.soon.isEmpty {
                    WorkspaceListSection(title:"即将",subtitle:"7 天内",count:surface.soon.count) {
                        ForEach(surface.soon) { entry in actionRow(entry.action,timeEntry:entry);if entry.id != surface.soon.last?.id { WorkspaceListDivider() } }
                    }
                }
                if !surface.anytime.isEmpty {
                    WorkspaceListSection(title:"随时",subtitle:"没有日期或更远",count:surface.anytime.count) {
                        ForEach(surface.anytime) { entry in actionRow(entry.action,timeEntry:entry);if entry.id != surface.anytime.last?.id { WorkspaceListDivider() } }
                    }
                }
            } else if actionFilter == "AI 助理" {
                if !executions.isEmpty {
                    WorkspaceListSection(title:"AI 助理的工作",count:executions.count) { executionRows(executions) }
                }
            } else if !visible.isEmpty {
                WorkspaceListSection(title:actionFilter == "全部" ? "我的待办" : actionFilter,subtitle:actionFilter == "问题与目标" ? "要达到的结果、要弄清的未知；转成待办后可提醒。" : "",count:visible.count) {
                    ForEach(visible) { action in actionRow(action);if action.id != visible.last?.id { WorkspaceListDivider() } }
                }
            }
            if actionFilter == "全部", !paused.isEmpty {
                WorkspaceListSection(title:"需要核对的待办",subtitle:"打开任务查看原因。",count:paused.count) {
                    ForEach(paused) { action in actionRow(action);if action.id != paused.last?.id { WorkspaceListDivider() } }
                    if model.pausedActionBatch == nil { PausedActionBatchControl(model:model) }
                }
            }
            let overviewGoals = actionFilter == "全部"
                ? model.actionRecords.filter { $0.kind != "task" && $0.state != "dismissed" && $0.validity == "current" }
                : []
            if !overviewGoals.isEmpty {
                WorkspaceListSection(title:"问题与目标",subtitle:"要达到的结果、要弄清的未知；转成待办后可提醒。",count:overviewGoals.count) {
                    ForEach(overviewGoals.prefix(3)) { action in
                        actionRow(action)
                        if action.id != overviewGoals.prefix(3).last?.id { WorkspaceListDivider() }
                    }
                    if overviewGoals.count > 3 {
                        Button("查看全部 \(overviewGoals.count)") { actionFilter = "问题与目标" }
                            .buttonStyle(.plain).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent).padding(.vertical,10)
                    }
                }
            }
            if !model.visibleOutcomeFollowups.isEmpty {
                WorkspaceListSection(title:"完成后的结果",count:model.visibleOutcomeFollowups.count,collapsible:true) {
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
            if visible.isEmpty && (actionFilter == "AI 助理" || actionFilter == "全部" ? executions.isEmpty : true) && !(actionFilter == "全部" && (!paused.isEmpty || !overviewGoals.isEmpty)) {
                WorkspaceEmptyState(
                    title: actionFilter == "历史记录" ? "还没有历史任务记录" : actionFilter == "已完成" ? "还没有已完成的事项" : actionFilter == "AI 助理" ? "还没有 AI 代办" : actionFilter == "待核对" ? "没有待核对的行动" : actionFilter == "问题与目标" ? "还没有问题与目标" : "目前没有可执行的待办",
                    systemImage:"checkmark.circle",
                    description: actionFilter == "AI 助理" ? "在一项待办中选择“交给 AI”，编辑要求后开始执行。" : actionFilter == "待核对" ? "下方处理问题里的事项仍需要查看。" : actionFilter == "问题与目标" ? "这里是你要达到的结果和要弄清的未知；转成待办后可提醒。" : "已暂停的历史、问题与目标分别保留，可通过上方分类查看。"
                ) {
                    HStack { Button("记录想法") { go(.capture) };if actionFilter != "问题与目标" { Button("查看问题与目标") { actionFilter="问题与目标" } } }
                }
            }
            if actionFilter == "待核对" { processingIssues }
            if ["全部","我的待办"].contains(actionFilter), !visible.isEmpty {
                Text("↑↓ 选择 · ↵ 打开 · x 完成 · z 不再跟进 · ⌥⌘Z 撤销上一次变更").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            }
            HStack { Button("同步提醒事项") { Task { await model.refreshTaskReminders() } }.disabled(model.reminderAccess?.enabled != true || model.remindersBusy);Spacer();Text(model.reminderSyncStatus).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText).lineLimit(2) }
        }.task(id: focusRefreshKey) { focusedActionIDs = await model.focusedActionIDs() }
    }
    @ViewBuilder private func executionRows(_ executions: [AssistantExecutionRecord]) -> some View {
        ForEach(executions) { execution in
            WorkspaceRow(title:execution.title,subtitle:assistantExecutionLabel(execution),icon:execution.state == "completed" ? "doc.text" : "sparkles",trailing:execution.state == "completed" ? "阅读结果" : "查看进度",trailingStyle:.link) { go(.delivery(execution.id)) }
            if execution.id != executions.last?.id { WorkspaceListDivider() }
        }
    }
    private var focusedActions: [ActionRecord] {
        Array(model.actionRecords.filter { focusedActionIDs.contains($0.id) && $0.state == "open" && $0.validity == "current" }.prefix(3))
    }
    private var focusRefreshKey: String {
        model.actionRecords.map { $0.id + String($0.version) + $0.state + $0.validity }.joined(separator: "|")
    }
    private var visibleActions: [ActionRecord] {
        model.actionRecords.filter { action in
            switch actionFilter {
            case "已完成": return action.state == "completed"
            case "历史记录": return action.state == "dismissed" || (action.validity != "current" && !model.workspaceTaskRequiresReview(action))
            case "待核对": return model.workspaceTaskRequiresReview(action) || action.validity == "current" && (action.intent?.uncertain == true || action.intent?.followupState == "needs_review")
            case "问题与目标": return action.kind != "task" && action.state != "dismissed" && action.validity == "current"
            default: return action.kind == "task" && action.state == "open" && action.validity == "current" && !model.workspaceTaskRequiresReview(action)
            }
        }
    }
    private var search: some View {
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        return LazyVStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            WorkspaceHeading(eyebrow:"",title:"搜索")
            WorkspaceSearchField(text:$query,placeholder:"搜索标题、原话、理解或行动",focus:$searchFocused,submit:{ if !searchSections.isEmpty { searchListFocused=true } })
                .task {
                    // Wait until the lazy field is attached to its native window.
                    do { try await Task.sleep(for:.milliseconds(100)); searchFocused = true } catch {}
                }
            if term.isEmpty {
                let sources=model.records.filter { !$0.isTrashed }
                if !sources.isEmpty { sectionTitle("材料与原话 · \(sources.count)") }
                let catalog=recordCatalog
                ForEach(sources) { sourceRow($0,catalog:catalog);Divider() }
            } else {
                searchResults
            }
        }
        .task(id: term) { await loadSearchHits(term) }
        .onChange(of:term) { _, _ in searchKeyboardFocus.id=nil }
    }
    @ViewBuilder private var searchResults: some View {
        if searchBusy && searchHits.isEmpty { ProgressView("正在检索…").controlSize(.small) }
        if searchFailed { WorkspaceNoticeText(message:model.status,severity:.danger) }
        let sections = searchSections
        if !sections.isEmpty {
            VStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
                ForEach(sections) { section in
                    WorkspaceSection(title:section.title,icon:section.icon,count:section.rows.count) {
                        ForEach(section.rows) { row in
                            WorkspaceRow(title:row.title,subtitle:row.subtitle,icon:row.icon) { row.open() }
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
                Button("清空搜索") { query="";searchFocused=true }
            }
        }
    }
    private var searchSections: [WorkspaceSearchSection] {
        let catalog = recordCatalog
        let materials = searchHits.filter { hit in
            guard hit.kind == .material, let source = catalog[hit.refID] else { return false }
            return !source.isTrashed
        }.map { hit in
            WorkspaceSearchRow(id:"material:" + hit.refID,title:displayTitle(hit.title),subtitle:hit.snippet,icon:"doc.text") { go(.source(hit.refID)) }
        }
        let claims = searchHits.filter { hit in
            hit.kind == .claim && model.claims.contains { $0.id == hit.refID && $0.validity == "current" && $0.reviewState != "rejected" }
        }.map { hit in
            WorkspaceSearchRow(id:"claim:" + hit.refID,title:hit.title,subtitle:hit.snippet,icon:"lightbulb") {
                if let sourceID=model.claims.first(where: { $0.id == hit.refID })?.references.first?.sourceID { go(.source(sourceID)) }
            }
        }
        let actions = searchHits.filter { $0.kind == .action }.map { hit in
            WorkspaceSearchRow(id:"action:" + hit.refID,title:hit.title,subtitle:hit.snippet,icon:"checkmark.circle") { go(.task(hit.refID)) }
        }
        var sections:[WorkspaceSearchSection]=[]
        if !materials.isEmpty { sections.append(WorkspaceSearchSection(id:"materials",title:"材料",icon:"books.vertical",rows:materials)) }
        if !claims.isEmpty { sections.append(WorkspaceSearchSection(id:"claims",title:"观点",icon:"lightbulb",rows:claims)) }
        if !actions.isEmpty { sections.append(WorkspaceSearchSection(id:"actions",title:"行动",icon:"checkmark.circle",rows:actions)) }
        return sections
    }
    private func loadSearchHits(_ term:String) async {
        guard !term.isEmpty else {
            searchHits=[];searchFailed=false;searchBusy=false;searchKeyboardFocus.id=nil
            return
        }
        searchBusy=true
        defer { searchBusy=false }
        do { try await Task.sleep(for:.milliseconds(180)) } catch { return }
        guard !Task.isCancelled else { return }
        if let results=await model.searchAll(term) {
            searchHits=results;searchFailed=false
        } else {
            searchHits=[];searchFailed=true
        }
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
            HStack(alignment:.top,spacing:40) {
                VStack(alignment:.leading,spacing:6) {
                    Text("⌥⌘D 口述 · 全局")
                    Text("⌥⌘V 保存剪贴板 · 全局")
                    Text("⌥⌘N 速记 · 全局")
                    Text("⌘I 导入音频或视频 · 全局")
                    Text("⌘F 搜索 · 主窗口")
                    Text("⌘1 到 ⌘5 切换页面 · 主窗口")
                    Text("⌘[ 返回 · 主窗口")
                }
                VStack(alignment:.leading,spacing:6) {
                    Text("⌘⇧R 口述 · 仅主窗口")
                    Text("↑↓ 选择 · 列表聚焦时")
                    Text("↵ 打开 · 列表聚焦时")
                    Text("x 完成 · 列表聚焦时")
                    Text("z 不再跟进 · 列表聚焦时")
                    Text("⌥⌘Z 撤销 · 仅本次运行")
                    Text("撤销只对当前会话有效")
                }
            }.vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
            Button("再看一次引导") { model.onboardingRequested = true }
            Divider()
            sectionTitle("模型与服务")
            WorkspaceRow(title:"语音转文字",subtitle:model.speechSummary,icon:"waveform") { model.chooseLocalSpeech() }
            WorkspaceRow(title:"理解、核对与 AI 助理",subtitle:model.modelSummary,icon:"sparkles") { model.chooseTextModel() }
            sectionTitle("连接与自动入口")
            WorkspaceRow(title:"自动接收录音",subtitle:"VoiceOS 收件箱与语音备忘录",icon:"tray.and.arrow.down") { go(.tool("自动入口")) }
            WorkspaceRow(title:"Apple 提醒事项",subtitle:model.reminderCalendarTitle,icon:"checklist") { Task { await model.connectReminders() } }
            if model.reminderAccess?.enabled == true { Button("暂停提醒事项连接") { Task { await model.disconnectReminders() } } }
            sectionTitle("资料与历史")
            HStack(spacing:12) {
                Button("导出结构化资料") { model.export(includeMedia:false) }
                Button("导出资料与原件") { model.export(includeMedia:true) }
                if model.exporting { ProgressView().controlSize(.small) }
            }.disabled(model.exporting)
            HStack(spacing:12) {
                Text(model.backupStatusText.isEmpty ? "尚未生成备份" : model.backupStatusText).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                Button("重试备份") { model.retryBackup() }.vosFont(WorkspaceText.meta)
            }
            HStack { Button("打开已有资料库") { chooseLibrary() };Button("从迁移包恢复") { go(.tool("恢复资料")) } }
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
    }
    @ViewBuilder private var processingIssues: some View {
        let catalog=recordCatalog
        ForEach(model.assistantAssessmentIssues) { issue in
            VStack(alignment:.leading,spacing:8) { Text(issue.title);Text(issue.error).vosFont(WorkspaceText.meta).foregroundStyle(.secondary);Button("重新识别 AI 委托") { Task { await model.retryAssistantAssessment(issue) } }.accessibilityLabel("重新识别 AI 委托：" + issue.title) }
        }
        ForEach(model.recordingFollowups.filter { $0.state == "failed" }) { receipt in
            let title=displayTitle(model.records.first { $0.id == receipt.sourceID }?.displayTitle ?? "资料跟进")
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
        default: WorkspaceProcessingView(model:model,inbox:model.recordingInbox,openSource:{ go(.source($0)) },openSettings:{ go(.settings) },openInbox:{ go(.tool("自动入口")) })
        }
    }
    private func sectionTitle(_ title:String) -> some View { Text(title).vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.secondaryText).accessibilityAddTraits(.isHeader) }
    private func sourceNavigationTitle(_ id:String) -> String {
        guard let source=model.records.first(where: { $0.id == id }) else { return "材料" }
        if let expression=source.recordingExpression(in:Dictionary(uniqueKeysWithValues:model.records.map { ($0.id,$0) })),expression.sourceIDs.count > 1,
           let index=expression.sourceIDs.firstIndex(of:id) { return expression.title+" / 第 \(index+1) 段原文" }
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
    private var recordCatalog: [String:SourceRecord] { Dictionary(uniqueKeysWithValues:model.records.map { ($0.id,$0) }) }
    private func sourceRow(_ source:SourceRecord,catalog:[String:SourceRecord],highlighted:Bool = false) -> some View {
        let expression=source.recordingExpression(in:catalog)
        let combined=(expression?.sourceIDs.count ?? 0) > 1
        let first=combined ? expression!.sourceIDs.first.flatMap { catalog[$0] } ?? source : source
        let origin=source.origin == "ai" ? "AI 交付" : source.origin == "user" ? "我的表达" : "外部资料"
        let reading=materialReadingStatus(source.id)
        return WorkspaceRow(title:displayTitle(combined ? expression!.title : source.displayTitle),subtitle:first.recordingDateLabel + " · " + origin + (source.localOnly ? " · 仅本地" : ""),icon:source.kind.contains("text") ? "doc.text" : "waveform",trailing:reading?.text ?? "",trailingStyle:reading.map { WorkspaceRow.TrailingStyle.status($0.color) } ?? .secondary) { go(.source(source.id)) }
            .background(highlighted ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .overlay { if highlighted { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.focusRing,lineWidth:1) } }
            .contextMenu {
                Button("标为未读") { setMaterialReading(source.id,.unread) }
                Button("标为在读") { setMaterialReading(source.id,.reading) }
                Button("标为已读") { setMaterialReading(source.id,.read) }
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
    private func actionRowDetail(_ action:ActionRecord,timeEntry:ActionTimeEntry? = nil) -> ActionRowDetail {
        var detail=ActionRowDetail()
        var due=""
        if let entry=timeEntry,entry.source == .localSchedule {
            if let date=entry.due { due=(entry.isOverdue ? "已逾期 " : "到期 ") + date.summary }
            if entry.needsLocalSyncLabel { detail.status="本地未同步";detail.statusColor=palette.warning }
        } else if action.state == "open", action.validity == "current", let date=model.reminderLinks.first(where: { link in
            link.actionID == action.id && link.state == "linked" && link.remoteDueDate.map({ $0 != .none }) == true
        })?.remoteDueDate {
            due=(reminderDueIsPast(date) ? "已逾期 " : "到期 ") + date.summary
        }
        if let title=actionSourceTitle(action) {
            detail.meta=due.isEmpty ? "来自『\(title)』" : due + " · 来自『\(title)』"
        } else { detail.meta=due }
        if action.kind != "task", action.state == "open", action.validity == "current" {
            let nextCount=model.actionRecords.filter { $0.parentID == action.id && $0.state == "open" }.count
            let nextLabel=nextCount == 0 ? "还没有下一步" : "\(nextCount) 个下一步"
            detail.meta=detail.meta.isEmpty ? nextLabel : detail.meta + " · " + nextLabel
        }
        if detail.status.isEmpty {
            if model.workspaceExternalCompletionNote(action) != nil {
                detail.status="提醒事项已完成";detail.statusColor=palette.success
            } else if action.state == "dismissed" {
                detail.status="已放下";detail.statusColor=palette.tertiaryText
            } else if action.intent?.followupState == "withdrawn" {
                detail.status="已撤回";detail.statusColor=palette.tertiaryText
            } else if model.workspaceTaskRequiresReview(action) {
                detail.status="待核对";detail.statusColor=palette.warning
            } else if action.state == "completed" {
                detail.status="已登记完成";detail.statusColor=palette.secondaryText
            } else if action.validity != "current" {
                detail.status="历史记录";detail.statusColor=palette.tertiaryText
            }
        }
        return detail
    }
    private func actionSourceTitle(_ action:ActionRecord) -> String? {
        guard let claim=model.claims.first(where: { $0.id == action.claimID }) else { return nil }
        for reference in claim.references {
            guard let source=model.records.first(where: { $0.id == reference.sourceID }) else { continue }
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
        if action.canPromoteToTask, model.openNextActions(of: action.id).isEmpty {
            Button("转为待办") { promoteAction(action) }
                .accessibilityLabel("转为待办：" + action.title)
        }
        Button("改天") { openReminderSettings(action) }.disabled(!canChangeDay)
        Button("不再跟进") { dismissAction(action) }.disabled(!canTransition)
        Button(focused ? "移出专注" : "加入专注") { toggleFocus(action.id) }.disabled(!canTransition)
    }
    private func actionRow(_ action:ActionRecord,timeEntry:ActionTimeEntry? = nil) -> some View {
        let selectable=action.state == "open" && action.validity == "current"
        let actionable=selectable && !selectingActions
        let selected=selectedActionIDs.contains(action.id)
        let keyboardHighlighted=page == .actions && !selectingActions && actionKeyboardHighlightID == action.id
        let icon=selectingActions && selectable ? (selected ? "checkmark.circle.fill" : "circle") : action.state == "completed" ? "checkmark.circle" : action.state == "dismissed" ? "minus.circle" : "circle"
        let focused=focusedActionIDs.contains(action.id)
        let canChangeDay=actionable && hasLinkedReminder(action) && !model.savingAction && !model.remindersBusy
        let canComplete=actionable && action.kind == "task"
        let detail=actionRowDetail(action,timeEntry:timeEntry)
        let marksSelected=selectingActions && selected
        let trailingStyle:WorkspaceRow.TrailingStyle=marksSelected ? .status(palette.accent) : (detail.status.isEmpty ? .secondary : .status(detail.statusColor ?? palette.secondaryText))
        return WorkspaceActionRowChrome(action:action,
            canTransition:actionable,
            canComplete:canComplete,
            onComplete:{ if !model.savingAction { applyActionState(action,to:.completed) } },
            menuItems:{
                if canComplete { Button("标为完成") { if !model.savingAction { applyActionState(action,to:.completed) } } }
                actionMenuItems(action,focused:focused,canChangeDay:canChangeDay,canTransition:actionable)
            },
            row:{
                WorkspaceRow(title:action.title,subtitle:detail.meta,icon:icon,trailing:marksSelected ? "已选" : detail.status,trailingStyle:trailingStyle) {
                    if selectingActions {
                        guard selectable else { return }
                        if selected { selectedActionIDs.remove(action.id) } else { selectedActionIDs.insert(action.id) }
                    } else { go(.task(action.id)) }
                }
            })
            .background(keyboardHighlighted ? palette.selection : .clear,in:RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .overlay { if keyboardHighlighted { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.focusRing,lineWidth:1) } }
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
    private func hasLinkedReminder(_ action:ActionRecord) -> Bool {
        model.reminderLinks.contains { $0.actionID == action.id && $0.state == "linked" }
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
    private func promoteAction(_ action:ActionRecord) {
        Task {
            if await model.promoteAction(action) { error="" }
            else { error=model.status.isEmpty ? "未能转为待办，请稍后重试。" : model.status }
        }
    }
    private func applyActionState(_ action:ActionRecord,to state:LocalActionState,nextHighlight:String? = nil) {
        Task {
            await model.changeAction(action,state:state)
            guard model.actionRecords.first(where: { $0.id == action.id })?.state == state.rawValue else {
                error=model.status.isEmpty ? "状态未能更新，请稍后重试。" : model.status
                return
            }
            error=""
            switch state {
            case .completed: showActionUndo(action.id,message:"已完成")
            case .dismissed: showActionUndo(action.id,message:"已放下")
            case .open: actionUndo=nil
            }
            if let nextHighlight { actionKeyboardHighlightID=nextHighlight }
        }
    }
    private func showActionUndo(_ id:String,message:String) {
        actionUndo=ActionUndoState(actionID:id,message:message,token:UUID())
    }
    private func undoActionChange() {
        guard let target=actionUndo?.actionID else { return }
        Task {
            if await model.undoActionState(actionID:target) { actionUndo=nil;error="" }
            else { error=model.status.isEmpty ? "未能撤销，请稍后重试。" : model.status }
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
            add(model.actionRecords.filter { $0.kind != "task" && $0.state != "dismissed" && $0.validity == "current" }.prefix(3))
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
            guard let id=searchKeyboardFocus.id, let row=rows.first(where: { $0.id == id }) else { return .ignored }
            row.open()
            return .handled
        default:
            return .ignored
        }
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
            Button("撤销") { undoActionChange() }
        }.padding(.horizontal,16).padding(.vertical,10)
            .background(palette.surface,in:Capsule())
            .overlay { Capsule().strokeBorder(palette.border,lineWidth:1) }
            .shadow(color:.black.opacity(0.18),radius:14,y:6)
            .padding(.bottom,16)
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
            }
        }
        if let id = model.pendingWorkspaceTaskID {
            model.pendingWorkspaceTaskID = nil
            go(.task(id))
        }
    }
    private func routeExternalURL(_ url:URL) {
        if CaptureLink.isCapture(url) { Task { await model.acceptCaptureURL(url) } }
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
    private func toggleDiscussion(force:Bool=false,prompt:String="") async {
        let key = discussionKey
        if discussionIsPresented && !force { showingDiscussion=false;return }
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
                  let record = model.records.first(where: { $0.id == sourceID }) else { return }
            opened = await model.beginDiscussion(record)
        case .source(let id): opened = if let source=model.records.first(where: { $0.id == id }) { await model.beginDiscussion(source) } else { false }
        case .task(let id): opened = if let action=model.actionRecords.first(where: { $0.id == id }) { await model.beginActionDiscussion(action) } else { false }
        case .delivery(let id): opened = if let execution=model.assistantExecutions.first(where: { $0.id == id }) { await model.beginAssistantDiscussion(execution) } else { false }
        case .themes:
            guard let topic else { error="请先选择一个主题，再开始讨论。"; return }
            do {
                let focus=try await model.loadTopicReflection(topic.id)
                guard key == discussionKey else { return }
                topicFocus=focus;opened=await model.beginReflectionDiscussion(focus)
            } catch { if key == discussionKey { self.error=error.localizedDescription };return }
        default:
            do {
                let focus=try await model.loadReflection(.init(start:.distantPast,end:.distantFuture))
                guard key == discussionKey else { return }
                opened = await model.beginReflectionDiscussion(focus)
            } catch { if key == discussionKey { self.error=error.localizedDescription };return }
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
    let actionID: String
    let message: String
    let token: UUID
}

private struct WorkspaceSearchRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let open: () -> Void
}

private struct WorkspaceSearchSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    let rows: [WorkspaceSearchRow]
}

private struct MaterialMenuRow<Row: View, MenuContent: View>: View {
    @Environment(\.workspacePalette) private var palette
    @ViewBuilder let menu: () -> MenuContent
    @ViewBuilder let row: () -> Row
    @State private var hovered = false

    var body: some View {
        row()
            .overlay(alignment:.trailing) {
                if hovered {
                    menu()
                        .vosFont(WorkspaceText.meta)
                        .padding(.horizontal,8).padding(.vertical,4)
                        .background(palette.surface,in:Capsule())
                        .overlay { Capsule().strokeBorder(palette.border,lineWidth:1) }
                        .padding(.trailing,12)
                        .transition(.opacity)
                }
            }
            .onHover { hovered=$0 }
            .animation(.easeOut(duration:0.12),value:hovered)
    }
}

private struct WorkspaceActionRowChrome<Row: View, MenuItems: View>: View {
    @Environment(\.workspacePalette) private var palette
    let action: ActionRecord
    let canTransition: Bool
    let canComplete: Bool
    let onComplete: () -> Void
    @ViewBuilder let menuItems: () -> MenuItems
    @ViewBuilder let row: () -> Row
    @State private var hovered = false

    var body: some View {
        row()
            .overlay(alignment:.trailing) {
                if hovered && canTransition {
                    HStack(spacing: 2) {
                    if canComplete {
                        Button(action: onComplete) {
                            Image(systemName:"checkmark.circle").vosFont(WorkspaceText.rowTitle.size, weight: .semibold)
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: WorkspaceMetrics.rowActionMinHeight, height: WorkspaceMetrics.rowActionMinHeight)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .help("标为完成")
                            .accessibilityLabel("标为完成：" + action.title)
                    }
                    Menu {
                        menuItems()
                    } label: {
                        Image(systemName:"ellipsis").vosFont(WorkspaceText.meta.size, weight: .semibold)
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: WorkspaceMetrics.rowActionMinHeight, height: WorkspaceMetrics.rowActionMinHeight)
                            .contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("更多操作")
                        .accessibilityLabel("更多操作：" + action.title)
                    }
                    .padding(.horizontal,6).padding(.vertical,3)
                    .background(palette.surface,in:Capsule())
                    .overlay { Capsule().strokeBorder(palette.border,lineWidth:1) }
                    .padding(.trailing,12)
                    .transition(.opacity)
                }
            }
            .onHover { hovered=$0 }
            .animation(.easeOut(duration:0.12),value:hovered)
    }
}
