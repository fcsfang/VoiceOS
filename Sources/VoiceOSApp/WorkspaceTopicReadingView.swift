import SwiftUI
import VoiceOSCore

struct WorkspaceTopicReadingView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let topic: ReflectionQuestion
    let mode: String
    let focus: ConversationReflectionFocus?
    let openSource: (String) -> Void
    let openTask: (String) -> Void
    let openDelivery: (String) -> Void
    let discuss: (String) -> Void
    let showActions: () -> Void
    let showUnderstanding: () -> Void
    @State private var selectedSection: String?
    @State private var showingAllSections = false
    @State private var showingStructure = false
    @State private var correctingClaim: CandidateClaim?

    private var sections: [TopicReadingSection] { topic.organization?.sections ?? [] }
    private var claimIDs: Set<String> { Set(sections.flatMap(\.claimIDs)) }
    private var actionIDs: Set<String> { Set(sections.flatMap(\.actionIDs)) }
    private var claims: [CandidateClaim] { model.claims.filter { claimIDs.contains($0.id) && $0.validity == "current" && $0.reviewState != "rejected" } }
    private var actions: [ActionRecord] { model.actionRecords.filter { actionIDs.contains($0.id) && $0.validity == "current" && $0.state != "dismissed" } }
    private var tasks: [ActionRecord] { actions.filter { $0.kind == "task" } }
    private var deliveries: [AssistantExecutionRecord] {
        model.assistantExecutions.filter { $0.validity == "current" && $0.state == "completed" && ($0.questionID == topic.id || actionIDs.contains($0.actionID)) }
    }
    private var outcomes: [ActionFeedbackRecord] { (focus?.outcomes ?? []).filter { feedback in actionIDs.contains(feedback.actionID) && feedback.sourceState != "frozen" && actions.contains { $0.id == feedback.actionID && $0.version == feedback.actionVersion } } }
    private var displayedSections: [TopicReadingSection] { selectedSection.map { id in sections.filter { $0.id == id } } ?? sections }
    // A shared recording alone does not prove a topic relationship. Only show
    // followups anchored to a claim explicitly assigned to this topic.
    private var connections: [ReflectionConnection] {
        (focus?.connections ?? []).filter { claimIDs.contains($0.update.claimID) }.sorted {
            connectionDate($0) > connectionDate($1)
        }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:28) {
            if mode == "概览" { introduction }
            if mode != "行动与结果" {
                if sections.isEmpty { preparingCards }
                else {
                    if mode == "概览" {
                        DisclosureGroup(isExpanded:$showingStructure) {
                            structure.padding(.top,14)
                        } label: { Label("内容结构 · \(sections.count) 个小主题",systemImage:"point.3.connected.trianglepath.dotted").font(.system(size:14,weight:.medium)) }
                    } else { structure }
                    if mode == "概览" {
                        Button("阅读认识、原话与完整脉络",systemImage:"text.book.closed") { showUnderstanding() }
                            .buttonStyle(.bordered)
                    } else { readingCards }
                }
                connectionsSection
                if mode == "认识与问题" { questions; personalEntries }
            }
            if mode == "概览" { overviewActions; questions }
            if mode == "行动与结果" { actionResults }
        }
        .onChange(of: sections.map(\.id)) { _,ids in if let selectedSection,!ids.contains(selectedSection) { self.selectedSection=nil } }
        .sheet(item:$correctingClaim) { claim in ClaimCorrectionView(claim:claim,model:model) { correctingClaim=nil } }
    }

    private var introduction: some View {
        VStack(alignment:.leading,spacing:15) {
            HStack {
                Label("主题速览",systemImage:"sparkles").font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("更新于 " + date(topic.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
            if let summary=topic.organization?.summary {
                WorkspaceExpandableText(text:summary,label:"主题概述",lines:4,size:18)
            } else {
                Text("在这里接续这个主题的认识、问题和实践。").font(.system(size:19,weight:.medium))
            }
            if !sections.isEmpty {
                HStack(spacing:18) {
                    metric("内容小节",value:sections.count,icon:"square.grid.2x2")
                    metric("待办",value:tasks.filter { $0.state == "open" }.count,icon:"circle")
                    metric("完成记录",value:tasks.filter { $0.state == "completed" }.count,icon:"checkmark.circle")
                }
            }
            Text("AI 综合整理 · 每张卡片保留原话入口").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            .background(palette.surface,in:RoundedRectangle(cornerRadius:16))
            .overlay { RoundedRectangle(cornerRadius:16).strokeBorder(palette.border,lineWidth:1) }
    }

    private func metric(_ title:String,value:Int,icon:String) -> some View {
        Label("\(value) " + title,systemImage:icon).font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
    }

    private var preparingCards: some View {
        VStack(alignment:.leading,spacing:12) {
            Label(model.organizingTopics ? "正在整理小主题与阅读卡片" : "这份主题尚未生成结构卡片",systemImage:"rectangle.3.group").font(.headline)
            Text("完整材料已保留。整理后，每个小主题会展示自己的要点、原话和相关行动。").font(.callout).foregroundStyle(.secondary)
            if model.organizingTopics { ProgressView().controlSize(.small) }
            else { Button("整理主题卡片") { model.queueTopicOrganization(retry:true) }.disabled(!model.modelConfigured) }
            if !model.topicOrganizationStatus.isEmpty { Text(model.topicOrganizationStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(palette.surface,in:RoundedRectangle(cornerRadius:14))
    }

    private var structure: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("内容结构").font(.system(size:20,weight:.semibold))
                    Text("点选一个小主题，阅读下方对应卡片").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selectedSection != nil { Button("查看全部") { selectedSection=nil } }
            }
            VStack(spacing:0) {
                Button { selectedSection=nil } label: {
                    Label(topic.title,systemImage:"circle.hexagongrid").font(.system(size:14,weight:.semibold))
                        .padding(.horizontal,18).padding(.vertical,12).frame(maxWidth:.infinity)
                        .background(palette.selection,in:RoundedRectangle(cornerRadius:10)).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Rectangle().fill(palette.border).frame(width:1,height:18)
                LazyVGrid(columns:[GridItem(.adaptive(minimum:210),spacing:12)],alignment:.leading,spacing:12) {
                    ForEach(Array((showingAllSections ? sections : Array(sections.prefix(6))).enumerated()),id:\.element.id) { index,section in
                        Button { selectedSection = selectedSection == section.id ? nil : section.id } label: {
                            HStack(alignment:.top,spacing:10) {
                                Text(String(format:"%02d",index+1)).font(.system(size:11,weight:.medium,design:.monospaced)).foregroundStyle(.secondary)
                                Text(section.title).font(.system(size:13,weight:.medium)).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                                Spacer(minLength:0)
                            }.padding(13).frame(maxWidth:.infinity,minHeight:60,alignment:.topLeading)
                                .background(selectedSection == section.id ? palette.selection : palette.canvas,in:RoundedRectangle(cornerRadius:9))
                                .overlay { RoundedRectangle(cornerRadius:9).strokeBorder(selectedSection == section.id ? palette.accent : palette.border,lineWidth:1) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityValue(selectedSection == section.id ? "已选择" : "")
                    }
                }
            }
            if sections.count > 6 { Button(showingAllSections ? "收起结构" : "展开全部 \(sections.count) 个小主题") { showingAllSections.toggle() }.font(.caption) }
            Text("连线表示主题下的内容分组").font(.system(size:11)).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            .background(palette.surface,in:RoundedRectangle(cornerRadius:14))
    }

    private var readingCards: some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:290),spacing:16)],alignment:.leading,spacing:16) {
            ForEach(displayedSections) { section in readingCard(section) }
        }
    }

    private func readingCard(_ section:TopicReadingSection) -> some View {
        let sectionClaims=claims.filter { section.claimIDs.contains($0.id) }
        let sectionActions=actions.filter { section.actionIDs.contains($0.id) }
        return VStack(alignment:.leading,spacing:16) {
            HStack {
                Label("AI 整理",systemImage:"text.alignleft").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format:"%02d",(sections.firstIndex { $0.id == section.id } ?? 0)+1)).font(.system(size:12,weight:.medium,design:.monospaced)).foregroundStyle(.secondary)
            }
            Text(section.title).font(.system(size:19,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
            WorkspaceExpandableText(text:section.summary,label:"小节内容",lines:5,size:15)
            if !sectionClaims.isEmpty {
                DisclosureGroup("相关观点（\(sectionClaims.count)）") {
                    VStack(alignment:.leading,spacing:15) {
                        ForEach(sectionClaims) { claim in
                            VStack(alignment:.leading,spacing:6) {
                                Text(ownership(claim)).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                                Text(claim.statement).font(.callout).textSelection(.enabled)
                                HStack {
                                    Button("更正理解或归属",systemImage:"pencil") { correctingClaim=claim }
                                    Button("停止使用") { Task { _=await model.review(claim,action:.reject) } }
                                }.font(.caption).disabled(model.reviewingClaim)
                            }
                        }
                    }.padding(.top,12)
                }.font(.caption)
            }
            if !sectionActions.isEmpty {
                DisclosureGroup("相关行动与问题（\(sectionActions.count)）") {
                    VStack(alignment:.leading,spacing:8) { ForEach(sectionActions) { action in taskButton(action) } }.padding(.top,10)
                }.font(.caption)
            }
            Divider()
            DisclosureGroup("查看原话依据") {
                VStack(alignment:.leading,spacing:13) {
                    ForEach(Array(section.evidence.enumerated()),id:\.offset) { _,evidence in
                        VStack(alignment:.leading,spacing:8) {
                            Text(evidence.quote).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Button(model.records.first { $0.id == evidence.sourceID }?.workspaceTitle ?? "打开来源") { openSource(evidence.sourceID) }.font(.caption)
                        }
                    }
                }.padding(.top,12)
            }.font(.caption)
            Button("讨论这个小主题",systemImage:"bubble.left.and.bubble.right") {
                discuss("围绕“" + section.title + "”继续讨论。请结合现有原话，区分已有结论、不同意见与需要验证的部分。")
            }.font(.system(size:12,weight:.medium)).buttonStyle(.borderless)
        }.padding(22).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(palette.canvas,in:RoundedRectangle(cornerRadius:14))
            .overlay(alignment:.topLeading) { RoundedRectangle(cornerRadius:2).fill(palette.action.opacity(0.65)).frame(width:28,height:3).padding(.leading,22) }
            .overlay { RoundedRectangle(cornerRadius:14).strokeBorder(palette.border,lineWidth:1) }
    }

    @ViewBuilder private var overviewActions: some View {
        let next=tasks.filter { $0.state == "open" }
        if !next.isEmpty {
            WorkspaceSection(title:"可以接着做",subtitle:"你已记录的待办，完成情况单独保存",icon:"arrow.right.circle",count:next.count,actionTitle:"全部行动与结果",action:showActions) {
                ForEach(Array(next.prefix(3))) { action in taskButton(action).padding(.vertical,10) }
            }
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
            VStack(alignment:.leading,spacing:14) {
                    Text("值得继续的问题").font(.system(size:20,weight:.semibold))
                    Text("AI 根据材料提出的讨论方向，可结合你的实际经历继续。")
                        .font(.caption).foregroundStyle(.secondary)
                ForEach(questions,id:\.self) { question in
                    Button { discuss(question) } label: {
                        HStack(alignment:.top,spacing:13) {
                            Image(systemName:"questionmark.bubble").foregroundStyle(palette.action)
                            Text(question).font(.system(size:15,weight:.medium)).multilineTextAlignment(.leading)
                            Spacer(minLength:4)
                            Image(systemName:"arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(palette.surface,in:RoundedRectangle(cornerRadius:11)).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("带上当前主题继续讨论")
                }
            }
        }
    }

    @ViewBuilder private var connectionsSection: some View {
        if !connections.isEmpty {
            WorkspaceSection(title:"后来的表达接上了什么",subtitle:"AI 对前后原话的关联分析，保留双方依据",icon:"arrow.triangle.branch",count:connections.count,
                             actionTitle:mode == "概览" ? "完整脉络" : "",action:mode == "概览" ? showUnderstanding : nil) {
                ForEach(mode == "概览" ? Array(connections.prefix(3)) : connections) { connection in
                    VStack(alignment:.leading,spacing:12) {
                        HStack {
                            Label(relation(connection.update.relation),systemImage:"quote.bubble")
                            Spacer()
                            Text(connectionDate(connection).formatted(date:.abbreviated,time:.omitted))
                        }.font(.caption).foregroundStyle(.secondary)
                        WorkspaceExpandableText(text:connection.update.understanding,label:"关联分析",lines:3,size:15)
                        DisclosureGroup("对照前后原话") {
                            VStack(alignment:.leading,spacing:12) {
                                Text("此前：" + connection.update.historicalQuote).textSelection(.enabled)
                                if let sourceID=historicalSourceID(connection) {
                                    Button("查看此前的来源") { openSource(sourceID) }
                                }
                                Text("后来：" + connection.update.currentQuote).textSelection(.enabled)
                                Button("查看后来的表达") { openSource(connection.sourceID) }
                                Text("关联依据：" + connection.update.reason).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(.top,10)
                        }.font(.caption)
                    }.padding(.vertical,17)
                    if connection.id != (mode == "概览" ? Array(connections.prefix(3)) : connections).last?.id { Divider() }
                }
            }
        }
    }

    private func connectionDate(_ connection:ReflectionConnection) -> Date {
        guard let source=model.records.first(where: { $0.id == connection.sourceID }) else { return .distantPast }
        return source.expressedDate ?? ConversationReflectionFocus.date(source.createdAt) ?? .distantPast
    }

    private func historicalSourceID(_ connection:ReflectionConnection) -> String? {
        let sourceIDs=model.claims.first(where: { $0.id == connection.update.claimID })?.references.map(\.sourceID) ?? []
        return sourceIDs.first { id in model.records.first(where: { $0.id == id })?.transcript?.contains(connection.update.historicalQuote) == true }
    }

    private func relation(_ value:String) -> String {
        switch value { case "supports": "再次表达支持";case "qualifies": "补充了条件";case "contradicts": "表达了不同看法";default: "继续了这条思考" }
    }

    private var actionResults: some View {
        VStack(alignment:.leading,spacing:24) {
            if sections.isEmpty { preparingCards }
            let open=tasks.filter { $0.state == "open" }
            let completed=tasks.filter { $0.state == "completed" }
            if !open.isEmpty {
                WorkspaceSection(title:"待跟进",icon:"circle",count:open.count) { ForEach(open) { action in actionWithResults(action) } }
            }
            if !completed.isEmpty {
                WorkspaceSection(title:"已完成的行动",subtitle:"完成记录与实际效果分别呈现",icon:"checkmark.circle",count:completed.count) { ForEach(completed) { action in actionWithResults(action) } }
            }
            let intentions=actions.filter { $0.kind != "task" }
            if !intentions.isEmpty {
                WorkspaceSection(title:"探索意图",subtitle:"问题、目标和建议，尚未作为明确待办",icon:"lightbulb",count:intentions.count) { ForEach(intentions) { action in taskButton(action).padding(.vertical,12) } }
            }
            if !deliveries.isEmpty {
                WorkspaceSection(title:"AI 的交付",subtitle:"可阅读和继续讨论，实际采纳与效果以你的记录为准",icon:"doc.text",count:deliveries.count) { ForEach(deliveries) { result in deliveryButton(result) } }
            }
            if !sections.isEmpty && actions.isEmpty && deliveries.isEmpty { Text("这个主题目前没有明确待办或结果。认识、疑问和感受仍保留在“认识与问题”，无需为了记录它们而创建任务。").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var personalEntries: some View {
        let entries=focus?.question?.entries ?? []
        if !entries.isEmpty {
            WorkspaceSection(title:"你留下的认识与实践",icon:"quote.bubble",count:entries.count) {
                ForEach(entries) { entry in
                    VStack(alignment:.leading,spacing:10) {
                        Text(entry.kind.label + " · " + date(entry.createdAt)).font(.caption).foregroundStyle(.secondary)
                        WorkspaceExpandableText(text:entry.text,label:"完整记录",size:16)
                        if !entry.unavailableSourceIDs.isEmpty { Text("部分关联材料已暂停使用，此处保留当时的表达。").font(.caption).foregroundStyle(.secondary) }
                        Button("查看记录原文") { openSource(entry.sourceID) }.font(.caption)
                    }.padding(.vertical,16)
                }
            }
        }
    }

    private func actionWithResults(_ action:ActionRecord) -> some View {
        let feedback=outcomes.filter { $0.actionID == action.id && $0.actionVersion == action.version }
        return VStack(alignment:.leading,spacing:12) {
            taskButton(action)
            if feedback.isEmpty { Text(action.state == "completed" ? "已完成，尚未记录实际效果" : "还没有登记实际进展").font(.caption).foregroundStyle(.secondary) }
            ForEach(feedback) { outcome in outcomeCard(outcome) }
        }.padding(.vertical,16)
    }

    private func taskButton(_ action:ActionRecord) -> some View {
        Button { openTask(action.id) } label: {
            HStack(alignment:.top,spacing:11) {
                Image(systemName:action.state == "completed" ? "checkmark.circle.fill" : action.kind == "task" ? "circle" : "lightbulb").foregroundStyle(palette.action)
                VStack(alignment:.leading,spacing:5) {
                    Text(action.title).font(.system(size:14,weight:.medium)).multilineTextAlignment(.leading)
                    Text(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength:0)
                Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func outcomeCard(_ outcome:ActionFeedbackRecord) -> some View {
        VStack(alignment:.leading,spacing:9) {
            Label("你的实际记录 · " + date(outcome.createdAt),systemImage:"quote.bubble").font(.caption).foregroundStyle(.secondary)
            if let action=actions.first(where: { $0.id == outcome.actionID }) {
                Button("回应的行动：" + action.title) { openTask(action.id) }.font(.caption)
            }
            WorkspaceExpandableText(text:outcome.text,label:"结果记录",size:15)
            Button("查看记录来源") { openSource(outcome.recordingSourceID ?? outcome.sourceID) }.font(.caption)
        }.padding(15).frame(maxWidth:.infinity,alignment:.leading).background(palette.outcome.opacity(0.07),in:RoundedRectangle(cornerRadius:10)).padding(.vertical,8)
    }

    private func deliveryButton(_ result:AssistantExecutionRecord) -> some View {
        WorkspaceRow(title:result.title,subtitle:"AI 交付 · 实践效果见实际记录",icon:"doc.text",trailing:"阅读") { openDelivery(result.id) }
    }
    private func ownership(_ claim:CandidateClaim) -> String {
        switch claim.ownership { case "user_tentative": "我的表达中提取"; case "external": "资料中的观点"; case "ai_candidate": "AI 分析与建议"; default: "内容归属待核对" }
    }
    private func date(_ value:String) -> String { ConversationReflectionFocus.date(value)?.formatted(date:.abbreviated,time:.omitted) ?? value }
}

struct WorkspaceTopicTile: View {
    @Environment(\.workspacePalette) private var palette
    let topic: ReflectionQuestion
    let sourceCount: Int
    let open: () -> Void
    var body: some View {
        Button(action:open) {
            VStack(alignment:.leading,spacing:15) {
                HStack {
                    Image(systemName:"circle.hexagongrid").font(.system(size:18)).foregroundStyle(palette.action)
                    Spacer()
                    Image(systemName:"arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
                Text(topic.title).font(.system(size:20,weight:.semibold)).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                if let summary=topic.organization?.summary {
                    Text(summary).font(.system(size:14)).lineSpacing(4).foregroundStyle(.secondary).multilineTextAlignment(.leading).lineLimit(3)
                }
                Spacer(minLength:0)
                HStack(spacing:15) {
                    Label("\(sourceCount) 份材料",systemImage:"doc.text")
                    if let count=topic.organization?.sections?.count { Label("\(count) 个小主题",systemImage:"square.grid.2x2") }
                }.font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                .background(palette.surface,in:RoundedRectangle(cornerRadius:15))
                .overlay { RoundedRectangle(cornerRadius:15).strokeBorder(palette.border,lineWidth:1) }
                .contentShape(RoundedRectangle(cornerRadius:15))
        }.buttonStyle(.plain)
    }
}
