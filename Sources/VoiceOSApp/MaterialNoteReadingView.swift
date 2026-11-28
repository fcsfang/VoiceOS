import Foundation
import SwiftUI
import VoiceOSCore

/// Article-shaped reading surface for one expression's saved note. The center
/// owns generation and persistence; this view only reads the newest revision,
/// keeps it current against member transcript versions, and renders the note as
/// an article. Paragraph anchors stay in the saved note as an audit trail, but
/// the product surface does not show them; raw material lives on the material
/// page behind 「查看材料与原文」.
private struct MaterialNoteReadKey: Hashable {
    let sourceID: String
    let transcriptVersionID: String?
    let policyVersion: Int
    let state: String
    let revision: Int
    let members: [String]
}

private struct MaterialNoteRequestKey: Hashable {
    let sourceID: String
    let members: [String]
}

private struct MaterialNoteDisplay: Equatable {
    let note: StoredMaterialNote
    let isCurrent: Bool
}

private struct HistoryConnectorAnchors: PreferenceKey {
    enum Endpoint: Hashable {
        case paragraph(String)
        case card(String)
        case articleViewport
        case listViewport
    }

    static let defaultValue: [Endpoint: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Endpoint: Anchor<CGRect>], nextValue: () -> [Endpoint: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum NoteSidebarTab: String, Hashable {
    case history = "历史批注"
    case discussion = "AI 讨论"
}

struct MaterialNoteReadingView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    var openSource: (String) -> Void = { _ in }
    var openTask: (String) -> Void = { _ in }
    var openDiscussion: (String) -> Void = { _ in }
    var openHistoryNote: ((String) -> Void)? = nil
    var backToNotes: (() -> Void)? = nil
    var relatedActions: [ActionRecord] = []
    var relatedDiscussions: [ConversationRecord] = []
    @Binding var hasNote: Bool
    /// 材料页的滚动位置；重开页面时据此回到上次读到的段落。
    var restoreScroll: Binding<ScrollPosition>? = nil
    var sidebar: Binding<NoteSidebarTab?>? = nil
    var discussionPanel: AnyView? = nil
    var discussParagraph: ((String) -> Void)? = nil
    var materialReader = false

    @State private var display: MaterialNoteDisplay?
    @State private var editing: StoredMaterialNote?
    @State private var replacement: StoredMaterialNote?
    @State private var requested = false
    @State private var loadedOnce = false
    @AppStorage("voiceos.note.annotations.visible") private var annotationsVisible = true
    @State private var probeBox = NoteReadingProbeBox()
    @State private var hasRestored = false
    @State private var boardNotice: String?
    @State private var historyResult: NoteHistoryResult?
    @State private var historyRun = false
    @State private var historyNotice: String?
    @State private var historySelection: String?
    private var historyPresented: Bool { sidebar?.wrappedValue == .history }
    @State private var articlePosition = ScrollPosition(edge: .top)

    private var catalog: [String: SourceRecord] { model.sourcePageIndex.recordsByID }
    private var expression: RecordingExpression? { model.sourcePageIndex.expression(for: source.id) }
    private var memberIDs: [String] {
        guard let expression else { return [source.id] }
        let external = (expression.externalVersions ?? [:]).keys.sorted()
        return expression.sourceIDs + external.filter { !expression.sourceIDs.contains($0) }
    }
    private var memberRecords: [SourceRecord] { memberIDs.compactMap { catalog[$0] } }
    private var noteState: MaterialNoteState? { model.materialNoteStates[source.id] }
    private var waitsForMaterialReview: Bool {
        materialReader && memberRecords.contains(where: \.hasProvisionalRecordingTranscript)
    }

    // Policy and local-only changes also matter: they can unblock or block the
    // next attempt even when no transcript changed.
    private var memberSignature: [String] {
        memberIDs.map { id in
            guard let record = catalog[id] else { return id + "|missing" }
            return id + "|" + (record.transcriptVersionID ?? "") + "|" + String(record.policyVersion) + "|" + (record.localOnly ? "local" : "cloud")
        }
    }

    private var readKey: MaterialNoteReadKey {
        MaterialNoteReadKey(sourceID: source.id, transcriptVersionID: source.transcriptVersionID,
                            policyVersion: source.policyVersion, state: Self.stateToken(noteState),
                            revision: model.materialNotesRevision, members: memberSignature)
    }

    private var requestKey: MaterialNoteRequestKey {
        MaterialNoteRequestKey(sourceID: source.id, members: memberSignature)
    }

    var body: some View {
        Group {
            if let backToNotes {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
                            HStack {
                                Button("所有笔记", systemImage: "arrow.left", action: backToNotes)
                                    .buttonStyle(.workspaceQuietCompact)
                                Spacer()
                                Button("查看材料与原文", systemImage: "books.vertical") { openSource(source.id) }
                                    .buttonStyle(.workspaceQuietCompact)
                            }
                            readingContent
                        }
                        .scrollTargetLayout()
                        .frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading)
                        .padding(WorkspaceMetrics.pagePadding)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollPosition(restoreScroll ?? $articlePosition)
                    .transformAnchorPreference(key: HistoryConnectorAnchors.self, value: .bounds) { value, anchor in
                        value[.articleViewport] = anchor
                    }
                    if let sidebar, sidebar.wrappedValue != nil {
                        Divider()
                        VStack(spacing: 0) {
                            Picker("侧栏", selection: Binding(
                                get: { sidebar.wrappedValue ?? .history },
                                set: { sidebar.wrappedValue = $0 }
                            )) {
                                Text("历史批注").tag(NoteSidebarTab.history)
                                Text("AI 讨论").tag(NoteSidebarTab.discussion)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .padding(12)
                            Divider()
                            if historyPresented {
                                historyInspector
                            } else {
                                discussionPanel
                            }
                        }
                        .frame(width: 320)
                        .background(palette.canvas)
                    }
                }
                .overlayPreferenceValue(HistoryConnectorAnchors.self) { endpoints in
                    if historyPresented { historyConnectors(endpoints) }
                }
            } else {
                readingContent
            }
        }
        .onChange(of: historyPresented) { _, presented in
            if !presented { historySelection = nil }
        }
    }

    private var readingContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let boardNotice {
                Text(boardNotice)
                    .vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if materialReader && !loadedOnce {
                ProgressView().controlSize(.small).accessibilityLabel("正在读取笔记")
            } else {
                if waitsForMaterialReview && display == nil {
                    noteText("校正后可整理笔记")
                } else {
                    statusRows
                }
            }
            if let display {
                article(display)
            }
        }
        .task(id: readKey) { await load() }
        .task(id: historyReadKey) { await loadHistory() }
        .task(id: historyRun) { if historyRun { await generateHistory() } }
        .task(id: requestKey) { await requestNote() }
        .sheet(item: $editing) { base in
            MaterialNoteEditor(base: base) { draft in
                guard let store = model.store else { throw VoiceOSError("资料库尚未打开") }
                let saved = try await store.editMaterialNote(draft, replacing: base)
                model.materialNoteRows[saved.expressionKey] = saved
                model.materialNoteDidSave()
            }
        }
        .alert("重新整理并替换手改笔记？", isPresented: Binding(get: { replacement != nil }, set: { if !$0 { replacement = nil } }), presenting: replacement) { base in
            Button("保留当前笔记", role: .cancel) {}
            Button("重新整理", role: .destructive) {
                Task { await model.requestMaterialNote(sourceID: source.id, force: true, replacingEdited: base.id) }
            }
        } message: { _ in Text("生成成功后，新笔记将成为阅读页显示的版本。") }
        .task(id: positionRestoreKey) { await restoreReadingPositionIfNeeded() }
    }

    // MARK: - 阅读位置

    /// 视口顶部（含少量布局抖动）即当前阅读段。恢复时目标段顶对齐到 0，
