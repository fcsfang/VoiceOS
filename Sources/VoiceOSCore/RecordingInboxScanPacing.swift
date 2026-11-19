import Foundation

/// When an event-driven inbox scan should run again, or nil once the inbox is settled.
/// Confirmation backs off from 1s to 30s while a file is still arriving; work blocked by a
/// busy organizer keeps the old 10s retry cadence; a scheduled retry wakes exactly when due.
public enum RecordingInboxScanPacing {
    public struct FollowUp: Equatable, Sendable {
        public var unstable: Bool
        public var blocked: Bool
        public var nextAttempt: Date?

        public init(unstable: Bool = false, blocked: Bool = false, nextAttempt: Date? = nil) {
            self.unstable = unstable
            self.blocked = blocked
            self.nextAttempt = nextAttempt
        }
    }

    public static func delay(for followUp: FollowUp, after previous: TimeInterval, now: Date) -> TimeInterval? {
        if followUp.unstable { return min(max(previous * 2, 1), 30) }
        if followUp.blocked { return 10 }
        if let due = followUp.nextAttempt, due > now { return due.timeIntervalSince(now) }
        return nil
    }
}
