import SwiftUI
import AppKit
import AVKit
import VoiceOSCore

// One navigation state owns the workspace. Discussion is a sibling, so expanding
// it never replaces the reading view or its disclosure/scroll state.
enum WorkspacePage: Equatable {
    case home, themes, materials, actions, source(String), delivery(String), task(String), settings, capture, search, tool(String)
}
private struct WorkspaceNavigationEntry {
    let page: WorkspacePage
    let topicID: String?
    let topicTab: String
    let topicReadingMode: String
}
extension SourceRecord {
    var workspaceTitle: String {
        guard kind == "user_text",contentTitle == nil,let text=transcript,!text.isEmpty else { return displayTitle }
        let line=text.drop(while: { $0 == "\n" }).prefix(49).prefix(while: { $0 != "\n" })
        return String(line.prefix(48)) + (line.count > 48 ? "…" : "")
    }
}
struct WorkspaceHeading: View {
    let eyebrow: String
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment:.leading,spacing:11) {
            Text(eyebrow).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
            Text(title).font(.system(size:30,weight:.semibold)).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty { Text(subtitle).font(.system(size:14)).foregroundStyle(.secondary).lineSpacing(4) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct WorkspaceRow: View {
    @Environment(\.workspacePalette) private var palette
    @State private var hovered = false
    let title: String
    let subtitle: String
    var icon: String = "doc.text"
    var trailing: String = ""
    let open: () -> Void
    var body: some View {
        Button(action:open) {
            HStack(alignment:.top,spacing:14) {
                Image(systemName:icon).font(.system(size:16)).foregroundStyle(palette.accent)
                    .frame(width:34,height:34).background(palette.selection.opacity(0.6),in:RoundedRectangle(cornerRadius:8))
                VStack(alignment:.leading,spacing:8) {
                    Text(title).font(.system(size:16,weight:.semibold)).lineSpacing(3).lineLimit(3).fixedSize(horizontal:false,vertical:true)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size:13)).foregroundStyle(.secondary).lineSpacing(3).lineLimit(2).fixedSize(horizontal:false,vertical:true) }
                }
                Spacer(minLength:8)
                if !trailing.isEmpty { Text(trailing).font(.system(size:12,weight:.medium)).foregroundStyle(.secondary).padding(.top,3) }
                Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top,3)
            }.padding(.vertical,18).padding(.horizontal,10).contentShape(RoundedRectangle(cornerRadius:9))
                .background(hovered ? palette.selection.opacity(0.5) : .clear,in:RoundedRectangle(cornerRadius:9))
        }.buttonStyle(.plain).onHover { hovered=$0 }
    }
}
struct WorkspaceView: View {
    @ObservedObject var model: ControlCenter
    @AppStorage("voiceos.workspaceTheme") private var theme = WorkspaceTheme.graphite
    @AppStorage("voiceos.workspaceAppearance") private var appearance = WorkspaceAppearance.system
    private var palette: WorkspacePalette { WorkspacePalette(theme: theme) }
    @State private var page: WorkspacePage = .home
    @State private var path: [WorkspaceNavigationEntry] = []
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
    @State private var materialFilter = "日常材料"
    @State private var actionFilter = "全部"
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var taskFeedbackDrafts: [String: TaskFeedbackDraft] = [:]
    @State private var creatingTopic = false
    @State private var newTopicTitle = ""
    @State private var topicFocus: ConversationReflectionFocus?
    @State private var reviewPeriod = ReflectionPeriod.week
    @State private var reviewAnchor = Date()
    @State private var error = ""
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
        case .search: "全局搜索"
        case .tool(let name): name
        }
    }
    private var sourceOpenedFromTheme: Bool {
        // Keep the material page in the navigation path it was opened from.
        for previous in path.reversed() {
            switch previous.page {
            case .themes: return true
            case .home, .materials, .actions, .search, .capture, .settings: return false
            default: continue
            }
        }
        return false
    }
    var body: some View {
        HStack(spacing:0) {
            sidebar
            Divider()
            VStack(spacing:0) {
                header
                Divider()
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
                    } else { pageContent }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(12) }
                WorkspaceProcessingBar(model: model, inbox: model.recordingInbox) { go(.tool("处理情况")) }
            }.frame(minWidth:440)
            if discussionIsPresented {
                Divider()
                WorkspaceDiscussionView(model:model,draft:$discussionDraft,close:{ showingDiscussion=false },openSource:{ go(.source($0)) })
                    .frame(minWidth:290,idealWidth:320,maxWidth:380)
            }
        }
        .font(.system(size:15)).foregroundStyle(palette.text).background(palette.canvas).tint(palette.accent)
        .environment(\.workspacePalette, palette)
        .preferredColorScheme(appearance.colorScheme)
        .frame(minWidth:980,minHeight:700)
        .navigationTitle(model.libraryTitle)
        .focusedSceneValue(\.voiceOSController,model)
        .task { await model.start() }
        .task(id:topicLoadKey) {
            guard page == .themes, let id=topicID else { topicFocus=nil; return }
            do { let focus=try await model.loadTopicReflection(id); if topicID == id && !Task.isCancelled { topicFocus=focus } }
            catch { if topicID == id && !Task.isCancelled { topicFocus=nil; self.error=error.localizedDescription } }
        }
        .onChange(of:page) { _, next in
            model.stopPlayback()
            if next != .search { searchFocused = false }
            if case .source(let id) = next { model.selected = id }
        }
        .onChange(of:model.selected) { _, id in
            model.stopPlayback()
            Task { await model.refreshSourceDiscussions(); await model.refreshAssociationSelection() }
        }
        .onChange(of:model.taskPresentation) { _, _ in
            if let id=model.focusedTaskID { go(.task(id)) } else { go(.actions) }
        }
        .onChange(of:model.fullRecordingInput?.id) { _, id in
            if id != nil { go(.tool("导入录音")); showingDiscussion=false }
            else if page == .tool("导入录音") { back() }
        }
        .onOpenURL { url in if model.initialized { openReminder(url) } else { pendingURL=url } }
        .onChange(of:model.initialized) { _, ready in if ready,let url=pendingURL { pendingURL=nil;openReminder(url) } }
        .sheet(isPresented:$model.choosingReminderCalendar) {
            VStack(alignment:.leading,spacing:16) {
                Text("选择提醒事项清单").font(.title2)
                ForEach(model.reminderCalendars) { calendar in Button(calendar.title) { Task { model.proposedReminderCalendarID=calendar.id; await model.saveReminderConnection() } } }
                Button("取消") { model.choosingReminderCalendar=false }
            }.padding(24).frame(width:440)
        }
        .sheet(item: $panoramaSourceEditor) { source in
            WorkspaceTranscriptEditor(model: model, source: source) { panoramaSourceEditor = nil }
        }
        .sheet(item: $panoramaClaimEditor) { claim in
            ClaimCorrectionView(claim: claim, model: model) { panoramaClaimEditor = nil }
        }
        .sheet(item:$model.pendingScheduleEffect) { effect in ReminderScheduleConfirmationView(effect:effect,model:model) { model.pendingScheduleEffect=nil } }
    }
    private var topicLoadKey: String {
        guard page == .themes, let id = topicID else { return "" }
        return id + (topic?.updatedAt ?? "") + String(model.recentOutcomes.count) + topicActions.map { $0.id+String($0.version) }.joined()
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:28) {
            Label("VoiceOS",systemImage:"waveform").font(.system(size:19,weight:.medium)).padding(.horizontal,9)
            VStack(spacing:5) {
                nav("首页",icon:"house",target:.home)
                nav("主题",icon:"circle.hexagongrid",target:.themes)
                nav("材料",icon:"books.vertical",target:.materials)
                nav("行动",icon:"checkmark.circle",target:.actions)
            }
            Spacer()
            Button { go(.capture) } label: { Label("记录想法",systemImage:"mic").frame(maxWidth:.infinity).padding(.vertical,7) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            VStack(alignment:.leading,spacing:12) {
                HStack(spacing:7) {
                    if model.organizingTopics || model.assistantBusy || model.followupBusy { ProgressView().controlSize(.mini) }
                    Text(model.organizingTopics ? "AI 正在连接主题" : "表达、理解与行动").font(.caption).foregroundStyle(.secondary)
                }
                Button { go(.settings);showingDiscussion=false } label: { Label("设置",systemImage:"slider.horizontal.3").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }.padding(.horizontal,8)
        }.padding(.horizontal,13).padding(.vertical,28).frame(width:172).background(palette.sidebar)
    }
    private func nav(_ title:String,icon:String,target:WorkspacePage) -> some View {
        Button { path=[];page=target;if target == .themes { topicID=nil;topicFocus=nil };error="" } label: {
            Label(title,systemImage:icon).font(.system(size:15,weight:section == title ? .semibold : .regular))
                .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,11)
                .background(section == title ? palette.selection : .clear,in:RoundedRectangle(cornerRadius:8))
                // Plain buttons otherwise only hit-test the icon and text, leaving the padded row inert.
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("workspace.nav."+title)
    }
    private var header: some View {
        HStack(spacing:12) {
            if !path.isEmpty {
                Button(action:back) {
                    Image(systemName:"chevron.left").font(.system(size:15,weight:.medium))
                        .frame(width:44,height:44)
                        .background(palette.selection.opacity(0.5),in:RoundedRectangle(cornerRadius:8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("返回").help("返回上一页")
            }
            Text(breadcrumb).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { if page == .search { searchFocused = true } else { go(.search) } } label: { Image(systemName:"magnifyingglass") }
                .buttonStyle(.plain).help("搜索全部内容（⌘F）").keyboardShortcut("f",modifiers:.command)
            Button { Task { await toggleDiscussion() } } label: { Label("讨论",systemImage:"sidebar.right") }
                .buttonStyle(.borderless).disabled(model.discussionSaving || model.discussionSending)
                .accessibilityIdentifier("workspace.discussion")
        }.padding(.horizontal,26).frame(height:58).background(palette.canvas)
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
            PanoramaHome(screen: model.panorama, retry: model.retryPanorama, chooseTextModel: model.chooseTextModel,
                openMaterials: { go(.materials) }, openSource: { go(.source($0)) }, correctSource: { id in
                    panoramaSourceEditor = model.records.first { $0.id == id }
                }, correctClaim: { id in
                    panoramaClaimEditor = model.claims.first { $0.id == id }
                }, discuss: { snapshot, selection in
                    Task { await openPanoramaDiscussion(snapshotID: snapshot, selection: selection) }
                })
        case .themes: scrolled { themes }.id((topicID ?? "all-topics") + ":" + topicTab)
        case .materials: scrolled { materials }
        case .actions: scrolled { actions }
        case .source(let id):
            if let source=model.records.first(where: { $0.id == id }) {
                if source.isTrashed { TrashedMaterialView(model:model,source:source) }
                else {
                    WorkspaceSourceView(model:model,source:source,openTask:{ go(.task($0)) },openDelivery:{ go(.delivery($0)) },openDiscussion:{ id in Task { await openSavedDiscussion(id) } },openSource:{ go(.source($0)) })
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
                    get: { taskFeedbackDrafts[id + ":" + String(action.version)] ?? TaskFeedbackDraft() },
                    set: { taskFeedbackDrafts[id + ":" + String(action.version)] = $0 }
                ),openSource:{ go(.source($0)) },openDelivery:{ go(.delivery($0)) },discuss:{ Task { await toggleDiscussion(force:true) } })
                    .id(id)
            } else { unavailable("任务暂时不可用",description:"可以回到行动查看当前事项。") }
        case .settings: scrolled { settings }
        case .capture:
            VStack(alignment:.leading,spacing:0) {
                HStack {
                    Button(model.dictationActive ? "停止并整理" : "开始口述并自动整理",systemImage:model.dictationActive ? "stop.circle" : "mic") {
                        if model.dictationActive { model.stopDictation() } else { Task { await model.startDictation(processAfterTranscription:true) } }
                    }.buttonStyle(.borderedProminent).disabled(model.dictationBusy || model.fullRecordingBusy)
                    Button("导入音频 / 视频") { model.chooseFullRecording() }
                }.padding(24)
                TextCaptureView(model:model,draft:$model.textCaptureDraft,onSaved:{ if page == .capture { go(.source($0)) } },dismiss:back)
            }.frame(maxWidth:860).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        case .search: scrolled { search }
        case .tool(let name): tool(name)
        }
    }
    private func scrolled<Content:View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView { content().frame(maxWidth:860,alignment:.leading).padding(30).frame(maxWidth:.infinity,alignment:.top) }
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
            materialFilter == "回收站" ? source.isTrashed : materialFilter == "已归档" ? source.isArchived : !source.isArchived && !source.isTrashed
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
    private func contextSourceID(_ source:SourceRecord,catalog:[String:SourceRecord]) -> String? {
        guard let pair=source.presentation?.recordingContext,pair.personalSourceID == source.id,
              let external=catalog[pair.externalSourceID],!source.localOnly,!external.localOnly,
              !source.needsTranscriptionReview,!external.needsTranscriptionReview,
              source.transcriptVersionID == pair.personalVersionID,external.transcriptVersionID == pair.externalVersionID,
              source.policyVersion == pair.personalPolicyVersion,external.policyVersion == pair.externalPolicyVersion else { return nil }
        return external.id
    }
    private var materials: some View {
        LazyVStack(alignment:.leading,spacing:24) {
            WorkspaceHeading(eyebrow:"材料 · \(readingMaterials.count) 份",title:"按材料查看",subtitle:"最近加入的材料在前。连续录音由 AI 自动合为一次表达，原始分段在详情中保留。")
            WorkspaceTabs(selection:$materialFilter,titles:["日常材料","已归档","回收站"])
            if materialFilter != "日常材料" {
                Text(materialFilter == "已归档" ? "归档材料仍可作为历史依据；打开材料可取消归档。" : "原件与历史保留，不用于当前理解；恢复后仅本机保存。Apple 提醒事项未被删除或取消。").font(.callout).foregroundStyle(.secondary)
            }
            if model.records.isEmpty {
                Text("还没有材料。可以先记录想法，或导入一段录音、视频。").foregroundStyle(.secondary)
                Button("添加材料") { go(.capture) }.buttonStyle(.borderedProminent)
            } else {
                ForEach(readingMaterials) { source in
                    sourceRow(source,showOriginalName:true)
                    MaterialManagementControls(model:model,source:source).font(.caption)
                    if source.id != readingMaterials.last?.id { Divider() }
                }
                if readingMaterials.isEmpty { Text("这里暂时没有材料。").foregroundStyle(.secondary) }
            }
        }
    }
    private var themes: some View {
        LazyVStack(alignment:.leading,spacing:24) {
            if let topic {
                HStack { Button("所有主题",systemImage:"arrow.left") { if path.last?.page == .themes && path.last?.topicID == nil { back() } else { topicID=nil;topicFocus=nil } };Spacer(); Menu("调整主题") { Button("修改主题名称") { newTopicTitle=topic.title;creatingTopic=true };Button("重新连接当前材料") { model.queueTopicOrganization(retry:true) } } }
                WorkspaceHeading(eyebrow:topic.isAIOrganized == true ? "AI 自动归组 · 持续演化" : "主题 · 持续演化",title:topic.title,subtitle:"\(topicSources.count) 份材料 · 跨时间连接理解、行动与结果")
                WorkspaceTabs(selection:$topicTab,titles:["概览","认识与问题","行动与结果","材料"])
                topicContent(topic)
            } else {
                HStack { WorkspaceHeading(eyebrow:"主题与问题",title:"让零散的积累，连成脉络",subtitle:"同一个主题跨周、跨月延续；时间用来回顾变化。")
                    Spacer();Button("新建主题") { newTopicTitle="";creatingTopic=true }
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
                    DisclosureGroup("尚未归入主题的材料（\(unlinked.count)）") { ForEach(distinctExpressions(unlinked)) { sourceRow($0) } }
                }
            }
            if creatingTopic {
                VStack(alignment:.leading,spacing:14) {
                    TextField("你持续关心的主题或问题",text:$newTopicTitle).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("取消") { creatingTopic=false }
                        Button("保存主题") { Task { await saveTopic() } }.buttonStyle(.borderedProminent).disabled(newTopicTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                }.padding(18).background(palette.selection,in:RoundedRectangle(cornerRadius:9))
            }
        }
    }
    @ViewBuilder private func topicContent(_ topic:ReflectionQuestion) -> some View {
        switch topicTab {
        case "材料":
            WorkspaceSection(title:"主题材料",subtitle:"完整原话与资料，按时间延续",icon:"books.vertical",count:topicSources.count) {
                ForEach(distinctExpressions(topicSources)) { source in sourceRow(source);if source.id != distinctExpressions(topicSources).last?.id { Divider() } }
            }
            DisclosureGroup("关联其他材料") {
                ForEach(model.records.filter { !sourceIDs.contains($0.id) && !($0.transcript ?? "").isEmpty }) { source in
                    Button(source.workspaceTitle) { Task { do { try await model.linkReflectionQuestionSource(questionID:topic.id,sourceID:source.id,linked:true);await model.refresh() } catch { self.error=error.localizedDescription } } }
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
            Text("放在完整主题的脉络里，看这段时间的变化。").font(.callout).foregroundStyle(.secondary)
            let interval=reviewPeriod.interval(containing:reviewAnchor)
            let sources=topicSources.filter { interval.contains($0.expressedDate ?? ConversationReflectionFocus.date($0.createdAt) ?? .distantPast) }
            ForEach(distinctExpressions(sources)) { sourceRow($0);Divider() }
            let actionIDs=Set(topicActions.map(\.id))
            let outcomes=(topicFocus?.outcomes ?? []).filter { actionIDs.contains($0.actionID) && ConversationReflectionFocus.date($0.createdAt).map { interval.contains($0) } == true }
            ForEach(outcomes) { outcome in WorkspaceRow(title:outcome.text,subtitle:"实际结果 · " + dateLabel(outcome.createdAt),icon:"leaf") { go(.task(outcome.actionID)) } }
            if sources.isEmpty && outcomes.isEmpty { Text("这段时间还没有新增材料或结果。这个主题的历史脉络仍保留在概览中。").foregroundStyle(.secondary) }
            Button("让 AI 一起回顾这个周期",systemImage:"sparkles") { Task { do { let focus=try await model.loadQuestionReflection(topic.id,interval:interval,period:reviewPeriod);_ = await openReflection(focus,prompt:reviewPeriod.reviewPrompt(dateLabel:interval.start.formatted(date:.abbreviated,time:.omitted),questionTitle:topic.title)) } catch { self.error=error.localizedDescription } } }.buttonStyle(.borderedProminent)
        }
    }
    private var actions: some View {
        LazyVStack(alignment:.leading,spacing:24) {
            WorkspaceHeading(eyebrow:"行动与交付",title:"事情在向前推进",subtitle:"你的待办、AI 承担的任务和完成结果，都在这里。")
            WorkspaceTabs(selection:$actionFilter,titles:["全部","我的待办","AI 助理","已完成","问题与目标","待核对","历史记录"])
            if ["全部","AI 助理"].contains(actionFilter) {
                let executions=model.assistantExecutions.filter { $0.state != "cancelled" }
                if !executions.isEmpty {
                    WorkspaceSection(title:"AI 助理的工作",subtitle:"执行进度与已保存的交付",icon:"sparkles",count:executions.count) {
                        ForEach(executions) { execution in
                            WorkspaceRow(title:execution.title,subtitle:assistantExecutionLabel(execution),icon:execution.state == "completed" ? "doc.text" : "sparkles",trailing:execution.state == "completed" ? "阅读结果" : "查看进度") { go(.delivery(execution.id)) }
                            if execution.id != executions.last?.id { Divider() }
                        }
                    }
                }
            }
            let visible = visibleActions
            let executions = model.assistantExecutions.filter { $0.state != "cancelled" }
            let paused = model.workspacePausedTasks
            if actionFilter != "AI 助理",!visible.isEmpty {
                WorkspaceSection(title:actionFilter == "全部" ? "我的待办" : actionFilter,icon:"checkmark.circle",count:visible.count) {
                    ForEach(visible) { action in actionRow(action);if action.id != visible.last?.id { Divider() } }
                }
            }
            if actionFilter == "全部", !paused.isEmpty {
                WorkspaceSection(title:"需要核对的待办",subtitle:"尚未登记完成，行动关系待核对或 AI 提取已暂停。打开任务查看依据和具体原因。",icon:"pause.circle",count:paused.count) {
                    ForEach(paused) { action in actionRow(action);if action.id != paused.last?.id { Divider() } }
                }
            }
            if visible.isEmpty && (actionFilter == "AI 助理" || actionFilter == "全部" ? executions.isEmpty : true) && !(actionFilter == "全部" && !paused.isEmpty) {
                VStack(alignment:.leading,spacing:12) {
                    Text(actionFilter == "历史记录" ? "还没有历史任务记录" : actionFilter == "已完成" ? "还没有已完成的事项" : actionFilter == "AI 助理" ? "还没有 AI 代办" : actionFilter == "待核对" ? "当前没有需要核对的行动" : actionFilter == "问题与目标" ? "还没有问题与目标" : "目前没有可执行的待办").font(.title3)
                    Text(actionFilter == "AI 助理" ? "在一项待办中选择“交给 AI”，编辑要求后开始执行。" : "已暂停的历史、问题与目标分别保留，可通过上方分类查看。").foregroundStyle(.secondary)
                    HStack { Button("记录想法") { go(.capture) };if actionFilter != "问题与目标" { Button("查看问题与目标") { actionFilter="问题与目标" } } }
                }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(palette.surface,in:RoundedRectangle(cornerRadius:12))
            }
            if actionFilter == "待核对" { processingIssues }
            HStack { Button("同步提醒事项") { Task { await model.refreshTaskReminders() } }.disabled(model.reminderAccess?.enabled != true || model.remindersBusy);Spacer();Text(model.reminderSyncStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
    }
    private var visibleActions: [ActionRecord] {
        model.actionRecords.filter { action in
            switch actionFilter {
            case "已完成": return action.state == "completed"
            case "历史记录": return action.validity != "current" && !model.workspaceTaskRequiresReview(action)
            case "待核对": return model.workspaceTaskRequiresReview(action) || action.validity == "current" && (action.intent?.uncertain == true || action.intent?.followupState == "needs_review")
            case "问题与目标": return action.kind != "task" && action.state != "dismissed"
            default: return action.kind == "task" && action.state == "open" && action.validity == "current" && !model.workspaceTaskRequiresReview(action)
            }
        }
    }
    private var search: some View {
        LazyVStack(alignment:.leading,spacing:24) {
            WorkspaceHeading(eyebrow:"全局搜索",title:"找回任何一段积累",subtitle:"原话、材料、理解、任务和结果，一起查找。")
            HStack {
                TextField("搜索标题、原话、理解或行动",text:$query).textFieldStyle(.roundedBorder).focused($searchFocused)
                    .task {
                        // Wait until the lazy field is attached to its native window.
                        do { try await Task.sleep(for:.milliseconds(100)); searchFocused = true } catch {}
                    }
                if !query.isEmpty { Button("清空") { query = ""; searchFocused = true } }
            }
            let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
            let matchingActions=model.actionRecords.filter { !term.isEmpty && ($0.title+"\n"+$0.note).localizedCaseInsensitiveContains(term) }
            if !matchingActions.isEmpty { sectionTitle("行动 · \(matchingActions.count)") }
            ForEach(matchingActions) { actionRow($0) }
            let matchingClaims=model.claims.filter { !term.isEmpty && $0.validity == "current" && $0.reviewState != "rejected" && $0.statement.localizedCaseInsensitiveContains(term) }
            if !matchingClaims.isEmpty { sectionTitle("理解 · \(matchingClaims.count)") }
            ForEach(matchingClaims) { thoughtRow($0) }
            let sources=model.records.filter { !$0.isTrashed && (term.isEmpty || ($0.workspaceTitle+"\n"+$0.name+"\n"+($0.transcript ?? "")).localizedCaseInsensitiveContains(term)) }
            if !sources.isEmpty { sectionTitle("材料与原话 · \(sources.count)") }
            ForEach(sources) { sourceRow($0);Divider() }
            if sources.isEmpty && matchingActions.isEmpty && matchingClaims.isEmpty { Text("没有找到相关内容。").foregroundStyle(.secondary) }
        }
    }
    private var settings: some View {
        VStack(alignment:.leading,spacing:26) {
            WorkspaceHeading(eyebrow:"统一设置",title:"让系统按你的方式工作",subtitle:"配置集中管理，阅读时聚焦内容。")
            sectionTitle("外观")
            HStack(spacing:12) {
                ForEach(WorkspaceTheme.allCases) { option in
                    WorkspaceThemeOption(theme:option,selected:theme == option) { theme=option }
                }
            }.frame(maxWidth:560)
            Picker("显示模式",selection:$appearance) {
                ForEach(WorkspaceAppearance.allCases) { option in Text(option.title).tag(option) }
            }.pickerStyle(.segmented).frame(maxWidth:360)
            Text("配色即时生效，并在下次打开时沿用。").font(.caption).foregroundStyle(.secondary)
            Divider()
            sectionTitle("模型与服务")
            WorkspaceRow(title:"语音转文字",subtitle:model.speechSummary,icon:"waveform") { model.chooseLocalSpeech() }
            WorkspaceRow(title:"理解、核对与 AI 助理",subtitle:model.modelSummary,icon:"sparkles") { model.chooseTextModel() }
            sectionTitle("连接与自动入口")
            WorkspaceRow(title:"自动接收录音",subtitle:"VoiceOS 收件箱与语音备忘录",icon:"tray.and.arrow.down") { go(.tool("自动入口")) }
            WorkspaceRow(title:"Apple 提醒事项",subtitle:model.reminderCalendarTitle,icon:"checklist") { Task { await model.connectReminders() } }
            if model.reminderAccess?.enabled == true { Button("暂停提醒事项连接") { Task { await model.disconnectReminders() } } }
            sectionTitle("资料与历史")
            HStack { Button("导出结构化资料") { model.export(includeMedia:false) };Button("导出资料与原件") { model.export(includeMedia:true) } }
            HStack { Button("打开已有资料库") { chooseLibrary() };Button("从迁移包恢复") { go(.tool("恢复资料")) } }
            DisclosureGroup("其他工作与维护") {
                VStack(alignment:.leading,spacing:15) {
                    Button("思想关联、目标下一步与英语反馈") { go(.tool("思想与下一步")) }
                    Button("纠错后的行动影响") { go(.tool("纠错影响")) }
                    Button("表达处理与重试") { go(.tool("处理情况")) }
                    Button("重新整理主题与简报") { model.queueTopicOrganization(retry:true) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.top,15)
            }
        }
    }
    @ViewBuilder private var processingIssues: some View {
        ForEach(model.assistantAssessmentIssues) { issue in
            VStack(alignment:.leading,spacing:8) { Text(issue.title);Text(issue.error).font(.caption).foregroundStyle(.secondary);Button("重新识别 AI 委托") { Task { await model.retryAssistantAssessment(issue) } } }
        }
        ForEach(model.recordingFollowups.filter { $0.state == "failed" }) { receipt in
            VStack(alignment:.leading,spacing:8) { Text(model.records.first { $0.id == receipt.sourceID }?.workspaceTitle ?? "资料跟进");Button("重试思想与下一步") { model.refreshFollowup(receipt.sourceID) } }
        }
        ForEach(activeMaterials.filter { ["failed","blocked"].contains($0.jobState ?? "") }) { source in sourceRow(source) }
        ForEach(model.processingIntents.filter { [.blocked,.unknown].contains($0.state) }) { intent in
            Text("表达处理：" + intent.state.rawValue).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func tool(_ name:String) -> some View {
        switch name {
        case "导入录音": if let input=model.fullRecordingInput { FullRecordingView(model:model,input:input,embedded:true) { model.fullRecordingInput=nil;go(.actions) }.frame(maxWidth:.infinity,maxHeight:.infinity) }
        case "自动入口": RecordingInboxView(inbox:model.recordingInbox,model:model,embedded:true,dismiss:back)
        case "思想与下一步": RecordingFollowupView(model:model,embedded:true,dismiss:openSelectedSource)
        case "纠错影响": CorrectionImpactView(model:model,embedded:true,dismiss:openSelectedSource)
        case "恢复资料": PackageRestoreView(dismiss:back).frame(maxWidth:.infinity,maxHeight:.infinity)
        default: WorkspaceProcessingView(model:model,inbox:model.recordingInbox,openSource:{ go(.source($0)) },openSettings:{ go(.settings) },openInbox:{ go(.tool("自动入口")) })
        }
    }
    private func sectionTitle(_ title:String) -> some View { Text(title).font(.system(size:21,weight:.semibold)).accessibilityAddTraits(.isHeader) }
    private func sourceNavigationTitle(_ id:String) -> String {
        guard let source=model.records.first(where: { $0.id == id }) else { return "材料" }
        if let expression=source.recordingExpression(in:Dictionary(uniqueKeysWithValues:model.records.map { ($0.id,$0) })),expression.sourceIDs.count > 1,
           let index=expression.sourceIDs.firstIndex(of:id) { return expression.title+" / 第 \(index+1) 段原文" }
        return source.workspaceTitle
    }
    private func sourceRow(_ source:SourceRecord,showOriginalName:Bool=false) -> some View {
        let expression=source.recordingExpression(in:Dictionary(uniqueKeysWithValues:model.records.map { ($0.id,$0) }))
        let combined=(expression?.sourceIDs.count ?? 0) > 1
        let originalName = showOriginalName && !combined && source.name != source.workspaceTitle ? " · " + source.name : ""
        let duration=combined ? Int(model.records.filter { expression?.sourceIDs.contains($0.id) == true }.reduce(0) { $0 + ($1.duration ?? 0) }.rounded()) : 0
        let first=combined ? model.records.first { $0.id == expression?.sourceIDs.first } ?? source : source
        let timing=combined ? "连续表达 · \(expression!.sourceIDs.count) 段 · 合计 \(duration/60)分\(duration%60)秒 · "+first.recordingDateLabel : source.recordingSubtitle
        return WorkspaceRow(title:combined ? expression!.title : source.workspaceTitle,subtitle:timing + " · " + (source.origin == "ai" ? "AI 交付" : source.origin == "user" ? "我的表达" : "外部资料") + (source.localOnly ? " · 仅本地" : "") + originalName,icon:source.kind.contains("text") ? "doc.text" : "waveform") { go(.source(source.id)) }
    }
    private func actionRow(_ action:ActionRecord) -> some View { WorkspaceRow(title:action.title,subtitle:model.workspaceActionStatus(action),icon:action.state == "completed" ? "checkmark.circle" : "circle") { go(.task(action.id)) } }
    private func thoughtRow(_ claim:CandidateClaim) -> some View { WorkspaceRow(title:claim.statement,subtitle:claim.ownership == "ai_candidate" ? "AI 分析 · 不代表我的观点" : claim.ownership == "external" ? "外部观点" : "从我的表达中整理",icon:"lightbulb") { if let id=claim.references.first?.sourceID { go(.source(id)) } } }
    private func dateLabel(_ text:String) -> String { ConversationReflectionFocus.date(text)?.formatted(date:.abbreviated,time:.omitted) ?? text }
    private var navigationEntry: WorkspaceNavigationEntry { .init(page:page,topicID:topicID,topicTab:topicTab,topicReadingMode:topicReadingMode) }
    private func go(_ next:WorkspacePage) { if page != next { path.append(navigationEntry);page=next };error="" }
    private func back() {
        if let entry=path.popLast() {
            topicID=entry.topicID;topicTab=entry.topicTab;topicReadingMode=entry.topicReadingMode;page=entry.page
        } else { page = .home }
        topicFocus=nil;error=""
    }
    private func selectTopic(_ id:String) {
        if page == .themes { path.append(navigationEntry) }
        go(.themes);topicID=id;topicTab="概览";topicReadingMode="卡片";topicFocus=nil
    }
    private func saveTopic() async {
        do {
            if let topic, creatingTopic, !newTopicTitle.isEmpty { try await model.renameReflectionQuestion(topic.id,title:newTopicTitle,allowCloud:true) }
            else { let created=try await model.createReflectionQuestion(newTopicTitle,allowCloud:true);topicID=created.id }
            creatingTopic=false;newTopicTitle="";model.queueTopicOrganization()
        } catch { self.error=error.localizedDescription }
    }
    private func openReminder(_ url:URL) { Task { if await model.focusReminder(url) { if let id=model.focusedTaskID { go(.task(id)) } else { go(.actions) } } } }
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
            guard let snapshot = model.panorama.state?.snapshot, let selection = model.panorama.selection else {
                error = "请先选择全景中的问题或联系，再沿线讨论。"
                return
            }
            await openPanoramaDiscussion(snapshotID: snapshot.id, selection: selection)
            return
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
                TextEditor(text:$text).frame(minHeight:100).padding(8).background(palette.surface,in:RoundedRectangle(cornerRadius:8))
                Button("保存并接回主题") { saving=true;Task { do { try await model.saveReflectionQuestionEntry(questionID:topic.id,kind:kind,text:text,sourceIDs:sourceIDs,allowCloud:true);text="";error="" } catch { self.error=error.localizedDescription };saving=false } }.disabled(saving || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(.top,12)
        }
    }
}
