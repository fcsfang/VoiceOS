import Foundation
import SwiftUI
import VoiceOSCore

/// Article-shaped reading surface for one expression's saved note. The center
/// owns generation and persistence; this view only reads the newest revision,
/// keeps it current against member transcript versions, and renders each
/// paragraph beside its verbatim anchors.
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

private struct MaterialNoteAnchorPresentation: Identifiable {
    let id: String
    let quote: String
    let memberTitle: String
    let roleLabel: String?
    let sourceID: String
    let spanID: String?
    let timeLabel: String?
    let canPlay: Bool
    let canOpen: Bool
    let caveat: String?
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
    @State private var expandedParagraphs: Set<String> = []
    @State private var requested = false
    @State private var loadedOnce = false
    @State private var probeBox = NoteReadingProbeBox()
    @State private var hasRestored = false

    private var catalog: [String: SourceRecord] { model.sourcePageIndex.recordsByID }
    private var expression: RecordingExpression? { model.sourcePageIndex.expression(for: source.id) }
    private var memberIDs: [String] {
        guard let expression else { return [source.id] }
        let external = (expression.externalVersions ?? [:]).keys.sorted()
        return expression.sourceIDs + external.filter { !expression.sourceIDs.contains($0) }
    }
    private var memberRecords: [SourceRecord] { memberIDs.compactMap { catalog[$0] } }
    private var noteState: MaterialNoteState? { model.materialNoteStates[source.id] }
    private var playbackAvailable: Bool { ["audio", "video"].contains(source.kind) && source.state == "saved" }

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

