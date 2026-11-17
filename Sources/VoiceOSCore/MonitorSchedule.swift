import Foundation

public enum MonitorTrigger: String, Codable, Sendable, Equatable {
    case launch, activation, wake, timer
}

public struct MonitorScheduleSettings: Codable, Sendable, Equatable {
    public var hour: Int
    public var minute: Int
    public init(hour: Int = 9, minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }
    public static let standard = MonitorScheduleSettings()
    public var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }
    public var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

public struct MonitorScheduleDecision: Sendable, Equatable {
    public let shouldRun: Bool
    public let reason: String
    public init(shouldRun: Bool, reason: String) {
        self.shouldRun = shouldRun
        self.reason = reason
    }
}

/// The daily gate reads only the clock and the latest report date. It never
/// touches QQ, the network or the model, so a ten-minute check stays cheap.
public enum MonitorSchedule {
    public static func dateKey(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func runTimeToday(now: Date, settings: MonitorScheduleSettings, calendar: Calendar = .current) -> Date? {
        guard settings.isValid else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = settings.hour
        components.minute = settings.minute
        components.second = 0
        return calendar.date(from: components)
    }

    /// Automatic runs happen at most once per day. A launch also catches up a
    /// missed day before the configured time; later triggers wait for the clock.
    public static func decide(trigger: MonitorTrigger, now: Date,
                              settings: MonitorScheduleSettings,
                              latestReportDate: String?,
                              calendar: Calendar = .current) -> MonitorScheduleDecision {
        guard let runTime = runTimeToday(now: now, settings: settings, calendar: calendar) else {
            return .init(shouldRun: false, reason: "自动检查时间无效，请在消息监测设置中重新选择")
        }
        let today = dateKey(now, calendar: calendar)
        if let latestReportDate, latestReportDate > today {
            return .init(shouldRun: false, reason: "最近报告的日期在今天之后，请检查系统时间")
        }
        if latestReportDate == today {
            return .init(shouldRun: false, reason: "今天已有报告，自动检查每天最多一次")
        }
        switch trigger {
        case .launch:
            if let latestReportDate {
                return .init(shouldRun: true, reason: "启动补跑：上次报告为 \(latestReportDate)")
            }
            return .init(shouldRun: true, reason: "首次启动，补跑今天的检查")
        case .activation, .wake, .timer:
            guard now >= runTime else {
                return .init(shouldRun: false, reason: "未到每日检查时间 \(settings.timeText)")
            }
            return .init(shouldRun: true, reason: "已到每日检查时间 \(settings.timeText)")
        }
    }
}
