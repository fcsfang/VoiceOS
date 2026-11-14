import Foundation

public struct CaptureLink: Sendable {
    public let text: String?
    public let title: String?
    public let url: String?
    public let successURL: URL?

    public static func isCapture(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "voiceos" && url.host?.lowercased() == "capture"
    }

    public static func parse(_ url: URL) -> CaptureLink? {
        guard isCapture(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let text = value("text"), title = value("title"), sourceURL = value("url")
        guard text != nil || sourceURL != nil else { return nil }
        let successURL: URL?
        if let raw = value("x-success") {
            guard let candidate = URL(string: raw), let scheme = candidate.scheme, !scheme.isEmpty else { return nil }
            successURL = candidate
        } else {
            successURL = nil
        }
        return CaptureLink(text: text, title: title, url: sourceURL, successURL: successURL)
    }

    public static func successCallback(_ url: URL, sourceID: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "source_id", value: sourceID))
        components.queryItems = items
        return components.url
    }
}