    private func noteAnchor(_ sectionIndex: Int, _ paragraphIndex: Int) -> String {
        "note.p.\(sectionIndex).\(paragraphIndex)"
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
                ForEach(Array(display.note.note.sections.enumerated()), id: \.offset) { sectionIndex, section in
                    sectionView(section, index: sectionIndex)
                }
                relatedSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func sectionView(_ section: MaterialNote.Section, index: Int) -> some View {
        let paragraphs = Array(section.paragraphs.enumerated()).filter {
            !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !paragraphs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if let heading = normalized(section.heading) {
                    Text(heading)
                        .vosFont(WorkspaceText.sectionTitle)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(paragraphs, id: \.offset) { paragraphIndex, paragraph in
                        paragraphView(paragraph, paragraphID: "\(index)-\(paragraphIndex)")
                            .id(noteAnchor(index, paragraphIndex))
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .scrollView(axis: .vertical)).minY
                            } action: { minY in
                                probe(minY, anchor: noteAnchor(index, paragraphIndex))
                            }
                    }
                }
            }
        }
    }

    private func paragraphView(_ paragraph: MaterialNote.Paragraph, paragraphID: String) -> some View {
        MaterialNoteParagraphView(
            text: paragraph.text,
            inferred: paragraph.inferred == true,
            anchors: anchorPresentations(paragraph.anchors, paragraphID: paragraphID),
            isExpanded: expandedParagraphs.contains(paragraphID),
            toggle: { toggle(paragraphID) },
            play: play,
            openSource: openSource)
    }

    private func toggle(_ paragraphID: String) {
        if expandedParagraphs.contains(paragraphID) { expandedParagraphs.remove(paragraphID) }
        else { expandedParagraphs.insert(paragraphID) }
    }

    private var metaLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(metaText)
                .vosFont(WorkspaceText.meta)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if playbackAvailable {
                Button {
                    Task { _ = await model.playSpan(source, milliseconds: 0) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle").accessibilityHidden(true)
                        Text("回听")
                    }
                    .vosFont(WorkspaceText.meta.size, weight: .medium)
                    .foregroundStyle(palette.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("从这次表达的开头回听")
                .accessibilityLabel("从这次表达的开头回听")
            }
            // 已是最新的笔记也需要一个安静的重整理入口（换模型、改提示词后可用）。
            Menu {
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

    // MARK: - Anchors

    private func anchorPresentations(_ anchors: [MaterialNote.Anchor], paragraphID: String) -> [MaterialNoteAnchorPresentation] {
        anchors.enumerated().compactMap { index, anchor in
            let quote = anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { return nil }
            let id = paragraphID + "-a" + String(index)
            guard let record = catalog[anchor.sourceID] else {
                return MaterialNoteAnchorPresentation(id: id, quote: quote, memberTitle: "已移出的材料", roleLabel: nil,
                                                      sourceID: "", spanID: nil, timeLabel: nil,
                                                      canPlay: false, canOpen: false,
                                                      caveat: "这段来源已不在资料库。")
            }
            let storedTitle = record.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let memberTitle = storedTitle.isEmpty ? MaterialNaming.displayName(record.name) : storedTitle
            let role = noteRole(record)
            let canOpen = record.id != source.id
            let localHint = canOpen ? "可回到这段来源核对。" : "可在下方「原文与回听」核对。"
            let versionMatches = anchor.transcriptVersionID == nil || anchor.transcriptVersionID == record.transcriptVersionID
            guard versionMatches else {
                return MaterialNoteAnchorPresentation(id: id, quote: quote, memberTitle: memberTitle, roleLabel: role,
                                                      sourceID: record.id, spanID: nil, timeLabel: nil,
                                                      canPlay: false, canOpen: canOpen,
                                                      caveat: "原文已更正，这段引文不能作为当前原话；" + localHint)
            }
            guard let spanID = anchor.spanID,
                  let span = record.spans.first(where: { $0.id == spanID }),
                  let start = span.startMS, let end = span.endMS else {
                return MaterialNoteAnchorPresentation(id: id, quote: quote, memberTitle: memberTitle, roleLabel: role,
                                                      sourceID: record.id, spanID: nil, timeLabel: nil,
                                                      canPlay: false, canOpen: canOpen,
                                                      caveat: "未能定位到这段原话在录音里的位置；" + localHint)
            }
            let playable = ["audio", "video"].contains(record.kind) && record.state == "saved"
            return MaterialNoteAnchorPresentation(id: id, quote: quote, memberTitle: memberTitle, roleLabel: role,
                                                  sourceID: record.id, spanID: span.id,
                                                  timeLabel: timeText(start) + " 至 " + timeText(end),
                                                  canPlay: playable, canOpen: canOpen,
                                                  caveat: playable ? nil : "这份来源当前没有可播放的录音。")
        }
    }

    /// 非本人材料的角色标注，让引文行能说清「谁说的」。
    private func noteRole(_ record: SourceRecord) -> String? {
        if record.origin == "ai" || record.speaker == "assistant" { return "AI 交付" }
        if record.origin == "user" && record.speaker == "user" { return nil }
        return ["audio", "video"].contains(record.kind) ? "对方" : "原文作者"
    }

    private func play(_ anchor: MaterialNoteAnchorPresentation) {
        guard anchor.canPlay, let record = catalog[anchor.sourceID], let spanID = anchor.spanID,
              let span = record.spans.first(where: { $0.id == spanID }),
              let start = span.startMS, let end = span.endMS,
              ["audio", "video"].contains(record.kind), record.state == "saved" else { return }
        Task { _ = await model.playSpan(record, milliseconds: start, endMilliseconds: end) }
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

    private func timeText(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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

/// One paragraph with its static text, the quiet "看原话" trigger and the
/// expanded verbatim anchors. Quote rows never wrap organized prose in quotes;
/// they show the anchored text with a source line and only offer playback when
/// the span resolves to a real time range.
private struct MaterialNoteParagraphView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let inferred: Bool
    let anchors: [MaterialNoteAnchorPresentation]
    let isExpanded: Bool
    let toggle: () -> Void
    let play: (MaterialNoteAnchorPresentation) -> Void
    let openSource: (String) -> Void
    @State private var hovered = false

    var body: some View {
        if anchors.isEmpty {
            content
        } else {
            content.contextMenu { menu }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .vosFont(WorkspaceText.body)
                .foregroundStyle(palette.text)
                .lineSpacing(WorkspaceText.body.size * textScale * 0.45)
                .fixedSize(horizontal: false, vertical: true)
            if inferred {
                Text("整理时补充的关联")
                    .vosFont(WorkspaceText.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .accessibilityLabel("这一段包含整理时补充的关联")
            }
            if !anchors.isEmpty {
                Button(action: toggle) {
                    HStack(spacing: 5) {
                        Text(isExpanded ? "收起原话" : "看原话 \(anchors.count)")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .vosFont(WorkspaceText.caption.size, weight: .semibold)
                    }
                    .vosFont(WorkspaceText.meta.size, weight: .medium)
                    .foregroundStyle(hovered || isExpanded ? palette.accent : palette.tertiaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查看这一段对应的原话")
                .accessibilityLabel(isExpanded ? "收起这一段的原话" : "查看这一段的原话")
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(anchors) { anchor in
                        quoteRow(anchor)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
    }

    @ViewBuilder
    private var menu: some View {
        Button(isExpanded ? "收起原话" : "看原话 \(anchors.count)", systemImage: "text.quote", action: toggle)
        if let first = anchors.first(where: { $0.canPlay }) {
            Button("回听这一段", systemImage: "play.circle") { play(first) }
        }
    }

    private func quoteRow(_ anchor: MaterialNoteAnchorPresentation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(anchor.quote)
                .vosFont(WorkspaceText.body)
                .foregroundStyle(palette.secondaryText)
                .lineSpacing(WorkspaceText.body.size * textScale * 0.35)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provenance(anchor))
                    .vosFont(WorkspaceText.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if anchor.canPlay {
                    Button("回听这句", systemImage: "play.circle") { play(anchor) }
                        .buttonStyle(.workspaceQuietCompact)
                        .help("回听这句原话")
                } else if anchor.canOpen {
                    Button("查看原文", systemImage: "text.magnifyingglass") { openSource(anchor.sourceID) }
                        .buttonStyle(.workspaceQuietCompact)
                        .help(anchor.caveat ?? "打开这段来源")
                }
            }
            if let caveat = anchor.caveat, !anchor.canPlay {
                Text(caveat)
                    .vosFont(WorkspaceText.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func provenance(_ anchor: MaterialNoteAnchorPresentation) -> String {
        var parts: [String] = []
        if let role = anchor.roleLabel { parts.append(role) }
        parts.append(anchor.memberTitle)
        if let time = anchor.timeLabel { parts.append(time) }
        return parts.joined(separator: " · ")
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