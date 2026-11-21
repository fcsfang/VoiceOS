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

    /// AI 生成标题的收紧，存量与新增都用：只去行首 markdown 标记与成对强调符，
    /// 保留词内 `#`、`_`（C#、snake_case），上限 24 个 Character，并保证幂等。
    public static func normalizedGenerated(_ title: String) -> String? {
        var clean = collapsed(markdownCleaned(title))
        var truncated = false
        while let last = clean.last, trailingPunctuation.contains(last) {
            if last == "…" { truncated = true }
            clean.removeLast()
            clean = clean.trimmingCharacters(in: .whitespaces)
        }
        guard containsReadableText(clean) else { return nil }
        if clean.count > 24 {
            return String(clean.prefix(24)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return truncated ? clean + "…" : clean
    }

    private static let openingFillers = ["我觉得", "我想说", "然后", "就是", "反正", "其实", "所以", "那个", "这个", "嗯", "啊", "哦", "呃"]
    private static let pronouns: Set<Character> = ["我", "你", "他", "她", "它"]
    private static let clauseSeparators: Set<Character> = ["。", "！", "？", "；", "，", "、"]
    private static let truncationPauses = clauseSeparators.union(["…"])
    private static let trailingPunctuation: Set<Character> = ["。", "！", "？", "；", "，", "、", "…", ".", "!", "?", ",", ";", ":", "："]

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 行首标记只在一行开头剥；词中的符号不属于 markdown。
    private static func markdownCleaned(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { rawLine -> String in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix(" ") { line.removeFirst() }
            while line.hasPrefix(">") { line.removeFirst() }
            if line.hasPrefix(" ") { line.removeFirst() }
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                line.removeFirst(2)
                break
            }
            if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            return line
        }
        var inline = lines.joined(separator: " ")
        for delimiter in ["**", "~~", "`"] {
            inline = removingPairs(of: delimiter, from: inline)
        }
        return inline
    }

    /// 只去掉成对出现的定界符；落单的定界符保持原样。
    private static func removingPairs(of delimiter: String, from text: String) -> String {
        let parts = text.components(separatedBy: delimiter)
        guard parts.count > 2 else { return text }
        var result = parts[0]
        let pairs = (parts.count - 1) / 2
        for index in 0..<pairs {
            result += parts[index * 2 + 1] + parts[index * 2 + 2]
        }
        if parts.count % 2 == 0, let last = parts.last { result += delimiter + last }
        return result
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