import Foundation

public struct MonitorQQSourceConfig: Codable, Sendable, Equatable {
    public var conversationID: String
    public var conversationName: String?
    public var startAt: String?
    public init(conversationID: String, conversationName: String? = nil, startAt: String? = nil) {
        self.conversationID = conversationID
        self.conversationName = conversationName
        self.startAt = startAt
    }
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case conversationName = "conversation_name"
        case startAt = "start_at"
    }
}

public struct MonitorWebsiteSourceConfig: Codable, Sendable, Equatable {
    public var columnURL: String
    public var startAt: String?
    public init(columnURL: String, startAt: String? = nil) {
        self.columnURL = columnURL
        self.startAt = startAt
    }
    enum CodingKeys: String, CodingKey {
        case columnURL = "column_url"
        case startAt = "start_at"
    }
}

/// Source configs are stored as JSON in monitor_sources. The runner reads only
/// the id or URL it needs; unit B adds an explicit start marker so a first run
/// never silently imports years of history.
public enum MonitorSourceConfigParser {
    public static func qq(_ json: String) throws -> MonitorQQSourceConfig {
        guard let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(MonitorQQSourceConfig.self, from: data) else {
            throw VoiceOSError("QQ 来源配置无效：需要 conversation_id（形如 group:群号）")
        }
        guard config.conversationID.hasPrefix("group:"), config.conversationID.count > "group:".count else {
            throw VoiceOSError("QQ 来源配置无效：会话标识应为 group:群号")
        }
        return config
    }

    public static func website(_ json: String) throws -> MonitorWebsiteSourceConfig {
        guard let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(MonitorWebsiteSourceConfig.self, from: data) else {
            throw VoiceOSError("官网来源配置无效：需要 column_url（栏目地址）")
        }
        try validateWebsiteURL(config.columnURL)
        return config
    }

    public static func qqJSON(conversationID: String, conversationName: String?, startAt: String?) throws -> String {
        let config = MonitorQQSourceConfig(conversationID: conversationID, conversationName: conversationName, startAt: startAt)
        return String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    }

    public static func websiteJSON(columnURL: String, startAt: String?) throws -> String {
        try validateWebsiteURL(columnURL)
        let config = MonitorWebsiteSourceConfig(columnURL: columnURL, startAt: startAt)
        return String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    }

    public static func validateWebsiteURL(_ raw: String) throws {
        guard let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            throw VoiceOSError("官网栏目必须是完整的 http 或 https 地址")
        }
    }

    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        TimestampFormatting.dayString(date, timeZone: calendar.timeZone)
    }

    public static func timestampString(_ date: Date) -> String { TimestampFormatting.iso.string(from: date) }

    public static func parseStart(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let date = TimestampFormatting.iso.date(from: text) { return date }
        if let date = TimestampFormatting.dayDate(text, timeZone: calendar.timeZone) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)
    }
}
