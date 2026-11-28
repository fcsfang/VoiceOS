import Foundation

/// The state every row in a filtered list already carries through its tab or
/// section heading. Repeating it on each row spends the status slot on
/// information the heading just gave the reader.
public enum ActionRowGroup: String, Sendable {
    case active
    case completed
    case history
    case needsReview
}

public enum ActionRowTone: String, Sendable {
    case secondary
    case warning
    case success
    case tertiary
}

/// The information a row shows under its title: one fact of metadata and one
/// status. The view maps the tone to the active palette.
public struct ActionRowStatus: Equatable, Sendable {
    public let meta: String
    public let status: String
    public let tone: ActionRowTone
    public init(meta: String, status: String, tone: ActionRowTone) {
        self.meta = meta
        self.status = status
        self.tone = tone
    }
}

/// Everything the row anatomy reads, so the four-slot rule lives in one place
/// instead of a chain of conditionals per view.
public struct ActionRowFacts: Sendable {
    public var isGoal = false
    public var isQuestion = false
    /// Latest analysis execution state for a question; empty when none exists.
    public var answerState = ""
    public var group: ActionRowGroup = .active
    public var state = "open"
    public var validity = "current"
    public var due: String? = nil
    /// Display text for the newest completion; empty when the action never completed.
    public var completedAt = ""
    public var sourceTitle: String? = nil
    public var nextStepCount = 0
    public var requiresReview = false
    public var externalCompletion = false
    public var withdrawn = false
    public var localUnsynced = false
    /// Latest observed link state, whatever it is; nil when the action never
    /// reached Reminders. Display-only: the sync state machine owns the write path.
    public var reminderLinkState: String? = nil
    /// The newest due date the reminder readback observed for this action.
    public var reminderDue: ReminderDueDate? = nil
    public init() {}
}

/// One fold per action-page body: reminder links and analysis runs are read
/// per row, so index them by action instead of scanning the arrays again.
public struct ActionRowReads: Sendable {
    public let linkedReminderByActionID: [String: ReminderLink]
    public let reminderLinkStateByActionID: [String: String]
    public let reminderDueByActionID: [String: ReminderDueDate]
    public let latestAnalysisStateByActionID: [String: String]
    public init(reminderLinks: [ReminderLink], executions: [AssistantExecutionRecord]) {
        var newestLinks: [String: ReminderLink] = [:]
        for link in reminderLinks {
            if let existing = newestLinks[link.actionID], (existing.lastObservedAt ?? "") >= (link.lastObservedAt ?? "") { continue }
            newestLinks[link.actionID] = link
        }
        var linked: [String: ReminderLink] = [:]
        var states: [String: String] = [:]
        var due: [String: ReminderDueDate] = [:]
        for (actionID, link) in newestLinks {
            if link.state == "linked" { linked[actionID] = link }
            states[actionID] = link.state
            if let date = link.remoteDueDate, date != .none { due[actionID] = date }
        }
        var statesByNewest: [String: String] = [:]
        var newest: [String: String] = [:]
        for execution in executions where execution.mode == .analysis && execution.validity == "current" {
            if let current = newest[execution.actionID], current >= execution.updatedAt { continue }
            newest[execution.actionID] = execution.updatedAt
            statesByNewest[execution.actionID] = execution.state
        }
        linkedReminderByActionID = linked
        reminderLinkStateByActionID = states
        reminderDueByActionID = due
        latestAnalysisStateByActionID = statesByNewest
    }
}

