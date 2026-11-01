import SwiftUI
import VoiceOSCore

private struct AtlasNode: Identifiable {
    let id: String
    let lane: Int
    let title: String
    let label: String
    let context: Bool
    var sourceID: String? = nil
    var claimID: String? = nil
    var actionID: String? = nil
    var feedback: ActionFeedbackRecord? = nil
    var completion: ReflectionCompletion? = nil
}
private struct AtlasEdge: Identifiable {
    let from: String
    let to: String
    let label: String
    var connection: ReflectionConnection? = nil
    var id: String { from + ":" + to + ":" + (connection?.id ?? label) }
}

struct ReflectionTimelineView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    var embeddedTopicID: String? = nil
    var openSource: ((String) -> Void)? = nil
    let dismiss: () -> Void
    let discuss: (CandidateClaim) -> Void
    let reflect: (ConversationReflectionFocus, String) async -> Bool
    @State private var periodic = false
    @State private var topics: [ReflectionQuestion] = []
    @State private var selectedTopicID: String?
    @State private var period = ReflectionPeriod.week
    @State private var anchor = Date()
    @State private var focus: ConversationReflectionFocus?
    @State private var error: String?
    @State private var loading = false
    @State private var timeline = false
    @State private var query = ""
    @State private var selection: String?
    @State private var scale = 0.8
    @State private var graphPosition = ScrollPosition(edge: .top)
    @State private var graphViewport = CGSize.zero
    @State private var relatedOnly = false
    @State private var showsQuestions = false
    @State private var showsChanges = false
    @State private var changeID: String?
    private var selectedTopic: ReflectionQuestion? { topics.first { $0.id == (embeddedTopicID ?? selectedTopicID) } ?? (embeddedTopicID == nil ? topics.first : nil) }
    private var reflectionKey: String { periodic ? intervalKey : "topic:" + (selectedTopic?.id ?? "empty") }
    private var interval: DateInterval { period.interval(containing: anchor) }
    private var intervalKey: String { period.rawValue + String(interval.start.timeIntervalSince1970) }
    private var dateLabel: String {
        let end = interval.end.addingTimeInterval(-1)
        switch period {
        case .day: return interval.start.formatted(.dateTime.year().month().day().weekday())
        case .week: return interval.start.formatted(.dateTime.year().month().day()) + " — " + end.formatted(.dateTime.month().day())
        case .month: return interval.start.formatted(.dateTime.year().month(.wide))
        }
    }
    private var draft: String {
        if !periodic, let focus { return focus.topicReviewPrompt }
        return period.reviewPrompt(dateLabel: dateLabel)
    }
    private var periodPurpose: String {
        if !periodic { return "沿着一个主题，看见跨越时间的认识、行动与结果。" }
        return switch period {
        case .day: "找回这一天值得留下的现场，与当时的想法。"
        case .week: "把这一周的线索连起来，找到分歧与下一个问题。"
        case .month: "看见认识如何变化，以及哪些判断有了实践依据。"
        }
    }
    var body: some View {
        Group {
            if embeddedTopicID != nil && showsChanges, let focus {
                ReflectionChangeView(model: model, focus: focus, selectedConnectionID: changeID,
                    embedded: true, close: { showsChanges = false }, openSource: openSource,
                    reflect: reflect, dismissAtlas: dismiss)
                    .frame(height: 720)
            } else { atlas }
        }
        .task { await loadTopics() }
        .task(id: reflectionKey) { await reload() }
        .sheet(isPresented: $showsQuestions, onDismiss: { Task { await loadTopics(); await reload() } }) {
            ReflectionQuestionsView(model: model, period: period, anchor: anchor, reflect: reflect, dismissAtlas: dismiss, initialQuestionID: selectedTopic?.id, selectTopic: { selectedTopicID = $0 })
        }
        .sheet(isPresented: Binding(get: { embeddedTopicID == nil && showsChanges }, set: { showsChanges = $0 })) {
            if let focus {
                ReflectionChangeView(model: model, focus: focus, selectedConnectionID: changeID, reflect: reflect, dismissAtlas: dismiss)
            }
        }
    }
    private var atlas: some View {
        VStack(spacing: 0) {
            if embeddedTopicID == nil { header }
            else {
                HStack {
                    Text("主题里的材料、认识、行动与结果").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("查看方式",selection:$timeline) { Text("图谱").tag(false);Text("时间线").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width:140)
                }.padding(14)
            }
            Divider().overlay(palette.text.opacity(0.12))
            if loading && focus == nil {
                ProgressView(periodic ? "整理这个周期的关系…" : "连接这个主题的完整脉络…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let focus {
                if timeline {
                    ReflectionEventListView(model: model, dismiss: dismiss, discuss: discuss, focus: focus,openSource:openSource)
                } else {
                    GeometryReader { geometry in
                        if embeddedTopicID != nil && geometry.size.width < 800 {
                            VStack(spacing:0) {
                                graph(focus).frame(maxWidth:.infinity,maxHeight:.infinity)
                                Divider()
                                inspector(focus).frame(height:240)
                            }
                        } else {
                            HStack(spacing: 0) {
                                graph(focus).frame(maxWidth: .infinity, maxHeight: .infinity)
                                Divider()
                                inspector(focus).frame(width: 282)
                            }
                        }
                    }
                }
            } else if !periodic && topics.isEmpty && error == nil {
                VStack(spacing: 18) {
                    ContentUnavailableView("从一个持续关心的主题开始", systemImage: "point.3.connected.trianglepath.dotted", description: Text("例如：Agent 记忆、我的学习方法，或一个还没有答案的问题。\n把资料、认识与结果连起来，跨越周与月继续探索。"))
                    Button("建立主题或问题") { showsQuestions = true }
                        .buttonStyle(.borderedProminent).tint(palette.accent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("暂时无法打开回顾", systemImage: "arrow.triangle.branch", description: Text(error ?? "请刷新资料"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error { Text(error).font(.callout).foregroundStyle(palette.danger).padding(10) }
            HStack {
                Label("实线：来源与行动关系", systemImage: "line.diagonal")
                Text("┄ AI 思想关联 · 可查看前后原话")
                if embeddedTopicID == nil { Spacer();Text("点击节点与关系查看依据") }
            }.font(.caption).foregroundStyle(palette.text.opacity(0.65)).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .foregroundStyle(palette.text).background(palette.canvas)
        .frame(width: embeddedTopicID == nil ? 1100 : nil, height: embeddedTopicID == nil ? 760 : 720)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                WorkspaceHero(eyebrow: "REFLECTION ATLAS", title: "认知地图", subtitle: periodPurpose)
                Spacer()
                Button { showsQuestions = true } label: { Label("主题与问题", systemImage: "square.stack") }
                Button { changeID = nil; showsChanges = true } label: { Label("认识对照", systemImage: "rectangle.split.2x1") }
                    .disabled(focus == nil || loading)
                Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 14) {
                Picker("探索方式", selection: $periodic) {
                    Text("主题探索").tag(false)
                    Text("周期回顾").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 190)
                if periodic {
                    Picker("回顾周期", selection: $period) {
                        ForEach(ReflectionPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
                    HStack(spacing: 8) {
                        Button { shift(-1) } label: { Image(systemName: "chevron.left") }.help("上一个周期").accessibilityLabel("上一个周期")
                        Text(dateLabel).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Button { shift(1) } label: { Image(systemName: "chevron.right") }.help("下一个周期").accessibilityLabel("下一个周期")
                    }.buttonStyle(.plain)
                    DatePicker("选择日期", selection: $anchor, displayedComponents: .date).labelsHidden().frame(width: 100)
                } else if !topics.isEmpty {
                    Picker("探索主题", selection: Binding(get: { selectedTopic?.id ?? "" }, set: { selectedTopicID = $0 })) {
                        ForEach(topics) { topic in Text(topic.title).tag(topic.id) }
                    }.labelsHidden().frame(maxWidth: 340)
                    Text("全部历史").font(.caption).foregroundStyle(palette.accent)
                }
                Spacer()
                Picker("回顾方式", selection: $timeline) { Text("图谱").tag(false); Text("时间线").tag(true) }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 138)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.help(periodic ? "刷新这个周期" : "刷新这个主题").accessibilityLabel(periodic ? "刷新这个周期" : "刷新这个主题").disabled(loading)
                Button {
                    if let focus { Task { if !(await reflect(focus, draft)) { error = model.status } } }
                } label: { Label(periodic ? "一起回顾" : "一起探索", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).tint(palette.accent)
                    .disabled(focus?.sourceIDs.isEmpty != false || loading || model.discussionSaving || model.discussionSending || model.discussionExtracting || model.dictationActive)
            }
            if focus?.sourceIDs.isEmpty == true {
                Text(periodic ? "当前周期没有可探索的材料" : "当前主题没有可探索的材料")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 20)
    }
    private func shift(_ value: Int) {
        anchor = Calendar.current.date(byAdding: period.component, value: value, to: anchor) ?? anchor
    }
    private func loadTopics() async {
        do {
            topics = try await model.loadReflectionQuestions()
            if !topics.contains(where: { $0.id == selectedTopicID }) { selectedTopicID = topics.first?.id }
        } catch { self.error = error.localizedDescription }
    }
    private func reload() async {
        let requestedKey = reflectionKey, requestedPeriod = period, requestedInterval = interval
        let topicID = selectedTopic?.id, requestedPeriodic = periodic
        loading = true; focus = nil; selection = nil; relatedOnly = false; query = ""; error = nil
        defer { if requestedKey == reflectionKey { loading = false } }
        guard requestedPeriodic || topicID != nil else { return }
        do {
            var snapshot: ConversationReflectionFocus
            if requestedPeriodic {
                snapshot = try await model.loadReflection(requestedInterval)
                snapshot.period = requestedPeriod
            } else if let topicID {
                snapshot = try await model.loadTopicReflection(topicID)
            } else { return }
            guard !Task.isCancelled, requestedKey == reflectionKey else { return }
            focus = snapshot
            if !requestedPeriodic, let topicID { try await model.markTopicReviewed(topicID) }
        } catch {
            guard !Task.isCancelled, requestedKey == reflectionKey else { return }
            self.error = error.localizedDescription
        }
    }
    private func nodes(_ focus: ConversationReflectionFocus) -> [AtlasNode] {
        var result = focus.expressions.map { expression in
            let source = model.records.first { $0.id == expression.id }
            let title = source?.kind == "user_text" && source?.contentTitle == nil ? source?.transcript ?? expression.title : expression.title
            return AtlasNode(id: "s:" + expression.id, lane: 0, title: title,
                label: expression.date.formatted(.dateTime.month().day()) + (source?.origin == "ai" ? " · AI 交付" : expression.usesImportDate ? " · 导入日期" : " · 表达"), context: !focus.isTopicOverview && !expression.isInPeriod, sourceID: expression.id)
        }
        let periodSourceIDs = Set(focus.expressions.filter(\.isInPeriod).map(\.id) + focus.outcomes.filter { focus.contains(timestamp: $0.createdAt) }.map(\.sourceID))
        result += focus.thoughts.map { thought in
            AtlasNode(id: "c:" + thought.claimID, lane: 1, title: thought.summary, label: owner(thought.ownership),
                context: !focus.isTopicOverview && !thought.evidence.contains { periodSourceIDs.contains($0.reference.sourceID) }, claimID: thought.claimID)
        }
        result += focus.tasks.map { task in
            AtlasNode(id: "a:" + task.actionID, lane: 2, title: task.title,
                label: (task.kind == "task" ? "任务" : "意图与目标") + " · " + (task.state == "completed" ? "当前完成" : task.state == "dismissed" ? "已放下" : "待跟进"),
                context: false, actionID: task.actionID)
        }
        result += focus.outcomes.map { feedback in
            AtlasNode(id: "f:" + feedback.id, lane: 3, title: feedback.text, label: feedback.label + " · " + (ConversationReflectionFocus.date(feedback.createdAt)?.formatted(.dateTime.month().day()) ?? "时间未知"),
                context: !focus.isTopicOverview && !focus.contains(timestamp: feedback.createdAt), sourceID: feedback.sourceID, actionID: feedback.actionID, feedback: feedback)
        }
        result += focus.completions.map { completion in
            AtlasNode(id: "r:" + completion.id, lane: 3, title: focus.tasks.first { $0.actionID == completion.actionID }?.title ?? "任务完成记录",
                label: "完成登记 · " + (ConversationReflectionFocus.date(completion.revision.createdAt)?.formatted(.dateTime.month().day()) ?? "时间未知"), context: false, actionID: completion.actionID, completion: completion)
        }
        return result
    }
    private func edges(_ focus: ConversationReflectionFocus, nodes: [AtlasNode]) -> [AtlasEdge] {
        let ids = Set(nodes.map(\.id)); var result: [AtlasEdge] = []
        for thought in focus.thoughts {
            for id in Set(thought.evidence.map { $0.reference.sourceID }) {
                let sourceID = ids.contains("s:" + id) ? "s:" + id : nodes.first { $0.feedback?.sourceID == id }?.id
                if let sourceID { result.append(.init(from: sourceID, to: "c:" + thought.claimID, label: "原话整理")) }
            }
        }
        for task in focus.tasks {
            if let id = task.claimID, ids.contains("c:" + id) { result.append(.init(from: "c:" + id, to: "a:" + task.actionID, label: "行动依据")) }
        }
        for node in nodes where node.lane == 3 {
            if let id = node.actionID { result.append(.init(from: "a:" + id, to: node.id, label: node.completion == nil ? "实际反馈" : "完成登记")) }
        }
        for connection in focus.connections {
            let from = ids.contains("s:" + connection.sourceID) ? "s:" + connection.sourceID : nodes.first { $0.feedback?.sourceID == connection.sourceID }?.id
            if let from { result.append(.init(from: from, to: "c:" + connection.update.claimID, label: "AI 关联", connection: connection)) }
        }
        return result
    }
    private func positions(_ focus: ConversationReflectionFocus, nodes: [AtlasNode]) -> [String: CGPoint] {
        let expressions = Set(focus.expressions.map(\.id))
        func rootForClaim(_ id: String, visited: Set<String> = []) -> String? {
            guard !visited.contains(id), let thought = focus.thoughts.first(where: { $0.claimID == id }) else { return nil }
            for evidence in thought.evidence {
                let sourceID = evidence.reference.sourceID
                if expressions.contains(sourceID) { return sourceID }
                if let result = focus.outcomes.first(where: { $0.sourceID == sourceID }),
                   let claimID = focus.tasks.first(where: { $0.actionID == result.actionID })?.claimID,
                   let root = rootForClaim(claimID, visited: visited.union([id])) { return root }
            }
            return nil
        }
        var roots: [String: String] = [:]
        for node in nodes {
            if node.lane == 0 { roots[node.id] = node.sourceID }
            else if let id = node.claimID { roots[node.id] = rootForClaim(id) }
            else if let actionID = node.actionID, let id = focus.tasks.first(where: { $0.actionID == actionID })?.claimID { roots[node.id] = rootForClaim(id) }
        }
        var groups = focus.expressions.map(\.id)
        for node in nodes where roots[node.id] == nil { roots[node.id] = node.id; groups.append(node.id) }
        var result: [String: CGPoint] = [:], y: CGFloat = 110
        for group in groups {
            var rows = 1
            for lane in 0..<4 {
                let column = nodes.filter { roots[$0.id] == group && $0.lane == lane }
                rows = max(rows, column.count)
                let x = CGFloat(112 + 246 * lane)
                for (row, node) in column.enumerated() {
                    let rowY = y + CGFloat(132 * row)
                    result[node.id] = CGPoint(x: x, y: rowY)
                }
            }
            y += CGFloat(rows * 132 + 20)
        }
        return result
    }
    private func graph(_ focus: ConversationReflectionFocus) -> some View {
        let items = nodes(focus), links = edges(focus, nodes: items)
        let layout = positions(focus, nodes: items)
        let visible = relatedNodeIDs(items: items, links: links)
        let visibleItems = items.filter { visible.contains($0.id) }
        let visibleLinks = links.filter { visible.contains($0.from) && visible.contains($0.to) }
        let matches = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : items.filter { ($0.title + $0.label).localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let height = max(460, (layout.values.map(\.y).max() ?? 110) + 90), width: CGFloat = 964
        return VStack(spacing: 0) {
            HStack {
                WorkspaceSearchField(text: $query, placeholder: "在图谱中定位内容…") {
                    if let node = matches.first { locate(node.id, layout: layout, contentSize: CGSize(width: width * scale + 36, height: height * scale + 36)) }
                }
                Text("\(items.count) 个节点 · \(links.count) 条关系").font(.caption).foregroundStyle(.secondary)
                Slider(value: $scale, in: 0.55...1.2).frame(width: 75).accessibilityLabel("图谱缩放")
            }.padding(.horizontal, 22).padding(.vertical, 14)
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if matches.isEmpty { Text("没有找到相符的内容").font(.caption).foregroundStyle(.secondary) }
                        ForEach(matches) { node in
                            Button { locate(node.id, layout: layout, contentSize: CGSize(width: width * scale + 36, height: height * scale + 36)) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(palette.graphColor(node.lane)).frame(width: 5, height: 5).padding(.top, 5)
                                    Text(node.title).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.down.right")
                                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).help("在地图中定位并查看依据")
                        }
                    }.padding(.horizontal, 22).padding(.vertical, 10)
                }.frame(maxHeight: 112).background(palette.surface)
            }
            HStack(spacing: 12) {
                Toggle("只看相连内容", isOn: $relatedOnly).toggleStyle(.checkbox).disabled(selection == nil)
                if relatedOnly { Text("显示 \(visibleItems.count) 个节点 · 保留原位置").foregroundStyle(.secondary) }
                Spacer()
                Button("回到全部") { relatedOnly = false; selection = nil; query = "" }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
            }.font(.caption).padding(.horizontal, 22).padding(.bottom, 12)
            Divider()
            if items.isEmpty {
                ContentUnavailableView("这一页，等待新的连接", systemImage: "point.3.connected.trianglepath.dotted", description: Text(focus.isTopicOverview ? "为这个主题关联资料，或留下现在的认识与实践结果。" : "换一个日、周或月，找回已经留下的表达与成果。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            for x in stride(from: 12.0, to: size.width, by: 22) {
                                for y in stride(from: 12.0, to: size.height, by: 22) {
                                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(palette.text.opacity(0.07)))
                                }
                            }
                            for edge in visibleLinks {
                                guard let from = items.first(where: { $0.id == edge.from }), let to = items.first(where: { $0.id == edge.to }) else { continue }
                                guard let a = layout[from.id], let b = layout[to.id] else { continue }
                                let highlighted = selection == edge.id || selection == from.id || selection == to.id
                                var path = Path()
                                path.move(to: CGPoint(x: a.x + 98, y: a.y))
                                path.addCurve(to: CGPoint(x: b.x - 98, y: b.y), control1: CGPoint(x: a.x + 134, y: a.y), control2: CGPoint(x: b.x - 134, y: b.y))
                                context.stroke(path, with: .color((edge.connection == nil ? palette.action : palette.accent).opacity(highlighted ? 0.8 : 0.24)), style: StrokeStyle(lineWidth: highlighted ? 2 : 1, dash: edge.connection == nil ? [] : [5, 5]))
                            }
                        }
                        ForEach(Array(["表达与材料", "认知与问题", "行动与目标", "结果与反思"].enumerated()), id: \.offset) { lane, title in
                            HStack(spacing: 7) {
                                Circle().fill(palette.graphColor(lane)).frame(width: 5, height: 5)
                                Text(title).font(.system(size: 12, weight: .semibold))
                            }.position(x: CGFloat(112 + lane * 246), y: 30)
                        }
                        ForEach(visibleLinks) { edge in
                            if let from = items.first(where: { $0.id == edge.from }), let to = items.first(where: { $0.id == edge.to }) {
                                let a = layout[from.id] ?? .zero, b = layout[to.id] ?? .zero
                                Button { selection = edge.id } label: {
                                    Text(edge.label).font(.system(size: 9, weight: .medium)).padding(4)
                                        .background(palette.canvas, in: Capsule())
                                }.buttonStyle(.plain).help("查看关系与原话依据")
                                    .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                            }
                        }
                        // Hidden neighbors leave gaps so selecting never reshuffles the map.
                        HStack(alignment: .top, spacing: 50) {
                            ForEach(0..<4, id: \.self) { lane in
                                let column = visibleItems.filter { $0.lane == lane }.sorted { (layout[$0.id]?.y ?? 0) < (layout[$1.id]?.y ?? 0) }
                                VStack(spacing: 0) {
                                    ForEach(Array(column.enumerated()), id: \.element.id) { index, node in
                                        let previousBottom = index == 0 ? 0 : (layout[column[index - 1].id]?.y ?? 0) + 52
                                        Color.clear.frame(height: max(0, (layout[node.id]?.y ?? 0) - 52 - previousBottom))
                                        nodeButton(node).opacity(query.isEmpty || (node.title + node.label).localizedCaseInsensitiveContains(query) ? 1 : 0.25)
                                            .id(node.id)
                                    }
                                }.frame(width: 196)
                            }
                        }.padding(.leading, 14)
                    }.frame(width: width, height: height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: width * scale, height: height * scale, alignment: .topLeading)
                        .padding(18)
                }
                .scrollPosition($graphPosition)
                .onGeometryChange(for: CGSize.self) { geometry in geometry.size } action: { graphViewport = $0 }
            }
        }
    }
    private func relatedNodeIDs(items: [AtlasNode], links: [AtlasEdge]) -> Set<String> {
        guard relatedOnly, let selection else { return Set(items.map(\.id)) }
        let roots: Set<String>
        if let edge = links.first(where: { $0.id == selection }) { roots = [edge.from, edge.to] }
        else { roots = [selection] }
        return roots.union(links.filter { roots.contains($0.from) || roots.contains($0.to) }.flatMap { [$0.from, $0.to] })
    }
    private func locate(_ id: String, layout: [String: CGPoint], contentSize: CGSize) {
        guard let center = layout[id] else { return }
        relatedOnly = false
        selection = id
        // The atlas scales its canvas. Scroll using actual scaled content
        // coordinates rather than node IDs inside that transform.
        let destination = CGPoint(
            x: min(max(0, center.x * scale + 18 - graphViewport.width / 2), max(0, contentSize.width - graphViewport.width)),
            y: min(max(0, center.y * scale + 18 - graphViewport.height / 2), max(0, contentSize.height - graphViewport.height))
        )
        withAnimation(.easeInOut(duration: 0.25)) {
            graphPosition.scrollTo(point: destination)
        }
    }
    private func nodeButton(_ node: AtlasNode) -> some View {
        Button { selection = node.id } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Text(node.label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if node.context { Text("此前").font(.system(size: 9)).padding(.horizontal, 4).background(palette.canvas, in: Capsule()) }
                }.foregroundStyle(palette.graphColor(node.lane))
                Text(node.title).font(.system(size: 13, weight: .medium)).lineLimit(3).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(13).frame(width: 196, height: 104, alignment: .topLeading)
                .background(palette.surface.opacity(node.context ? 0.5 : 1), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(palette.graphColor(node.lane)).frame(width: 3, height: 30).padding(.leading, 1) }
                .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).stroke(selection == node.id ? palette.graphColor(node.lane) : palette.text.opacity(0.12), lineWidth: selection == node.id ? 2 : 1) }
                .shadow(color: palette.text.opacity(0.04), radius: 7, y: 3)
        }.buttonStyle(.plain).accessibilityLabel(node.label + "，" + node.title)
    }
    private func inspector(_ focus: ConversationReflectionFocus) -> some View {
        let items = nodes(focus), links = edges(focus, nodes: items)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(selection == nil ? (focus.isTopicOverview ? "这个主题的脉络" : "这个周期的线索") : "关系与依据").font(.system(size: 20, weight: .medium, design: .serif))
                if let node = items.first(where: { $0.id == selection }) {
                    nodeDetails(node, focus: focus)
                    let connected = links.filter { $0.from == node.id || $0.to == node.id }
                    if !connected.isEmpty {
                        Divider()
                        Text("连接").font(.headline)
                        ForEach(connected) { edge in
                            Button { selection = edge.id } label: { Label(edge.label + " · 查看依据", systemImage: "arrow.triangle.branch") }.buttonStyle(.plain).font(.callout)
                        }
                    }
                } else if let edge = links.first(where: { $0.id == selection }) {
                    Text(edge.label).font(.headline).foregroundStyle(palette.accent)
                    if let connection = edge.connection {
                        Text("AI 关系判断 · 待核对").font(.caption).foregroundStyle(.secondary)
                        Text(connection.update.understanding).textSelection(.enabled)
                        Text(connection.update.reason).font(.callout).textSelection(.enabled)
                        quote("此前原话", connection.update.historicalQuote)
                        quote("本次原话", connection.update.currentQuote)
                        Button("并排对照与追问") { changeID = connection.id; showsChanges = true }
                    } else {
                        Text(edge.label == "完成登记" ? "这是任务状态的登记；实际收获以你的反馈为依据。" : edge.label == "原话整理" ? "这条内容的整理引用了相连来源的原话；摘要仍需核对。" : edge.label == "行动依据" ? "这项行动保留了所依据的观点与原话。" : "反馈明确关联到这项任务及其当时版本。")
                    }
                    ForEach([edge.from, edge.to], id: \.self) { id in
                        if let node = items.first(where: { $0.id == id }) { Button(node.title) { selection = id }.buttonStyle(.link) }
                    }
                } else {
                    metric("表达与材料", focus.isTopicOverview ? focus.expressions.count : focus.expressions.filter(\.isInPeriod).count, color: palette.text)
                    metric(focus.isTopicOverview ? "完成登记" : "周期内完成登记", focus.completions.count, color: palette.action)
                    metric("结果与反思", focus.isTopicOverview ? focus.outcomes.count : focus.outcomes.filter { focus.contains(timestamp: $0.createdAt) }.count, color: palette.outcome)
                    Divider()
                    Text(focus.isTopicOverview ? "关联资料跨时间完整展示。先后日期帮助理解判断如何形成，主题不会因换周而中断。任务状态与实际结果分别保留。" : "旧资料作为背景接入，以「此前」标记。任务卡片显示当前状态，完成登记按实际记录时间归入周期。").font(.callout).foregroundStyle(.secondary)
                    Text("你带来经历与判断，VoiceOS 帮你找回联系、提出问题。一起回顾后，可以继续讨论并保留有价值的认识。").font(.callout)
                    Text("AI 使用完整相关原文；先查看并编辑讨论草稿，再确认发送。").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
        }.background(palette.surface)
    }
    private func nodeDetails(_ node: AtlasNode, focus: ConversationReflectionFocus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(node.label + (node.context ? " · 此前背景" : "")).font(.caption).foregroundStyle(palette.graphColor(node.lane))
            Text(node.title).font(.headline).textSelection(.enabled)
            if let claimID = node.claimID, let thought = focus.thoughts.first(where: { $0.claimID == claimID }) {
                Text("当前整理 · 不等于事实已验证").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(thought.evidence.enumerated()), id: \.offset) { _, evidence in
                    quote("来源原话", evidence.quote)
                    Button("查看表达全文") { showSource(evidence.reference.sourceID) }
                }
                if let claim = model.claims.first(where: { $0.id == claimID }) { Button("继续讨论这条思考") { discuss(claim) } }
            } else if let feedback = node.feedback {
                Text("记录时间：" + (ConversationReflectionFocus.date(feedback.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? feedback.createdAt)).font(.caption)
                if let task = focus.tasks.first(where: { $0.actionID == feedback.actionID }) {
                    Text("反馈属于第 \(feedback.actionVersion) 版任务；当前第 \(task.version) 版。").font(.caption).foregroundStyle(.secondary)
                }
                Button("查看结果原文") { showSource(feedback.sourceID) }
                Button("任务与全部结果") { model.showTask(feedback.actionID); dismiss() }
            } else if let completion = node.completion {
                Text("登记于 " + (ConversationReflectionFocus.date(completion.revision.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? completion.revision.createdAt)).font(.caption)
                Text("任务第 \(completion.revision.version) 版 · " + (completion.revision.actor == "user" ? "用户记录" : "提醒状态同步")).font(.caption)
                Text("完成状态独立保存；是否取得收获，要看实际结果。").font(.callout).foregroundStyle(.secondary)
                if !completion.revision.note.isEmpty { Text(completion.revision.note).font(.callout).textSelection(.enabled) }
                Button("任务与结果") { model.showTask(completion.actionID); dismiss() }
            } else if let actionID = node.actionID {
                Text("当前状态，不能用来推断何时完成或学会。").font(.caption).foregroundStyle(.secondary)
                Button("打开任务或目标") { model.showTask(actionID); dismiss() }
            } else if let sourceID = node.sourceID {
                if let source = model.records.first(where: { $0.id == sourceID }) {
                    Text(source.origin == "ai" ? "AI 交付物 · 不代表我的观点或实际验证" : source.origin == "user" ? "个人表达" : "外部资料 · 不代表我的观点").font(.caption)
                    if let summary = source.contentSummary { Text(summary).font(.callout).textSelection(.enabled) }
                    if let text = source.transcript { DisclosureGroup("完整原文") { Text(text).font(.callout).textSelection(.enabled) } }
                }
                Button("查看资料全文") { showSource(sourceID) }
            }
        }
    }
    private func showSource(_ id:String) {
        if let openSource { openSource(id) }
        else { model.requestWorkspaceSource(id); dismiss() }
    }
    private func quote(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
    }
    private func metric(_ title: String, _ count: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.callout)
            Spacer()
            Text(String(count)).font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(color)
        }
    }
    private func owner(_ value: String) -> String {
        switch value { case "user_tentative": "我的暂定表达"; case "external": "外部主张"; case "ai_candidate": "AI 建议"; default: "归属待核对" }
    }
}
