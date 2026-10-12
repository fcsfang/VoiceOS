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
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id, $0) })
        // Historical model batches remain auditable, but only claims from the
        // newest completed producer for each source may create new external
        // tasks.  Otherwise an old, previously unlinked task could reappear
        // after reprocessing and become a duplicate reminder.
        let sourceIDs = try db.query("SELECT id FROM sources").compactMap { $0["id"] }
        var currentClaimIDs = Set<String>()
        for sourceID in sourceIDs {
            currentClaimIDs.formUnion(try latestCandidateClaims(for: sourceID).map(\.id))
        }
        // A fresh understanding of the same source may add distinct task
        // identities. Keep a title barrier only within that source; identical
        // titles in separate recordings remain independent user tasks.
        var linkedTitleSources = Set<String>()
        for row in try db.query("SELECT l.desired_title,c.refs_json FROM reminder_links l JOIN actions a ON a.id=l.action_id JOIN claims c ON c.id=a.claim_id WHERE l.calendar_id=?", [access.calendarID]) {
            let title = row["desired_title"] ?? ""
            let refs = try JSONDecoder().decode([ClaimReference].self, from: Data((row["refs_json"] ?? "[]").utf8))
            for ref in refs { linkedTitleSources.insert(title + "|" + ref.sourceID) }
        }
        let pending = try actions().filter { action in
            guard action.kind == "task", action.intentActor == "user", !linked.contains(action.id), currentClaimIDs.contains(action.claimID), let claim = claims[action.claimID] else { return false }
            guard !claim.references.contains(where: { linkedTitleSources.contains(action.title + "|" + $0.sourceID) }) else { return false }
            // P01 grants the assistant autonomy for user-owned task actions.
            // The model may conservatively set autoSend=false; that flag is
            // advisory here. Ambiguous material remains an opportunity and is
            // therefore excluded by kind before reaching this path.
            return claims[action.claimID]?.ownership == CandidateOwnership.userTentative.rawValue
        }
        for action in pending {
            try Task.checkCancellation()
            try checkReminderAccess(calendarID: access.calendarID, expectedVersion: expectedAccessVersion)
            // Do not let a local-only source block unrelated authorized tasks.
            let claim = try candidateClaims().first { $0.id == action.claimID }
            guard let claim, try claim.references.allSatisfy({ try sourcePolicy(sourceID: $0.sourceID).localOnly == false }) else { continue }
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
