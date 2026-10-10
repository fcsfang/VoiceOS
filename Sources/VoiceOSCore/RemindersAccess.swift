import Foundation

public struct ReminderAccess: Sendable {
    public let version: Int
    public let calendarID: String
    public let title: String
    public let enabled: Bool
}
extension VoiceOSStore {
    public func reminderAccess() throws -> ReminderAccess? {
        try db.query("SELECT * FROM reminder_access ORDER BY version DESC LIMIT 1").first.map {
            ReminderAccess(version: Int($0["version"]!)!, calendarID: $0["calendar_id"]!, title: $0["title"]!, enabled: $0["enabled"] == "1")
        }
    }
    public func setReminderAccess(calendarID: String, title: String, enabled: Bool, expectedVersion: Int) throws -> ReminderAccess {
        let prior = try reminderAccess()
        guard (prior?.version ?? 0) == expectedVersion else { throw VoiceOSError("提醒事项授权已变化，请重新核对") }
        guard !calendarID.isEmpty, calendarID.utf8.count <= 4096, !title.isEmpty, title.unicodeScalars.count <= 2000 else { throw VoiceOSError("请选择有效的提醒事项清单") }
        if prior?.calendarID == calendarID && prior?.title == title && prior?.enabled == enabled { return prior! }
        let next = expectedVersion + 1
        try db.execute("INSERT INTO reminder_access(id,version,calendar_id,title,enabled,created_at) VALUES(?,?,?,?,?,?)", [UUID().uuidString,String(next),calendarID,title,enabled ? "1" : "0",ISO8601DateFormatter().string(from: Date())])
        return try reminderAccess()!
    }
    func checkReminderAccess(calendarID: String, expectedVersion: Int?) throws {
        // nil is the existing explicit one-shot API, used by development fixtures.
        guard let expectedVersion else { return }
        guard let access = try reminderAccess(), access.enabled, access.calendarID == calendarID, access.version == expectedVersion else { throw VoiceOSError("提醒事项持续授权已变化，停止旧请求") }
    }
    /// Only reconciles already attempted links; never invokes create or selects another list.
    public func reconcileReminders(expectedAccessVersion: Int, using port: any RemindersPort) async throws {
        guard let access = try reminderAccess() else { throw VoiceOSError("尚未授权提醒事项清单") }
        try checkReminderAccess(calendarID: access.calendarID, expectedVersion: expectedAccessVersion)
        var failed = false
        for link in try reminderLinks().filter({ $0.calendarID == access.calendarID }) {
            try Task.checkCancellation()
            try checkReminderAccess(calendarID: access.calendarID, expectedVersion: expectedAccessVersion)
            // A foreground create owns this link; its own readback covers it.
            if activeReminderLinks.contains(link.id) { continue }
            do { try await readReminder(linkID: link.id, calendarID: access.calendarID, using: port, expectedAccessVersion: expectedAccessVersion) }
            catch { failed = true }
        }
        try checkReminderAccess(calendarID: access.calendarID, expectedVersion: expectedAccessVersion)
        if failed { throw VoiceOSError("部分提醒事项未完成回读；保留历史，不自动重建") }
    }
}
