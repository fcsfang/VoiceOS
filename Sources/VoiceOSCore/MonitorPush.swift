import Foundation

public enum MonitorPushChannel: String, Codable, Sendable, Equatable, CaseIterable {
    case wecom
    case serverChan = "serverchan"
    public var displayName: String {
        switch self {
        case .wecom: "企业微信群机器人"
        case .serverChan: "Server酱式"
        }
    }
    public var webhookHint: String {
        switch self {
        case .wecom: "粘贴企业微信群机器人的 Webhook 地址（https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…）"
        case .serverChan: "粘贴 Server酱式的发送地址（https://sctapi.ftqq.com/<SendKey>.send）"
        }
    }
}

public struct MonitorPushItem: Sendable, Equatable {
    public let title: String
    public let deadline: String?
    public let whyRelevant: String
    public let sourceName: String
    public let category: MonitorItemCategory
    public init(title: String, deadline: String?, whyRelevant: String, sourceName: String, category: MonitorItemCategory) {
        self.title = title
        self.deadline = deadline
        self.whyRelevant = whyRelevant
        self.sourceName = sourceName
        self.category = category
    }
}

public struct MonitorPushContent: Sendable, Equatable {
    public let date: String
    public let headline: String
    public let summary: String
    public let items: [MonitorPushItem]
    public init(date: String, headline: String, summary: String, items: [MonitorPushItem]) {
        self.date = date
        self.headline = headline
        self.summary = summary
        self.items = items
    }
}

public struct MonitorPushRequest {
    public let channel: MonitorPushChannel
    public let title: String
    public let body: String
    public let urlRequest: URLRequest
    public init(channel: MonitorPushChannel, title: String, body: String, urlRequest: URLRequest) {
        self.channel = channel
        self.title = title
        self.body = body
        self.urlRequest = urlRequest
    }
}

public enum MonitorPushComposer {
    public static let footer = "在 VoiceOS 中查看完整原文。"
    public static let wecomLimit = 3800
    public static let serverChanLimit = 30_000
    private static let formAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func request(_ content: MonitorPushContent, channel: MonitorPushChannel, webhookURL: URL) throws -> MonitorPushRequest {
        guard ["http", "https"].contains(webhookURL.scheme?.lowercased() ?? ""), webhookURL.host != nil else {
            throw VoiceOSError("推送地址无效：需要完整的 http 或 https 地址")
        }
        switch channel {
        case .wecom:
            let body = wecomMarkdown(content)
            let payload: [String: Any] = ["msgtype": "markdown", "markdown": ["content": body]]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            var request = URLRequest(url: webhookURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            return .init(channel: channel, title: content.headline, body: body, urlRequest: request)
        case .serverChan:
            let title = serverChanTitle(content)
            let body = serverChanDesp(content)
            let form = "title=" + formEncode(title) + "&desp=" + formEncode(body)
            var request = URLRequest(url: webhookURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.utf8)
            return .init(channel: channel, title: title, body: body, urlRequest: request)
        }
    }

    public static func wecomMarkdown(_ content: MonitorPushContent) -> String {
        var lines: [String] = ["### 每日消息监测 · \(content.date)", ""]
        if !content.headline.isEmpty { lines.append("**\(content.headline)**") }
        if !content.summary.isEmpty {
            lines.append("")
            lines.append(content.summary)
        }
        lines += itemLines(content)
        lines.append("")
        lines.append(footer)
        return truncate(lines.joined(separator: "\n"), limit: wecomLimit,
                         note: "内容较长，已省略部分事项；请在 VoiceOS 中查看完整报告。")
    }

    public static func serverChanTitle(_ content: MonitorPushContent) -> String {
        let title = content.headline.isEmpty ? "每日消息监测" : content.headline
        let text = "每日消息监测 · \(content.date)｜\(title)"
        return String(text.prefix(80))
    }

    public static func serverChanDesp(_ content: MonitorPushContent) -> String {
        var lines: [String] = ["## 每日消息监测 · \(content.date)", ""]
        if !content.headline.isEmpty { lines.append("**\(content.headline)**") }
        if !content.summary.isEmpty {
            lines.append("")
            lines.append(content.summary)
        }
        lines += itemLines(content)
        lines.append("")
        lines.append(footer)
        return truncate(lines.joined(separator: "\n"), limit: serverChanLimit,
                         note: "内容较长，已省略部分事项；请在 VoiceOS 中查看完整报告。")
    }

    public static func validateResponse(channel: MonitorPushChannel, statusCode: Int, body: Data) throws {
        guard (200..<300).contains(statusCode) else {
            throw VoiceOSError("推送服务返回 HTTP \(statusCode)，可稍后重试")
        }
        switch channel {
        case .wecom:
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let errcode = (object["errcode"] as? NSNumber)?.intValue else {
                throw VoiceOSError("企业微信返回内容无法识别，无法确认送达；请核对机器人地址")
            }
            guard errcode == 0 else {
                let message = object["errmsg"] as? String ?? "原因未知"
                throw VoiceOSError("企业微信返回 errcode=\(errcode)：\(message)")
            }
        case .serverChan:
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
            if let code = (object["code"] as? NSNumber)?.intValue, code != 0 {
                let message = (object["message"] as? String) ?? (object["msg"] as? String) ?? "原因未知"
                throw VoiceOSError("Server酱返回 code=\(code)：\(message)")
            }
        }
    }

    private static func itemLines(_ content: MonitorPushContent) -> [String] {
        var lines: [String] = []
        let groups: [(String, [MonitorPushItem])] = [
            ("适用", content.items.filter { $0.category == .applicable }),
            ("待核对", content.items.filter { $0.category == .needsCheck })
        ]
        if content.items.isEmpty { lines.append(""); lines.append("今天没有需要关注或行动的事项。") }
        for (title, items) in groups where !items.isEmpty {
            lines.append("")
            lines.append("**\(title)**")
            for (index, item) in items.enumerated() {
                var head = "\(index + 1). **\(item.title)**"
                if let deadline = item.deadline?.trimmingCharacters(in: .whitespacesAndNewlines), !deadline.isEmpty {
                    head += "（截止 \(deadline)）"
                }
                lines.append(head)
                if !item.whyRelevant.isEmpty { lines.append("   \(item.whyRelevant)") }
                lines.append("   来源：\(item.sourceName)")
            }
        }
        return lines
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }

    static func truncate(_ text: String, limit: Int, note: String) -> String {
        guard text.utf8.count > limit else { return text }
        let noteLine = "\n\n" + note
        let budget = max(0, limit - noteLine.utf8.count)
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > budget { break }
            result.append(character)
            used += size
        }
        return result + noteLine
    }
}

