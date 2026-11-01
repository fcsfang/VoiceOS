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
    let retryRefresh: () -> Void
    let dismissReadError: () -> Void
    let chooseTextModel: () -> Void
    let openMaterials: () -> Void
    let openSource: (String) -> Void
    let correctSource: (String) -> Void
    let correctClaim: (String) -> Void
    let discuss: (String, PanoramaSelection) -> Void
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
        if let selection {
            inspector(snapshot, selection: selection, performAction: performAction)
        } else if let focusedRegionID, let region = snapshot.proposal.regions.first(where: { $0.id == focusedRegionID }) {
            regionInspector(snapshot, region: region)
        }
    }

    private func constellationToolbar(width: CGFloat) -> some View {
        let compact = width < 900
        let minimal = width < 720
        return HStack(spacing: minimal ? 6 : compact ? 8 : 12) {
            Text("思考全景").font(.system(size: 16, weight: .semibold)).lineLimit(1)
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
                    .font(.system(size: 12))
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
            Text(text).font(.system(size: 12)).lineLimit(2)
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
                .font(.system(size: 12, weight: .medium))
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
            .font(.system(size: 11))
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
            .font(.system(size: 11))
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
            if iconOnly {
                Button { retry() } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
                    .buttonStyle(.borderless)
                    .help("继续核对")
                    .accessibilityLabel("继续核对")
            } else {
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
                        Text(region.title).font(.system(size: 13, weight: .medium))
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
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 62, weight: .light)).foregroundStyle(.secondary)
            }.padding(.bottom, 20)
            Text(state?.snapshot != nil ? "材料已核对，尚未形成持续问题" : isGenerating ? "让完整表达连成脉络" : "从表达中发现持续探索的问题").font(.title2)
            Text(toolbarMessage).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480).help(toolbarMessageHelp)
            HStack { Button("打开材料", action: openMaterials); if state?.snapshot == nil, state?.input.units.isEmpty == false { Button("生成或重试全景", action: retry).disabled(!modelConfigured || isGenerating || state?.status == "running") } }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func regionInspector(_ snapshot: PanoramaSnapshot, region: PanoramaRegion) -> some View {
        let model = ConstellationModel(snapshot: snapshot, now: .now)
        let questions = (model.regionByID[region.id]?.questionIDs ?? []).compactMap { model.questionByID[$0] }
        let incident = snapshot.proposal.relations.filter { relation in
            guard let from = model.questionByID[relation.from], let to = model.questionByID[relation.to] else { return false }
            return from.regionID == region.id || to.regionID == region.id
        }
        let evidenceCount = questions.reduce(0) { $0 + $1.evidence.count }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("探索区域 · AI 归纳").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    WorkspaceIconButton(systemImage: "xmark", label: "关闭区域摘要") { focusedRegionID = nil }
                }
                Text(region.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(region.summary).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("\(questions.count) 个问题 · \(evidenceCount) 处原话").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(questions) { question in
                        Button { self.selection = .question(question.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(question.title).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.leading)
                                Text("\(question.evidence.count) 处原话").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(palette.selection.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help(question.title)
                        .accessibilityLabel("AI 归纳问题：" + question.title)
                    }
                }
                if incident.isEmpty {
                    Text("当前区域尚无候选联系。").font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    Text("与这些问题相连的候选联系").font(.system(size: 14, weight: .semibold))
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(incident) { relation in
                            Button { self.selection = .relation(relation.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(model.questionByID[relation.from]?.title ?? "")
                                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                                        Text(model.questionByID[relation.to]?.title ?? "")
                                    }.font(.system(size: 13)).foregroundStyle(.secondary)
                                    Text(relation.label).font(.system(size: 14, weight: .medium))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(palette.selection.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12).stroke(
                                        self.selection == .relation(relation.id) ? palette.accent : palette.border,
                                        style: StrokeStyle(dash: [5, 4])
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("AI 候选联系：" + relation.label)
                        }
                    }
                    Text("虚线 · AI 候选联系，尚待核对").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
    }

    private func inspector(_ snapshot: PanoramaSnapshot, selection: PanoramaSelection, performAction: @escaping (@escaping () -> Void) -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let focusedRegionID, let region = snapshot.proposal.regions.first(where: { $0.id == focusedRegionID }) {
                    Button { self.selection = nil } label: {
                        Label("返回「\(region.title)」", systemImage: "chevron.left").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("返回区域：" + region.title)
                }
                HStack {
                    Text("核对这条线索").font(.headline)
                    Spacer()
                    WorkspaceIconButton(systemImage: "xmark", label: "关闭检查器") {
                        self.selection = nil
                        self.focusedRegionID = nil
                    }
                }
                switch selection {
                case .question(let id):
                    if let question = snapshot.proposal.questions.first(where: { $0.id == id }) {
                        Text(question.title).font(.title3.weight(.semibold))
                        Text("AI 归纳 · 未表示本人认可").font(.caption).foregroundStyle(.secondary)
                        Text(question.summary)
                        evidenceList(question.evidence, snapshot: snapshot, performAction: performAction)
                        ForEach(snapshot.proposal.relations.filter { $0.from == id || $0.to == id }) { relation in
                            Button("候选联系 · " + relation.label) { self.selection = .relation(relation.id) }
                        }
                    }
                case .relation(let id):
                    if let relation = snapshot.proposal.relations.first(where: { $0.id == id }) {
                        Text(relation.label).font(.title3.weight(.semibold))
                        Text("AI 候选解释 · 尚待核对").font(.caption).foregroundStyle(palette.warning)
                        Text(relation.explanation).textSelection(.enabled)
                        ForEach(snapshot.proposal.questions.filter { $0.id == relation.from || $0.id == relation.to }) { question in
                            Button(question.title) { self.selection = .question(question.id) }
                        }
                        Text("一侧原话").font(.headline)
                        evidenceList(relation.fromEvidence, snapshot: snapshot, performAction: performAction)
                        Text("另一侧原话").font(.headline)
                        evidenceList(relation.toEvidence, snapshot: snapshot, performAction: performAction)
                        Text("对联系有异议，可沿线讨论。原话与理解更正分别返回材料的正式更正入口。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { performAction { discuss(snapshot.id, selection) } } label: { HStack { Text("沿这条线索继续"); Spacer(); Image(systemName: "arrow.right") }.padding(8) }.buttonStyle(.borderedProminent)
                Text("带入相关完整表达与节目原文，先打开可编辑的 AI 候选草稿；点击发送后才成为你的提问。").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }

    private func evidenceList(_ evidence: [PanoramaEvidence], snapshot: PanoramaSnapshot, performAction: @escaping (@escaping () -> Void) -> Void) -> some View {
        ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
            if let source = snapshot.input.sources.first(where: { $0.id == item.sourceID }) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(source.transcript.origin == "user" && source.transcript.speaker == "user" ? "我的原话" : "外部 / AI 来源 · 不代表本人认可").font(.caption.weight(.medium))
                    Text("“" + item.quote + "”").textSelection(.enabled)
                    Text(source.occurredAt + " · " + source.title).font(.caption).foregroundStyle(.secondary)
                    Text(evidenceTime(item, source: source) + " · 当前原文第 \(item.start)–\(item.end) 字符").font(.caption2).foregroundStyle(.secondary)
                    HStack { Button("完整原文") { performAction { openSource(item.sourceID) } }; Button("更正原文") { performAction { correctSource(item.sourceID) } } }
                    ForEach(item.claimIDs, id: \.self) { id in Button("更正这条理解或归属") { performAction { correctClaim(id) } } }
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(palette.selection.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
            }
        }
    }

    private func evidenceTime(_ item: PanoramaEvidence, source: PanoramaSource) -> String {
        let spans = source.transcript.spans.filter { $0.textEnd > item.start && $0.textStart < item.end }
        guard let start = spans.compactMap(\.startMS).min(), let end = spans.compactMap(\.endMS).max() else { return "文字来源" }
        func time(_ ms: Int) -> String { String(format: "%d:%02d", ms / 60000, (ms / 1000) % 60) }
        return time(start) + "–" + time(end)
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
                                    Text(item.stage + " · " + item.receipt.responseID).font(.caption).textSelection(.enabled)
                                }
                            } else {
                                Text("生成回执 · " + snapshot.generation.responseID).font(.caption).textSelection(.enabled)
                                Text("独立核对回执 · " + snapshot.verification.responseID).font(.caption).textSelection(.enabled)
                            }
                            Text("输入摘要 · " + snapshot.input.manifest.digest).font(.caption).textSelection(.enabled)
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

struct PanoramaHome: View {
    @ObservedObject var screen: PanoramaScreenModel
    let retry: () -> Void
    let chooseTextModel: () -> Void
    let openMaterials: () -> Void
    let openSource: (String) -> Void
    let correctSource: (String) -> Void
    let correctClaim: (String) -> Void
    let discuss: (String, PanoramaSelection) -> Void
    var body: some View {
        ThoughtPanoramaView(state: screen.state, message: screen.message, isGenerating: screen.isGenerating, modelConfigured: screen.modelConfigured, readError: screen.readError, selection: $screen.selection, retry: retry, retryRefresh: { screen.retryRefresh() }, dismissReadError: { screen.dismissReadError() }, chooseTextModel: chooseTextModel, openMaterials: openMaterials, openSource: openSource, correctSource: correctSource, correctClaim: correctClaim, discuss: discuss)
    }
}
