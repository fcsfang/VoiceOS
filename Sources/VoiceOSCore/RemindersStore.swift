import Foundation
import CryptoKit

public struct ReminderSnapshot: Sendable, Codable {
    public let id: String
    public let title: String
    public let completed: Bool
    public let marker: String
    public init(id: String, title: String, completed: Bool, marker: String) {
        self.id = id; self.title = title; self.completed = completed; self.marker = marker
    }
}
public protocol RemindersPort: Sendable {
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot]
    func create(calendarID: String, title: String, marker: String) async throws
}
public struct ReminderLink: Identifiable, Sendable {
    public let id: String
    public let actionID: String
    public let calendarID: String
    public let state: String
    public let externalID: String?
    public let remoteTitle: String?
    public let remoteCompleted: Bool?
    public let lastObservedAt: String?
    public let lastCheckedAt: String?
}
extension VoiceOSStore {
    public func reminderLinks() throws -> [ReminderLink] {
        try db.query("SELECT l.*,o.title AS remote_title,o.completed AS remote_completed,o.created_at AS observed_at FROM reminder_links l LEFT JOIN reminder_observations o ON o.id=(SELECT id FROM reminder_observations WHERE link_id=l.id ORDER BY sequence DESC LIMIT 1) ORDER BY l.created_at,l.id").map {
            ReminderLink(id: $0["id"]!, actionID: $0["action_id"]!, calendarID: $0["calendar_id"]!, state: $0["state"]!, externalID: $0["external_id"], remoteTitle: $0["remote_title"], remoteCompleted: $0["remote_completed"].map { $0 == "1" }, lastObservedAt: $0["observed_at"], lastCheckedAt: $0["last_checked_at"])
        }
    }
    /// One create attempt per action identity. Every subsequent invocation only reads.
    public func sendTaskToReminders(actionID: String, expectedVersion: Int, calendarID: String, using port: any RemindersPort, expectedAccessVersion: Int? = nil) async throws {
        try Task.checkCancellation()
        try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
        if let existing = try db.query("SELECT * FROM reminder_links WHERE action_id=?", [actionID]).first {
            guard existing["calendar_id"] == calendarID else { throw VoiceOSError("已有提醒事项尝试，不能更换清单重复创建") }
            try await readReminder(linkID: existing["id"]!, calendarID: calendarID, using: port, expectedAccessVersion: expectedAccessVersion); return
        }
        guard !calendarID.isEmpty, calendarID.utf8.count <= 4096,
              let action = try actions().first(where: { $0.id == actionID }), action.version == expectedVersion, action.kind == "task", action.intentActor == "user" else {
            throw VoiceOSError("只能把有效的明确任务发送到所选清单")
        }
        guard try reminderSourceAllowed(action) else { throw VoiceOSError("行动依据含仅本地资料，不能写入提醒事项") }
        if expectedAccessVersion != nil {
            guard try reminderCognitionIsLatest(action) else { throw VoiceOSError("行动认知批次已更新，停止历史任务外写") }
        }
        let id = UUID().uuidString; let marker = "voiceos-action:" + id
        try db.execute("INSERT INTO reminder_links(id,action_id,action_version,calendar_id,marker,desired_title,state,created_at) VALUES(?,?,?,?,?,?,'reserved',?)", [id,actionID,String(expectedVersion),calendarID,marker,action.title,ISO8601DateFormatter().string(from: Date())])
        activeReminderLinks.insert(id); defer { activeReminderLinks.remove(id) }
        do {
            try checkpoint(.reminderReserved)
            // Explicit preflight query. Absence after a prior attempt never permits recreation.
            let found = try await port.find(calendarID: calendarID, externalID: nil, marker: marker)
            try Task.checkCancellation()
            try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
            guard found.isEmpty else { throw VoiceOSError("操作标记已有匹配，停止新建并请回读") }
            guard let current = try actions().first(where: { $0.id == actionID }), current.version == expectedVersion, try reminderSourceAllowed(current) else { throw VoiceOSError("发送前行动或依据已变化") }
            if expectedAccessVersion != nil {
                guard try reminderCognitionIsLatest(current) else { throw VoiceOSError("发送前认知批次已更新，停止历史任务外写") }
            }
            try await port.create(calendarID: calendarID, title: action.title, marker: marker)
            try checkpoint(.reminderSaved)
            // Save return is not readback evidence. Record ambiguity before the next await.
            try db.execute("UPDATE reminder_links SET state='unknown' WHERE id=?", [id])
            try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
            try Task.checkCancellation()
            let matches = try await port.find(calendarID: calendarID, externalID: nil, marker: marker)
            try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
            try Task.checkCancellation()
            try applyReminder(matches, linkID: id)
        } catch {
            try db.execute("UPDATE reminder_links SET state='unknown' WHERE id=? AND state='reserved'", [id])
            // Preserve cancellation for the refresh orchestrator: stopping a
            // send must also stop its follow-up reconciliation, even when a
            // connector returns normally after the task was cancelled.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw VoiceOSError("提醒事项结果尚未确认；尝试已保留，请回读，不会自动重建")
        }
    }
    private func reminderSourceAllowed(_ action: ActionRecord) throws -> Bool {
        guard let claim = try candidateClaims().first(where: { $0.id == action.claimID }), !claim.references.isEmpty else { return false }
        return try claim.references.allSatisfy { ref in
            try db.query("SELECT local_only FROM sources WHERE id=?", [ref.sourceID]).first?["local_only"] == "0"
        }
    }
    /// A source may be reprocessed while the connector's preflight is awaiting.
    /// Only new writes use this barrier; existing links still reconcile history.
    func reminderCognitionIsLatest(_ action: ActionRecord) throws -> Bool {
        guard let claim = try candidateClaims().first(where: { $0.id == action.claimID }), !claim.references.isEmpty else { return false }
        for sourceID in Set(claim.references.map(\.sourceID)) {
            guard try latestCandidateClaims(for: sourceID).contains(where: { $0.id == claim.id }) else { return false }
        }
        return true
    }
    public func readReminder(linkID: String, calendarID: String, using port: any RemindersPort, expectedAccessVersion: Int? = nil) async throws {
        try Task.checkCancellation()
        try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
        guard !activeReminderLinks.contains(linkID) else { throw VoiceOSError("提醒事项操作正在进行") }
        guard let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [linkID]).first, link["calendar_id"] == calendarID else { throw VoiceOSError("只能回读明确选定清单内的关联任务") }
        activeReminderLinks.insert(linkID); defer { activeReminderLinks.remove(linkID) }
        do {
            let matches = try await port.find(calendarID: calendarID, externalID: link["external_id"], marker: link["marker"]!)
            try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
            try Task.checkCancellation()
            try applyReminder(matches, linkID: linkID)
        } catch {
            try db.execute("UPDATE reminder_links SET state='unknown' WHERE id=?", [linkID])
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw VoiceOSError("提醒事项回读失败，结果未知；没有修改或重建外部任务")
        }
    }
    private func applyReminder(_ matches: [ReminderSnapshot], linkID: String) throws {
        guard let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [linkID]).first else { throw VoiceOSError("提醒事项关联缺失") }
        guard matches.count == 1, let remote = matches.first else {
            try db.execute("UPDATE reminder_links SET state=?,last_checked_at=? WHERE id=?", [matches.isEmpty ? "missing" : "conflict",ISO8601DateFormatter().string(from: Date()),linkID]); return
        }
        guard !remote.id.isEmpty, remote.id.utf8.count <= 4096, remote.title.unicodeScalars.count <= 10000, remote.marker.utf8.count <= 4096 else { throw VoiceOSError("提醒事项字段无效或过长") }
        let action = try actions(includeHistory: true).first { $0.id == link["action_id"] }
        let validMarker = remote.marker == link["marker"]
        let observationID = UUID().uuidString
        let sequence = Int(try db.query("SELECT COUNT(*) AS n FROM reminder_observations WHERE link_id=?", [linkID]).first!["n"]!)! + 1
        var feedbackID: String?
        var conflict = !validMarker
        try db.transaction {
            if validMarker, let action, action.validity == "current" {
                if remote.completed && action.state == "open" && action.version == Int(link["action_version"]!) {
                    let revisionID = UUID().uuidString
                    let next = action.version + 1
                    let note = "Apple 提醒事项唯一关联项回读为已完成；不代表观点已验证"
                    let fields = [action.id,String(action.version),"completed",note]
                    let hash = SHA256.hash(data: try JSONSerialization.data(withJSONObject: fields)).map { String(format: "%02x", $0) }.joined()
                    try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,'external',?,?,?)", [revisionID,action.id,String(next),String(action.version),"completed",note,"reminder-feedback:"+observationID,hash,ISO8601DateFormatter().string(from: Date())])
                    try db.execute("UPDATE actions SET state='completed',version=? WHERE id=?", [String(next),action.id])
                    feedbackID = revisionID
                } else if remote.completed != (action.state == "completed") {
                    // External reopen or a local edit cannot silently overwrite either side.
                    conflict = true
                }
            }
            let prior = try db.query("SELECT * FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [linkID]).first
            let changed = prior?["external_id"] != remote.id || prior?["title"] != remote.title || prior?["completed"] != (remote.completed ? "1" : "0") || prior?["marker_valid"] != (validMarker ? "1" : "0")
            if changed || feedbackID != nil {
                try db.execute("INSERT INTO reminder_observations(id,link_id,external_id,title,completed,marker_valid,feedback_revision_id,created_at,sequence) VALUES(?,?,?,?,?,?,?,?,?)", [observationID,linkID,remote.id,remote.title,remote.completed ? "1" : "0",validMarker ? "1" : "0",feedbackID,ISO8601DateFormatter().string(from: Date()),String(sequence)])
            }
            try db.execute("UPDATE reminder_links SET state=?,external_id=?,last_checked_at=? WHERE id=?", [conflict ? "conflict" : "linked",remote.id,ISO8601DateFormatter().string(from: Date()),linkID])
            try checkpoint(.reminderFeedbackUncommitted)
        }
        try checkpoint(.reminderFeedbackCommitted)
    }
    static func validateStoredReminders(_ db: Database) throws {
        for link in try db.query("SELECT l.*,a.kind,a.title,a.version AS latest_version FROM reminder_links l JOIN actions a ON a.id=l.action_id") {
            guard link["kind"] == "task", link["marker"] == "voiceos-action:" + link["id"]!,
                  let pin = link["action_version"].flatMap(Int.init), let latest = link["latest_version"].flatMap(Int.init), pin <= latest,
                  link["desired_title"] == link["title"], !(link["calendar_id"] ?? "").isEmpty else { throw VoiceOSError("迁移提醒事项身份或行动版本不一致") }
            if pin > 1 { guard try db.query("SELECT id FROM action_revisions WHERE action_id=? AND version=?", [link["action_id"],String(pin)]).count == 1 else { throw VoiceOSError("迁移提醒事项缺少行动版本") } }
            let observations = try db.query("SELECT sequence FROM reminder_observations WHERE link_id=? ORDER BY sequence", [link["id"]])
            for (i, row) in observations.enumerated() { guard row["sequence"] == String(i+1) else { throw VoiceOSError("迁移提醒事项回读历史不连续") } }
            if link["state"] == "linked" {
                guard let last = try db.query("SELECT * FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [link["id"]]).first, last["marker_valid"] == "1", last["external_id"] == link["external_id"] else { throw VoiceOSError("迁移提醒事项缺少唯一回读记录") }
            }
        }
        for observation in try db.query("SELECT o.*,l.action_id,l.action_version FROM reminder_observations o JOIN reminder_links l ON l.id=o.link_id") {
            guard !(observation["external_id"] ?? "").isEmpty, (observation["title"]?.unicodeScalars.count ?? 10001) <= 10000 else { throw VoiceOSError("迁移提醒事项回读字段无效") }
            if let revisionID = observation["feedback_revision_id"] {
                guard observation["completed"] == "1", observation["marker_valid"] == "1", let revision = try db.query("SELECT * FROM action_revisions WHERE id=?", [revisionID]).first,
                      revision["actor"] == "external", revision["action_id"] == observation["action_id"], revision["state"] == "completed", revision["from_version"] == observation["action_version"], revision["command_id"] == "reminder-feedback:" + observation["id"]! else { throw VoiceOSError("迁移提醒事项反馈与行动历史不一致") }
            }
        }
        for revision in try db.query("SELECT id FROM action_revisions WHERE actor='external'") {
            guard try db.query("SELECT id FROM reminder_observations WHERE feedback_revision_id=?", [revision["id"]]).count == 1 else { throw VoiceOSError("迁移外部完成反馈缺少唯一回读依据") }
        }
    }
}
