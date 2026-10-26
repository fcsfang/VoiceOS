import SwiftUI
import VoiceOSCore

struct ThoughtPanoramaView: View {
    let state: PanoramaState?
    let message: String
    let isGenerating: Bool
    let modelConfigured: Bool
    @Binding var selection: PanoramaSelection?
    let retry: () -> Void
    let chooseTextModel: () -> Void
    let openMaterials: () -> Void
    let openSource: (String) -> Void
    let correctSource: (String) -> Void
    let correctClaim: (String) -> Void
    let discuss: (String, PanoramaSelection) -> Void
    @State private var query = ""
    @State private var recent = true
    @State private var focusedRegionID: String?
    @State private var showCoverage = false
    @State private var pendingReaderAction: (() -> Void)?
    private let palette: [Color] = [.green, .blue, .orange, .purple, .teal, .pink]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                let hasSideReader = geometry.size.width >= 740
                HStack(spacing: 0) {
                    panorama
                    if hasSideReader, let snapshot = state?.snapshot, let selection {
                        Divider()
                        inspector(snapshot, selection: selection, performAction: { action in
                            self.selection = nil
                            action()
                        }).frame(width: 310)
                    }
                }
                .sheet(isPresented: Binding(
                    get: { !hasSideReader && state?.snapshot != nil && selection != nil },
                    set: { if !$0 && !hasSideReader { selection = nil } }
                ), onDismiss: {
                    let action = pendingReaderAction
                    pendingReaderAction = nil
                    action?()
                }) {
                    if let snapshot = state?.snapshot, let selection {
                        inspector(snapshot, selection: selection, performAction: { action in
                            pendingReaderAction = action
                            self.selection = nil
                        }).frame(minWidth: 540, minHeight: 480)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCoverage) { coverage.frame(minWidth: 620, minHeight: 480) }
        .onAppear { reconcileNavigation() }
        .onChange(of: navigationIDs) { _, _ in reconcileNavigation() }
        .onChange(of: selection) { _, _ in focusSelection() }
    }
    private var panorama: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = state?.snapshot, !snapshot.proposal.questions.isEmpty {
                graph(snapshot)
                accessibleOutline(snapshot)
            } else {
                emptyState
            }
            Divider()
            coverageButton
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("思考全景").font(.system(size: 28, weight: .semibold))
                Spacer()
                Picker("时间高亮", selection: $recent) { Text("近期高亮").tag(true); Text("全部").tag(false) }.pickerStyle(.segmented).frame(width: 170)
                Button("材料", systemImage: "doc.on.doc", action: openMaterials)
            }
            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let snapshot = state?.snapshot, snapshot.isPartial {
                Text("已核对 \(snapshot.workflow?.verifiedUnitIDs.count ?? 0)/\(snapshot.workflow?.totalUnitCount ?? 0) 个完整单元 · 仅显示已核对区域，跨材料联系与全局覆盖尚未完成").font(.system(size: 13)).foregroundStyle(.orange)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找问题与联系，长期节点始终保留", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除查找") }
                if isGenerating { ProgressView().controlSize(.small) }
                else if !modelConfigured { Button("连接文本模型", action: chooseTextModel) }
                else if let state, ["failed", "unknown"].contains(state.status) { Button("继续核对", action: retry) }
            }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        }.padding(22)
    }
    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Ellipse().fill(.green.opacity(0.08)).frame(width: 300, height: 190).rotationEffect(.degrees(-15))
                Ellipse().fill(.blue.opacity(0.08)).frame(width: 240, height: 160).offset(x: 110, y: 40)
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 62, weight: .light)).foregroundStyle(.secondary)
            }.padding(.bottom, 20)
            Text(state?.snapshot != nil ? "材料已核对，尚未形成持续问题" : isGenerating ? "让完整表达连成脉络" : "从表达中发现持续探索的问题").font(.title2)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            HStack { Button("打开材料", action: openMaterials); if state?.snapshot == nil, state?.input.units.isEmpty == false { Button("生成或重试全景", action: retry).disabled(!modelConfigured || isGenerating || state?.status == "running") } }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func graph(_ snapshot: PanoramaSnapshot) -> some View {
        let chronology = PanoramaChronology(snapshot)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if focusedRegionID != nil {
                    Button { focusedRegionID = nil; selection = nil } label: { Label("全部区域", systemImage: "arrow.left") }
                }
                Text(focusedRegionID == nil ? "\(snapshot.proposal.regions.count) 个探索区域 · \(snapshot.proposal.questions.count) 个问题" : "聚焦区域 · 点击问题核对原话")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            if let region = snapshot.proposal.regions.first(where: { $0.id == focusedRegionID }) {
                regionContext(snapshot)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(region.title).font(.title2.weight(.semibold)).foregroundStyle(regionColor(region.id, snapshot: snapshot))
                                Text(region.summary).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                            ForEach(chronology.questions.filter { $0.regionID == region.id }) { question in
                                questionNode(question, snapshot: snapshot)
                            }
                        }
                        relationContacts(snapshot, regionID: region.id)
                    }.padding(18)
                }.id(region.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 8)], spacing: 8) {
                            ForEach(chronology.regions) { region in regionNode(region, snapshot: snapshot) }
                        }
                        relationContacts(snapshot, regionID: nil)
                    }.padding(18)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func regionNode(_ region: PanoramaRegion, snapshot: PanoramaSnapshot) -> some View {
        let questions = snapshot.proposal.questions.filter { $0.regionID == region.id }
        let questionIDs = Set(questions.map(\.id))
        let color = regionColor(region.id, snapshot: snapshot)
        let highlighted = recent && questions.contains { isRecent($0, snapshot: snapshot) }
        let matching = matches(region.title + region.summary) || questions.contains { matches($0.title + $0.summary) }
            || snapshot.proposal.relations.contains {
                (questionIDs.contains($0.from) || questionIDs.contains($0.to)) && matches($0.label + $0.explanation)
            }
        return Button { focusRegion(region.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text("\(questions.count) 个问题").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if highlighted { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("近期有表达") }
                }.font(.system(size: 13))
                Text(region.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(11).frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(color.opacity(highlighted ? 0.11 : 0.055), in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(color.opacity(highlighted ? 0.4 : 0.2)) }
        }.buttonStyle(.plain).opacity(matching ? 1 : 0.3).help(region.title)
            .accessibilityLabel("探索区域：\(region.title)，\(questions.count) 个问题，点击展开")
    }
    private func regionContext(_ snapshot: PanoramaSnapshot) -> some View {
        let chronology = PanoramaChronology(snapshot)
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(chronology.regions) { region in
                    Button { focusRegion(region.id) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(regionColor(region.id, snapshot: snapshot)).frame(width: 7, height: 7)
                            Text(region.title).lineLimit(1)
                            Text("\(snapshot.proposal.questions.filter { $0.regionID == region.id }.count)").foregroundStyle(.secondary)
                        }.font(.system(size: 13)).padding(.horizontal, 11).padding(.vertical, 8)
                            .background(focusedRegionID == region.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: Capsule())
                            .overlay { Capsule().stroke(focusedRegionID == region.id ? Color.accentColor.opacity(0.5) : .clear) }
                    }.buttonStyle(.plain).help(region.title)
                }
            }.padding(.horizontal, 18)
        }.padding(.bottom, 8)
    }
    private func relationContacts(_ snapshot: PanoramaSnapshot, regionID: String?) -> some View {
        let questions = Dictionary(uniqueKeysWithValues: snapshot.proposal.questions.map { ($0.id, $0) })
        let relations = snapshot.proposal.relations.filter { relation in
            guard let from = questions[relation.from], let to = questions[relation.to] else { return false }
            return regionID.map { from.regionID == $0 || to.regionID == $0 } ?? (from.regionID != to.regionID)
        }
        return VStack(alignment: .leading, spacing: 10) {
            if !relations.isEmpty {
                Text(regionID == nil ? "区域之间的候选联系" : "与这些问题相连").font(.system(size: 14, weight: .semibold))
                ForEach(relations) { relation in
                    Button { selection = .relation(relation.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 6) {
                                Text(contactTitle(questions[relation.from], snapshot: snapshot, regionID: regionID))
                                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                                Text(contactTitle(questions[relation.to], snapshot: snapshot, regionID: regionID))
                            }.font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(relation.label).font(.system(size: 14, weight: .medium))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(selection == .relation(relation.id) ? Color.accentColor : .secondary.opacity(0.2), style: StrokeStyle(dash: [5, 4])) }
                    }.buttonStyle(.plain).opacity(matches(relation.label + relation.explanation) ? 1 : 0.3)
                        .accessibilityLabel("AI 候选联系：" + relation.label)
                }
                Text("虚线 · AI 候选联系，尚待核对").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text(snapshot.isPartial ? "跨材料联系尚未完成；当前只展示已核对区域。" : regionID == nil ? "当前没有已核对的跨区域候选联系。" : "当前区域尚无候选联系。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func contactTitle(_ question: PanoramaQuestion?, snapshot: PanoramaSnapshot, regionID: String?) -> String {
        guard let question else { return "" }
        if regionID != nil { return question.title }
        return snapshot.proposal.regions.first(where: { $0.id == question.regionID })?.title ?? question.title
    }
    private func questionNode(_ question: PanoramaQuestion, snapshot: PanoramaSnapshot) -> some View {
        let color = regionColor(question.regionID, snapshot: snapshot)
        let selected = selection == .question(question.id)
        let highlighted = recent && isRecent(question, snapshot: snapshot)
        return Button { selection = .question(question.id) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(highlighted ? "近期有表达" : "AI 归纳问题").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                Text(question.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("\(question.evidence.count) 处原话").font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.accentColor : color.opacity(highlighted ? 0.5 : 0.22), lineWidth: selected ? 2 : 1) }
        }.buttonStyle(.plain).opacity(matches(question.title + question.summary) ? 1 : 0.25)
            .accessibilityLabel("AI 归纳问题：" + question.title)
    }
    private func regionColor(_ id: String, snapshot: PanoramaSnapshot) -> Color {
        palette[(snapshot.proposal.regions.firstIndex { $0.id == id } ?? 0) % palette.count]
    }
    private func focusRegion(_ id: String) {
        focusedRegionID = id
        selection = nil
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
    private func matches(_ text: String) -> Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private func isRecent(_ question: PanoramaQuestion, snapshot: PanoramaSnapshot) -> Bool {
        let recentIDs = Set(snapshot.input.sources.filter { source in
            guard let date = ISO8601DateFormatter().date(from: source.occurredAt) else { return false }
            return date >= Date().addingTimeInterval(-14 * 86400)
        }.map(\.id))
        return question.evidence.contains { recentIDs.contains($0.sourceID) }
    }
    private func accessibleOutline(_ snapshot: PanoramaSnapshot) -> some View {
        DisclosureGroup("问题与联系列表 · 键盘与辅助阅读") {
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(PanoramaChronology(snapshot).questions) { question in Button(question.title) { selection = .question(question.id) } }
                    ForEach(snapshot.proposal.relations) { relation in Button("AI 候选联系 · " + relation.label) { selection = .relation(relation.id) } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
    private func inspector(_ snapshot: PanoramaSnapshot, selection: PanoramaSelection, performAction: @escaping (@escaping () -> Void) -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("核对这条线索").font(.headline); Spacer(); Button { self.selection = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
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
                        Text("AI 候选解释 · 尚待核对").font(.caption).foregroundStyle(.blue)
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
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
            }
        }
    }
    private func evidenceTime(_ item: PanoramaEvidence, source: PanoramaSource) -> String {
        let spans = source.transcript.spans.filter { $0.textEnd > item.start && $0.textStart < item.end }
        guard let start = spans.compactMap(\.startMS).min(), let end = spans.compactMap(\.endMS).max() else { return "文字来源" }
        func time(_ ms: Int) -> String { String(format: "%d:%02d", ms / 60000, (ms / 1000) % 60) }
        return time(start) + "–" + time(end)
    }
    private var coverageButton: some View {
        HStack {
            if let state {
                Text("\(state.input.units.count) 个完整单元 · \(state.input.sources.count) 份来源 · \(dependencyCount(state.input)) 份节目依赖 · \(state.input.claims.count) 条当前认识").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("覆盖与未归入项", action: { showCoverage = true })
            } else { Button("打开材料", action: openMaterials) }
        }.padding(14)
    }
    private func dependencyCount(_ input: PanoramaInput) -> Int {
        Set(input.units.flatMap(\.dependencyIDs)).count
    }
    private var coverage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("完整材料与覆盖情况").font(.title2); Spacer(); Button("关闭") { showCoverage = false } }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let state {
                        if let snapshot=state.snapshot, snapshot.isPartial {
                            Text("这是已核对区域。其余完整单元、跨单元联系与全局覆盖尚未完成；当前结果不代表本人认可。").foregroundStyle(.orange)
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
        ThoughtPanoramaView(state: screen.state, message: screen.message, isGenerating: screen.isGenerating, modelConfigured: screen.modelConfigured, selection: $screen.selection, retry: retry, chooseTextModel: chooseTextModel, openMaterials: openMaterials, openSource: openSource, correctSource: correctSource, correctClaim: correctClaim, discuss: discuss)
    }
}

private struct PanoramaChronology {
    let regions: [PanoramaRegion]
    let questions: [PanoramaQuestion]

    init(_ snapshot: PanoramaSnapshot) {
        let formatter = ISO8601DateFormatter()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sourceDates = Dictionary(uniqueKeysWithValues: snapshot.input.sources.map { source in
            (source.id, formatter.date(from: source.occurredAt)
                ?? fractionalFormatter.date(from: source.occurredAt) ?? .distantPast)
        })
        let questionDates = Dictionary(uniqueKeysWithValues: snapshot.proposal.questions.map { question in
            (question.id, question.evidence.compactMap { sourceDates[$0.sourceID] }.max() ?? .distantPast)
        })
        let regionDates = Dictionary(grouping: snapshot.proposal.questions, by: \.regionID).mapValues { questions in
            questions.compactMap { questionDates[$0.id] }.max() ?? .distantPast
        }
        questions = snapshot.proposal.questions.enumerated().sorted { lhs, rhs in
            let left = questionDates[lhs.element.id] ?? .distantPast
            let right = questionDates[rhs.element.id] ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        regions = snapshot.proposal.regions.enumerated().sorted { lhs, rhs in
            let left = regionDates[lhs.element.id] ?? .distantPast
            let right = regionDates[rhs.element.id] ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }
}
