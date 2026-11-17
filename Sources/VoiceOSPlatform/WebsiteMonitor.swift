import Foundation
import VoiceOSCore

/// Fetches one department column page, then each candidate article, serially
/// with a fixed spacing. Parsing is deliberately conservative: same-host links
/// that look like CMS article URLs only.
public struct WebsiteMonitor: WebsiteMonitorCollecting {
    public static let requestSpacing: TimeInterval = 0.5
    public typealias FetchHTML = @Sendable (URL) async throws -> String
    private let fetchHTML: FetchHTML

    public init(fetchHTML: @escaping FetchHTML = WebsiteMonitor.defaultFetchHTML) {
        self.fetchHTML = fetchHTML
    }

    public func collect(columnURL: URL) async throws -> [WebsiteMonitorEntry] {
        guard ["http", "https"].contains(columnURL.scheme?.lowercased() ?? "") else {
            throw VoiceOSError("官网栏目必须是 http 或 https 地址")
        }
        let html = try await fetchHTML(columnURL)
        let links = MonitorListParser.articleLinks(html: html, baseURL: columnURL)
        var entries: [WebsiteMonitorEntry] = []
        for (index, link) in links.enumerated() {
            if index > 0 { try await Task.sleep(for: .seconds(Self.requestSpacing)) }
            var text = link.title
            var note: String?
            do {
                let articleHTML = try await fetchHTML(link.url)
                if let article = ArticleExtractor.extract(html: articleHTML, baseURL: link.url), article.text.count > text.count {
                    text = article.text
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                note = error.localizedDescription
            }
            entries.append(WebsiteMonitorEntry(url: link.url.absoluteString, title: link.title,
                                              publishedAt: link.publishedAt, text: text, note: note))
        }
        return entries
    }

    public static func defaultFetchHTML(_ url: URL) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("VoiceOS-Monitor/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VoiceOSError("网页返回 \(http.statusCode)，无法读取")
        }
        guard data.count <= 4 * 1024 * 1024 else { throw VoiceOSError("网页超过 4MB，无法读取") }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw VoiceOSError("网页编码无法识别")
        }
        return html
    }
}

public enum MonitorListParser {
    public struct ArticleLink: Sendable, Equatable {
        public let url: URL
        public let title: String
        public let publishedAt: Date?
        public init(url: URL, title: String, publishedAt: Date?) {
            self.url = url; self.title = title; self.publishedAt = publishedAt
        }
    }

    private static let navigationTitles: Set<String> = ["首页", "上一页", "下一页", "尾页", "更多", "返回", "English"]

    public static func articleLinks(html: String, baseURL: URL) -> [ArticleLink] {
        guard let regex = try? NSRegularExpression(
            pattern: "<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]) else { return [] }
        let text = html as NSString
        var seen = Set<String>()
        var links: [ArticleLink] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTitle = String(html[titleRange]).replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let title = decodeEntities(rawTitle).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard title.count >= 6, !navigationTitles.contains(title) else { continue }
            let lowered = href.lowercased()
            guard !href.hasPrefix("#"), !lowered.hasPrefix("javascript:"), !lowered.hasPrefix("mailto:") else { continue }
            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.host?.lowercased() == baseURL.host?.lowercased() else { continue }
            let path = url.path.lowercased()
            guard path.count > 1, !path.contains("index"), !path.contains("list"), !path.contains("default") else { continue }
            let looksLikeArticle = path.range(of: "/20\\d\\d/", options: .regularExpression) != nil
                || path.contains("/info/") || path.contains("/content/")
                || path.range(of: "c\\d+a\\d+", options: .regularExpression) != nil
                || path.range(of: "/\\d{3,}", options: .regularExpression) != nil
            guard looksLikeArticle else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            links.append(ArticleLink(url: url, title: title,
                                     publishedAt: publishedDate(in: title + " " + url.absoluteString)))
        }
        return links
    }

    private static func publishedDate(in text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: "(20\\d{2})[-/.年](\\d{1,2})[-/.月](\\d{1,2})") else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let year = Int(ns.substring(with: match.range(at: 1))),
              let month = Int(ns.substring(with: match.range(at: 2))),
              let day = Int(ns.substring(with: match.range(at: 3))) else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
