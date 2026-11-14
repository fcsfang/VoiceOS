import Foundation

/// Which existing date record supplied a task's time-surface entry.
public enum ActionTimeSource: String, Sendable { case localSchedule, reminderReadback, none }

public struct ActionTimeEntry: Identifiable, Sendable {
    public let action: ActionRecord
    public let due: ReminderDueDate?
    public let source: ActionTimeSource
    public let isOverdue: Bool
    /// A local pledge is shown without a matching reminder readback.
    public let needsLocalSyncLabel: Bool
    public var id: String { action.id }
}

public struct ActionTimeSurface: Sendable {
    public let today: [ActionTimeEntry]
    public let soon: [ActionTimeEntry]
    public let anytime: [ActionTimeEntry]
}

extension ActionTimeSurface {
    /// Groups open tasks by the one date the app already trusts. The latest
    /// current local schedule wins even when it has no date; only an action
    /// without a local schedule reads its linked reminder observation.
    public static func build(actions: [ActionRecord], schedules: [ActionScheduleIntent],
                             links: [ReminderLink], now: Date, calendar: Calendar) -> ActionTimeSurface {
        let latestSchedules = schedules.reduce(into: [String: ActionScheduleIntent]()) { result, intent in
            guard intent.validity == "current" else { return }
            if let existing = result[intent.actionID], existing.version >= intent.version { return }
            result[intent.actionID] = intent
        }
        let linked = links.reduce(into: [String: ReminderLink]()) { result, link in
            guard link.state == "linked", result[link.actionID] == nil else { return }
            result[link.actionID] = link
        }
        let today = calendar.startOfDay(for: now)
        let soonEnd = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        var rows: [(entry: ActionTimeEntry, day: Date?, index: Int)] = []
        for (index, action) in actions.enumerated() {
            let remote = Self.meaningful(linked[action.id]?.remoteDueDate)
            let remoteDate = remote.flatMap { Self.date($0, calendar: calendar) }
            let schedule = latestSchedules[action.id]
            let local = Self.meaningful(schedule?.due)
            let localDate = local.flatMap { Self.date($0, calendar: calendar) }
            let usesLocal = schedule != nil
            let due = usesLocal ? local : remote
            let day = usesLocal ? localDate : remoteDate
            let source: ActionTimeSource = usesLocal ? .localSchedule : (remote != nil ? .reminderReadback : .none)
            let isOverdue = usesLocal ? Self.isPast(local, now: now, calendar: calendar) : Self.isPast(remote, now: now, calendar: calendar)
            let entry = ActionTimeEntry(action: action, due: due, source: source, isOverdue: isOverdue,
                                        needsLocalSyncLabel: usesLocal && localDate != remoteDate)
            rows.append((entry, day.map { calendar.startOfDay(for: $0) }, index))
        }
        func ordered(_ values: [(entry: ActionTimeEntry, day: Date?, index: Int)]) -> [ActionTimeEntry] {
            values.sorted { left, right in
                let leftDay = left.day ?? .distantFuture, rightDay = right.day ?? .distantFuture
                return leftDay == rightDay ? left.index < right.index : leftDay < rightDay
            }.map(\.entry)
        }
        let todayRows = rows.filter { $0.day.map { $0 <= today } ?? false }
        let soonRows = rows.filter { $0.day.map { $0 > today && $0 <= soonEnd } ?? false }
        let anytimeRows = rows.filter { $0.day.map { $0 > soonEnd } ?? true }
        return .init(today: ordered(todayRows), soon: ordered(soonRows), anytime: ordered(anytimeRows))
    }

    private static func meaningful(_ due: ReminderDueDate?) -> ReminderDueDate? {
        guard let due, due != .none else { return nil }
        return due
    }

    private static func date(_ due: ReminderDueDate, calendar: Calendar) -> Date? {
        switch due {
        case .none:
            return nil
        case let .dateOnly(localDate, zoneID):
            var zoneCalendar = Calendar(identifier: .gregorian)
            zoneCalendar.timeZone = zoneID.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
            let parts = localDate.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return zoneCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        case let .instant(utc, _):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: utc) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: utc)
        }
    }

    private static func isPast(_ due: ReminderDueDate?, now: Date, calendar: Calendar) -> Bool {
        guard let due, let date = date(due, calendar: calendar) else { return false }
        switch due {
        case .none:
            return false
        case .instant:
            return date < now
        case .dateOnly:
            return calendar.startOfDay(for: date) < calendar.startOfDay(for: now)
        }
    }
}