public struct MonitorPushResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol MonitorPushTransport: Sendable {
    func send(_ request: URLRequest) async throws -> MonitorPushResponse
}

public struct URLSessionMonitorPushTransport: MonitorPushTransport {
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 20) { self.timeout = timeout }
    public func send(_ request: URLRequest) async throws -> MonitorPushResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoiceOSError("推送服务没有返回 HTTP 响应，无法确认送达")
        }
        return .init(statusCode: http.statusCode, body: data)
    }
}

public struct MonitorPushOutcome: Sendable, Equatable {
    public let success: Bool
    public let error: String?
    public let deliveredAt: String?
    public init(success: Bool, error: String?, deliveredAt: String?) {
        self.success = success
        self.error = error
        self.deliveredAt = deliveredAt
    }
}

public enum MonitorPushErrorText {
    public static func display(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "网络未连接，推送未送达；可稍后重试"
        case NSURLErrorTimedOut:
            return "推送超时，未确认送达；可稍后重试"
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "无法连接推送服务；请检查网络与地址"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "推送服务的安全连接失败；请核对地址"
        default:
            return error.localizedDescription
        }
    }
}

/// Builds the body, persists it before sending, and records the delivery state.
/// A failure keeps the payload so the user can retry without rebuilding it.
public struct MonitorPushService: Sendable {
    private let store: VoiceOSStore
    private let transport: any MonitorPushTransport
    private let now: @Sendable () -> Date
    public init(store: VoiceOSStore, transport: any MonitorPushTransport = URLSessionMonitorPushTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.now = now
    }

    public func deliver(reportID: String, date: String, content: MonitorPushContent,
                        channel: MonitorPushChannel, webhookURL: URL) async -> MonitorPushOutcome {
        let request: MonitorPushRequest
        do {
            request = try MonitorPushComposer.request(content, channel: channel, webhookURL: webhookURL)
        } catch {
            let message = MonitorPushErrorText.display(error)
            try? await store.markMonitorReportDeliveryFailed(id: reportID, error: message)
            return .init(success: false, error: message, deliveredAt: nil)
        }
        do {
            try await store.setMonitorReportPayload(id: reportID, payloadJSON: Self.payloadJSON(request))
            let response = try await transport.send(request.urlRequest)
            try MonitorPushComposer.validateResponse(channel: channel, statusCode: response.statusCode, body: response.body)
            let deliveredAt = ISO8601DateFormatter().string(from: now())
            try await store.markMonitorReportDelivered(id: reportID, at: deliveredAt)
            return .init(success: true, error: nil, deliveredAt: deliveredAt)
        } catch {
            let message = MonitorPushErrorText.display(error)
            try? await store.markMonitorReportDeliveryFailed(id: reportID, error: message)
            return .init(success: false, error: message, deliveredAt: nil)
        }
    }

    public func sendTest(_ content: MonitorPushContent, channel: MonitorPushChannel, webhookURL: URL) async -> MonitorPushOutcome {
        do {
            let request = try MonitorPushComposer.request(content, channel: channel, webhookURL: webhookURL)
            let response = try await transport.send(request.urlRequest)
            try MonitorPushComposer.validateResponse(channel: channel, statusCode: response.statusCode, body: response.body)
            return .init(success: true, error: nil, deliveredAt: ISO8601DateFormatter().string(from: now()))
        } catch {
            return .init(success: false, error: MonitorPushErrorText.display(error), deliveredAt: nil)
        }
    }

    static func payloadJSON(_ request: MonitorPushRequest) -> String {
        let object: [String: Any] = ["channel": request.channel.rawValue, "title": request.title, "body": request.body]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
