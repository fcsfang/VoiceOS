import SwiftUI
import VoiceOSCore

/// 笔记页：每个表达的最新一篇笔记，按整理时间倒序列出。材料页回答「我有
/// 什么材料」，主题页回答「我在关心什么」，笔记页回答「我整理出了什么」。
/// 点开任一篇都落到与首页、材料页相同的正文与阅读位置。
struct NotesLibraryView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    /// 打开纯笔记阅读页（文章本体），不是完整的材料页。
    let openNote: (String) -> Void
    /// 去材料页看全部来源。
    var openMaterials: () -> Void = {}

    @State private var notes: [NoteLibraryRow] = []
    @State private var query = ""
    @State private var readingStates: [String: SourceReadingState] = [:]
    @State private var selectedPending: Set<String> = []
    @State private var organizingSelected = false

    /// 还没读过的材料就是首页的「待处理」：直接从这里点开整理，读完自动消失。
    private var pendingMaterials: [SourceRecord] {
        model.records.filter { record in
            ["saved", "reference_only"].contains(record.state)
                && !record.isArchived
                && record.origin == "user" && record.speaker == "user"
                && record.feedbackKind == nil && !record.name.hasPrefix("行动反馈")
                && (readingStates[record.id] ?? .unread) != .read
        }.sorted {
            let left = $0.expressedDate ?? ConversationReflectionFocus.date($0.createdAt) ?? .distantPast
            let right = $1.expressedDate ?? ConversationReflectionFocus.date($1.createdAt) ?? .distantPast
            return left > right
        }
    }

    private var filtered: [NoteLibraryRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.searchableText.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let pendingMaterials = self.pendingMaterials
        let filtered = self.filtered
        return LazyVStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            WorkspacePageHeading(title: "笔记", subtitle: notes.isEmpty ? "" : "共 \(notes.count) 篇") {
                WorkspaceSearchField(text: $query, placeholder: "搜索笔记")
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("notes.search")
            }
            if notes.isEmpty {
                Text("还没有整理出笔记。打开一份材料让它整理成笔记后，会出现在这里。")
                    .foregroundStyle(palette.secondaryText)
            } else if filtered.isEmpty {
                Text("没有匹配的笔记").foregroundStyle(palette.secondaryText)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, stored in
                        if index > 0 { WorkspaceListDivider() }
                        Button { open(stored) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 13) {
                                VStack(alignment: .leading, spacing: 5) {
                                    // 标题不截断：长短由内容决定，列表用换行与滚动适配。
                                    Text(stored.title)
                                        .vosFont(WorkspaceText.rowTitle)
                                        .foregroundStyle(palette.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                    if let preview = stored.preview {
                                        Text(preview).vosFont(WorkspaceText.meta)
                                            .foregroundStyle(palette.secondaryText)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(ConversationReflectionFocus.date(stored.createdAt)?.formatted(date: .abbreviated, time: .omitted) ?? String(stored.createdAt.prefix(10)))
                                    .vosFont(WorkspaceText.caption, monospacedDigit: true)
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle()).workspaceHoverHighlight()
                        }
                        .buttonStyle(.plain)
                        .help("打开这篇笔记，回到上次读到的位置")
                        .accessibilityIdentifier("notes.row")
                    }
                }
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !pendingMaterials.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        WorkspaceSectionHeading("待阅读的材料", count: "\(pendingMaterials.count)")
                        Spacer(minLength: 8)
                        Button("全部材料", action: openMaterials)
                            .buttonStyle(.workspaceQuietCompact)
                    }
                    WorkspaceListDivider()
                    if !selectedPending.isEmpty {
                        HStack(spacing: 10) {
                            Text("已选 \(selectedPending.count) 份").vosFont(WorkspaceText.meta)
                            Button(organizingSelected ? "整理中…" : "整理成笔记（\(selectedPending.count) 份）") {
                                let records = pendingMaterials.filter { selectedPending.contains($0.id) }
                                organizingSelected = true
                                Task {
                                    await model.generateNotesSequentially(records)
                                    organizingSelected = false
                                    selectedPending = []
                                }
                            }
                            .buttonStyle(.workspaceSecondaryCompact)
                            .disabled(organizingSelected)
                            Button("取消选择") { selectedPending = [] }.buttonStyle(.workspaceQuietCompact)
                            Spacer(minLength: 0)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(pendingMaterials.prefix(12).enumerated()), id: \.element.id) { index, record in
                            if index > 0 { WorkspaceListDivider() }
                            HStack(spacing: 8) {
                                Button {
                                    if selectedPending.contains(record.id) { selectedPending.remove(record.id) }
                                    else { selectedPending.insert(record.id) }
                                } label: {
                                    Image(systemName: selectedPending.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedPending.contains(record.id) ? palette.accent : palette.tertiaryText)
                                        .padding(4).contentShape(Rectangle()).workspaceHoverHighlight()
                                }
                                .buttonStyle(.plain)
                                .help(selectedPending.contains(record.id) ? "取消选择" : "选择这份材料")
                                .accessibilityLabel(selectedPending.contains(record.id) ? "取消选择" : "选择这份材料")
                            Button { openNote(record.id) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(record.displayTitle)
                                        .vosFont(WorkspaceText.meta)
                                        .foregroundStyle(palette.text)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Text((readingStates[record.id] ?? .unread) == .reading ? "在读" : "未读")
                                        .vosFont(WorkspaceText.caption)
                                        .foregroundStyle(palette.tertiaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle()).workspaceHoverHighlight()
                            }
                            .buttonStyle(.plain)
                            .help("打开并整理成笔记")
                            .accessibilityIdentifier("notes.pending.row")
                            }
                        }
                    }
                    if pendingMaterials.count > 12 {
                        Button("还有 \(pendingMaterials.count - 12) 条，去材料页", action: openMaterials)
                            .buttonStyle(.workspaceQuietCompact)
                    }
                }
            }
        }
        .task(id: HomeRecentNotesKeyForNotes(records: model.recordsRevision, notes: model.materialNotesRevision)) {
            guard let store = model.store else { return }
            let trashed = Set(model.records.lazy.filter(\.isTrashed).map(\.id))
            let rows = try? await store.noteLibraryRows(excluding: trashed)
            if !Task.isCancelled, let rows { notes = rows }
        }
        .task(id: model.recordsRevision) { readingStates = await model.readingStates() }
    }

    private func open(_ stored: NoteLibraryRow) {
        let ids = stored.expressionKey.split(separator: "|").map(String.init)
        let index = model.sourcePageIndex
        for id in ids {
            if let expression = index.expression(for: id),
               VoiceOSStore.materialNoteExpressionKey(expression.sourceIDs + Array((expression.externalVersions ?? [:]).keys)) == stored.expressionKey,
               let personalID = expression.sourceIDs.first {
                openNote(personalID)
                return
            }
        }
        if let id = ids.first(where: { index.recordsByID[$0]?.origin == "user" }) ?? ids.first {
            openNote(id)
        }
    }
}

