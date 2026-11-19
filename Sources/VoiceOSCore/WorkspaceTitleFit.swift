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
        let segments = url.pathComponents.filter { $0 != "/" }.compactMap { $0.removingPercentEncoding }
        let last = segments.last?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = last.isEmpty ? host : last
        let parent = segments.dropLast().joined(separator: "/")
        var source: String? = parent.isEmpty ? host : host + "/" + parent
        if source == title { source = nil }
        return Presentation(title: title, source: source)
    }
}