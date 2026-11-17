import Foundation

/// Which weekly-review summary stats can scroll somewhere. A stat with a zero
/// count, or whose section is not rendered, must render as plain text. The
/// pending-outcome stat points into the completed section (a pending row, or
/// that section's top), so it needs completions on screen even when its own
/// count is positive.
public struct WeeklyReviewSummaryLinks: Equatable, Sendable {
    public let completed: Bool
    public let pendingOutcome: Bool
    public let stalled: Bool
    public let unclarified: Bool

    public init(weekCompleted: Int, pendingOutcomes: Int, stalledGoals: Int, unclarifiedTasks: Int) {
        completed = weekCompleted > 0
        pendingOutcome = pendingOutcomes > 0 && weekCompleted > 0
        stalled = stalledGoals > 0
        unclarified = unclarifiedTasks > 0
    }
}
