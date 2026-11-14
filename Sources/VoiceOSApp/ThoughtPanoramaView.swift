import SwiftUI
import VoiceOSCore

struct ThoughtPanoramaView: View {
    let state: PanoramaState?
    let message: String
    let isGenerating: Bool
    let modelConfigured: Bool
    let readError: String?
    @Binding var selection: PanoramaSelection?
    @Environment(\.workspacePalette) private var palette
    let retry: () -> Void
    let draft: () -> Void
    let retryRefresh: () -> Void
    let dismissReadError: () -> Void
    let chooseTextModel: () -> Void
    let openMaterials: () -> Void
    let openSource: (String) -> Void
    let correctSource: (String) -> Void
    let correctClaim: (String) -> Void
    let discuss: (String, PanoramaSelection) -> Void
    let themeReply: (PanoramaThemeBriefing) async throws -> String
    @State private var query = ""
    @State private var searchMatches = ConstellationSearchMatches()
    @State private var recenterToken = 0
    @State private var recent = true
    @State private var focusedRegionID: String?
    @State private var showCoverage = false
    @State private var showOutline = false
    @State private var pendingReaderAction: (() -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let hasSideReader = width >= 740
            VStack(spacing: 0) {
                constellationToolbar(width: width)
                if let readError { readErrorBanner(readError) }
                Divider()
                HStack(spacing: 0) {
                    panorama(state?.snapshot)
                    if hasSideReader, let snapshot = state?.snapshot, hasReader {
                        Divider()
                        readerContent(snapshot, performAction: { action in
                            self.selection = nil
                            self.focusedRegionID = nil
                            action()
                        }).frame(width: 310)
                    }
                }
                .sheet(isPresented: Binding(
                    get: { !hasSideReader && state?.snapshot != nil && hasReader },
                    set: { if !$0 && !hasSideReader { selection = nil; focusedRegionID = nil } }
                ), onDismiss: {
                    let action = pendingReaderAction
                    pendingReaderAction = nil
                    action?()
                }) {
                    if let snapshot = state?.snapshot {
                        readerContent(snapshot, performAction: { action in
                            pendingReaderAction = action
                            selection = nil
                            focusedRegionID = nil
                        }).frame(minWidth: 540, minHeight: 480)
                    }
                }
            }
        }
        .background(palette.canvas)
        .sheet(isPresented: $showCoverage) { coverage.frame(minWidth: 620, minHeight: 480) }
        .onAppear { reconcileNavigation() }
        .onChange(of: navigationIDs) { _, _ in reconcileNavigation() }
        .onChange(of: selection) { _, _ in focusSelection() }
    }

    private var hasReader: Bool { selection != nil || focusedRegionID != nil }

    @ViewBuilder
    private func readerContent(_ snapshot: PanoramaSnapshot, performAction: @escaping (@escaping () -> Void) -> Void) -> some View {
        let actions = ReaderActions(
            perform: performAction,
            openSource: openSource,
            correctSource: correctSource,
            correctClaim: correctClaim,
            discuss: discuss
        )
        if let selection {
            switch selection {
            case .question(let id):
                if let question = snapshot.proposal.questions.first(where: { $0.id == id }) {
                    QuestionInspectorPanel(
                        snapshot: snapshot,
                        question: question,
                        backRegion: focusedRegionID.flatMap { regionID in
                            snapshot.proposal.regions.first { $0.id == regionID }
                        },
                        selection: $selection,
                        focusedRegionID: $focusedRegionID,
                        actions: actions
                    )
                    .id(id)
                }
            case .relation(let id):
                if let relation = snapshot.proposal.relations.first(where: { $0.id == id }) {
                    RelationInspectorPanel(
                        snapshot: snapshot,
                        relation: relation,
                        backRegion: focusedRegionID.flatMap { regionID in
                            snapshot.proposal.regions.first { $0.id == regionID }
                        },
                        selection: $selection,
                        focusedRegionID: $focusedRegionID,
                        actions: actions
                    )
                    .id(id)
                }
            }
        } else if let focusedRegionID, let region = snapshot.proposal.regions.first(where: { $0.id == focusedRegionID }) {
            RegionInspectorPanel(
                snapshot: snapshot,
                region: region,
                history: state?.themeHistory[region.id],
                selection: $selection,
                focusedRegionID: $focusedRegionID,
                actions: actions,
                themeReply: themeReply
            )
            .id(region.id)
        }
    }

    private func constellationToolbar(width: CGFloat) -> some View {
        let compact = width < 900
        let minimal = width < 720
        return HStack(spacing: minimal ? 6 : compact ? 8 : 12) {
            Text("思考全景").vosFont(16, weight: .semibold).lineLimit(1)
            if let snapshot = state?.snapshot, snapshot.isPartial {
                partialChip(snapshot, short: compact)
            }
            Picker("时间高亮", selection: $recent) {
                Text("全部").tag(false)
                Text("近期高亮").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: compact ? 130 : 150)
            searchField(width: minimal ? 120 : compact ? 150 : 220)
            searchMatchStatus(width: width)
            if compact {
                Image(systemName: "info.circle")
                    .foregroundStyle(showsUnitFailure ? palette.warning : Color.secondary)
                    .help(toolbarMessageHelp)
                    .accessibilityLabel(toolbarMessage)
                Spacer(minLength: 0)
            } else {
                Text(toolbarMessage)
                    .vosFont(12)
                    .foregroundStyle(showsUnitFailure ? palette.warning : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(toolbarMessageHelp)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            contextualControl(iconOnly: minimal)
            outlineToolbarButton
            coverageToolbarButton
            materialsToolbarButton
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }

    // Core reports unit failures as "N 个完整单元未能核对" plus raw unit IDs.
    // Keep the count in the toolbar and leave the full IDs in the tooltip.
    private var unverifiedUnitIDs: [String] {
        guard let state else { return [] }
        let verified = Set(state.snapshot?.workflow?.verifiedUnitIDs ?? [])
        return state.input.units.map(\.id).filter { !verified.contains($0) }
    }

    private var showsUnitFailure: Bool {
        !unverifiedUnitIDs.isEmpty && message.contains("个完整单元未能核对")
    }

    private var toolbarMessage: String {
        showsUnitFailure ? "\(unverifiedUnitIDs.count) 个单元尚未核对" : message
    }

    private var toolbarMessageHelp: String {
        showsUnitFailure ? "尚未核对的完整单元：\n" + unverifiedUnitIDs.joined(separator: "\n") : message
    }

    private func readErrorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.danger)
            Text(text).vosFont(12).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试", action: retryRefresh).controlSize(.small)
            Button { dismissReadError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("关闭读取错误提示")
                .accessibilityLabel("关闭读取错误提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.danger.opacity(0.10))
    }

    private func partialChip(_ snapshot: PanoramaSnapshot, short: Bool) -> some View {
        let verified = snapshot.workflow?.verifiedUnitIDs.count ?? 0
        let total = snapshot.workflow?.totalUnitCount ?? 0
        return Button { showCoverage = true } label: {
            Text(short ? "\(verified)/\(total)" : "部分全景 \(verified)/\(total)")
                .vosFont(12, weight: .medium)
                .foregroundStyle(palette.warning)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.warning.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("已核对 \(verified)/\(total) 个完整单元 · 仅显示已核对区域，跨材料联系与全局覆盖尚未完成")
        .accessibilityLabel("部分全景，已核对 \(verified)/\(total) 个完整单元")
    }

    private func searchField(width: CGFloat) -> some View {
        WorkspaceSearchField(text: $query, placeholder: "查找问题与联系，长期节点始终保留")
            .frame(width: width)
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPanoramaRegions: Bool {
        guard let snapshot = state?.snapshot else { return false }
        return !snapshot.proposal.questions.isEmpty
    }

    // The status shrinks with the toolbar so it never pushes the right-side
    // controls out: full copy, then the count, then only the locate control.
    // Below 520 the fixed items already fill the pane.
    @ViewBuilder
    private func searchMatchStatus(width: CGFloat) -> some View {
        if hasQuery, hasPanoramaRegions {
            if width >= 900 {
                searchMatchText(searchMatchLabel)
                if searchMatches.count > 0 { locateButton }
            } else if width >= 620 {
                searchMatchText(searchMatchCompactLabel)
                if searchMatches.count > 0 { locateButton }
            } else if width >= 520 {
                if searchMatches.count > 0 {
                    locateIconButton
                } else {
                    searchMatchText("无匹配")
                }
            }
        }
    }

    private var searchMatchLabel: String {
        if searchMatches.count == 0 { return "没有匹配的区域" }
        let suffix = searchMatches.includesQuestionOrRelationText ? "（含问题与联系文字）" : ""
        return "\(searchMatches.count) 个区域匹配" + suffix
    }

    private var searchMatchCompactLabel: String {
        searchMatches.count == 0 ? "无匹配" : "\(searchMatches.count) 个"
    }

    private var searchMatchHelp: String {
        let base = searchMatches.count == 0 ? "没有匹配的区域" : "\(searchMatches.count) 个区域匹配"
        let detail = searchMatches.includesQuestionOrRelationText ? base + "，含问题与联系文字" : base
        return detail + "；按区域标题、摘要、问题与联系文字匹配"
    }

    private func searchMatchText(_ text: String) -> some View {
        Text(text)
            .vosFont(11)
            .foregroundStyle(searchMatches.count == 0 ? palette.warning : Color.secondary)
            .lineLimit(1)
            .fixedSize()
            .help(searchMatchHelp)
            .accessibilityLabel(searchMatchHelp)
    }

    private var locateHelp: String {
        "定位到 \(searchMatches.count) 个匹配区域"
    }

    private var locateButton: some View {
        Button("定位") { recenterToken &+= 1 }
            .vosFont(11)
            .buttonStyle(.borderless)
            .help(locateHelp)
            .accessibilityLabel(locateHelp)
    }

    private var locateIconButton: some View {
        Button { recenterToken &+= 1 } label: {
            Image(systemName: "scope").frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(locateHelp)
        .accessibilityLabel(locateHelp)
    }

    @ViewBuilder
    private func contextualControl(iconOnly: Bool) -> some View {
        if isGenerating {
            ProgressView().controlSize(.small).frame(width: 22, height: 22)
        } else if !modelConfigured {
            if iconOnly {
                Button { chooseTextModel() } label: { Image(systemName: "link").frame(width: 22, height: 22) }
                    .buttonStyle(.borderless)
                    .help("连接文本模型")
                    .accessibilityLabel("连接文本模型")
            } else {
                Button("连接文本模型", action: chooseTextModel)
            }
        } else if let state, ["failed", "unknown"].contains(state.status) {
            let canDraft=state.snapshot?.isPartial == true && state.snapshot?.proposal.relations.isEmpty == true
            if iconOnly {
                if canDraft {
                    Button { draft() } label: { Image(systemName: "doc.badge.plus").frame(width: 22, height: 22) }
                        .buttonStyle(.borderless)
                        .help("先生成综合草稿")
                        .accessibilityLabel("先生成综合草稿")
                }
                Button { retry() } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
                    .buttonStyle(.borderless)
                    .help("继续核对")
                    .accessibilityLabel("继续核对")
            } else {
                if canDraft { Button("生成草稿", action: draft).help("用已核对单元先生成带联系的综合草稿，全局核对尚未完成") }
                Button("继续核对", action: retry)
            }
        }
    }

    private var outlineToolbarButton: some View {
        Button { showOutline = true } label: { Image(systemName: "list.bullet").frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .help("问题与联系列表 · 键盘与辅助阅读")
            .accessibilityLabel("问题与联系列表")
            .popover(isPresented: $showOutline) {
                if let snapshot = state?.snapshot { outlinePanel(snapshot) }
            }
    }

    private var coverageToolbarButton: some View {
        Button { showCoverage = true } label: { Image(systemName: "chart.pie").frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .help("覆盖与未归入项")
            .accessibilityLabel("覆盖与未归入项")
    }

    private var materialsToolbarButton: some View {
        Button(action: openMaterials) { Image(systemName: "doc.on.doc").frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .help("打开材料")
            .accessibilityLabel("打开材料")
    }

    private func outlinePanel(_ snapshot: PanoramaSnapshot) -> some View {
        let model = ConstellationModel(snapshot: snapshot, now: .now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("问题与联系列表").font(.headline)
                Text("与画布一致；键盘可逐项浏览。").font(.caption).foregroundStyle(.secondary)
                ForEach(model.regions) { region in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                focusedRegionID = region.id
                                selection = nil
                                showOutline = false
                            } label: {
                                Text("打开区域摘要").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.accent)
                            .accessibilityLabel("打开区域摘要：" + region.title)
                            ForEach(region.questionIDs, id: \.self) { id in
                                Button {
                                    selection = .question(id)
                                    showOutline = false
                                } label: {
                                    Text(model.questionByID[id]?.title ?? id).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("AI 归纳问题：" + (model.questionByID[id]?.title ?? id))
                            }
                        }
                        .padding(.leading, 8)
                        .padding(.top, 4)
                    } label: {
                        Text(region.title).vosFont(13, weight: .medium)
                    }
                }
                Divider()
                Text("候选联系").font(.headline)
                if snapshot.proposal.relations.isEmpty {
                    Text(snapshot.isPartial ? "跨材料联系尚未核对完成；当前只展示已核对区域。" : "当前没有已核对的跨区域候选联系。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.proposal.relations) { relation in
                        Button {
                            selection = .relation(relation.id)
                            showOutline = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(relation.label)
                                Text("AI 候选联系 · 尚待核对").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("AI 候选联系：" + relation.label)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 340, height: 480)
    }

    private func panorama(_ snapshot: PanoramaSnapshot?) -> some View {
        Group {
            if let snapshot, !snapshot.proposal.questions.isEmpty {
                PanoramaConstellationView(
                    snapshot: snapshot,
                    query: query,
                    recentOnly: recent,
                    selection: $selection,
                    focusedRegionID: $focusedRegionID,
                    searchMatches: $searchMatches,
                    recenterToken: recenterToken
                )
            } else {
                emptyState
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Ellipse().fill(palette.selection).frame(width: 300, height: 190).rotationEffect(.degrees(-15))
                Ellipse().fill(palette.accent.opacity(0.08)).frame(width: 240, height: 160).offset(x: 110, y: 40)
                Image(systemName: "point.3.connected.trianglepath.dotted").vosFont(62, weight: .light).foregroundStyle(.secondary)
            }.padding(.bottom, 20)
            Text(state?.snapshot != nil ? "材料已核对，尚未形成持续问题" : isGenerating ? "让完整表达连成脉络" : "从表达中发现持续探索的问题").font(.title2)
            Text(toolbarMessage).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480).help(toolbarMessageHelp)
            HStack { Button("打开材料", action: openMaterials); if state?.snapshot == nil, state?.input.units.isEmpty == false { Button("生成或重试全景", action: retry).disabled(!modelConfigured || isGenerating || state?.status == "running") } }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dependencyCount(_ input: PanoramaInput) -> Int {
        Set(input.units.flatMap(\.dependencyIDs)).count
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("完整材料与覆盖情况").font(.title2); Spacer(); Button("关闭") { showCoverage = false } }
            if let state {
                Text("\(state.input.units.count) 个完整单元 · \(state.input.sources.count) 份来源 · \(dependencyCount(state.input)) 份节目依赖 · \(state.input.claims.count) 条当前认识").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let state {
                        if let snapshot=state.snapshot, snapshot.isPartial {
                            Text("这是已核对区域。其余完整单元、跨单元联系与全局覆盖尚未完成；当前结果不代表本人认可。").foregroundStyle(palette.warning)
                        }
                        Text("输入不按近期或条数裁剪。仅完整整理、当前版本与许可均有效的材料入选；节目依赖单独计数。AI 未归入项仍保留完整入口。")
                        ForEach(state.input.sources) { source in
                            HStack { Text(source.title); Spacer(); Text(state.snapshot?.coverage.submittedSourceIDs.contains(source.id) != true ? "尚未核对" : state.snapshot?.coverage.representedSourceIDs.contains(source.id) == true ? "已核对并表达" : "已核对，未归入具体问题").foregroundStyle(.secondary); Button("全文") { showCoverage = false; openSource(source.id) } }
                            if let reason = state.snapshot?.coverage.unrepresentedSources.first(where: { $0.id == source.id })?.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(state.snapshot?.coverage.unrepresentedClaims ?? [], id: \.id) { item in
                            if let claim = state.input.claims.first(where: { $0.id == item.id }) {
                                Text(claim.statement).font(.headline); Text(item.reason).foregroundStyle(.secondary)
                                HStack { Button("更正理解") { showCoverage = false; correctClaim(item.id) }; if let source = claim.references.first?.sourceID { Button("完整原文") { showCoverage = false; openSource(source) } } }
                            }
                        }
                        Divider(); Text("尚未合格的材料").font(.headline)
                        ForEach(state.input.exclusions) { item in HStack { VStack(alignment: .leading) { Text(item.title); Text(item.reason).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("材料") { showCoverage = false; openSource(item.id) } } }
                        if let snapshot = state.snapshot {
                            Divider()
                            if let workflow=snapshot.workflow {
                                Text(snapshot.isPartial ? "以下回执分别对应已核对单元；全局核对尚未完成。" : "分阶段生成与独立核对回执").font(.caption)
                                ForEach(Array(workflow.receipts.enumerated()), id: \.offset) { _, item in
                                    Text(panoramaStageLabel(item.stage)).font(.caption)
                                }
                            } else {
                                Text("生成已完成").font(.caption)
                                Text("独立核对已完成").font(.caption)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24)
    }

    private var navigationIDs: [[String]] {
        guard let snapshot = state?.snapshot else { return [] }
        return [[snapshot.id], snapshot.proposal.regions.map(\.id),
                snapshot.proposal.questions.flatMap { [$0.id, $0.regionID] },
                snapshot.proposal.relations.flatMap { [$0.id, $0.from, $0.to] }]
    }

    private func reconcileNavigation() {
        guard let snapshot = state?.snapshot else { focusedRegionID = nil; selection = nil; return }
        if !snapshot.proposal.regions.contains(where: { $0.id == focusedRegionID }) { focusedRegionID = nil }
        if let selection {
            switch selection {
            case .question(let id):
                if !snapshot.proposal.questions.contains(where: { $0.id == id }) { self.selection = nil }
            case .relation(let id):
                if !snapshot.proposal.relations.contains(where: { $0.id == id }) { self.selection = nil }
            }
        }
        focusSelection()
    }

    private func focusSelection() {
        guard let snapshot = state?.snapshot, let selection else { return }
        switch selection {
        case .question(let id):
            focusedRegionID = snapshot.proposal.questions.first(where: { $0.id == id })?.regionID
        case .relation(let id):
            guard let relation = snapshot.proposal.relations.first(where: { $0.id == id }) else { return }
            let endpoints = snapshot.proposal.questions.filter { $0.id == relation.from || $0.id == relation.to }
            if !endpoints.contains(where: { $0.regionID == focusedRegionID }) {
                focusedRegionID = snapshot.proposal.questions.first(where: { $0.id == relation.from })?.regionID
            }
        }
    }
}

// MARK: - Reader panels

private struct ReaderActions {
    let perform: (@escaping () -> Void) -> Void
    let openSource: (String) -> Void
    let correctSource: (String) -> Void
    let correctClaim: (String) -> Void
    let discuss: (String, PanoramaSelection) -> Void
}

private struct RegionInspectorPanel: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: PanoramaSnapshot
    let region: PanoramaRegion
    let history: PanoramaThemeHistory?
    @Binding var selection: PanoramaSelection?
    @Binding var focusedRegionID: String?
    let actions: ReaderActions
    let themeReply: (PanoramaThemeBriefing) async throws -> String
    @State private var showsRelations = false
    @State private var showsOtherQuestions = false
    @State private var reply: String?
    @State private var replyError: String?
    @State private var loadingReply = false

    var body: some View {
        let model = ConstellationModel(snapshot: snapshot, now: .now)
        let questions = (model.regionByID[region.id]?.questionIDs ?? []).compactMap { model.questionByID[$0] }
        let incident = snapshot.proposal.relations.filter { relation in
            guard let from = model.questionByID[relation.from], let to = model.questionByID[relation.to] else { return false }
            return from.regionID == region.id || to.regionID == region.id
        }
        let area = model.areas.first { $0.regionIDs.contains(region.id) }
        let briefing = PanoramaThemeBriefing.make(snapshot: snapshot, region: region)
        let openQuestion = briefing.openQuestionID.flatMap { id in questions.first { $0.id == id } }
        let quoted = Set(briefing.quotes.map(\.questionID))
        let otherQuestions = questions.filter { question in
            question.id != openQuestion?.id && !quoted.contains(question.id)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ReaderKicker(
                        dot: area.map { RegionIdentity.color(index: $0.identityIndex, scheme: colorScheme) } ?? palette.accent,
                        text: area.map { "大区 · " + $0.title } ?? "探索区域"
                    )
                    Spacer(minLength: 0)
                    WorkspaceIconButton(systemImage: "xmark", label: "关闭主题") { focusedRegionID = nil }
                }
                Text(region.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(themeMetaLine(briefing, questions: questions, relations: incident.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !briefing.quotes.isEmpty {
                    ReaderSectionLabel("你的话")
                    ForEach(briefing.quotes) { quote in
                        Button { selection = .question(quote.questionID) } label: {
                            themeQuoteCard(quote)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("你的原话：" + quote.text)
                    }
                    ReaderSectionLabel("AI 的回应")
                    if loadingReply {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读这件事…").vosFont(12).foregroundStyle(.secondary)
                        }
                    } else if let reply {
                        Text(reply)
                            .vosFont(13)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    } else if let replyError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(replyError).vosFont(12).foregroundStyle(palette.danger)
                            Button("重试") { Task { await loadReply(briefing) } }
                                .vosFont(12, weight: .medium)
                                .buttonStyle(.borderless)
                                .foregroundStyle(palette.accent)
                        }
                    }
                    Text("AI 的推断，不是你的结论").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ReaderCappedText(text: region.summary, size: 14)
                }
                if let openQuestion {
                    ReaderSectionLabel("还没想完")
                    ReaderQuestionRow(question: openQuestion) { selection = .question(openQuestion.id) }
                    Text("\(briefing.openQuestionEvidenceCount) 处原话")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !otherQuestions.isEmpty {
                    ReaderDisclosure(title: "其他问题 · \(otherQuestions.count)", expanded: $showsOtherQuestions) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(otherQuestions.enumerated()), id: \.offset) { index, question in
                                if index > 0 { Divider() }
                                ReaderQuestionRow(question: question) { selection = .question(question.id) }
                            }
                        }
                    }
                }
                if !incident.isEmpty {
                    ReaderDisclosure(title: "候选联系 · \(incident.count)", expanded: $showsRelations) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(incident.enumerated()), id: \.offset) { index, relation in
                                if index > 0 { Divider() }
                                ReaderRelationRow(
                                    relation: relation,
                                    fromTitle: model.questionByID[relation.from]?.title ?? "",
                                    toTitle: model.questionByID[relation.to]?.title ?? ""
                                ) { selection = .relation(relation.id) }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .defaultScrollAnchor(.top)
        .task(id: briefing.digest) {
            guard !briefing.quotes.isEmpty else { return }
            await loadReply(briefing)
        }
    }

    private func loadReply(_ briefing: PanoramaThemeBriefing) async {
        if reply != nil { return }
        loadingReply = true
        replyError = nil
        do { reply = try await themeReply(briefing) }
        catch { replyError = error.localizedDescription }
        loadingReply = false
    }

    private func themeMetaLine(_ briefing: PanoramaThemeBriefing, questions: [PanoramaQuestion], relations: Int) -> String {
        let evidenceCount = questions.reduce(0) { $0 + $1.evidence.count }
        var parts: [String] = []
        if let history, history.appearanceCount > 1 {
            parts.append("第 \(history.appearanceCount) 次出现")
            if let date = themeShortDate(history.firstSeenAt) { parts.append("首次 " + date) }
        }
        if let iso = briefing.quotes.map(\.occurredAt).max(), let date = themeShortDate(iso) {
            parts.append(date)
        }
        parts.append("\(questions.count) 个问题")
        parts.append("\(evidenceCount) 处原话")
        if relations > 0 { parts.append("\(relations) 条候选联系") }
        return parts.joined(separator: " · ")
    }

    private func themeQuoteCard(_ quote: PanoramaThemeQuote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("“" + quote.text + "”")
                .vosFont(13)
                .lineSpacing(3)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            Text(themeMeta(quote))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.selection, in: RoundedRectangle(cornerRadius: 8))
    }

    private func themeMeta(_ quote: PanoramaThemeQuote) -> String {
        var parts: [String] = []
        if let date = themeShortDate(quote.occurredAt) { parts.append(date) }
        if !quote.sourceTitle.isEmpty { parts.append(quote.sourceTitle) }
        return parts.joined(separator: " · ")
    }

    private func themeShortDate(_ iso: String) -> String? { panoramaShortDate(iso) }
}

private struct QuestionInspectorPanel: View {
    let snapshot: PanoramaSnapshot
    let question: PanoramaQuestion
    let backRegion: PanoramaRegion?
    @Binding var selection: PanoramaSelection?
    @Binding var focusedRegionID: String?
    let actions: ReaderActions
    @State private var showsRelations = false

    var body: some View {
        let model = ConstellationModel(snapshot: snapshot, now: .now)
        let relations = snapshot.proposal.relations.filter { $0.from == question.id || $0.to == question.id }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    if let backRegion {
                        Button { selection = nil } label: {
                            Label("返回「\(backRegion.title)」", systemImage: "chevron.left")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("返回区域：" + backRegion.title)
                    }
                    Spacer(minLength: 0)
                    WorkspaceIconButton(systemImage: "xmark", label: "关闭检查器") {
                        selection = nil
                        focusedRegionID = nil
                    }
                }
                Text(question.title).font(.title3.weight(.semibold))
                Text("\(question.evidence.count) 处原话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderCappedText(text: question.summary, size: 13)
                ReaderEvidenceBlock(
                    label: "原话",
                    question: nil,
                    evidence: question.evidence,
                    sources: snapshot.input.sources,
                    claims: snapshot.input.claims,
                    firstLineLimit: 4,
                    actions: actions,
                    openQuestion: nil
                )
                if !relations.isEmpty {
                    ReaderDisclosure(title: "候选联系 · \(relations.count)", expanded: $showsRelations) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(relations.enumerated()), id: \.offset) { index, relation in
                                if index > 0 { Divider() }
                                ReaderRelationRow(
                                    relation: relation,
                                    fromTitle: model.questionByID[relation.from]?.title ?? "",
                                    toTitle: model.questionByID[relation.to]?.title ?? ""
                                ) { selection = .relation(relation.id) }
                            }
                        }
                    }
                }
                ReaderPrimaryAction(title: "沿这条线索继续") {
                    actions.perform { actions.discuss(snapshot.id, .question(question.id)) }
                }
            }
            .padding(20)
        }
    }
}

private struct RelationInspectorPanel: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: PanoramaSnapshot
    let relation: PanoramaRelation
    let backRegion: PanoramaRegion?
    @Binding var selection: PanoramaSelection?
    @Binding var focusedRegionID: String?
    let actions: ReaderActions

    var body: some View {
        let model = ConstellationModel(snapshot: snapshot, now: .now)
        let fromQuestion = model.questionByID[relation.from]
        let toQuestion = model.questionByID[relation.to]
        let anchor = fromQuestion.flatMap { model.regionByID[$0.regionID] }
        let areaIndex = anchor.flatMap { $0.areaIndex }
        let area = areaIndex.flatMap { index in model.areas.first { $0.identityIndex == index } }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    if let backRegion {
                        Button { selection = nil } label: {
                            Label("返回「\(backRegion.title)」", systemImage: "chevron.left")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("返回区域：" + backRegion.title)
                    }
                    Spacer(minLength: 0)
                    WorkspaceIconButton(systemImage: "xmark", label: "关闭检查器") {
                        selection = nil
                        focusedRegionID = nil
                    }
                }
                ReaderKicker(
                    dot: area.map { RegionIdentity.color(index: $0.identityIndex, scheme: colorScheme) } ?? palette.accent,
                    text: area.map { "大区 · " + $0.title } ?? "候选联系"
                )
                Text(relation.label).font(.title3.weight(.semibold))
                Text("AI 候选解释 · 尚待核对").font(.caption).foregroundStyle(palette.warning)
                Text(relation.explanation).vosFont(13).foregroundStyle(.secondary).textSelection(.enabled)
                ReaderEvidenceBlock(
                    label: "一侧原话",
                    question: fromQuestion,
                    evidence: relation.fromEvidence,
                    sources: snapshot.input.sources,
                    claims: snapshot.input.claims,
                    firstLineLimit: 3,
                    actions: actions,
                    openQuestion: { selection = .question(relation.from) }
                )
                ReaderEvidenceBlock(
                    label: "另一侧原话",
                    question: toQuestion,
                    evidence: relation.toEvidence,
                    sources: snapshot.input.sources,
                    claims: snapshot.input.claims,
                    firstLineLimit: 3,
                    actions: actions,
                    openQuestion: { selection = .question(relation.to) }
                )
                Text("对联系有异议，可沿线讨论。原话与理解更正分别返回材料的正式更正入口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ReaderPrimaryAction(title: "沿这条线索继续") {
                    actions.perform { actions.discuss(snapshot.id, .relation(relation.id)) }
                }
            }
            .padding(20)
        }
    }
}

private struct ReaderEvidenceBlock: View {
    @Environment(\.workspacePalette) private var palette
    let label: String
    let question: PanoramaQuestion?
    let evidence: [PanoramaEvidence]
    let sources: [PanoramaSource]
    let claims: [PanoramaClaim]
    let firstLineLimit: Int
    let actions: ReaderActions
    let openQuestion: (() -> Void)?
    @State private var showsMore = false

    var body: some View {
        let pairs = evidence.compactMap { item in
            sources.first(where: { $0.id == item.sourceID }).map { (item: item, source: $0) }
        }
        VStack(alignment: .leading, spacing: 8) {
            ReaderSectionLabel(label)
            if let question, let openQuestion {
                Button(action: openQuestion) {
                    Text(question.title)
                        .vosFont(11)
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("AI 归纳问题：" + question.title)
            }
            if let first = pairs.first {
                ReaderQuoteCard(item: first.item, source: first.source, claims: claims, lineLimit: firstLineLimit, actions: actions)
            } else {
                Text("尚无原话").vosFont(13).foregroundStyle(.secondary)
            }
            if pairs.count > 1 {
                ReaderDisclosure(title: "其他 \(pairs.count - 1) 处原话", expanded: $showsMore) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(pairs.dropFirst().enumerated()), id: \.offset) { _, pair in
                            ReaderQuoteCard(item: pair.item, source: pair.source, claims: claims, lineLimit: 3, actions: actions)
                        }
                    }
                }
            }
        }
    }
}

private struct ReaderQuoteCard: View {
    @Environment(\.workspacePalette) private var palette
    let item: PanoramaEvidence
    let source: PanoramaSource
    let claims: [PanoramaClaim]
    let lineLimit: Int
    let actions: ReaderActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(source.transcript.origin == "user" && source.transcript.speaker == "user" ? "我的原话" : "外部 / AI 来源 · 不代表本人认可")
                .font(.caption.weight(.medium))
            Text("“" + item.quote + "”")
                .vosFont(13)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
            let date = panoramaShortDate(source.occurredAt)
            Text((date.map { $0 + " · " } ?? "") + readerEvidenceTime(item, source: source) + " · " + source.title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 12) {
                Button("完整原文") { actions.perform { actions.openSource(item.sourceID) } }
                Button("更正原文") { actions.perform { actions.correctSource(item.sourceID) } }
                claimCorrectionMenu
                Spacer(minLength: 0)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.selection.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var claimCorrectionMenu: some View {
        if item.claimIDs.count == 1, let id = item.claimIDs.first {
            Button("更正理解或归属") { actions.perform { actions.correctClaim(id) } }
        } else if item.claimIDs.count > 1 {
            Menu("更正理解（\(item.claimIDs.count)）") {
                ForEach(Array(item.claimIDs.enumerated()), id: \.offset) { index, id in
                    Button(claimLabel(id, index: index)) { actions.perform { actions.correctClaim(id) } }
                }
            }
        }
    }

    private func claimLabel(_ id: String, index: Int) -> String {
        let statement = claims.first { $0.id == id }?.statement ?? ""
        guard !statement.isEmpty else { return "第 \(index + 1) 条理解" }
        return statement.count > 24 ? String(statement.prefix(24)) + "…" : statement
    }
}

private struct ReaderPrimaryAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: action) {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(8)
            }
            .buttonStyle(.borderedProminent)
            Text("带入相关完整表达与节目原文，先打开可编辑的 AI 候选草稿；点击发送后才成为你的提问。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReaderDisclosure<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    let content: () -> Content

    init(title: String, expanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _expanded = expanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .vosFont(10, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            if expanded { content() }
        }
    }
}

private struct ReaderKicker: View {
    let dot: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct ReaderSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct ReaderCappedText: View {
    @Environment(\.workspacePalette) private var palette
    let text: String
    let size: CGFloat
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .vosFont(size)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 60 {
                Button(expanded ? "收起" : "展开") { expanded.toggle() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.accent)
                    .accessibilityLabel(expanded ? "收起摘要" : "展开摘要")
            }
        }
    }
}

private struct ReaderQuestionRow: View {
    let question: PanoramaQuestion
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(question.title)
                    .vosFont(13, weight: .medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(question.evidence.count) 处原话")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(question.title)
        .accessibilityLabel("AI 归纳问题：" + question.title)
    }
}

private struct ReaderRelationRow: View {
    let relation: PanoramaRelation
    let fromTitle: String
    let toTitle: String
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                Text(relation.label)
                    .vosFont(12.5, weight: .medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(fromTitle + " ↔ " + toTitle)
                    .vosFont(11)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI 候选联系：" + relation.label)
    }
}

private func panoramaShortDate(_ iso: String) -> String? {
    let parts = iso.prefix(10).split(separator: "-")
    guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
    return "\(month)月\(day)日"
}
private func panoramaStageLabel(_ stage: String) -> String {
    switch stage {
    case "unit.generate", "unit.focus.generate", "unit.focus.regenerate": return "单元生成已完成"
    case "unit.verify", "unit.review", "unit.review-repair", "unit.repair", "unit.focus.repair": return "单元核对已完成"
    case "draft.areas", "draft.synthesize", "global.synthesize", "global.repair", "global.areas": return "全局整理已完成"
    case "global.consistency", "global.question", "global.relation", "global.coverage": return "全局核对已完成"
    default: return "已完成"
    }
}
private func readerEvidenceTime(_ item: PanoramaEvidence, source: PanoramaSource) -> String {
    let spans = source.transcript.spans.filter { $0.textEnd > item.start && $0.textStart < item.end }
    guard let start = spans.compactMap(\.startMS).min(), let end = spans.compactMap(\.endMS).max() else { return "文字来源" }
    func time(_ ms: Int) -> String { String(format: "%d:%02d", ms / 60000, (ms / 1000) % 60) }
    return time(start) + "–" + time(end)
}

struct PanoramaHome: View {
    @ObservedObject var screen: PanoramaScreenModel
    let retry: () -> Void
    let draft: () -> Void
    let chooseTextModel: () -> Void
    let openMaterials: () -> Void
    let openSource: (String) -> Void
    let correctSource: (String) -> Void
    let correctClaim: (String) -> Void
    let discuss: (String, PanoramaSelection) -> Void
    let themeReply: (PanoramaThemeBriefing) async throws -> String
    var body: some View {
        ThoughtPanoramaView(state: screen.state, message: screen.message, isGenerating: screen.isGenerating, modelConfigured: screen.modelConfigured, readError: screen.readError, selection: $screen.selection, retry: retry, draft: draft, retryRefresh: { screen.retryRefresh() }, dismissReadError: { screen.dismissReadError() }, chooseTextModel: chooseTextModel, openMaterials: openMaterials, openSource: openSource, correctSource: correctSource, correctClaim: correctClaim, discuss: discuss, themeReply: themeReply)
    }
}
