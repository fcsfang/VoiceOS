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
    public init() {}
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

    /// Line two carries one fact: the due date when there is one, otherwise the
    /// source. The status slot carries exceptions and, on a goal, the open
    /// next-action count. A goal with no next actions shows nothing here; the
    /// page banner already says so.
    public static func status(_ facts: ActionRowFacts) -> ActionRowStatus {
        var meta = ""
        if facts.group == .completed, !facts.completedAt.isEmpty {
            meta = facts.completedAt
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
}