public enum ActionRowLayout {
    /// Open next actions per outcome, counted in one pass so a page of rows
    /// never scans the whole list per row.
    public static func nextStepCounts(_ actions: [ActionRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for action in actions where action.state == "open" {
            guard let parent = action.parentID else { continue }
            counts[parent, default: 0] += 1
        }
        return counts
    }

    /// Line two carries one fact: the reminder chain when the action reached
    /// Reminders, otherwise the local due date, otherwise the source. The status
    /// slot carries exceptions and, on a goal, the open next-action count. A goal
    /// with no next actions shows nothing here; the page banner already says so.
    public static func status(_ facts: ActionRowFacts, now: Date = Date(), calendar: Calendar = .current) -> ActionRowStatus {
        var meta = ""
        if facts.group == .completed, !facts.completedAt.isEmpty {
            meta = facts.completedAt
        } else if facts.reminderLinkState == "linked", let due = facts.reminderDue, due != .none, let day = linkedReminderDay(due, now: now, calendar: calendar) {
            // A linked reminder is the normal case; the row names only its day
            // so the exceptions below stand out instead of drowning in repeats.
            meta = day
        } else if facts.reminderLinkState != "linked", let reminder = reminderSummary(linkState: facts.reminderLinkState, due: facts.reminderDue, now: now, calendar: calendar) {
            meta = reminder
        } else if let due = facts.due, !due.isEmpty {
            meta = due
        } else if let source = facts.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            meta = "来自『" + source + "』"
        }
        func row(_ status: String, _ tone: ActionRowTone) -> ActionRowStatus {
            ActionRowStatus(meta: meta, status: status, tone: tone)
        }
        if facts.localUnsynced { return row("本地未同步", .warning) }
        if facts.externalCompletion { return row("提醒事项已完成", .success) }
        if facts.withdrawn { return row("已撤回", .tertiary) }
        if facts.requiresReview && facts.group != .needsReview { return row("待核对", .warning) }
        if facts.state == "dismissed" { return row("已放下", .tertiary) }
        if facts.state == "completed" && facts.group != .completed { return row("已登记完成", .secondary) }
        if facts.validity != "current" && facts.group != .history && facts.group != .needsReview { return row("历史记录", .tertiary) }
        if facts.isQuestion {
            switch facts.answerState {
            case "completed": return row("已回答", .success)
            case "queued", "running", "reserved", "blocked": return row("回答中", .secondary)
            case "failed", "cancelled": return row("回答失败", .warning)
            default: return row("未回答", .secondary)
            }
        }
        if facts.isGoal && facts.group == .active && facts.nextStepCount > 0 {
            return row("\(facts.nextStepCount) 个下一步", .secondary)
        }
        return row("", .secondary)
    }

    /// The reminder chain on line two: what the linked reminder is doing, then
    /// the due date it carries. An overdue date keeps the absolute month and day
    /// so a stale reminder is never mistaken for a fresh one.
    public static func reminderSummary(linkState: String?, due: ReminderDueDate?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let label: String
        switch linkState {
        case "linked": label = "已写入提醒事项"
        case "conflict": label = "提醒待核对"
        case "missing": label = "提醒缺失"
        default: return nil
        }
        guard let due, due != .none, let day = day(for: due, calendar: calendar) else { return label }
        if calendar.startOfDay(for: day) < calendar.startOfDay(for: now) {
            return label + " · 已逾期 " + monthDayLabel(day, calendar: calendar)
        }
        return label + " · " + relativeDayLabel(due, now: now, calendar: calendar)
    }

    private static func linkedReminderDay(_ due: ReminderDueDate, now: Date, calendar: Calendar) -> String? {
        guard let day = day(for: due, calendar: calendar) else { return nil }
        if calendar.startOfDay(for: day) < calendar.startOfDay(for: now) { return "已逾期 " + monthDayLabel(day, calendar: calendar) }
        return relativeDayLabel(due, now: now, calendar: calendar)
    }

    /// Today, tomorrow, yesterday and the coming week read as words; anything
    /// further out falls back to the month and day.
    public static func relativeDayLabel(_ due: ReminderDueDate, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let day = day(for: due, calendar: calendar) else { return "" }
        let diff = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 0
        switch diff {
        case 0: return "今天"
        case 1: return "明天"
        case -1: return "昨天"
        case 2...6: return weekdays[calendar.component(.weekday, from: day) - 1]
        default: return monthDayLabel(day, calendar: calendar)
        }
    }

    /// Line two for a local schedule, which is a pledge the user made before
    /// any reminder readback exists.
    public static func dueSummary(_ due: ReminderDueDate, isOverdue: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let day = day(for: due, calendar: calendar) else { return "" }
        return isOverdue ? "已逾期 " + monthDayLabel(day, calendar: calendar) : "到期 " + relativeDayLabel(due, now: now, calendar: calendar)
    }

    private static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    private static func monthDayLabel(_ day: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day], from: day)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    private static func day(for due: ReminderDueDate, calendar: Calendar) -> Date? {
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
            return TimestampFormatting.parse(utc)
        }
    }
}
