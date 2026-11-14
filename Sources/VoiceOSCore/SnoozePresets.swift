import Foundation

public enum SnoozePreset: String, CaseIterable, Sendable {
    case tonight, tomorrow, nextWeek

    public var title: String {
        switch self {
        case .tonight: return "今晚"
        case .tomorrow: return "明天"
        case .nextWeek: return "下周"
        }
    }

    public func dueDate(now: Date, calendar: Calendar) -> Date {
        switch self {
        case .tonight:
            let eight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now)
            if let eight, eight > now { return eight }
            return calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        case .tomorrow:
            let base = calendar.startOfDay(for: now)
            let next = calendar.date(byAdding: .day, value: 1, to: base) ?? base
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: next) ?? next
        case .nextWeek:
            let base = calendar.startOfDay(for: now)
            let weekday = calendar.component(.weekday, from: base)
            let offset = weekday == 2 ? 7 : (2 - weekday + 7) % 7
            let target = calendar.date(byAdding: .day, value: offset, to: base) ?? base
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: target) ?? target
        }
    }
}
