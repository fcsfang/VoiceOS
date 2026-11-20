import Foundation

/// A raw material title is often a bare URL, which reads as machine output at
/// heading size. Split it into the part worth echoing large and the source it
/// came from, so every surface headlines the same words in the same order.
public enum WorkspaceTitleFit {
    public struct Presentation: Equatable, Sendable {
        /// What a heading may show. For links this is the last path segment.
        public let title: String
        /// Where the link came from, shown small under the title.
        public let source: String?

        public init(title: String, source: String? = nil) {
            self.title = title
            self.source = source
        }
    }

    private static let genericSegments: Set<String> = ["watch", "s", "p", "index", "view", "detail"]

    /// Splits a note that starts with a bare link into the link and the rest, so
    /// a captured URL plus commentary does not headline as one long string.
    public static func splitLeadingLink(_ raw: String) -> (link: String, rest: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = text.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return nil }
        let token = String(text[..<space])
        guard token.hasPrefix("http://") || token.hasPrefix("https://") else { return nil }
        let rest = String(text[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        return (token, rest)
    }

    public static func present(_ raw: String) -> Presentation {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") {
            text.removeFirst()
            if text.hasPrefix(" ") { text.removeFirst() }
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return Presentation(title: text)
        }
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty else { return Presentation(title: text) }
        let segments = url.pathComponents.filter { $0 != "/" }.compactMap { $0.removingPercentEncoding }
        let last = segments.last?.trimmingCharacters(in: .whitespaces) ?? ""
        let generic = last.isEmpty || last.utf8.count <= 2 || genericSegments.contains(last.lowercased())
        let title = generic ? host : last
        let parent = segments.dropLast().joined(separator: "/")
        var source: String? = generic ? nil : (parent.isEmpty ? host : host + "/" + parent)
        if source == title { source = nil }
        return Presentation(title: title, source: source)
    }
}