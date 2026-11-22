import Foundation

/// 笔记阅读位置：键是笔记表达键（成员 sourceID 排序连接），值是该笔记版本下的
/// 段落锚点。「继续读」的 help 承诺隔天回到同一位置，所以这里写入 UserDefaults
/// 持久化；同时记住保存时的笔记 id，重生成后段落结构变化就不再沿用旧锚点。
@MainActor
enum MaterialNoteReadingPosition {
    private struct Entry: Codable {
        let noteID: String
        let anchor: String
    }

    private static let defaultsKey = "voiceos.note.readingPosition.v1"
    private static let limit = 400
    private static var entries: [String: Entry] = load()

    static func anchor(for expressionKey: String, noteID: String) -> String? {
        guard let entry = entries[expressionKey], entry.noteID == noteID else { return nil }
        return entry.anchor
    }

    static func record(_ anchor: String, for expressionKey: String, noteID: String) {
        if entries[expressionKey]?.noteID == noteID, entries[expressionKey]?.anchor == anchor { return }
        entries[expressionKey] = Entry(noteID: noteID, anchor: anchor)
        // 只保留最近写入的一批，避免无界增长；超限时按字典顺序淘汰。
        while entries.count > limit { entries.removeValue(forKey: entries.keys.first!) }
        save()
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return decoded
    }

    private static func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}