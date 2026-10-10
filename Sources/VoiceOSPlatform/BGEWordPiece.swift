import Foundation
import VoiceOSCore

/// Exact pinned tokenizer settings: cased BertNormalizer, no accent stripping.
struct BGEWordPiece {
    let vocabulary: [String:Int]
    init(vocabulary: String) throws {
        var lines = vocabulary.components(separatedBy:"\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 21128, Set(lines).count == lines.count else { throw VoiceOSError("本地分词资源身份不符") }
        self.vocabulary = Dictionary(uniqueKeysWithValues:lines.enumerated().map { ($0.element,$0.offset) })
        guard self.vocabulary["[PAD]"] == 0, self.vocabulary["[UNK]"] == 100, self.vocabulary["[CLS]"] == 101, self.vocabulary["[SEP]"] == 102, self.vocabulary["[MASK]"] == 103 else { throw VoiceOSError("本地分词特殊标记不符") }
    }
    func encode(_ text: String) throws -> [Int] {
        let chars = Array(text.unicodeScalars)
        var tokens: [String] = [], current = "", i = 0
        func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
        let specials = ["[PAD]","[UNK]","[CLS]","[SEP]","[MASK]"]
        while i < chars.count {
            if let special = specials.first(where: { s in
                let word = Array(s.unicodeScalars)
                return i + word.count <= chars.count && Array(chars[i..<i+word.count]) == word
            }) { flush(); tokens.append(special); i += special.unicodeScalars.count; continue }
            let c = chars[i]; i += 1
            let category = c.properties.generalCategory
            if c.value == 0 || c.value == 0xFFFD || ((category == .control || category == .format) && ![9,10,13].contains(c.value)) { continue }
            if c.properties.isWhitespace { flush(); continue }
            if Self.chinese(c.value) || Self.punctuation(c) { flush(); tokens.append(String(c)); continue }
            current.unicodeScalars.append(c)
        }
        flush()
        var result = [101]
        for token in tokens {
            if specials.contains(token) { result.append(vocabulary[token]!); continue }
            let word = Array(token.unicodeScalars)
            if word.count > 100 { result.append(100); continue }
            var start = 0, pieces: [Int] = [], failed = false
            while start < word.count {
                var end = word.count, found: Int?
                while end > start {
                    let key = (start == 0 ? "" : "##") + String(String.UnicodeScalarView(word[start..<end]))
                    if let id = vocabulary[key] { found = id; break }
                    end -= 1
                }
                guard let found else { failed = true; break }
                pieces.append(found); start = end
            }
            result.append(contentsOf:failed ? [100] : pieces)
        }
        result.append(102)
        guard result.count <= 512 else { throw VoiceOSError("查询超过本地模型的文字长度，请缩短；原文未截断") }
        return result
    }
    static func chinese(_ n: UInt32) -> Bool {
        [(0x4E00,0x9FFF),(0x3400,0x4DBF),(0x20000,0x2A6DF),(0x2A700,0x2B73F),(0x2B740,0x2B81F),(0x2B820,0x2CEAF),(0xF900,0xFAFF),(0x2F800,0x2FA1F)].contains { n >= $0.0 && n <= $0.1 }
    }
    static func punctuation(_ c: Unicode.Scalar) -> Bool {
        if [(33,47),(58,64),(91,96),(123,126)].contains(where:{ c.value >= $0.0 && c.value <= $0.1 }) { return true }
        return [.connectorPunctuation,.dashPunctuation,.openPunctuation,.closePunctuation,.initialPunctuation,.finalPunctuation,.otherPunctuation].contains(c.properties.generalCategory)
    }
}
