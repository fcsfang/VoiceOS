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
    /// Ordinary extracted tasks only. Durable links still prohibit repeat creation.
    public func activateExtractedTasks(expectedAccessVersion: Int, using port: any RemindersPort) async throws {
        guard let access = try reminderAccess() else { throw VoiceOSError("尚未授权提醒事项清单") }
        try checkReminderAccess(calendarID: access.calendarID, expectedVersion: expectedAccessVersion)
        let linked = Set(try reminderLinks().map(\.actionID))
        let pending = try actions().filter { $0.autoSend && $0.kind == "task" && !linked.contains($0.id) }
        var activated = 0
        for action in pending {
            if activated == 3 { break }
            try Task.checkCancellation()
            try checkReminderAccess(calendarID: access.calendarID, expectedVersion: expectedAccessVersion)
            // Do not let a local-only source block unrelated authorized tasks.
            let claim = try candidateClaims().first { $0.id == action.claimID }
            guard let claim, try claim.references.allSatisfy({ try sourcePolicy(sourceID: $0.sourceID).localOnly == false }) else { continue }
            // Reinterpreting a previously sent source is not fresh user intent.
            // Keep new proposals local until the user explicitly sends them.
            let attempt = try db.query("SELECT attempt_id FROM claims WHERE id=?", [claim.id]).first?["attempt_id"]
            var oldIntent = false
            for row in try db.query("SELECT c.attempt_id,c.refs_json FROM reminder_links l JOIN actions a ON a.id=l.action_id JOIN claims c ON c.id=a.claim_id WHERE c.attempt_id!=?", [attempt]) {
                let refs = try JSONDecoder().decode([ClaimReference].self, from: Data(row["refs_json"]!.utf8))
                if !Set(refs.map(\.sourceID)).isDisjoint(with: Set(claim.references.map(\.sourceID))) { oldIntent = true; break }
            }
            if oldIntent { continue }
            activated += 1
            try await sendTaskToReminders(actionID: action.id, expectedVersion: action.version, calendarID: access.calendarID, using: port, expectedAccessVersion: access.version)
        }
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
    /// A failed new create must not prevent completion readback for existing
    /// links. Cancellation and revoked scope still stop before reconciliation.
    public func refreshAuthorizedReminders(expectedAccessVersion: Int, using port: any RemindersPort) async throws {
        var activationFailed=false
        do { try await activateExtractedTasks(expectedAccessVersion:expectedAccessVersion,using:port) }
        catch is CancellationError { throw CancellationError() }
        catch { activationFailed=true }
        try Task.checkCancellation()
        guard let access=try reminderAccess() else { throw VoiceOSError("尚未授权提醒事项清单") }
        try checkReminderAccess(calendarID:access.calendarID,expectedVersion:expectedAccessVersion)
        try await reconcileReminders(expectedAccessVersion:expectedAccessVersion,using:port)
        if activationFailed { throw VoiceOSError("新任务发送未完成；已核对既有任务，保留尝试且不自动重建") }
    }
}
