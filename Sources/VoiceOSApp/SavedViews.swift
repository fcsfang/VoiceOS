import Foundation
import VoiceOSCore

enum SavedViewPage: String, Codable {
    case materials, actions

    var filters: [String] {
        switch self {
        case .materials: ["日常材料", "未读", "在读", "已归档", "回收站"]
        case .actions: ["全部", "我的待办", "AI 助理", "已完成", "问题与目标", "待核对", "历史记录"]
        }
    }
}

struct SavedWorkspaceView: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var page: SavedViewPage
    var filter: String
}

extension ControlCenter {
    static let savedViewsLimit = 8
    static let savedViewNameLimit = 20

    func savedWorkspaceViews() async -> [SavedWorkspaceView] {
        loadSavedViews(key: await savedViewsKey())
    }

    func saveWorkspaceView(name: String, page: SavedViewPage, filter: String) async -> [SavedWorkspaceView]? {
        let key = await savedViewsKey()
        var views = loadSavedViews(key: key)
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ControlCenter.savedViewNameLimit))
        guard !trimmed.isEmpty, page.filters.contains(filter),
              views.count < ControlCenter.savedViewsLimit,
              !views.contains(where: { $0.name == trimmed }) else { return nil }
        views.append(SavedWorkspaceView(id: UUID().uuidString, name: trimmed, page: page, filter: filter))
        return writeSavedViews(views, key: key) ? views : nil
    }

    func deleteWorkspaceView(id: String) async -> [SavedWorkspaceView]? {
        let key = await savedViewsKey()
        var views = loadSavedViews(key: key)
        guard views.contains(where: { $0.id == id }) else { return nil }
        views.removeAll { $0.id == id }
        return writeSavedViews(views, key: key) ? views : nil
    }

    private func savedViewsKey() async -> String {
        let root = await store?.root
        return "voiceos.savedViews.v1:" + (root?.standardizedFileURL.path ?? libraryTitle)
    }

    private func loadSavedViews(key: String) -> [SavedWorkspaceView] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedWorkspaceView].self, from: data) else { return [] }
        return Array(decoded
            .filter { $0.page.filters.contains($0.filter) && (1...ControlCenter.savedViewNameLimit).contains($0.name.count) }
            .prefix(ControlCenter.savedViewsLimit))
    }

    private func writeSavedViews(_ views: [SavedWorkspaceView], key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(Array(views.prefix(ControlCenter.savedViewsLimit))) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }
}
