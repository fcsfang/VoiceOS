import SwiftUI
import VoiceOSCore

/// 笔记页：每个表达的最新一篇笔记，按整理时间倒序列出。材料页回答「我有
/// 什么材料」，主题页回答「我在关心什么」，笔记页回答「我整理出了什么」。
/// 点开任一篇都落到与首页、材料页相同的正文与阅读位置。
struct NotesLibraryView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let openSource: (String) -> Void

    @State private var notes: [StoredMaterialNote] = []
    @State private var query = ""

    private var filtered: [StoredMaterialNote] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return notes }
        return notes.filter { stored in self.matches(stored, query: q) }
    }

    private func matches(_ stored: StoredMaterialNote, query: String) -> Bool {
        let note = stored.note
        var parts = [note.title]
        if let lead = note.lead { parts.append(lead) }
        for section in note.sections {
            if let heading = section.heading { parts.append(heading) }
            parts.append(contentsOf: section.paragraphs.map(\.text))
        }
        return parts.joined(separator: "\n").localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            HStack(alignment: .firstTextBaseline) {
                WorkspaceHeading(eyebrow: "", title: "笔记")
                Spacer()
                Text("\(notes.count) 篇 · 按整理时间").vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.secondaryText)
            }
            WorkspaceSearchField(text: $query, placeholder: "搜索笔记标题或正文")
                .accessibilityIdentifier("notes.search")
            if notes.isEmpty {
                Text("还没有整理出笔记。打开一份材料让它整理成笔记后，会出现在这里。")
                    .foregroundStyle(palette.secondaryText)
            } else if filtered.isEmpty {
                Text("没有匹配的笔记").foregroundStyle(palette.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, stored in
                        if index > 0 { WorkspaceListDivider() }
                        Button { open(stored) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 13) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(MaterialNoteHomeText.title(stored.note) ?? "未命名笔记")
                                        .vosFont(WorkspaceText.rowTitle)
                                        .foregroundStyle(palette.text)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                    if let preview = MaterialNoteHomeText.preview(stored.note) {
                                        Text(preview).vosFont(WorkspaceText.meta)
                                            .foregroundStyle(palette.secondaryText)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(String(stored.createdAt.prefix(10)))
                                    .vosFont(WorkspaceText.caption, monospacedDigit: true)
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .help("打开这篇笔记，回到上次读到的位置")
                        .accessibilityIdentifier("notes.row")
                    }
                }
            }
        }
        .task(id: HomeRecentNotesKeyForNotes(records: model.recordsRevision, notes: model.materialNotesRevision)) {
            await reload()
        }
        .task { await reload() }
    }

    private func open(_ stored: StoredMaterialNote) {
        guard let first = stored.expressionKey.split(separator: "|").first.map(String.init) else { return }
        openSource(first)
    }

    private func reload() async {
        notes = await model.recentMaterialNotes(limit: 500)
    }
}

private struct HomeRecentNotesKeyForNotes: Equatable {
    let records: Int
    let notes: Int
}