private struct HomeRecentNotesKeyForNotes: Equatable {
    let records: Int
    let notes: Int
}

private struct NoteLibraryRow: Identifiable, Sendable {
    let id: String
    let expressionKey: String
    let title: String
    let preview: String?
    let createdAt: String
    let searchableText: String
}

private extension VoiceOSStore {
    func noteLibraryRows(excluding trashed: Set<String>) throws -> [NoteLibraryRow] {
        try recentMaterialNotes(limit: nil).compactMap { stored in
            guard !stored.expressionKey.split(separator: "|").contains(where: { trashed.contains(String($0)) }) else { return nil }
            return NoteLibraryRow(id: stored.id, expressionKey: stored.expressionKey,
                           title: MaterialNoteHomeText.title(stored.note) ?? "未命名笔记",
                           preview: MaterialNoteHomeText.preview(stored.note),
                           createdAt: stored.createdAt, searchableText: stored.note.searchableText)
        }
    }
}


/// 首页与笔记页共用的标题与预览文本：lead 优先，其次第一个文字块的首句，
/// 截断到 80 字；笔记板（v6）与旧 sections 都能取。
enum MaterialNoteHomeText {
    static func title(_ note: MaterialNote) -> String? {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func preview(_ note: MaterialNote) -> String? {
        if let lead = note.lead {
            let text = flattened(lead)
            if !text.isEmpty { return text }
        }
        for section in note.sections {
            for paragraph in section.paragraphs {
                let text = flattened(paragraph.text)
                if !text.isEmpty { return excerpt(text) }
            }
        }
        // 笔记板（v6）：预览取第一个文字块的正文。
        for block in NoteBoardAdapting.blocks(for: note) where block.kind == "text" {
            for paragraph in block.paragraphs ?? [] {
                let text = flattened(paragraph.text)
                if !text.isEmpty { return excerpt(text) }
            }
        }
        return nil
    }

    private static let excerptLength = 80
    private static let sentenceEndings: Set<Character> = ["。", "！", "？", "!", "?", "…"]

    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func excerpt(_ text: String) -> String {
        if let ending = text.firstIndex(where: { sentenceEndings.contains($0) }),
           text.distance(from: text.startIndex, to: ending) < excerptLength {
            var end = text.index(after: ending)
            while end < text.endIndex, text[end] == "…" { end = text.index(after: end) }
            return String(text[..<end])
        }
        guard text.count > excerptLength else { return text }
        return String(text.prefix(excerptLength)) + "…"
    }
}
