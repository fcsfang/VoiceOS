import Foundation

extension VoiceOSStore {
    func reminderStatusBaseline(_ link: [String: String]) throws -> Int {
        let latest = try db.query("SELECT action_version FROM reminder_status_resolutions WHERE link_id=? ORDER BY action_version DESC LIMIT 1", [link["id"]]).first
        guard let version = (latest?["action_version"] ?? link["action_version"]).flatMap(Int.init) else { throw VoiceOSError("提醒事项同步基线缺失") }
        return version
    }

    /// Adopts one freshly checked status locally. It never writes external data.
    /// The caller must supply the exact observation and action version displayed.
    @discardableResult
    public func acceptReminderStatus(linkID: String, expectedActionVersion: Int, expectedObservationID: String,
                                     expectedAccessVersion: Int, using port: any RemindersPort,
                                     commandID: String = UUID().uuidString) async throws -> Int {
        try Task.checkCancellation()
        guard let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [linkID]).first else { throw VoiceOSError("提醒事项关联缺失") }
        try checkReminderAccess(calendarID: link["calendar_id"]!, expectedVersion: expectedAccessVersion)
        let fingerprint = try Self.actionHash([linkID, expectedObservationID, String(expectedActionVersion), String(expectedAccessVersion)])
        if let receipt = try db.query("SELECT * FROM reminder_status_resolutions WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == fingerprint else { throw VoiceOSError("同一状态恢复命令不能更换内容") }
            return Int(receipt["action_version"]!)!
        }
        guard !activeReminderLinks.contains(linkID) else { throw VoiceOSError("提醒事项操作正在进行") }
        let initial = try reminderResolutionInput(link: link, actionVersion: expectedActionVersion, observationID: expectedObservationID)
        activeReminderLinks.insert(linkID); defer { activeReminderLinks.remove(linkID) }
        let matches: [ReminderSnapshot]
        do {
            matches = try await port.find(calendarID: link["calendar_id"]!, externalID: link["external_id"], marker: link["marker"]!)
            try Task.checkCancellation()
            try checkReminderAccess(calendarID: link["calendar_id"]!, expectedVersion: expectedAccessVersion)
        } catch {
            try db.execute("UPDATE reminder_links SET state='unknown' WHERE id=?", [linkID])
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw VoiceOSError("恢复前回读未完成；保留冲突和历史，没有修改外部任务")
        }
        // Revalidate local edits and source barriers after the connector await.
        _ = try reminderResolutionInput(link: link, actionVersion: expectedActionVersion, observationID: expectedObservationID)
        try applyReminder(matches, linkID: linkID)
        guard matches.count == 1, let remote = matches.first, remote.marker == link["marker"],
              remote.id == initial.observation["external_id"],
              try db.query("SELECT id FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [linkID]).first?["id"] == expectedObservationID else {
            throw VoiceOSError("外部状态或身份已变化，请查看最新回读后再选择；没有采用旧观测")
        }
        let target = remote.completed ? "completed" : "open"
        let next = expectedActionVersion + 1
        let resolutionID = UUID().uuidString, revisionID = UUID().uuidString
        let note = Self.reminderResolutionNote(expectedObservationID)
        let revisionCommand = "reminder-status-resolution:" + resolutionID
        let revisionHash = try Self.actionHash([initial.action.id, String(expectedActionVersion), target, note])
        let baseline = try reminderStatusBaseline(link)
        let now = ISO8601DateFormatter().string(from: Date())
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,'user',?,?,?)",
                           [revisionID, initial.action.id, String(next), String(expectedActionVersion), target, note, revisionCommand, revisionHash, now])
            try db.execute("UPDATE actions SET state=?,version=? WHERE id=?", [target, String(next), initial.action.id])
            try db.execute("INSERT INTO reminder_status_resolutions(id,link_id,observation_id,action_revision_id,base_action_version,action_version,access_version,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                           [resolutionID, linkID, expectedObservationID, revisionID, String(baseline), String(next), String(expectedAccessVersion), commandID, fingerprint, now])
            try db.execute("UPDATE reminder_links SET state='linked' WHERE id=?", [linkID])
            try checkpoint(.reminderResolutionUncommitted)
        }
        try checkpoint(.reminderResolutionCommitted)
        return next
    }

    private func reminderResolutionInput(link: [String: String], actionVersion: Int, observationID: String) throws -> (action: ActionRecord, observation: [String: String]) {
        guard let currentLink = try db.query("SELECT * FROM reminder_links WHERE id=?", [link["id"]]).first,
              currentLink["state"] == "conflict",
              let action = try actions(includeHistory: true).first(where: { $0.id == link["action_id"] }),
              action.kind == "task", action.validity == "current", action.version == actionVersion,
              let observation = try db.query("SELECT * FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [link["id"]]).first,
              observation["id"] == observationID, observation["marker_valid"] == "1",
              observation["external_id"] == currentLink["external_id"],
              action.state != (observation["completed"] == "1" ? "completed" : "open") else {
            throw VoiceOSError("仅能恢复当前有效任务的已知状态冲突；请重新核对行动与外部观测")
        }
        return (action, observation)
    }
    private static func reminderResolutionNote(_ observationID: String) -> String {
        "用户采用重新回读的提醒事项状态；观测 " + observationID + "；不代表观点已验证"
    }

    static func validateReminderStatusResolutions(_ db: Database) throws {
        for link in try db.query("SELECT * FROM reminder_links") {
            var baseline = Int(link["action_version"]!)!
            var priorSequence = 0
            for resolution in try db.query("SELECT * FROM reminder_status_resolutions WHERE link_id=? ORDER BY action_version", [link["id"]]) {
                guard let observation = try db.query("SELECT * FROM reminder_observations WHERE id=?", [resolution["observation_id"]]).first,
                      let revision = try db.query("SELECT * FROM action_revisions WHERE id=?", [resolution["action_revision_id"]]).first,
                      let from = revision["from_version"].flatMap(Int.init), let to = revision["version"].flatMap(Int.init),
                      let scope = resolution["access_version"].flatMap(Int.init), scope > 0,
                      let sequence = observation["sequence"].flatMap(Int.init), sequence >= priorSequence,
                      resolution["base_action_version"] == String(baseline), from >= baseline, to == from + 1,
                      resolution["action_version"] == String(to), observation["link_id"] == link["id"], observation["marker_valid"] == "1",
                      revision["action_id"] == link["action_id"], revision["actor"] == "user",
                      revision["state"] == (observation["completed"] == "1" ? "completed" : "open"),
                      revision["note"] == reminderResolutionNote(observation["id"]!),
                      revision["command_id"] == "reminder-status-resolution:" + resolution["id"]!,
                      resolution["input_fingerprint"] == (try actionHash([link["id"]!, observation["id"]!, String(from), String(scope)])),
                      revision["input_fingerprint"] == (try actionHash([link["action_id"]!, String(from), revision["state"]!, revision["note"]!])) else {
                    throw VoiceOSError("迁移提醒事项状态恢复依据或版本不一致")
                }
                guard try db.query("""
                    SELECT r.id FROM reminder_observations o JOIN action_revisions r ON r.id=o.feedback_revision_id
                    WHERE o.link_id=? AND o.sequence<=? AND r.version>?
                    """, [link["id"],String(sequence),String(from)]).isEmpty else {
                    throw VoiceOSError("迁移提醒事项状态恢复引用了未来观测")
                }
                baseline = to; priorSequence = sequence
            }
        }
        for revision in try db.query("SELECT id FROM action_revisions WHERE command_id LIKE 'reminder-status-resolution:%'") {
            guard try db.query("SELECT id FROM reminder_status_resolutions WHERE action_revision_id=?", [revision["id"]]).count == 1 else {
                throw VoiceOSError("迁移提醒事项状态恢复缺少绑定记录")
            }
        }
    }
}
