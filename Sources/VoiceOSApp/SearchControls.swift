import Foundation
import SwiftUI
import VoiceOSCore

extension ControlCenter {
    func searchAll(_ query: String) async -> [SearchHit]? {
        guard let store else { status = "资料库尚未打开"; return nil }
        do { return try await store.search(query: query, limit: 60) }
        catch { status = error.localizedDescription; return nil }
    }
}

struct SearchResultsView: View {
    @ObservedObject var model: ControlCenter
    let query: String
    let openMaterial: (String) -> Void
    let openTask: (String) -> Void
    let clearQuery: () -> Void
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var failed = false

    private var materials: [SearchHit] {
        let catalog = Dictionary(uniqueKeysWithValues: model.records.map { ($0.id, $0) })
        return hits.filter { hit in
            guard hit.kind == .material, let source = catalog[hit.refID] else { return false }
            return !source.isTrashed
        }
    }

    private var claims: [SearchHit] {
        hits.filter { hit in
            hit.kind == .claim && model.claims.contains { $0.id == hit.refID && $0.validity == "current" && $0.reviewState != "rejected" }
        }
    }

    private var actions: [SearchHit] {
        hits.filter { $0.kind == .action }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if searching && hits.isEmpty { ProgressView("正在检索…").controlSize(.small) }
            if failed { WorkspaceNoticeText(message: model.status, severity: .danger) }
            if !materials.isEmpty {
                WorkspaceSection(title: "材料", icon: "books.vertical", count: materials.count) {
                    ForEach(materials.indices, id: \.self) { index in
                        let hit = materials[index]
                        WorkspaceRow(title: hit.title, subtitle: hit.snippet, icon: "doc.text") { openMaterial(hit.refID) }
                        if index < materials.count - 1 { Divider() }
                    }
                }
            }
            if !claims.isEmpty {
                WorkspaceSection(title: "观点", icon: "lightbulb", count: claims.count) {
                    ForEach(claims.indices, id: \.self) { index in
                        let hit = claims[index]
                        WorkspaceRow(title: hit.title, subtitle: hit.snippet, icon: "lightbulb") {
                            if let sourceID = model.claims.first(where: { $0.id == hit.refID })?.references.first?.sourceID {
                                openMaterial(sourceID)
                            }
                        }
                        if index < claims.count - 1 { Divider() }
                    }
                }
            }
            if !actions.isEmpty {
                WorkspaceSection(title: "行动", icon: "checkmark.circle", count: actions.count) {
                    ForEach(actions.indices, id: \.self) { index in
                        let hit = actions[index]
                        WorkspaceRow(title: hit.title, subtitle: hit.snippet, icon: "checkmark.circle") { openTask(hit.refID) }
                        if index < actions.count - 1 { Divider() }
                    }
                }
            }
            if !searching && !failed && materials.isEmpty && claims.isEmpty && actions.isEmpty {
                WorkspaceEmptyState(title: "没有找到相关内容", systemImage: "magnifyingglass", description: "换个关键词，或清空搜索查看全部材料。") {
                    Button("清空搜索") { clearQuery() }
                }
            }
        }
        .task(id: query) { await runSearch() }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { hits = []; failed = false; return }
        searching = true
        defer { searching = false }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        guard !Task.isCancelled else { return }
        if let results = await model.searchAll(trimmed) {
            hits = results
            failed = false
        } else {
            hits = []
            failed = true
        }
    }
}
