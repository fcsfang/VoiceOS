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
    @State private var zoom = 1.0
    @State private var gestureZoom = 1.0
    @State private var showCoverage = false
    private let palette: [Color] = [.green, .blue, .orange, .purple, .teal, .pink]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if let snapshot = state?.snapshot, !snapshot.proposal.questions.isEmpty {
                        graph(snapshot)
                        HStack(spacing: 16) {
                            Label("AI 归纳的问题", systemImage: "circle")
                            Label("虚线 · AI 候选联系，待核对", systemImage: "line.diagonal")
                            Spacer()
                            Button { zoom = max(0.5, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                            Button("\(Int(zoom * 100))%") { zoom = 1 }
                            Button { zoom = min(2, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                        }.font(.caption).foregroundStyle(.secondary).padding(16)
                        accessibleOutline(snapshot)
                    } else {
                        emptyState
                    }
                    Divider()
                    coverageButton
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let snapshot = state?.snapshot, let selection {
                    Divider()
                    inspector(snapshot, selection: selection).frame(width: 310)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCoverage) { coverage.frame(minWidth: 620, minHeight: 480) }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("思考全景").font(.system(size: 28, weight: .semibold))
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("时间高亮", selection: $recent) { Text("近期高亮").tag(true); Text("全部").tag(false) }.pickerStyle(.segmented).frame(width: 170)
                Button("材料", systemImage: "doc.on.doc", action: openMaterials)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找问题与联系，长期节点始终保留", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                if isGenerating { ProgressView().controlSize(.small) }
                else if !modelConfigured { Button("连接文本模型", action: chooseTextModel) }
                else if let state, ["failed", "unknown"].contains(state.status) { Button("重新生成", action: retry) }
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
        let layout = PanoramaLayout(snapshot.proposal)
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(snapshot.proposal.regions.enumerated()), id: \.element.id) { index, region in
                    let frame = layout.regions[region.id]!
                    let color = palette[index % palette.count]
                    RoundedRectangle(cornerRadius: 95).fill(color.opacity(0.055))
                        .overlay { RoundedRectangle(cornerRadius: 95).stroke(color.opacity(0.06), lineWidth: 1) }
                        .frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(region.title).font(.title3.weight(.semibold)).foregroundStyle(color)
                        Text(region.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(region.summary)
                    }.frame(width: frame.width - 70, alignment: .leading).position(x: frame.midX, y: frame.minY + 50)
                }
                Canvas { context, _ in
                    for relation in snapshot.proposal.relations {
                        guard let a = layout.questions[relation.from], let b = layout.questions[relation.to], let label = layout.relationLabels[relation.id] else { continue }
                        var path = Path(); path.move(to: a)
                        path.addQuadCurve(to: b, control: CGPoint(x: label.x * 2 - (a.x+b.x)/2, y: label.y * 2 - (a.y+b.y)/2))
                        context.stroke(path, with: .color(selection == .relation(relation.id) ? .accentColor : .secondary.opacity(0.45)), style: StrokeStyle(lineWidth: selection == .relation(relation.id) ? 2.5 : 1.5, dash: [6,5]))
                    }
                }.frame(width: layout.size.width, height: layout.size.height).allowsHitTesting(false)
                ForEach(snapshot.proposal.relations) { relation in
                    if let point = layout.relationLabels[relation.id] {
                        Button { selection = .relation(relation.id) } label: {
                            Text(relation.label).font(.caption.weight(.medium)).lineLimit(2).frame(width: 200, height: 34).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color(nsColor: .windowBackgroundColor).opacity(0.96), in: Capsule())
                                .overlay { Capsule().stroke(selection == .relation(relation.id) ? Color.accentColor : .secondary.opacity(0.2)) }
                        }.buttonStyle(.plain).position(point).help(relation.label)
                            .opacity(matches(relation.label + relation.explanation) ? 1 : 0.3)
                            .accessibilityLabel("AI 候选联系：" + relation.label)
                    }
                }
                ForEach(snapshot.proposal.questions) { question in
                    if let point = layout.questions[question.id] {
                        questionNode(question, snapshot: snapshot).position(point)
                    }
                }
            }.frame(width: layout.size.width, height: layout.size.height)
                .scaleEffect(zoom * gestureZoom, anchor: .topLeading)
                .frame(width: layout.size.width * zoom * gestureZoom, height: layout.size.height * zoom * gestureZoom, alignment: .topLeading)
                .padding(18)
        }.gesture(MagnifyGesture().onChanged { gestureZoom = $0.magnification }.onEnded { zoom = min(2,max(0.5,zoom * $0.magnification)); gestureZoom = 1 })
    }
    private func questionNode(_ question: PanoramaQuestion, snapshot: PanoramaSnapshot) -> some View {
        let index = snapshot.proposal.regions.firstIndex { $0.id == question.regionID } ?? 0
        let color = palette[index % palette.count]
        let selected = selection == .question(question.id)
        let highlighted = recent && isRecent(question, snapshot: snapshot)
        return Button { selection = .question(question.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(color.opacity(0.8)).frame(width: 9, height: 9).padding(.top, 5)
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.title).font(.system(size: 14, weight: .semibold)).lineLimit(3)
                    Text(question.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }.padding(16).frame(width: 225, alignment: .leading).frame(minHeight: 92)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 24))
                .overlay { RoundedRectangle(cornerRadius: 24).stroke(selected ? Color.accentColor : color.opacity(0.22), lineWidth: selected ? 2 : 1) }
                .shadow(color: selected ? Color.accentColor.opacity(0.18) : color.opacity(highlighted ? 0.15 : 0.04), radius: selected ? 16 : 10)
                .padding(6).background(selected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 29))
        }.buttonStyle(.plain).opacity(matches(question.title + question.summary) ? 1 : 0.25)
            .accessibilityLabel("AI 归纳问题：" + question.title)
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
                    ForEach(snapshot.proposal.questions) { question in Button(question.title) { selection = .question(question.id) } }
                    ForEach(snapshot.proposal.relations) { relation in Button("AI 候选联系 · " + relation.label) { selection = .relation(relation.id) } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
        }.padding(.horizontal, 18).padding(.bottom, 12)
    }
    private func inspector(_ snapshot: PanoramaSnapshot, selection: PanoramaSelection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("核对这条线索").font(.headline); Spacer(); Button { self.selection = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                switch selection {
                case .question(let id):
                    if let question = snapshot.proposal.questions.first(where: { $0.id == id }) {
                        Text(question.title).font(.title3.weight(.semibold))
                        Text("AI 归纳 · 未表示本人认可").font(.caption).foregroundStyle(.secondary)
                        Text(question.summary)
                        evidenceList(question.evidence, snapshot: snapshot)
                        ForEach(snapshot.proposal.relations.filter { $0.from == id || $0.to == id }) { relation in
                            Button("候选联系 · " + relation.label) { self.selection = .relation(relation.id) }
                        }
                    }
                case .relation(let id):
                    if let relation = snapshot.proposal.relations.first(where: { $0.id == id }) {
                        Text(relation.label).font(.title3.weight(.semibold))
                        Text("AI 候选解释 · 尚待核对").font(.caption).foregroundStyle(.blue)
                        Text(relation.explanation).textSelection(.enabled)
                        Text("一侧原话").font(.headline)
                        evidenceList(relation.fromEvidence, snapshot: snapshot)
                        Text("另一侧原话").font(.headline)
                        evidenceList(relation.toEvidence, snapshot: snapshot)
                        Text("对联系有异议，可沿线讨论。原话与理解更正分别返回材料的正式更正入口。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { discuss(snapshot.id, selection) } label: { HStack { Text("沿这条线索继续"); Spacer(); Image(systemName: "arrow.right") }.padding(8) }.buttonStyle(.borderedProminent)
                Text("带入相关完整表达与节目原文，先打开可编辑的 AI 候选草稿；点击发送后才成为你的提问。").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
    private func evidenceList(_ evidence: [PanoramaEvidence], snapshot: PanoramaSnapshot) -> some View {
        ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
            if let source = snapshot.input.sources.first(where: { $0.id == item.sourceID }) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(source.transcript.origin == "user" && source.transcript.speaker == "user" ? "我的原话" : "外部 / AI 来源 · 不代表本人认可").font(.caption.weight(.medium))
                    Text("“" + item.quote + "”").textSelection(.enabled)
                    Text(source.occurredAt + " · " + source.title).font(.caption).foregroundStyle(.secondary)
                    Text(evidenceTime(item, source: source) + " · 当前原文第 \(item.start)–\(item.end) 字符").font(.caption2).foregroundStyle(.secondary)
                    HStack { Button("完整原文") { openSource(item.sourceID) }; Button("更正原文") { correctSource(item.sourceID) } }
                    ForEach(item.claimIDs, id: \.self) { id in Button("更正这条理解或归属") { correctClaim(id) } }
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
                        Text("输入不按近期或条数裁剪。仅完整整理、当前版本与许可均有效的材料入选；节目依赖单独计数。AI 未归入项仍保留完整入口。")
                        ForEach(state.input.sources) { source in
                            HStack { Text(source.title); Spacer(); Text(state.snapshot == nil ? "等待全景核对" : state.snapshot?.coverage.representedSourceIDs.contains(source.id) == true ? "已表达" : "未归入具体问题").foregroundStyle(.secondary); Button("全文") { showCoverage = false; openSource(source.id) } }
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
                            Divider(); Text("生成回执 · " + snapshot.generation.responseID).font(.caption).textSelection(.enabled)
                            Text("独立核对回执 · " + snapshot.verification.responseID).font(.caption).textSelection(.enabled)
                            Text("输入摘要 · " + snapshot.input.manifest.digest).font(.caption).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24)
    }
}

private struct PanoramaLayout {
    let regions: [String: CGRect]
    let questions: [String: CGPoint]
    let relationLabels: [String: CGPoint]
    let size: CGSize
    init(_ proposal: PanoramaProposal) {
        let columns = max(1, Int(ceil(sqrt(Double(proposal.regions.count)))))
        let width: CGFloat = 570
        var regions: [String: CGRect] = [:], questions: [String: CGPoint] = [:]
        var y: CGFloat = 12, maxX: CGFloat = 0
        for rowStart in stride(from: 0, to: proposal.regions.count, by: columns) {
            let row = Array(proposal.regions[rowStart..<min(proposal.regions.count, rowStart + columns)])
            let rowHeight = row.map { region -> CGFloat in
                let count = proposal.questions.filter { $0.regionID == region.id }.count
                return max(320, 140 + CGFloat((count + 1) / 2) * 155)
            }.max() ?? 320
            for (column, region) in row.enumerated() {
                let x = CGFloat(column) * (width + 35) + 12
                regions[region.id] = CGRect(x: x, y: y, width: width, height: rowHeight)
                let nodes = proposal.questions.filter { $0.regionID == region.id }
                for (index, question) in nodes.enumerated() {
                    questions[question.id] = CGPoint(x: x + (index % 2 == 0 ? 150 : 420), y: y + 165 + CGFloat(index / 2) * 155 + (index % 2 == 0 ? 0 : 38))
                }
                maxX = max(maxX, x + width)
            }
            y += rowHeight + 28
        }
        let nodeFrames = questions.values.map { CGRect(x: $0.x - 125, y: $0.y - 75, width: 250, height: 150) }
        var labelFrames: [CGRect] = [], relationLabels: [String: CGPoint] = [:]
        for relation in proposal.relations.sorted(by: { $0.id < $1.id }) {
            guard let a = questions[relation.from], let b = questions[relation.to] else { continue }
            var frame = CGRect(x: (a.x+b.x)/2 - 110, y: (a.y+b.y)/2 - 24, width: 220, height: 48)
            while (labelFrames + nodeFrames).contains(where: { $0.intersects(frame) }) { frame.origin.y += 56 }
            labelFrames.append(frame)
            relationLabels[relation.id] = CGPoint(x: frame.midX, y: frame.midY)
        }
        self.regions = regions; self.questions = questions; self.relationLabels = relationLabels
        size = CGSize(width: max(600, maxX + 12), height: max(400, y, (labelFrames.map(\.maxY).max() ?? 0) + 24))
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
