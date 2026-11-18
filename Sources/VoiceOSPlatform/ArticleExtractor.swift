import Foundation

public struct ExtractedArticle: Sendable {
    public let title: String
    public let text: String
    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

public enum ArticleExtractor {
    private static let hiddenBlocks = ["script", "style", "noscript", "svg", "iframe", "nav"]
    private static let blockTags = ["br", "p", "div", "section", "article", "header", "footer", "main", "aside", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "blockquote", "pre", "table", "ul", "ol"]

    public static func extract(html: String, baseURL: URL) -> ExtractedArticle? {
        var body = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        for tag in hiddenBlocks {
            body = body.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(of: "<a\\b[^>]*>", with: "\u{01}", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "</a\\s*>", with: "\u{02}", options: [.regularExpression, .caseInsensitive])
        for tag in blockTags {
            body = body.replacingOccurrences(of: "</?\(tag)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        body = decodeEntities(body)
        let lines = body.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .compactMap(dropLinkDominatedLine)
        let text = lines.joined(separator: "\n")
        guard text.count >= 80 else { return nil }
        return ExtractedArticle(title: title(from: html, baseURL: baseURL), text: text)
    }

    private static func dropLinkDominatedLine(_ line: String) -> String? {
        var anchorCharacters = 0
        var linkCount = 0
        var insideAnchor = false
        for scalar in line.unicodeScalars {
            if scalar == "\u{01}" {
                insideAnchor = true
                linkCount += 1
            } else if scalar == "\u{02}" {
                insideAnchor = false
            } else if insideAnchor {
                anchorCharacters += 1
            }
        }
        let visibleCharacters = line.unicodeScalars.count - linkCount * 2
        guard visibleCharacters > 0 else { return nil }
        if linkCount >= 2 && anchorCharacters * 5 > visibleCharacters * 3 { return nil }
        return line.replacingOccurrences(of: "\u{01}", with: "").replacingOccurrences(of: "\u{02}", with: "")
    }

    private static func title(from html: String, baseURL: URL) -> String {
        if let range = html.range(of: "<title\\b[^>]*>[\\s\\S]*?</title\\s*>", options: [.regularExpression, .caseInsensitive]) {
            let raw = String(html[range]).replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let line = decodeEntities(raw).split(whereSeparator: \.isNewline)
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .first { !$0.isEmpty }
            if let line { return line }
        }
        return baseURL.host ?? baseURL.absoluteString
    }

    private static func decodeEntities(_ value: String) -> String {
        let text = value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let regex = try? NSRegularExpression(pattern: "&#([xX]?[0-9A-Fa-f]+);") else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
            guard let digitsRange = Range(match.range(at: 1), in: text) else { continue }
            let digits = String(text[digitsRange])
            let scalarValue = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { continue }
            result.replaceCharacters(in: match.range, with: String(Character(scalar)))
        }
        return result as String
    }
}
