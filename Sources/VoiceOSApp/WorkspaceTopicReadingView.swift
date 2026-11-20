import SwiftUI
import VoiceOSCore

struct WorkspaceTopicReadingView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var scale
    @ObservedObject var model: ControlCenter
    let topic: ReflectionQuestion
    let mode: String
    let focus: ConversationReflectionFocus?
    let reading: TopicReadingData
    let level: TopicLevel
    let openSource: (String) -> Void
    let openTopic: (String) -> Void
    let openTask: (String) -> Void
    let openDelivery: (String) -> Void
    let discuss: (String) -> Void
    let showActions: () -> Void
    let showUnderstanding: () -> Void
    @State private var selectedSection: String?
    @State private var showingAllSections = false
    @State private var showingStructure = false
    @State private var correctingClaim: CandidateClaim?
    @State private var pendingRejection: CandidateClaim?
    @State private var confirmingRejection = false
    @State private var hoveredSectionID: String?
    @State private var hoveredQuestion: String?
    @State private var localFilter = ""
    @State private var keyboardSectionID: String?
    @FocusState private var structureFocused: Bool

    private var sections: [TopicReadingSection] { topic.organization?.sections ?? [] }
    private var bodyPending: Bool { topic.organization?.bodyPending == true }
    private var sectionsWithoutClaims: Bool {
        !sections.isEmpty && sections.allSatisfy { (reading.sectionClaims[$0.id] ?? []).isEmpty }
    }
    private var claimIDs: Set<String> { reading.claimIDs }
    private var actionIDs: Set<String> { reading.actionIDs }
    private var actions: [ActionRecord] { reading.actions }
    private var tasks: [ActionRecord] { actions.filter { $0.kind == "task" } }
    private var deliveries: [AssistantExecutionRecord] {
        model.assistantExecutions.filter { $0.validity == "current" && $0.state == "completed" && ($0.questionID == topic.id || actionIDs.contains($0.actionID)) }
    }
    private var outcomes: [ActionFeedbackRecord] { (focus?.outcomes ?? []).filter { feedback in actionIDs.contains(feedback.actionID) && feedback.sourceState != "frozen" && reading.actionVersionByID[feedback.actionID] == feedback.actionVersion } }
    private var filterTerm: String { localFilter.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var showsTopicFilter: Bool { sections.count > 4 }
    private var filteredSections: [TopicReadingSection] {
        guard !filterTerm.isEmpty else { return sections }
        return sections.filter { sectionMatches($0,term:filterTerm) }
    }
    private var displayedSections: [TopicReadingSection] {
        if let selectedSection { return filteredSections.filter { $0.id == selectedSection } }
        return filteredSections
    }
    private var listedSections: [TopicReadingSection] {
        showingAllSections ? filteredSections : Array(filteredSections.prefix(6))
    }
    private func sectionMatches(_ section:TopicReadingSection,term:String) -> Bool {
        if section.title.localizedStandardContains(term) || section.summary.localizedStandardContains(term) { return true }
        if section.evidence.contains(where: { $0.quote.localizedStandardContains(term) }) { return true }
        let sectionClaims=reading.sectionClaims[section.id] ?? []
        if sectionClaims.contains(where: { $0.statement.localizedStandardContains(term) }) { return true }
        return (reading.sectionActions[section.id] ?? []).contains { $0.title.localizedStandardContains(term) }
    }
    private var topicFilter: some View {
        HStack(spacing:12) {
            WorkspaceSearchField(text:$localFilter,placeholder:"筛选小主题、观点与原话")
                .frame(maxWidth:360)
            if !filterTerm.isEmpty {
                Text("\(filteredSections.count) / \(sections.count) 个小主题").vosFont(WorkspaceText.meta.size, monospacedDigit: true).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
        }
    }
    // A shared recording alone does not prove a topic relationship. Only show
    // followups anchored to a claim explicitly assigned to this topic.
    private var connections: [ReflectionConnection] {
        (focus?.connections ?? []).filter { claimIDs.contains($0.update.claimID) }.sorted {
            connectionDate($0) > connectionDate($1)
        }
    }
    private struct AdjacentTopic: Identifiable {
        let topic: ReflectionQuestion
        let sharedCount: Int
        var id: String { topic.id }
    }
    private var adjacentTopics: [AdjacentTopic] {
        let selected = reading.sourceIDs
        guard !selected.isEmpty else { return [] }
        let counts = TopicAdjacency.sharedCounts(selectedTopicID: topic.id, selectedSourceIDs: selected,
                                                 topics: model.workspaceTopics,
                                                 topicSources: model.workspaceTopicSources)
        return model.workspaceTopics.compactMap { other -> AdjacentTopic? in
            guard let shared = counts[other.id], shared > 0 else { return nil }
            return AdjacentTopic(topic: other, sharedCount: shared)
        }.sorted { left, right in
            if left.sharedCount != right.sharedCount { return left.sharedCount > right.sharedCount }
            return left.topic.title.localizedStandardCompare(right.topic.title) == .orderedAscending
        }
    }
    @ViewBuilder private var adjacentTopicsSection: some View {
        if !adjacentTopics.isEmpty {
            WorkspaceSection(title:"相邻主题",icon:"point.3.connected.trianglepath.dotted",count:adjacentTopics.count) {
                ForEach(adjacentTopics) { adjacent in
                    WorkspaceRow(title:adjacent.topic.title,subtitle:"共享 \(adjacent.sharedCount) 份材料",icon:"circle.hexagongrid",trailing:"查看") { openTopic(adjacent.topic.id) }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:WorkspaceMetrics.sectionGap) {
            if topic.organizationStale == true { TopicStaleBanner() }
            if bodyPending { topicPendingBanner }
            if mode == "概览" { introduction }
            if mode != "行动与结果" {
                if sections.isEmpty { preparingCards }
                else {
                    if showsTopicFilter { topicFilter }
                    if mode == "概览" {
                        DisclosureGroup(isExpanded:$showingStructure) {
                            structure.padding(.top,16)
                        } label: {
                            HStack(spacing:8) {
                                Label("内容结构",systemImage:"point.3.connected.trianglepath.dotted").vosFont(WorkspaceText.meta.size, weight: .medium)
                                WorkspaceBadge(text:"\(sections.count) 个小主题")
                            }
                        }
                    } else { structure }
                    if mode == "概览" { overviewReadingCards } else { readingCards }
                }
                adjacentTopicsSection
                connectionsSection
                TopicUnlinkedReferencesSection(model:model,topic:topic)
                if mode == "认识与问题" { questions; personalEntries }
            }
            if mode == "概览" { overviewActions; questions }
            if mode == "行动与结果" { actionResults }
        }
        .onChange(of: sections.map(\.id)) { _,ids in if let selectedSection,!ids.contains(selectedSection) { self.selectedSection=nil } }
        .sheet(item:$correctingClaim) { claim in ClaimCorrectionView(claim:claim,model:model) { correctingClaim=nil } }
        .alert("停止使用这条理解？", isPresented:$confirmingRejection, presenting:pendingRejection) { claim in
            Button("停止使用", role:.destructive) { Task { _=await model.review(claim, action:.reject) } }
            Button("取消", role:.cancel) {}
        } message: { _ in
            Text("确定后，这份理解将不再用于主题阅读与相关行动。原文与处理历史会保留。")
        }
    }

    private var introduction: some View {
        WorkspaceCard {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Label("主题速览",systemImage:"sparkles").vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(.secondary)
                    Spacer()
                    Text("更新于 " + date(topic.updatedAt)).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
                if level == .clue {
                    HStack(spacing:8) {
                        WorkspaceBadge(text:"线索")
                        Text("尚未达到主题判据：至少 \(TopicLevel.minimumMaterials) 份材料且跨 \(TopicLevel.minimumDistinctDays) 个日期").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    }
                }
                if let summary=topic.organization?.summary {
                    WorkspaceExpandableText(text:summary,label:"主题概述",lines:4,size:WorkspaceText.body.size)
                } else {
                    Text("在这里接续这个主题的认识、问题和实践。").vosFont(WorkspaceText.body)
                }
                if sectionsWithoutClaims {
                    Text("这些小节的原文已保留，尚未关联观点").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var topicPendingBanner: some View {
        HStack(spacing:12) {
            WorkspaceNoticeText(message:"主题整理未完成 · 正文待补齐",severity:.info)
            if model.organizingTopics { ProgressView().controlSize(.small) }
            else { Button("补齐正文") { model.queueTopicOrganization(topUp:true) }.buttonStyle(.workspaceSecondaryCompact).disabled(!model.modelConfigured) }
        }
    }

    private var preparingCards: some View {
        WorkspaceCard {
            VStack(alignment:.leading,spacing:12) {
                Label(model.organizingTopics ? "正在整理小主题与阅读卡片" : bodyPending ? "正文整理中" : "这份主题尚未生成结构卡片",systemImage:"rectangle.3.group").vosFont(WorkspaceText.meta.size, weight: .semibold)
                Text(bodyPending ? "正文分批生成，已完成的部分会保留。" : "原文已保留；整理后会显示要点、原话与行动。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                if model.organizingTopics { ProgressView().controlSize(.small) }
                else if bodyPending {
                    Button("补齐正文") { model.queueTopicOrganization(topUp:true) }.buttonStyle(.workspacePrimary).disabled(!model.modelConfigured)
                    if !model.modelConfigured {
                        HStack(spacing:8) {
                            Text("整理需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                            Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceQuietCompact)
                        }
                    }
                }
                else {
                    Button("整理主题卡片") { model.queueTopicOrganization(retry:true) }.buttonStyle(.workspacePrimary).disabled(!model.modelConfigured)
                    if !model.modelConfigured {
                        HStack(spacing:8) {
                            Text("整理需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                            Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceQuietCompact)
                        }
                    }
                }
                if !model.topicOrganizationStatus.isEmpty { Text(model.topicOrganizationStatus).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
    }

    private var structure: some View {
        WorkspaceCard {
            VStack(alignment:.leading,spacing:12) {
                WorkspaceSectionHeading(title:"内容结构") {
                    if selectedSection != nil { Button("查看全部") { selectedSection=nil }.buttonStyle(.workspaceQuietCompact) }
                }
                VStack(spacing:0) {
                    Button { selectedSection=nil } label: {
                        Label(topic.title,systemImage:"circle.hexagongrid").vosFont(WorkspaceText.rowTitle)
                            .padding(.horizontal,20).padding(.vertical,12).frame(maxWidth:.infinity)
                            .background(palette.selection,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.sectionRadius))
                            .overlay { RoundedRectangle(cornerRadius:WorkspaceMetrics.sectionRadius).strokeBorder(palette.border,lineWidth:1) }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Rectangle().fill(palette.border).frame(width:1,height:16)
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:210),spacing:12)],alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                        ForEach(Array(listedSections.enumerated()),id:\.element.id) { index,section in
                            Button { selectedSection = selectedSection == section.id ? nil : section.id } label: {
                                HStack(alignment:.top,spacing:8) {
                                    Text(String(format:"%02d",index+1)).vosFont(WorkspaceText.caption.size, weight: .medium, design: .monospaced).foregroundStyle(.secondary)
                                    Text(section.title).vosFont(WorkspaceText.rowTitle).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                                    Spacer(minLength:0)
                                }.padding(12).frame(maxWidth:.infinity,minHeight:60,alignment:.topLeading)
                                    .background(selectedSection == section.id ? palette.selection : hoveredSectionID == section.id || keyboardSectionID == section.id ? palette.selection.opacity(0.5) : palette.canvas,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
                                    .overlay { RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius).strokeBorder(selectedSection == section.id ? palette.accent : keyboardSectionID == section.id ? palette.focusRing : palette.border,lineWidth:1) }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityValue(selectedSection == section.id ? "已选择" : "")
                                .accessibilityLabel("小主题：\(section.title)，\(sectionClaimCount(section)) 条认识")
                                .onHover { inside in hoveredSectionID = inside ? section.id : (hoveredSectionID == section.id ? nil : hoveredSectionID) }
                        }
                    }
                }
                if filteredSections.isEmpty && !filterTerm.isEmpty { Text("没有匹配的小主题。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                if filteredSections.count > 6 { Button(showingAllSections ? "收起结构" : "展开全部 \(filteredSections.count) 个小主题") { showingAllSections.toggle() }.buttonStyle(.workspaceQuietCompact) }
            }
        }
        .focusable()
        .focused($structureFocused)
        .focusEffectDisabled()
        .onKeyPress { handleStructureKey($0) }
        .onChange(of: selectedSection) { _, _ in structureFocused=true }
        .onAppear { requestStructureFocus() }
    }

    @ViewBuilder private var readingCards: some View {
        if displayedSections.isEmpty && !filterTerm.isEmpty {
            Text("没有匹配的小主题。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns:[GridItem(.adaptive(minimum:290 * min(max(scale,1),1.25)),spacing:WorkspaceMetrics.groupGap)],alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                ForEach(displayedSections) { section in readingCard(section) }
            }
        }
    }

    @ViewBuilder private var overviewReadingCards: some View {
        if displayedSections.isEmpty && !filterTerm.isEmpty {
            Text("没有匹配的小主题。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns:[GridItem(.adaptive(minimum:290 * min(max(scale,1),1.25)),spacing:WorkspaceMetrics.groupGap)],alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                ForEach(Array(displayedSections.prefix(3))) { section in readingCard(section) }
            }
            Button("查看全部 \(sections.count) 张卡片",systemImage:"text.book.closed") { showUnderstanding() }
                .buttonStyle(.workspaceSecondary)
        }
    }

    private func readingCard(_ section:TopicReadingSection) -> some View {
        let sectionClaims=reading.sectionClaims[section.id] ?? []
        let previewClaims=Array(sectionClaims.prefix(2))
        let sectionActions=reading.sectionActions[section.id] ?? []
        return WorkspaceCard {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Spacer()
                    Text(String(format:"%02d",(reading.sectionPosition[section.id] ?? 0)+1)).vosFont(WorkspaceText.caption.size, weight: .medium, design: .monospaced).foregroundStyle(.secondary)
                }
                Text(section.title).vosFont(WorkspaceText.sectionTitle).fixedSize(horizontal:false,vertical:true).accessibilityAddTraits(.isHeader)
                WorkspaceExpandableText(text:section.summary,label:"小节内容",lines:5,size:WorkspaceText.body.size)
                if !previewClaims.isEmpty {
                    VStack(alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                        ForEach(previewClaims) { claim in
                            VStack(alignment:.leading,spacing:4) {
                                Text(ownership(claim)).vosFont(WorkspaceText.caption.size, weight: .semibold).foregroundStyle(.secondary)
                                Text(claim.statement).vosFont(WorkspaceText.body).lineLimit(scale >= 1.3 ? 3 : 2)
                            }
                        }
                    }
                }
                if !sectionClaims.isEmpty {
                    DisclosureGroup {
                        VStack(alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                            ForEach(sectionClaims) { claim in
                                VStack(alignment:.leading,spacing:8) {
                                    Text(ownership(claim)).vosFont(WorkspaceText.caption.size, weight: .semibold).foregroundStyle(.secondary)
                                    Text(claim.statement).vosFont(WorkspaceText.body).textSelection(.enabled)
                                    HStack {
                                        Button("更正理解或归属",systemImage:"pencil") { correctingClaim=claim }.buttonStyle(.workspaceQuietCompact)
                                        Button("停止使用") { pendingRejection=claim;confirmingRejection=true }.buttonStyle(.workspaceQuietCompact)
                                    }.disabled(model.reviewingClaim)
                                }
                            }
                        }.padding(.top,12)
                    } label: {
                        HStack(spacing:8) {
                            Text("相关观点").vosFont(WorkspaceText.meta)
                            WorkspaceBadge(text:String(sectionClaims.count))
                        }
                    }
                }
                if !sectionActions.isEmpty {
                    DisclosureGroup {
                        VStack(alignment:.leading,spacing:8) { ForEach(sectionActions) { action in taskButton(action) } }.padding(.top,12)
                    } label: {
                        HStack(spacing:8) {
                            Text("相关行动与问题").vosFont(WorkspaceText.meta)
                            WorkspaceBadge(text:String(sectionActions.count))
                        }
                    }
                }
                WorkspaceListDivider()
                DisclosureGroup {
                    VStack(alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                        ForEach(Array(section.evidence.enumerated()),id:\.offset) { _,evidence in
                            VStack(alignment:.leading,spacing:8) {
                                Text(evidence.quote).vosFont(WorkspaceText.body).foregroundStyle(.secondary).textSelection(.enabled)
                                Button(model.sourcePageIndex.recordsByID[evidence.sourceID]?.displayTitle ?? "打开来源") { openSource(evidence.sourceID) }.buttonStyle(.workspaceQuietCompact)
                            }
                        }
                    }.padding(.top,12)
                } label: {
                    HStack(spacing:8) {
                        Text("查看原话依据").vosFont(WorkspaceText.meta)
                        WorkspaceBadge(text:String(section.evidence.count))
                    }
                }
                Button("讨论这个小主题",systemImage:"bubble.left.and.bubble.right") {
                    discuss("围绕“" + section.title + "”继续讨论。请结合现有原话，区分已有结论、不同意见与需要验证的部分。")
                }.buttonStyle(.workspaceQuietCompact)
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }
    }

    @ViewBuilder private var overviewActions: some View {
        let open=tasks.filter { $0.state == "open" }
        if !open.isEmpty {
            Button { showActions() } label: {
                HStack(spacing:8) {
                    Text("查看 \(open.count) 条开放行动")
                    Image(systemName:"chevron.right").vosFont(WorkspaceText.caption)
                }.vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(palette.accent).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        if !outcomes.isEmpty || !deliveries.isEmpty {
            WorkspaceSection(title:"最近带回来的结果",icon:"tray.and.arrow.down",actionTitle:"查看全部",action:showActions) {
                ForEach(Array(outcomes.suffix(2))) { outcome in outcomeCard(outcome) }
                ForEach(Array(deliveries.prefix(2))) { result in deliveryButton(result) }
            }
        }
    }

    @ViewBuilder private var questions: some View {
        let questions=topic.organization?.questions ?? []
        if !questions.isEmpty {
            WorkspaceSection(title:"值得继续的问题",icon:"questionmark.bubble",count:questions.count) {
                ForEach(questions,id:\.self) { question in
                    Button { discuss(question) } label: {
                        HStack(alignment:.top,spacing:12) {
                            Image(systemName:"questionmark.bubble").foregroundStyle(palette.action)
                            Text(question).vosFont(WorkspaceText.rowTitle).multilineTextAlignment(.leading)
                            Spacer(minLength:4)
                            Image(systemName:"arrow.up.right").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(hoveredQuestion == question ? palette.selection : palette.surface,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.sectionRadius)).overlay { RoundedRectangle(cornerRadius:WorkspaceMetrics.sectionRadius).strokeBorder(palette.border,lineWidth:1) }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help("带上当前主题继续讨论")
                        .onHover { inside in hoveredQuestion = inside ? question : (hoveredQuestion == question ? nil : hoveredQuestion) }
                }
            }
        }
    }

    @ViewBuilder private var connectionsSection: some View {
        if !connections.isEmpty {
            WorkspaceSection(title:"后来的表达接上了什么",icon:"arrow.triangle.branch",count:connections.count,
                             actionTitle:mode == "概览" ? "完整脉络" : "",action:mode == "概览" ? showUnderstanding : nil) {
                ForEach(mode == "概览" ? Array(connections.prefix(3)) : connections) { connection in
                    VStack(alignment:.leading,spacing:12) {
                        HStack {
                            Label(relation(connection.update.relation),systemImage:"quote.bubble")
                            Spacer()
                            Text(connectionDate(connection).formatted(date:.abbreviated,time:.omitted))
                        }.vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        WorkspaceExpandableText(text:connection.update.understanding,label:"关联分析",lines:3,size:WorkspaceText.body.size)
                        DisclosureGroup("对照前后原话") {
                            VStack(alignment:.leading,spacing:12) {
                                Text("此前：" + connection.update.historicalQuote).textSelection(.enabled)
                                if let sourceID=historicalSourceID(connection) {
                                    Button("查看此前的来源") { openSource(sourceID) }.buttonStyle(.workspaceQuietCompact)
                                }
                                Text("后来：" + connection.update.currentQuote).textSelection(.enabled)
                                Button("查看后来的表达") { openSource(connection.sourceID) }.buttonStyle(.workspaceQuietCompact)
                                Text("关联依据：" + connection.update.reason).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(.top,12)
                        }.vosFont(WorkspaceText.meta)
                    }.padding(.vertical,WorkspaceMetrics.rowGap)
                    if connection.id != (mode == "概览" ? Array(connections.prefix(3)) : connections).last?.id { WorkspaceListDivider() }
                }
            }
        }
    }

    private func connectionDate(_ connection:ReflectionConnection) -> Date {
        guard let source=model.sourcePageIndex.recordsByID[connection.sourceID] else { return .distantPast }
        return source.expressedDate ?? ConversationReflectionFocus.date(source.createdAt) ?? .distantPast
    }

    private func historicalSourceID(_ connection:ReflectionConnection) -> String? {
        let sourceIDs=model.sourcePageIndex.claim(for: connection.update.claimID)?.references.map(\.sourceID) ?? []
        return sourceIDs.first { id in model.sourcePageIndex.recordsByID[id]?.transcript?.contains(connection.update.historicalQuote) == true }
    }

    private func relation(_ value:String) -> String {
        switch value { case "supports": "再次表达支持";case "qualifies": "补充了条件";case "contradicts": "表达了不同看法";default: "继续了这条思考" }
    }

    private var actionResults: some View {
        VStack(alignment:.leading,spacing:WorkspaceMetrics.sectionGap) {
            if sections.isEmpty { preparingCards }
            let open=tasks.filter { $0.state == "open" }
            let completed=tasks.filter { $0.state == "completed" }
            if !open.isEmpty {
                WorkspaceSection(title:"待跟进",icon:"circle",count:open.count) { ForEach(open) { action in actionWithResults(action) } }
            }
            if !completed.isEmpty {
                WorkspaceSection(title:"已完成的行动",icon:"checkmark.circle",count:completed.count) { ForEach(completed) { action in actionWithResults(action) } }
            }
            let intentions=actions.filter { $0.kind != "task" }
            if !intentions.isEmpty {
                WorkspaceSection(title:"探索意图",icon:"lightbulb",count:intentions.count) { ForEach(intentions) { action in taskButton(action).padding(.vertical,WorkspaceMetrics.rowGap) } }
            }
            if !deliveries.isEmpty {
                WorkspaceSection(title:"AI 的交付",icon:"doc.text",count:deliveries.count) { ForEach(deliveries) { result in deliveryButton(result) } }
            }
            if !sections.isEmpty && actions.isEmpty && deliveries.isEmpty { Text("这个主题目前没有待办或结果。").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var personalEntries: some View {
        let entries=focus?.question?.entries ?? []
        if !entries.isEmpty {
            WorkspaceSection(title:"你留下的认识与实践",icon:"quote.bubble",count:entries.count) {
                ForEach(entries) { entry in
                    VStack(alignment:.leading,spacing:12) {
                        Text(entry.kind.label + " · " + date(entry.createdAt)).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        WorkspaceExpandableText(text:entry.text,label:"完整记录",size:WorkspaceText.body.size)
                        if !entry.unavailableSourceIDs.isEmpty { Text("部分关联材料已暂停使用，此处保留当时的表达。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                        Button("查看记录原文") { openSource(entry.sourceID) }.buttonStyle(.workspaceQuietCompact)
                    }.padding(.vertical,WorkspaceMetrics.rowGap)
                }
            }
        }
    }

    private func actionWithResults(_ action:ActionRecord) -> some View {
        let feedback=outcomes.filter { $0.actionID == action.id && $0.actionVersion == action.version }
        return VStack(alignment:.leading,spacing:12) {
            taskButton(action)
            if feedback.isEmpty { Text(action.state == "completed" ? "已完成，尚未记录实际效果" : "还没有登记实际进展").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
            ForEach(feedback) { outcome in outcomeCard(outcome) }
        }.padding(.vertical,WorkspaceMetrics.rowGap)
    }

    private func taskButton(_ action:ActionRecord) -> some View {
        Button { openTask(action.id) } label: {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:action.state == "completed" ? "checkmark.circle.fill" : action.kind == "task" ? "circle" : "lightbulb").foregroundStyle(palette.action)
                    .accessibilityHidden(true)
                VStack(alignment:.leading,spacing:4) {
                    Text(action.title).vosFont(WorkspaceText.rowTitle).multilineTextAlignment(.leading)
                    Text(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action)).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
                Spacer(minLength:0)
                Image(systemName:"chevron.right").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }.padding(10).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                .workspaceHoverHighlight(cornerRadius:WorkspaceMetrics.panelRadius)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel(taskButtonAccessibilityLabel(action))
        }.buttonStyle(.plain)
    }

    private func taskButtonAccessibilityLabel(_ action:ActionRecord) -> String {
        let state = action.state == "completed" ? "已完成" : action.kind == "task" ? "待办" : "想法"
        return [action.title, state, model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action)]
            .joined(separator:"，")
    }

    private func outcomeCard(_ outcome:ActionFeedbackRecord) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Label("你的实际记录 · " + date(outcome.createdAt),systemImage:"quote.bubble").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            if let action=reading.actionsByID[outcome.actionID] {
                Button("回应的行动：" + action.title) { openTask(action.id) }.buttonStyle(.workspaceQuietCompact)
            }
            WorkspaceExpandableText(text:outcome.text,label:"结果记录",size:WorkspaceText.body.size)
            Button("查看记录来源") { openSource(outcome.recordingSourceID ?? outcome.sourceID) }.buttonStyle(.workspaceQuietCompact)
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(palette.outcome.opacity(0.07),in:RoundedRectangle(cornerRadius:WorkspaceMetrics.panelRadius)).padding(.vertical,8)
    }

    private func deliveryButton(_ result:AssistantExecutionRecord) -> some View {
        WorkspaceRow(title:result.title,subtitle:"AI 交付",icon:"doc.text",trailing:"阅读") { openDelivery(result.id) }
    }
    private func sectionClaimCount(_ section:TopicReadingSection) -> Int {
        reading.sectionClaims[section.id]?.count ?? 0
    }
    private func requestStructureFocus() {
        Task {
            try? await Task.sleep(for:.milliseconds(100))
            structureFocused=true
        }
    }
    private func handleStructureKey(_ press:KeyPress) -> KeyPress.Result {
        guard structureFocused, press.modifiers.isDisjoint(with:[.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        let ids=listedSections.map(\.id)
        switch press.key {
        case .downArrow, .upArrow:
            guard !ids.isEmpty else { return .ignored }
            let current=keyboardSectionID.flatMap { id in ids.firstIndex(of: id) }
            let next: Int
            if press.key == .upArrow { next=current.map { max(0,$0 - 1) } ?? ids.count - 1 }
            else { next=current.map { min(ids.count - 1,$0 + 1) } ?? 0 }
            keyboardSectionID=ids[next]
            return .handled
        case .return:
            guard let id=keyboardSectionID, ids.contains(id) else { return .ignored }
            selectedSection = selectedSection == id ? nil : id
            return .handled
        default:
            return .ignored
        }
    }
    private func ownership(_ claim:CandidateClaim) -> String {
        switch claim.ownership { case "user_tentative": "我的表达中提取"; case "external": "资料中的观点"; case "ai_candidate": "AI 分析与建议"; default: "内容归属待核对" }
    }
    private func date(_ value:String) -> String { ConversationReflectionFocus.date(value)?.formatted(date:.abbreviated,time:.omitted) ?? value }
}

struct TopicStaleBanner: View {
    var body: some View {
        WorkspaceNoticeText(message:"材料已更新，待重新整理",severity:.info)
    }
}

struct WorkspaceTopicTile: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var scale
    @State private var hovered = false
    let topic: ReflectionQuestion
    let sourceCount: Int
    let open: () -> Void
    var body: some View {
        Button(action:open) {
            WorkspaceCard {
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Image(systemName:"circle.hexagongrid").vosFont(18).foregroundStyle(palette.action)
                        Spacer()
                        Image(systemName:"arrow.up.right").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                    }
                    Text(topic.title).vosFont(WorkspaceText.rowTitle).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                    if topic.organizationStale == true { TopicStaleBanner() }
                    if topic.organization?.bodyPending == true {
                        WorkspaceBadge(text:"正文整理中")
                    }
                    if let summary=topic.organization?.summary, !summary.isEmpty {
                        Text(summary).vosFont(WorkspaceText.body).lineSpacing(4)
                            .foregroundStyle(palette.secondaryText).multilineTextAlignment(.leading)
                            .lineLimit(scale >= 1.3 ? 3 : 2)
                    }
                    Spacer(minLength:0)
                    HStack(spacing:16) {
                        Label("\(sourceCount) 份材料",systemImage:"doc.text")
                        if let count=topic.organization?.sections?.count { Label("\(count) 个小主题",systemImage:"square.grid.2x2") }
                    }.vosFont(WorkspaceText.meta).foregroundStyle(palette.tertiaryText)
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }
            .overlay {
                RoundedRectangle(cornerRadius:WorkspaceMetrics.sectionRadius)
                    .strokeBorder(hovered ? palette.accent : .clear,lineWidth:1)
            }
            .contentShape(RoundedRectangle(cornerRadius:WorkspaceMetrics.sectionRadius))
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}
