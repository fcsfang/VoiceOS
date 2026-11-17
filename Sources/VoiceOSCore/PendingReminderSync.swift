import Foundation

/// One completion or reopen that is saved locally but has not reached Apple Reminders.
/// The latest failure stays with the entry until a readback succeeds and removes it.
public struct PendingReminderSync: Codable, Equatable, Identifiable, Sendable {
    public let actionID: String
    public let linkID: String
    public let calendarID: String
    public let externalID: String
    public let marker: String
    public let title: String
    public let desiredState: String
    public let createdAt: String
    public var lastFailureReason: String?
    public var lastFailureAt: String?
    public var id: String { actionID }

    public init(actionID: String, linkID: String, calendarID: String, externalID: String, marker: String,
                title: String, desiredState: String, createdAt: String,
                lastFailureReason: String? = nil, lastFailureAt: String? = nil) {
        self.actionID = actionID; self.linkID = linkID; self.calendarID = calendarID
        self.externalID = externalID; self.marker = marker; self.title = title
        self.desiredState = desiredState; self.createdAt = createdAt
        self.lastFailureReason = lastFailureReason; self.lastFailureAt = lastFailureAt
    }

    public mutating func recordFailure(_ reason: String, at timestamp: String) {
        lastFailureReason = reason
        lastFailureAt = timestamp
    }

    public mutating func clearFailure() {
        lastFailureReason = nil
        lastFailureAt = nil
    }
}
