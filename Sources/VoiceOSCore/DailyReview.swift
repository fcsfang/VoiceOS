import Foundation

public struct DailyReview: Sendable {
    public let today: [ActionTimeEntry]
    public let overdue: [ActionTimeEntry]
    public let remaining: [ActionTimeEntry]
    public let completedCount: Int
    public let dismissedCount: Int

    public var remainingCount: Int { today.count + overdue.count }
    public var isClear: Bool { today.isEmpty && overdue.isEmpty }

    public static func build(actions: [ActionRecord], schedules: [ActionScheduleIntent],
                             links: [ReminderLink], now: Date,
                             calendar: Calendar = .current) -> DailyReview {
        let tasks = actions.filter { $0.kind == "task" && $0.validity == "current" }
        let surface = ActionTimeSurface.build(actions: tasks, schedules: schedules, links: links,
                                              now: now, calendar: calendar)
        let openToday = surface.today.filter { $0.action.state == "open" }
        return .init(today: openToday.filter { !$0.isOverdue },
                     overdue: openToday.filter(\.isOverdue),
                     remaining: (surface.soon + surface.anytime).filter { $0.action.state == "open" },
                     completedCount: surface.today.filter { $0.action.state == "completed" }.count,
                     dismissedCount: surface.today.filter { $0.action.state == "dismissed" }.count)
    }
}