/// 这里必须用同一基准判定，否则恢复完会立刻把下一段记成当前位置、每次
/// 重开都向下漂一段。
    private static let readingTopTolerance: CGFloat = 8

    private struct PositionRestoreKey: Hashable {
        let expressionKey: String
        let ready: Bool
    }

    private var positionKey: String { VoiceOSStore.materialNoteExpressionKey(memberIDs) }

    private var positionRestoreKey: PositionRestoreKey {
        PositionRestoreKey(expressionKey: positionKey, ready: display != nil)
    }

    /// 探针值不参与观察，避免滚动时每帧触发整页重算。
    @MainActor
    private final class NoteReadingProbeBox {
        var tops: [String: CGFloat] = [:]
        var lastAnchor: String?
    }

    private func probe(_ minY: CGFloat, anchor: String) {
        probeBox.tops[anchor] = minY
        guard hasRestored else { return }
        recordReadingPosition()
    }

    private func recordReadingPosition() {
        guard let display else { return }
        // 视口顶部处开始的块就是当前阅读位置；都比线低说明还在笔记上方。
        guard let pick = probeBox.tops.filter({ $0.value <= Self.readingTopTolerance })
            .max(by: { $0.value < $1.value })?.key,
            pick != probeBox.lastAnchor else { return }
        probeBox.lastAnchor = pick
        MaterialNoteReadingPosition.record(pick, for: positionKey, noteID: display.note.id)
    }

    private func restoreReadingPositionIfNeeded() async {
        guard !hasRestored, let display else { return }
        guard let scroll = restoreScroll,
              let anchor = MaterialNoteReadingPosition.anchor(for: positionKey, noteID: display.note.id) else {
            hasRestored = true
            return
        }
        // 等首次布局完成再跳；恢复完成前探针不记录，避免把页面顶部写回。
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        scroll.wrappedValue.scrollTo(id: anchor, anchor: .top)
        hasRestored = true
    }

    // MARK: - Article

    private func article(_ display: MaterialNoteDisplay) -> some View {
        HStack(alignment: .top, spacing: 18) {
            if !materialReader {
                Rectangle().fill(palette.border)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 26) {
                if !display.isCurrent { staleRow }
                if materialReader {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        noteHeading(display.note.note)
                        Spacer(minLength: 0)
                        noteActions
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        noteHeading(display.note.note)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(palette.warning.opacity(0.35))
                            .frame(width: 88, height: 3)
                            .accessibilityHidden(true)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .scrollView(axis: .vertical)).minY
                            } action: { minY in
                                probe(minY, anchor: "note.title")
                            }
                        metaLine
                    }
                }
                if let lead = normalized(display.note.note.lead) {
                    Text(lead)
                        .vosFont(WorkspaceText.body)
                        .foregroundStyle(palette.text)
                        .lineSpacing(WorkspaceText.body.size * textScale * 0.45)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(NoteBoardAdapting.blocks(for: display.note.note)) { block in
                    blockView(block)
                }
                if !materialReader { relatedSection }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    private func noteHeading(_ note: MaterialNote) -> some View {
        Text(articleTitle(note))
            .vosFont(WorkspaceText.pageTitle)
            .foregroundStyle(palette.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .id("note.title")
    }

    /// 成品视图：段落只有正文与「整理时补充的关联」标记。逐段原话与回听
    /// 属于原材料侧的信息，只在「查看材料与原文」里出现，不挂在成品上。
    private func paragraphView(_ paragraph: MaterialNote.Paragraph, anchor: String) -> some View {
        let number = orderedHistory.firstIndex { $0.paragraphID == anchor }.map { $0 + 1 }
        let selected = historyPresented && historySelection == anchor
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(attributedParagraph(paragraph))
                    .vosFont(WorkspaceText.body)
                    .foregroundStyle(palette.text)
                    .lineSpacing(WorkspaceText.body.size * textScale * 0.45)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        if let discussParagraph {
                            Button("讨论这一段", systemImage: "bubble.left.and.bubble.right") {
                                discussParagraph(paragraph.text)
                            }
                        }
                    }
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(palette.selection)
                                .padding(-5)
                        }
                    }
                if historyPresented && !orderedHistory.isEmpty {
                    Group {
                        if let number {
                            Button {
                                historySelection = anchor
                            } label: {
                                historyIndex(number, selected: selected)
                                    .frame(minWidth: 28, minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .workspaceHoverHighlight()
                            .accessibilityLabel("历史批注 \(number)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("note.history.marker")
                            .help("历史批注")
                            .anchorPreference(key: HistoryConnectorAnchors.self, value: .bounds) {
                                [.paragraph(anchor): $0]
                            }
                        } else {
                            Color.clear.frame(height: 0).accessibilityHidden(true)
                        }
                    }
                    .frame(width: 28)
                }
            }
            if paragraph.inferred == true {
                Text("整理时补充的关联")
                    .vosFont(WorkspaceText.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .accessibilityLabel("这一段包含整理时补充的关联")
            }
            if annotationsVisible, let annotations = paragraph.annotations, !annotations.isEmpty {
                ForEach(annotations) { annotation in
                    annotationView(annotation)
                }
            }
        }
    }

    private func annotationView(_ annotation: MaterialNote.Annotation) -> some View {
        let ink = annotationColor(annotation.kind)
        return VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("AI 批注").vosFont(WorkspaceText.caption.size, weight: .semibold)
                        .foregroundStyle(ink)
                    if let label = Self.annotationKindLabel(annotation.kind) {
                        Text(label).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                    }
                    if let voice = normalized(annotation.voice) {
                        Text("· " + voice).vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                    }
                }
                Text(annotation.text)
                    .vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let source = normalized(annotation.source) {
                    Text("来源：" + source)
                        .vosFont(WorkspaceText.caption)
                        .foregroundStyle(palette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
        }
        .padding(12)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink.opacity(0.09), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(ink.opacity(0.60))
                .frame(width: 2)
                .padding(.vertical, 12)
                .padding(.leading, 10)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI 批注" + (Self.annotationKindLabel(annotation.kind).map { "，" + $0 } ?? ""))
    }

    private func annotationColor(_ kind: String) -> Color {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "question", "analysis", "distinction", "research_frame": return palette.noteBlue
        case "pattern", "theory", "insight", "reflection": return palette.noteViolet
        case "extension", "advice", "coaching", "suggestion": return palette.noteGreen
        case "assumption": return palette.noteRose
        default: return palette.noteAmber
        }
    }

    private static func annotationKindLabel(_ kind: String) -> String? {
        switch kind {
        case "pattern": return "照见模式"
        case "question": return "追问"
        case "assumption": return "隐含假设"
        case "theory": return "理论"
        case "extension": return "延伸"
        case "advice": return "建议"
        default: return kind.isEmpty ? nil : kind
        }
    }

    // MARK: - 笔记板

    /// 一块板的组件渲染。引用块（todo/claim/quote）解析到实时记录；目标
    /// 不存在的引用降级显示模型写下的文字；未知 kind 以降级卡片呈现。
    @ViewBuilder
    private func blockView(_ block: NoteBlock) -> some View {
        switch block.kind {
        case "todo":
            todoBlockView(block)
        case "claim":
            claimBlockView(block)
        case "quote":
            quoteBlockView(block)
        case "insight":
            insightBlockView(block)
        case "callout":
            calloutBlockView(block)
        default:
            if let paragraphs = block.paragraphs, !paragraphs.isEmpty || block.heading != nil {
                textBlockView(block)
            } else {
                unknownBlockView(block)
            }
        }
    }

    @ViewBuilder
    private func textBlockView(_ block: NoteBlock) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let heading = normalized(block.heading) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(palette.warning.opacity(0.4))
                        .frame(width: 3, height: 14 * vosLayoutScale(textScale))
                        .accessibilityHidden(true)
                    Text(heading)
                        .vosFont(WorkspaceText.sectionTitle)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array((block.paragraphs ?? []).enumerated()), id: \.offset) { index, paragraph in
                    let anchor = blockParagraphAnchor(block, index)
                    paragraphView(paragraph, anchor: anchor)
                        .id(anchor)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .scrollView(axis: .vertical)).minY
                        } action: { minY in
                            probe(minY, anchor: anchor)
                        }
                }
            }
        }
    }

    private func blockParagraphAnchor(_ block: NoteBlock, _ index: Int) -> String {
        "note.b.\(block.id).p\(index)"
    }

    @ViewBuilder
    private func todoBlockView(_ block: NoteBlock) -> some View {
        if let actionID = block.actionID, let action = model.sourcePageIndex.allAction(for: actionID), action.validity == "current", action.state != "dismissed" {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    guard action.state != "completed" else { return }
                    // 板上的勾选走通用完成入口：有提醒关联时同步并回读，没有时本地完成。
                    Task {
                        if await model.changeAction(action, state: .completed) == nil {
                            boardNotice = model.status.isEmpty ? "没能完成这条待办，请稍后重试" : model.status
                        }
                    }
                } label: {
                    Image(systemName: action.state == "completed" ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(action.state == "completed" ? palette.success : palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(action.state == "completed")
                .help(action.state == "completed" ? "已完成" : "勾选完成这件事")
                .accessibilityLabel(action.state == "completed" ? "已完成" : "勾选完成")
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .vosFont(WorkspaceText.body)
                        .foregroundStyle(palette.text)
                        .strikethrough(action.state == "completed", color: palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if action.state == "completed" {
                        Text("已完成").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(palette.border, lineWidth: 1) }
        }
    }

    @ViewBuilder
    private func claimBlockView(_ block: NoteBlock) -> some View {
        if let claimID = block.claimID, let claim = model.sourcePageIndex.claim(for: claimID), claim.validity == "current", claim.reviewState != "rejected" {
            let reference = claim.references.first
            Button {
                if let reference { openSource(reference.sourceID) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(claim.statement)
                        .vosFont(WorkspaceText.body)
                        .foregroundStyle(palette.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if reference != nil {
                        Text("打开原话").vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(palette.border, lineWidth: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reference == nil)
        }
    }

    @ViewBuilder
    private func quoteBlockView(_ block: NoteBlock) -> some View {
        if let quote = normalized(block.quote) ?? normalized(block.text) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(palette.secondaryText.opacity(0.25))
                    .frame(width: 2)
                    .accessibilityHidden(true)
                Text(quote)
                    .vosFont(WorkspaceText.body)
                    .foregroundStyle(palette.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private func insightBlockView(_ block: NoteBlock) -> some View {
        if annotationsVisible, let annotation = block.annotation {
            VStack(alignment: .leading, spacing: 6) {
                if let title = normalized(annotation.title) ?? normalized(block.titleOverride) {
                    Text(title)
                        .vosFont(WorkspaceText.rowTitle)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                annotationView(annotation)
            }
        }
    }

    @ViewBuilder
    private func calloutBlockView(_ block: NoteBlock) -> some View {
        if let text = normalized(block.text) ?? normalized(block.titleOverride) {
            Text(text)
                .vosFont(WorkspaceText.body)
                .foregroundStyle(palette.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(markInk(block.tone).opacity(0.12), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        }
    }

    /// 引用失效或未知组件的降级卡片：保留模型写下的文字，不丢内容。
    @ViewBuilder
    private func unknownBlockView(_ block: NoteBlock) -> some View {
        if let text = normalized(block.titleOverride) ?? normalized(block.text) ?? normalized(block.quote) {
            VStack(alignment: .leading, spacing: 4) {
                if !block.kind.isEmpty {
                    Text("AI 的 " + block.kind).vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText)
                }
                Text(text)
                    .vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.tertiaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        }
    }

    /// 行内标记渲染：正文永远是纯文本，样式是并列的一层数据。style/tone 都是
    /// 自由字符串——已知值映射为背景、下划线、粗细、颜色，未知值按默认渲染；
    /// 新增样式只改这里，数据结构与提示词无需变化。
    private func attributedParagraph(_ paragraph: MaterialNote.Paragraph) -> AttributedString {
        var attributed = AttributedString(paragraph.text)
        guard let marks = paragraph.marks, !marks.isEmpty else { return attributed }
        for mark in marks {
            guard !mark.text.isEmpty else { continue }
            var searchRange = paragraph.text.startIndex..<paragraph.text.endIndex
            while let found = paragraph.text.range(of: mark.text, range: searchRange) {
                if let range = Range(found, in: attributed) {
                    apply(mark, to: &attributed, range: range)
                }
                searchRange = found.upperBound..<paragraph.text.endIndex
                if searchRange.isEmpty { break }
            }
        }
        return attributed
    }

    private func apply(_ mark: MaterialNote.InlineMark, to attributed: inout AttributedString, range: Range<AttributedString.Index>) {
        let ink = markInk(mark.tone)
        switch (mark.style ?? "marker").lowercased() {
        case "underline":
            attributed[range].underlineStyle = .single
        case "bold":
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        case "italic":
            attributed[range].inlinePresentationIntent = .emphasized
        default:
            attributed[range].backgroundColor = ink.opacity(0.24)
        }
    }

    private func markInk(_ tone: String?) -> Color {
        switch tone?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accent", "blue": return palette.noteBlue
        case "muted", "violet", "purple": return palette.noteViolet
        case "green", "mint": return palette.noteGreen
        case "rose", "pink": return palette.noteRose
        default: return palette.noteAmber
        }
    }

    private var metaLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(metaText)
                .vosFont(WorkspaceText.meta)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            noteActions
        }
    }

    private var noteActions: some View {
        Menu {
            Button("编辑笔记…") { editing = display?.note }
            Button(annotationsVisible ? "隐藏 AI 批注" : "显示 AI 批注") {
                annotationsVisible.toggle()
            }
            Button("重新整理笔记") { retry() }
                .disabled(noteState == .generating || waitsForMaterialReview)
        } label: {
            Image(systemName: "ellipsis.circle")
                .vosFont(WorkspaceText.meta.size)
                .foregroundStyle(palette.secondaryText)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("笔记操作")
        .accessibilityLabel("笔记操作")
    }

    private var metaText: String {
        var parts = [source.recordingSubtitle]
        if memberIDs.count > 1 { parts.append("本次表达 \(memberIDs.count) 段") }
        parts.append(source.origin == "user" ? "AI 根据你的口述整理" : "AI 根据原文整理")
        return parts.joined(separator: " · ")
    }

    private func articleTitle(_ note: MaterialNote) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let expression { return expression.displayTitle(in: catalog) }
        return source.displayTitle
    }

    // MARK: - Related

    /// End-of-note entries, only for real associations: open actions that the
    /// source page already derives from this expression, and discussions that
    /// have not ended. With neither, the section renders nothing and the note
    /// simply ends.
    private var relatedOpenActions: [ActionRecord] {
        relatedActions.filter { $0.validity == "current" && $0.state == "open" }
    }

    private var ongoingDiscussions: [ConversationRecord] {
        relatedDiscussions.filter { $0.state == "active" && $0.validity == "current" }
    }

    @ViewBuilder
    private var relatedSection: some View {
        let shownActions = Array(relatedOpenActions.prefix(5))
        let remainingActions = relatedOpenActions.count - shownActions.count
        let discussions = ongoingDiscussions
        if !shownActions.isEmpty || !discussions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("相关")
                    .vosFont(WorkspaceText.caption.size, weight: .medium)
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                ForEach(shownActions) { action in
                    MaterialNoteRelatedRow(title: action.title, help: "打开这项行动") {
                        openTask(action.id)
                    }
                }
                if remainingActions > 0 {
                    Text("还有 \(remainingActions) 项在下方列表。")
                        .vosFont(WorkspaceText.caption)
                        .foregroundStyle(palette.tertiaryText)
                }
                if !discussions.isEmpty {
                    MaterialNoteRelatedRow(title: discussionRowTitle(count: discussions.count), help: "打开这段讨论") {
                        openDiscussion(discussions[0].id)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func discussionRowTitle(count: Int) -> String {
        count == 1 ? "继续这段讨论" : "继续最近一段讨论（还有 \(count) 段没有结束）"
    }

    private var staleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .vosFont(WorkspaceText.meta.size, weight: .medium)
                .foregroundStyle(palette.warning)
                .accessibilityHidden(true)
            Text("原话已更正或处理许可变化，这篇笔记可能不再对应。")
                .vosFont(WorkspaceText.meta)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("重新整理") { retry() }
                .buttonStyle(.workspaceQuietCompact)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRows: some View {
        if let noteState {
            switch noteState {
            case .generating:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(display == nil ? "正在整理笔记…" : "正在重新整理…")
                        .vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
            case .unavailable(let reason):
                // 已有可读笔记时不再显示「不能整理」类横幅：内容与横幅会自相矛盾。
                if display == nil { unavailableRow(reason) }
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("整理没有完成：\(message)", systemImage: "exclamationmark.triangle")
                        .vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("重试", systemImage: "arrow.clockwise") { retry() }
                        .buttonStyle(.workspaceQuietCompact)
                }
            case .idle:
                idleRow
            }
        } else {
            idleRow
        }
    }

    @ViewBuilder
    private var idleRow: some View {
        if display == nil, loadedOnce, requested {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("还没有整理成笔记。")
                    .vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 8)
                Button("整理成笔记") {
                    Task { await model.requestMaterialNote(sourceID: source.id) }
                }
                .buttonStyle(.workspaceSecondaryCompact)
            }
        }
    }

    @ViewBuilder
    private func unavailableRow(_ reason: String) -> some View {
        switch reason {
        case "仅本机保存":
            if source.localOnly {
                actionRow("这段文字仅保存在本机，还没有交给模型整理。") {
                    Button("允许这份文字用于云端并整理") { allowCloudAndRequest() }
                        .buttonStyle(.workspaceSecondaryCompact)
                }
            } else {
                let blocked = memberRecords.filter(\.localOnly)
                actionRow("这份表达里还有 \(max(blocked.count, 1)) 段文字仅本机保存；到那一部分允许云端整理后，这里会自动继续。") {
                    if let first = blocked.first {
                        Button("打开那段") { openSource(first.id) }
                            .buttonStyle(.workspaceQuietCompact)
                    }
                }
            }
        case "文本模型未配置":
            actionRow("还没有配置文本模型，暂时不能整理成笔记。") {
                Button("配置文本模型…") { model.chooseTextModel() }
                    .buttonStyle(.workspaceSecondaryCompact)
            }
        case "尚无转写":
            noteText("转写完成后才能整理成笔记；录音和原文已经保存。")
        case "材料尚未保存完成":
            noteText("材料还在保存，稍后会自动尝试整理。")
        case "资料库尚未打开":
            noteText("资料库还没有打开，暂时无法读取这份笔记。")
        default:
            noteText(sentence(reason))
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .vosFont(WorkspaceText.meta)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actionRow<Actions: View>(_ text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            noteText(text)
            Spacer(minLength: 8)
            actions()
        }
    }

    // MARK: - Actions and reads

    private func retry() {
        if let base = display?.note, base.note.manuallyEdited == true { replacement = base; return }
        Task { await model.requestMaterialNote(sourceID: source.id, force: true) }
    }

    private struct HistoryReadKey: Equatable {
        let noteID: String?
        let records: Int
        let notes: Int
    }

    private var historyReadKey: HistoryReadKey {
        .init(noteID: display?.note.id, records: model.recordsRevision, notes: model.materialNotesRevision)
    }

    private var validHistory: NoteHistoryResult? {
        guard let historyResult, display?.isCurrent == true, historyResult.noteID == display?.note.id,
              historyResult.recordVersions.allSatisfy({ id, version in
                  catalog[id].map(NoteHistoryResult.version) == version
              }) else { return nil }
        return historyResult
    }

    private var historyInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if historyRun { ProgressView().controlSize(.small) }
                Spacer()
                Button("回看相关历史", systemImage: "clock.arrow.circlepath") {
                    historyNotice = nil
                    historyRun = true
                }
                .disabled(historyRun || display?.isCurrent != true)
                .accessibilityIdentifier("note.history.request")
            }
            .padding(12)
            if model.noteHistorySyncing {
                noteText("正在同步历史记忆…").padding(.horizontal, 12)
            }
            if let notice = historyNotice ?? model.noteHistorySyncIssue {
                noteText(notice).padding(.horizontal, 12)
            }
            if orderedHistory.isEmpty {
                if !historyRun && historyNotice == nil {
                    ContentUnavailableView("暂无历史批注", systemImage: "text.bubble")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(orderedHistory.enumerated()), id: \.element.id) { index, annotation in
                                historyCard(annotation, number: index + 1)
                                    .id(annotation.id)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transformAnchorPreference(key: HistoryConnectorAnchors.self, value: .bounds) { value, anchor in
                        value[.listViewport] = anchor
                    }
                    .onChange(of: historySelection) { _, anchor in
                        if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(palette.canvas)
    }

    private var orderedHistory: [NoteHistoryAnnotation] {
        guard let annotations = validHistory?.annotations, !annotations.isEmpty, let display else { return [] }
        let byParagraph = Dictionary(annotations.map { ($0.paragraphID, $0) }, uniquingKeysWith: { first, _ in first })
        return NoteBoardAdapting.blocks(for: display.note.note).flatMap { block in
            (block.paragraphs ?? []).indices.compactMap { byParagraph[blockParagraphAnchor(block, $0)] }
        }
    }

    private func historyIndex(_ number: Int, selected: Bool) -> some View {
        Text(number.formatted())
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(selected ? palette.surface : palette.accent)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(selected ? palette.accent : palette.selection, in: Capsule())
    }

    private func historyCard(_ annotation: NoteHistoryAnnotation, number: Int) -> some View {
        let selected = historySelection == annotation.id
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                historySelection = annotation.id
                let position = restoreScroll ?? $articlePosition
                position.wrappedValue.scrollTo(id: annotation.paragraphID, anchor: .center)
            } label: {
                HStack(spacing: 8) {
                    historyIndex(number, selected: selected)
                    Text("查看对应段落").vosFont(WorkspaceText.meta)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.left").accessibilityHidden(true)
                }
                .foregroundStyle(palette.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .workspaceHoverHighlight()
            .accessibilityLabel("查看历史批注 \(number) 对应段落")
            .accessibilityIdentifier("note.history.jump")
            .anchorPreference(key: HistoryConnectorAnchors.self, value: .bounds) {
                [.card(annotation.id): $0]
            }
            Text(annotation.text)
                .vosFont(WorkspaceText.body).lineSpacing(4).textSelection(.enabled)
                .accessibilityIdentifier("note.history.annotation")
            Divider().padding(.top, 4)
            Text("相关笔记").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(Set(annotation.sourceIDs)).sorted(), id: \.self) { id in
                if let title = validHistory?.sourceTitles[id] {
                    Button {
                        sidebar?.wrappedValue = nil
                        openHistoryNote?(id)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "doc.text")
                            Text(title).fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .accessibilityHidden(true)
                        }
                        .vosFont(WorkspaceText.meta)
                        .foregroundStyle(palette.accent)
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .workspaceHoverHighlight()
                    .accessibilityIdentifier("note.history.source")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? palette.selection : palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? palette.accent : palette.border)
        }
    }

    private func historyConnectors(_ endpoints: [HistoryConnectorAnchors.Endpoint: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let viewportAnchor = endpoints[.listViewport],
                      let articleAnchor = endpoints[.articleViewport] else { return }
                let viewport = geometry[viewportAnchor]
                let article = geometry[articleAnchor]
                for annotation in orderedHistory {
                    let id = annotation.id
                    guard let paragraph = endpoints[.paragraph(id)], let card = endpoints[.card(id)] else { continue }
                    let left = geometry[paragraph], right = geometry[card]
                    let start = CGPoint(x: left.midX + 10, y: left.midY)
                    let end = CGPoint(x: right.minX - 12, y: right.midY)
                    guard end.x > start.x, start.y >= max(0, article.minY), start.y <= min(size.height, article.maxY),
                          end.y >= max(0, viewport.minY), end.y <= min(size.height, viewport.maxY) else { continue }

                    let bend = (end.x - start.x) * 0.55
                    let selected = historySelection == id
                    var line = Path()
                    line.move(to: start)
                    line.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y),
                                  control2: CGPoint(x: end.x - bend, y: end.y))
                    context.stroke(line, with: .color(palette.accent.opacity(selected ? 0.85 : 0.42)),
                                   style: StrokeStyle(lineWidth: selected ? 1.75 : 1, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func loadHistory() async {
        guard openHistoryNote != nil, let root = model.libraryRoot else { return }
        guard let displayed = display, displayed.isCurrent, let store = model.store else { return }
        let key = historyReadKey
        let cached = NoteHistoryResult.read(root: root, sourceID: source.id)
        if let cached, cached.noteID == displayed.note.id,
           await historyVersionsMatch(cached, store: store),
           key == historyReadKey, !Task.isCancelled {
            historyResult = cached
        } else if key == historyReadKey && !Task.isCancelled {
            historyResult = nil
            historySelection = nil
        }
    }

    private func historyVersionsMatch(_ result: NoteHistoryResult, store: VoiceOSStore) async -> Bool {
        guard let records = try? await store.sourceRecords(ids: Array(result.recordVersions.keys)) else { return false }
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        guard result.recordVersions.allSatisfy({ id, version in
            indexed[id].map(NoteHistoryResult.version) == version
        }) else { return false }
        for (expressionKey, revisionID) in result.sourceNoteIDs {
            let ids = expressionKey.split(separator: "|").map(String.init)
            guard let current = try? await store.latestMaterialNote(memberSourceIDs: ids),
                  current.id == revisionID else { return false }
        }
        return true
    }

    private func generateHistory() async {
        defer { historyRun = false }
        guard let displayed = display, displayed.isCurrent,
              let store = model.store, let root = model.libraryRoot, let port = model.textModels?.note else {
            historyNotice = "暂时无法回看历史，请检查资料库和文本模型。"
            return
        }
        do {
            guard let memory = try NoteHistoryMemory.load(root: root) else {
                throw VoiceOSError("此资料库尚未连接历史记忆")
            }
            let indexed = Dictionary(uniqueKeysWithValues: try await store.sources().map { ($0.id, $0) })
            let baseIDs = memberIDs
            if let reason = MaterialNoteGating.unavailableReason(memberIDs: baseIDs, catalog: indexed) {
                throw VoiceOSError(reason)
            }
            var revisions = [displayed.note.expressionKey: displayed.note.id]
            var usedRecords = Set(baseIDs)
            let current = await store.materialNoteIsCurrent(displayed.note,
                currentTranscriptVersions: MaterialNoteGating.transcriptVersions(memberIDs: baseIDs, catalog: indexed))
            guard current else { throw VoiceOSError("原话已更新，请先更新笔记。") }
            try Task.checkCancellation()
            let query = [articleTitle(displayed.note.note), displayed.note.note.lead,
                         String(NoteHistoryMemory.body(displayed.note.note).prefix(2000))]
                .compactMap { $0 }.joined(separator: "\n")
            let documents = try await memory.recalledDocuments(query: query)
            let candidates = try await store.recentMaterialNotes(limit: nil).filter {
                $0.id != displayed.note.id && NoteHistoryMemory.canIndex($0, catalog: indexed)
            }
            let byDocument = Dictionary(uniqueKeysWithValues: candidates.map { (NoteHistoryMemory.documentID($0), $0) })
            var evidence: [NoteHistoryEvidence] = []
            for document in documents {
                guard let prior = byDocument[document] else { continue }
                let ids = NoteHistoryMemory.members(prior)
                guard let sourceID = ids.first(where: { indexed[$0]?.speaker == "user" }) ?? ids.first,
                      Set(baseIDs).isDisjoint(with: ids) else { continue }
                let body = NoteHistoryMemory.body(prior.note)
                guard !body.isEmpty else { continue }
                let date = ids.compactMap { indexed[$0]?.expressedDate }.min()
                    .map { $0.formatted(date: .numeric, time: .omitted) } ?? ""
                evidence.append(.init(sourceID: sourceID, title: prior.note.title, date: date, text: body))
                revisions[prior.expressionKey] = prior.id
                usedRecords.formUnion(ids)
            }
            let versions = Dictionary(uniqueKeysWithValues: usedRecords.compactMap { id in
                indexed[id].map { (id, NoteHistoryResult.version($0)) }
            })
            let titles = Dictionary(evidence.map { ($0.sourceID, $0.title) }, uniquingKeysWith: { first, _ in first })
            let snapshot = NoteHistoryResult(noteID: displayed.note.id, sourceNoteIDs: revisions, sourceTitles: titles,
                                             recordVersions: versions, annotations: [])
            guard await historyVersionsMatch(snapshot, store: store),
                  display?.note.id == displayed.note.id, model.libraryRoot == root else {
                throw VoiceOSError("笔记或材料已更新，请重新回看。")
            }
            try Task.checkCancellation()
            let paragraphs = NoteBoardAdapting.blocks(for: displayed.note.note)
                .filter { !["todo", "claim", "quote", "insight", "callout"].contains($0.kind) }
                .flatMap { block in
                    (block.paragraphs ?? []).enumerated().map { index, paragraph in
                        NoteHistoryParagraph(id: blockParagraphAnchor(block, index), text: paragraph.text)
                    }
                }
            let annotations = try await port.historyAnnotations(paragraphs: paragraphs, evidence: evidence)
            guard await historyVersionsMatch(snapshot, store: store),
                  display?.note.id == displayed.note.id, model.libraryRoot == root else {
                throw VoiceOSError("笔记或材料已更新，请重新回看。")
            }
            try Task.checkCancellation()
            let result = NoteHistoryResult(noteID: snapshot.noteID, sourceNoteIDs: revisions, sourceTitles: titles,
                                           recordVersions: versions, annotations: annotations)
            try result.save(root: root, sourceID: source.id)
            historyResult = result
            if annotations.isEmpty {
                historyNotice = model.noteHistorySyncing ? "历史记忆正在同步，稍后可以再回看。" : "没有找到值得补充的前情。"
            }
            if !annotations.contains(where: { $0.id == historySelection }) { historySelection = nil }

        } catch is CancellationError {
            return
        } catch {
            historyNotice = error.localizedDescription
        }
    }

    private func allowCloudAndRequest() {
        Task {
            await model.changeTextPolicy(source)
            await model.requestMaterialNote(sourceID: source.id, force: true)
        }
    }

    @MainActor
    private func load() async {
        let key = readKey
        let result = await model.materialNoteForDisplay(sourceID: source.id)
        guard key == readKey, !Task.isCancelled else { return }
        loadedOnce = true
        if let result {
            let next = MaterialNoteDisplay(note: result.note, isCurrent: result.isCurrent)
            if next.note.id != display?.note.id { resetReadingProbes() }
            display = next
            hasNote = true
            model.materialNotePresence[source.id] = true
        } else {
            display = nil
            hasNote = false
            model.materialNotePresence[source.id] = false
        }
    }

    /// 重生成后段落集合可能变化，旧探针残值不能再参与位置挑选。
    private func resetReadingProbes() {
        probeBox.tops.removeAll()
        probeBox.lastAnchor = nil
    }

    @MainActor
    private func requestNote() async {
        guard !waitsForMaterialReview else { return }
        await model.requestMaterialNote(sourceID: source.id)
        guard !Task.isCancelled else { return }
        requested = true
    }

    // MARK: - Formatting

    private static func stateToken(_ state: MaterialNoteState?) -> String {
        guard let state else { return "idle" }
        switch state {
        case .idle: return "idle"
        case .generating: return "generating"
        case .unavailable(let reason): return "unavailable:" + reason
        case .failed(let message): return "failed:" + message
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return "。！？!?".contains(last) ? trimmed : trimmed + "。"
    }
}

/// One quiet end-of-note entry. No card, border or icon: the row reads as one
/// more line of text until hovered, when it takes the accent color.
private struct MaterialNoteRelatedRow: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .vosFont(WorkspaceText.meta.size, weight: .medium)
                    .foregroundStyle(hovered ? palette.accent : palette.secondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
    }
}
