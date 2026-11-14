import Foundation

public struct SourceChapter: Sendable {
    public let sourceID: String
    public let ordinal: Int
    public let title: String
    public let startMS: Int
}

extension VoiceOSStore {
    public func chapters(sourceID: String) throws -> [SourceChapter] {
        try db.query("SELECT * FROM source_chapters WHERE source_id=? ORDER BY ordinal", [sourceID]).map { row in
            guard let sourceID = row["source_id"], let ordinal = row["ordinal"].flatMap(Int.init), let title = row["title"], let startMS = row["start_ms"].flatMap(Int.init) else {
                throw VoiceOSError("章节记录损坏")
            }
            return SourceChapter(sourceID: sourceID, ordinal: ordinal, title: title, startMS: startMS)
        }
    }

    public func replaceChapters(sourceID: String, entries: [(title: String, startMS: Int)]) throws {
        guard try db.query("SELECT id FROM sources WHERE id=?", [sourceID]).first != nil else { throw VoiceOSError("来源不存在") }
        let ordered = entries.enumerated().sorted { ($0.element.startMS, $0.offset) < ($1.element.startMS, $1.offset) }.map { $0.element }
        try db.transaction {
            try db.execute("DELETE FROM source_chapters WHERE source_id=?", [sourceID])
            for (ordinal, entry) in ordered.enumerated() {
                let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.unicodeScalars.count <= 200 else { throw VoiceOSError("章节标题需为 1 到 200 字") }
                guard entry.startMS >= 0 else { throw VoiceOSError("章节起点不能为负") }
                try db.execute("INSERT INTO source_chapters(source_id,ordinal,title,start_ms) VALUES(?,?,?,?)", [sourceID, String(ordinal), title, String(entry.startMS)])
            }
        }
    }
}
