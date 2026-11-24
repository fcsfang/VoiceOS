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


struct MaterialNoteReadingView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    var openSource: (String) -> Void = { _ in }
    var openTask: (String) -> Void = { _ in }
    var openDiscussion: (String) -> Void = { _ in }
    var relatedActions: [ActionRecord] = []
    var relatedDiscussions: [ConversationRecord] = []
    @Binding var hasNote: Bool
    /// 材料页的滚动位置；重开页面时据此回到上次读到的段落。
    var restoreScroll: Binding<ScrollPosition>? = nil

    @State private var display: MaterialNoteDisplay?
    @State private var requested = false
    @State private var loadedOnce = false
    @AppStorage("voiceos.note.annotations.visible") private var annotationsVisible = true
    @State private var probeBox = NoteReadingProbeBox()
    @State private var hasRestored = false
    @State private var boardNotice: String?

    private var catalog: [String: SourceRecord] { model.sourcePageIndex.recordsByID }
    private var expression: RecordingExpression? { model.sourcePageIndex.expression(for: source.id) }
    private var memberIDs: [String] {
        guard let expression else { return [source.id] }
        let external = (expression.externalVersions ?? [:]).keys.sorted()
        return expression.sourceIDs + external.filter { !expression.sourceIDs.contains($0) }
    }
    private var memberRecords: [SourceRecord] { memberIDs.compactMap { catalog[$0] } }
    private var noteState: MaterialNoteState? { model.materialNoteStates[source.id] }

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
                            members: memberSignature)
    }

    private var requestKey: MaterialNoteRequestKey {
        MaterialNoteRequestKey(sourceID: source.id, members: memberSignature)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let boardNotice {
                Text(boardNotice)
                    .vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusRows
            if let display {
                article(display)
            }
        }
        .task(id: readKey) { await load() }
        .task(id: requestKey) { await requestNote() }
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
            Rectangle().fill(palette.border)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 26) {
                if !display.isCurrent { staleRow }
                VStack(alignment: .leading, spacing: 12) {
                    Text(articleTitle(display.note.note))
                        .vosFont(WorkspaceText.pageTitle)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .id("note.title")
                    // 手账感下划线：固定视觉语言，不消耗模型选择。
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
                relatedSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    /// 成品视图：段落只有正文与「整理时补充的关联」标记。逐段原话与回听
    /// 属于原材料侧的信息，只在「查看材料与原文」里出现，不挂在成品上。
    private func paragraphView(_ paragraph: MaterialNote.Paragraph) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(attributedParagraph(paragraph))
                .vosFont(WorkspaceText.body)
                .foregroundStyle(palette.text)
                .lineSpacing(WorkspaceText.body.size * textScale * 0.45)
                .fixedSize(horizontal: false, vertical: true)
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

    /// 一条 AI 批注：低饱和暖色底、左缘色条、轻标签；形式与长度随内容，
    /// 理论出处与身份（voice）有就给一行。批注是成品的一部分。
    private func annotationView(_ annotation: MaterialNote.Annotation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(palette.warning.opacity(0.45))
                .frame(width: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("AI 批注").vosFont(WorkspaceText.caption.size, weight: .semibold)
                        .foregroundStyle(palette.warning)
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
        }
        .padding(12)
        .background(palette.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI 批注" + (Self.annotationKindLabel(annotation.kind).map { "，" + $0 } ?? ""))
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
                    paragraphView(paragraph)
                        .id(blockParagraphAnchor(block, index))
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .scrollView(axis: .vertical)).minY
                        } action: { minY in
                            probe(minY, anchor: blockParagraphAnchor(block, index))
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
        if let actionID = block.actionID, let action = model.sourcePageIndex.allAction(for: actionID) {
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
                    Text(normalized(block.titleOverride) ?? action.title)
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
        } else {
            unknownBlockView(block)
        }
    }

    @ViewBuilder
    private func claimBlockView(_ block: NoteBlock) -> some View {
        if let claimID = block.claimID, let claim = model.sourcePageIndex.claim(for: claimID) {
            let reference = claim.references.first
            Button {
                if let reference { openSource(reference.sourceID) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(normalized(block.titleOverride) ?? claim.statement)
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
        } else {
            unknownBlockView(block)
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
                .background(markToneColor(block.tone), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
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
        let color = markToneColor(mark.tone)
        switch (mark.style ?? "marker").lowercased() {
        case "underline":
            attributed[range].underlineStyle = .single
        case "bold":
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        case "italic":
            attributed[range].inlinePresentationIntent = .emphasized
        default:
            attributed[range].backgroundColor = color
        }
    }

    private func markToneColor(_ tone: String?) -> Color {
        switch (tone ?? "").lowercased() {
        case "accent": return palette.accent.opacity(0.16)
        case "muted": return palette.secondaryText.opacity(0.10)
        default: return palette.warning.opacity(0.20)
        }
    }

    private var metaLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(metaText)
                .vosFont(WorkspaceText.meta)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // 已是最新的笔记也需要一个安静的重整理入口（换模型、改提示词后可用）。
            Menu {
                Button(annotationsVisible ? "隐藏 AI 批注" : "显示 AI 批注") {
                    annotationsVisible.toggle()
                }
                Button("重新整理笔记") {
                    Task { await model.requestMaterialNote(sourceID: source.id, force: true) }
                }
                .disabled(noteState == .generating)
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
                    Text(display == nil ? "正在整理成笔记…" : "正在重新整理…")
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
        Task { await model.requestMaterialNote(sourceID: source.id, force: true) }
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
