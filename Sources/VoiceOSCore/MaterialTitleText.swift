import Foundation

/// 材料标题的单一契约：AI 标题收紧与正文回退共用同一套 Character 计数规则，
/// 首页列表的长短和形状因此来自同一个地方。
public enum MaterialTitleText {
    /// 把口语原文凝成标题样式的回退。空或仅标点时返回 nil，调用方保留旧回退。
    public static func derived(fromTranscript transcript: String) -> String? {
        var normalized = collapsed(transcript)
        normalized = String(normalized.drop(while: { $0.isWhitespace || clauseSeparators.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        let stripped = strippedOpening(normalized)
        let base = stripped.count >= 6 ? stripped : normalized
        let title = cappedToTwenty(firstClause(base)).trimmingCharacters(in: .whitespaces)
        guard containsReadableText(title) else { return nil }
        return title
    }

    /// AI 生成标题的收紧，存量与新增都用：去 markdown 与句末标点，上限 24 个 Character。
    public static func normalizedGenerated(_ title: String) -> String? {
        var clean = collapsed(title.filter { !markdownCharacters.contains($0) })
        if clean.hasPrefix("- ") { clean = String(clean.dropFirst(2)) }
        clean = clean.trimmingCharacters(in: .whitespaces)
        while let last = clean.last, trailingPunctuation.contains(last) { clean.removeLast() }
        clean = clean.trimmingCharacters(in: .whitespaces)
        guard containsReadableText(clean) else { return nil }
        guard clean.count > 24 else { return clean }
        return String(clean.prefix(24)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let openingFillers = ["我觉得", "我想说", "然后", "就是", "反正", "其实", "所以", "那个", "这个", "嗯", "啊", "哦", "呃"]
    private static let pronouns: Set<Character> = ["我", "你", "他", "她", "它"]
    private static let clauseSeparators: Set<Character> = ["。", "！", "？", "；", "，", "、"]
    private static let truncationPauses = clauseSeparators.union(["…"])
    private static let markdownCharacters: Set<Character> = ["#", "*", "`", "~", "_", ">"]
    private static let trailingPunctuation: Set<Character> = ["。", "！", "？", "；", "，", "、", "…", ".", "!", "?", ",", ";", ":", "："]

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 只在句首剥语气词，最多两轮；剥掉后顺带清掉紧跟的标点。
    private static func strippedOpening(_ text: String) -> String {
        var current = text
        for _ in 0..<2 {
            guard let filler = openingFillers.first(where: { current.hasPrefix($0) }) else { break }
            current = String(current.dropFirst(filler.count))
            current = String(current.drop(while: { $0.isWhitespace || clauseSeparators.contains($0) }))
        }
        var characters = Array(current)
        while characters.count > 1, characters[0] == characters[1], pronouns.contains(characters[0]) {
            characters.remove(at: 0)
        }
        return String(characters)
    }

    private static func firstClause(_ text: String) -> String {
        var clause: [Character] = []
        for character in text {
            if clause.count >= 2, clauseSeparators.contains(character) { break }
            clause.append(character)
        }
        return String(clause)
    }

    private static func cappedToTwenty(_ text: String) -> String {
        guard text.count > 20 else { return text }
        let head = Array(text.prefix(20))
        if let pause = head.lastIndex(where: { truncationPauses.contains($0) }) {
            let cut = String(head[..<pause]).trimmingCharacters(in: .whitespaces)
            if !cut.isEmpty { return cut + "…" }
        }
        return String(head).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func containsReadableText(_ text: String) -> Bool {
        text.contains { character in
            !character.isWhitespace && !character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
        }
    }
}
