import Foundation

/// A material's original text, split into blocks so the reading view can give
/// each tier its own type size. Inline emphasis stays inside `text`; the view
/// parses it.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case list(ordered: Bool, items: [MarkdownListItem])
    case quote(text: String)
    case rule
}

public struct MarkdownListItem: Equatable, Sendable {
    public let depth: Int
    public let text: String
    public init(depth: Int, text: String) {
        self.depth = depth
        self.text = text
    }
}

public enum MarkdownDocument {
    /// Drops a heading marker so it never renders as a literal `#`. Mirrors the
    /// file-private `displayTitle(_:)` helper in WorkspaceView.
    public static func plainTitle(_ raw: String) -> String {
        var text = raw
        while text.hasPrefix("#") {
            text.removeFirst()
            if text.hasPrefix(" ") { text.removeFirst() }
        }
        return text
    }

    public static func blocks(from raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var listOrdered: Bool?
        var items: [MarkdownListItem] = []
        var inFence = false
        var fenceLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(text: quote.joined(separator: "\n")))
            quote = []
        }
        func flushList() {
            if let ordered = listOrdered, !items.isEmpty {
                blocks.append(.list(ordered: ordered, items: items))
            }
            listOrdered = nil
            items = []
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFence {
                if isFence(trimmed) {
                    inFence = false
                    if !fenceLines.isEmpty { blocks.append(.paragraph(text: fenceLines.joined(separator: "\n"))) }
                    fenceLines = []
                } else {
                    fenceLines.append(line)
                }
                continue
            }
            if isFence(trimmed) {
                flushAll()
                inFence = true
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }
            if let text = quoteText(line) {
                flushParagraph()
                flushList()
                quote.append(text)
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                if let ordered = listOrdered, ordered != item.ordered { flushList() }
                listOrdered = item.ordered
                items.append(MarkdownListItem(depth: item.depth, text: item.text))
                continue
            }
            if listOrdered != nil, !items.isEmpty,
               line.first?.isWhitespace == true, let last = items.last {
                items[items.count - 1] = MarkdownListItem(depth: last.depth, text: last.text + " " + trimmed)
                continue
            }
            flushQuote()
            flushList()
            paragraph.append(trimmed)
        }
        if inFence, !fenceLines.isEmpty { blocks.append(.paragraph(text: fenceLines.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    private static func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3, let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func quoteText(_ line: String) -> String? {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        guard text.first == ">" else { return nil }
        while text.first == ">" {
            text = text.dropFirst()
            if text.first == " " { text = text.dropFirst() }
        }
        return String(text)
    }

    private static func listItem(_ line: String) -> (ordered: Bool, depth: Int, text: String)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let depth = min(4, width / 2)
        let body = line.dropFirst(indent.count)

        if let marker = body.first, marker == "-" || marker == "*" || marker == "+" {
            let rest = body.dropFirst()
            guard rest.first == " " else { return nil }
            let text = rest.drop(while: { $0 == " " })
            guard !text.isEmpty else { return nil }
            return (false, depth, String(text))
        }

        let digits = body.prefix(while: { $0.isASCII && $0.isWholeNumber })
        guard (1...3).contains(digits.count) else { return nil }
        let afterNumber = body.dropFirst(digits.count)
        guard let punctuation = afterNumber.first, punctuation == "." || punctuation == ")" else { return nil }
        let rest = afterNumber.dropFirst()
        guard rest.first == " " else { return nil }
        let text = rest.drop(while: { $0 == " " })
        guard !text.isEmpty else { return nil }
        return (true, depth, String(text))
    }
}
