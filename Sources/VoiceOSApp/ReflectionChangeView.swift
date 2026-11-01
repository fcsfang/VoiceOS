import SwiftUI
import VoiceOSCore

/// These are evidence-backed relationship candidates, not an endorsed growth history.
struct ReflectionChangeView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let focus: ConversationReflectionFocus
    let reflect: (ConversationReflectionFocus, String) async -> Bool
    let dismissAtlas: () -> Void
    let embedded: Bool
    let close: (() -> Void)?
    let openSource: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var error: String?

    init(model: ControlCenter, focus: ConversationReflectionFocus, selectedConnectionID: String?,
         embedded: Bool = false, close: (() -> Void)? = nil, openSource: ((String) -> Void)? = nil,
         reflect: @escaping (ConversationReflectionFocus, String) async -> Bool, dismissAtlas: @escaping () -> Void) {
        self.model = model; self.focus = focus; self.reflect = reflect; self.dismissAtlas = dismissAtlas
        self.embedded = embedded; self.close = close; self.openSource = openSource
        _selectedID = State(initialValue: selectedConnectionID)
    }

    private var selected: ReflectionConnection? {
        focus.connections.first { $0.id == selectedID } ?? focus.connections.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                WorkspaceHero(eyebrow: "THOUGHTS IN CONTEXT", title: "认识对照", subtitle: "从前后原话出发，看看什么延续了，什么仍需核对。")
                Spacer()
                Button("返回地图", action: closeView).keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            if let selected {
                HStack(spacing: 0) {
                    if focus.connections.count > 1 {
                        connectionList.frame(width: 210)
                        Divider()
                    }
                    ScrollView {
                        comparison(selected).padding(24)
                    }
                }
            } else {
                ContentUnavailableView("这个周期还没有可对照的关联", systemImage: "rectangle.split.2x1", description: Text("后续表达与已有观点形成有依据的关联时，会在这里展示前后原话。也可以先从地图发起一次回顾。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error { Text(error).font(.callout).foregroundStyle(palette.danger).padding(16) }
        }.foregroundStyle(palette.text).background(palette.canvas)
            .frame(width: embedded ? nil : 960, height: embedded ? nil : 680)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var connectionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(focus.connections.count) 条关联候选").font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                ForEach(focus.connections) { connection in
                    Button { selectedID = connection.id } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(relation(connection.update.relation)).font(.caption).foregroundStyle(palette.accent)
                            Text(connection.update.understanding).font(.callout).lineLimit(4).multilineTextAlignment(.leading)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.accent.opacity(selected?.id == connection.id ? 0.10 : 0), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    }.buttonStyle(.plain)
                }
            }.padding(14)
        }.background(palette.surface)
    }
    private func comparison(_ connection: ReflectionConnection) -> some View {
        let update = connection.update
        let thought = focus.thoughts.first { $0.claimID == update.claimID }
        let historicalSources = Array(Set(thought?.evidence.filter { $0.quote.contains(update.historicalQuote) }.map { $0.reference.sourceID } ?? [])).sorted()
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(relation(update.relation)).font(.headline).foregroundStyle(palette.accent)
                Spacer()
                Text("AI 关系候选 · 待你核对").font(.caption).foregroundStyle(.secondary)
            }
            Text(update.understanding).font(.system(size: 19, weight: .medium, design: .serif)).textSelection(.enabled)
            HStack(alignment: .top, spacing: 14) {
                evidenceCard("此前原话", quote: update.historicalQuote, sourceIDs: historicalSources)
                evidenceCard("这次原话", quote: update.currentQuote, sourceIDs: [connection.sourceID])
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("为什么提出这条关联").font(.subheadline.bold())
                Text(update.reason).font(.callout).textSelection(.enabled)
            }
            Text("原话中的条件、犹豫与归属都属于依据。转写纠错不代表观点改变；支持或延续也不代表已经验证。这里不会自动确认你的认识发生了变化。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("接着问清楚").font(.system(size: 20, weight: .medium, design: .serif))
                Text("这个联系成立的条件是什么？有没有相反经历？哪些变化是我明确表达的，哪些只是 AI 的解释？")
                    .font(.callout)
                Button {
                    Task { if await reflect(focus, prompt(connection)) { closeView() } else { error = model.status } }
                } label: { Label("带着原话继续讨论", systemImage: "bubble.left.and.bubble.right") }
                    .buttonStyle(.borderedProminent).tint(palette.accent)
                    .disabled(model.discussionSaving || model.discussionSending || model.discussionExtracting || model.dictationActive)
                Text("先打开可编辑的问题，确认发送后再交给 AI。关联仍作为候选保留。").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func evidenceCard(_ title: String, quote: String, sourceIDs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
            Text(quote).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if sourceIDs.isEmpty { Text("请返回地图核对观点来源").font(.caption).foregroundStyle(.secondary) }
            ForEach(sourceIDs, id: \.self) { id in
                if let source = model.records.first(where: { $0.id == id }) {
                    Text(source.workspaceTitle).font(.caption.weight(.medium)).textSelection(.enabled)
                    Text(source.origin == "user" ? "个人表达" : source.origin == "ai" ? "AI 材料" : "外部资料 · 不代表我的观点").font(.caption).foregroundStyle(.secondary)
                    if let date = source.expressedDate { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                }
                Button("查看来源全文") {
                    if let openSource { openSource(id) }
                    else { model.requestWorkspaceSource(id); dismiss(); dismissAtlas() }
                }.font(.caption)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).stroke(palette.accent.opacity(0.14), lineWidth: 1) }
    }
    private func closeView() {
        if let close { close() } else { dismiss() }
    }
    private func relation(_ value: String) -> String {
        switch value {
        case "supports": "支持此前表达"
        case "qualifies": "补充条件与边界"
        case "contradicts": "存在分歧，值得核对"
        case "continues": "继续探索同一思路"
        default: "关系待核对"
        }
    }
    private func prompt(_ connection: ReflectionConnection) -> String {
        """
        请围绕这条 AI 关联候选，与我核对前后表达。使用回顾资料的完整来源，先说明原话的归属与语境。
        历史观点 ID：\(connection.update.claimID)
        本次来源 ID：\(connection.sourceID)
        此前原话：\(connection.update.historicalQuote)
        这次原话：\(connection.update.currentQuote)
        候选关系：\(relation(connection.update.relation))
        AI 当前解释：\(connection.update.understanding)
        请区分明确的表达变化、条件差异和你的推论；转写纠错不算观点变化，外部主张不算我的立场。追问这条关系成立的限制、可能的反例和仍缺少的证据，帮助我判断是否需要修正认识。不要替我确认成长，也不要把任务完成当成已经学会。
        """
    }
}
