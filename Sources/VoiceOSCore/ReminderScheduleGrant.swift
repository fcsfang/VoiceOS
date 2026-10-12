import Foundation

/// Read-only preparation is not approval or an external operation.
public struct ReminderScheduleEffect: Identifiable, Sendable {
    public var id: String { digest }
    public let intentID: String
    public let actionID: String
    public let linkID: String
    public let observationID: String
    public let accessVersion: Int
    public let calendarTitle: String
    public let before: ReminderSnapshot
    public let desired: ReminderDueDate
    public let authority: ScheduleAuthority
    public let rawExpression: String
    public let anchorSummary: String
    public let digest: String
}
public struct ReminderScheduleGrant: Identifiable, Sendable {
    public let id: String
    public let intentID: String
    public let linkID: String
    public let effectDigest: String
    public let validity: String
    public let revoked: Bool
    public let eligibleForExecution: Bool
}
extension VoiceOSStore {
    public func prepareReminderScheduleEffect(intentID: String, expectedObservationID: String,
                                              expectedAccessVersion: Int) throws -> ReminderScheduleEffect {
        let input = try schedulePlanningInput(intentID: intentID, observationID: expectedObservationID, accessVersion: expectedAccessVersion)
        guard try previewReminderSchedule(intentID: intentID, expectedAccessVersion: expectedAccessVersion).disposition == .requiresConfirmation else {
            throw VoiceOSError("只有实际重要期限差异需要具体效果确认；一致、未知或双方弹性变化不能借确认重发")
        }
        _ = try input.intent.due.writableComponents()
        let before = try scheduleObservationSnapshot(expectedObservationID, marker: input.marker)
        let row = try db.query("SELECT * FROM action_schedule_intents WHERE id=?", [intentID]).first!
        return .init(intentID: intentID, actionID: input.intent.actionID, linkID: input.link.id, observationID: expectedObservationID,
                     accessVersion: expectedAccessVersion, calendarTitle: try reminderAccess()!.title, before: before,
                     desired: input.intent.due, authority: input.intent.authority, rawExpression: input.intent.rawExpression,
                     anchorSummary: input.intent.anchorSummary,
                     digest: try Self.scheduleEffectDigest(intent: row, linkID: input.link.id, calendarID: input.link.calendarID,
                                                           observationID: expectedObservationID, beforeJSON: Self.scheduleJSON(before),
                                                           accessVersion: expectedAccessVersion))
    }
    /// Explicit user approval of the displayed effect. Records permission only.
    @discardableResult
    public func confirmReminderSchedule(intentID: String, expectedObservationID: String, expectedAccessVersion: Int,
                                         displayedEffectDigest: String, actor: ActionScheduleActor,
                                         commandID: String = UUID().uuidString) throws -> String {
        guard actor == .user else { throw VoiceOSError("AI 不得代用户批准重要期限变更") }
        let hash = try Self.actionHash([displayedEffectDigest,actor.rawValue])
        if let receipt = try db.query("SELECT * FROM reminder_schedule_grants WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == hash, receipt["intent_id"] == intentID,
                  receipt["observation_id"] == expectedObservationID, receipt["access_version"] == String(expectedAccessVersion) else {
                throw VoiceOSError("同一确认命令不能更换效果")
            }
            return receipt["id"]!
        }
        let effect = try prepareReminderScheduleEffect(intentID: intentID, expectedObservationID: expectedObservationID,
                                                       expectedAccessVersion: expectedAccessVersion)
        guard effect.digest == displayedEffectDigest, !activeReminderLinks.contains(effect.linkID),
              try db.query("SELECT id FROM reminder_schedule_operations WHERE intent_id=?", [intentID]).isEmpty else {
            throw VoiceOSError("显示的效果已变化或已尝试；重新核对，不能扩大旧确认")
        }
        if let prior = try db.query("SELECT * FROM reminder_schedule_grants WHERE intent_id=?", [intentID]).first {
            guard prior["effect_digest"] == effect.digest, prior["validity"] == "current",
                  try db.query("SELECT id FROM reminder_schedule_grant_revocations WHERE grant_id=?", [prior["id"]]).isEmpty else {
                throw VoiceOSError("旧确认已撤回/冻结或效果变化；须形成新排期意图再确认")
            }
            return prior["id"]!
        }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("""
                INSERT INTO reminder_schedule_grants(id,intent_id,link_id,observation_id,access_version,before_json,desired_json,
                effect_digest,actor,validity,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,?,?,'user','current',?,?,?)
                """, [id,intentID,effect.linkID,expectedObservationID,String(expectedAccessVersion),try Self.scheduleJSON(effect.before),
                        try Self.scheduleJSON(effect.desired),effect.digest,commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try checkpoint(.scheduleGrantUncommitted)
        }
        try checkpoint(.scheduleGrantCommitted)
        return id
    }
    /// Stops subsequent writes; dispatched effects retain their readback history.
    @discardableResult
    public func revokeReminderScheduleGrant(grantID: String, reason: String, actor: ActionScheduleActor,
                                             commandID: String = UUID().uuidString) throws -> String {
        guard actor == .user, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reason.unicodeScalars.count <= 2000 else { throw VoiceOSError("撤回具体效果须来自用户并保留原因") }
        let hash = try Self.actionHash([grantID,reason,actor.rawValue])
        if let receipt = try db.query("SELECT * FROM reminder_schedule_grant_revocations WHERE command_id=? OR grant_id=?", [commandID,grantID]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("已撤回的确认不能更换记录内容") }
            return receipt["id"]!
        }
        guard let grant = try db.query("SELECT * FROM reminder_schedule_grants WHERE id=?", [grantID]).first,
              grant["validity"] == "current" else { throw VoiceOSError("确认不存在或为冻结历史") }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO reminder_schedule_grant_revocations(id,grant_id,actor,reason,command_id,input_fingerprint,created_at) VALUES(?,?,'user',?,?,?,?)",
                           [id,grantID,reason,commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try checkpoint(.scheduleGrantRevocationUncommitted)
        }
        try checkpoint(.scheduleGrantRevocationCommitted)
        return id
    }
    public func reminderScheduleGrants() throws -> [ReminderScheduleGrant] {
        try db.query("SELECT * FROM reminder_schedule_grants ORDER BY created_at,id").map { row in
            let revoked = try !db.query("SELECT id FROM reminder_schedule_grant_revocations WHERE grant_id=?", [row["id"]]).isEmpty
            let effect = try? prepareReminderScheduleEffect(intentID: row["intent_id"]!, expectedObservationID: row["observation_id"]!, expectedAccessVersion: Int(row["access_version"]!)!)
            let unused = try db.query("SELECT id FROM reminder_schedule_operations WHERE intent_id=?", [row["intent_id"]]).isEmpty
            return .init(id: row["id"]!, intentID: row["intent_id"]!, linkID: row["link_id"]!, effectDigest: row["effect_digest"]!,
                         validity: row["validity"]!, revoked: revoked,
                         eligibleForExecution: row["validity"] == "current" && !revoked && unused && effect?.digest == row["effect_digest"])
        }
    }
    func validateActiveScheduleGrant(_ grantID: String, intentID: String, observationID: String, accessVersion: Int) throws {
        let effect = try prepareReminderScheduleEffect(intentID: intentID, expectedObservationID: observationID, expectedAccessVersion: accessVersion)
        guard let row = try db.query("SELECT * FROM reminder_schedule_grants WHERE id=?", [grantID]).first,
              row["validity"] == "current", row["actor"] == "user", row["intent_id"] == intentID,
              row["link_id"] == effect.linkID, row["observation_id"] == observationID,
              row["access_version"] == String(accessVersion), row["effect_digest"] == effect.digest,
              try db.query("SELECT id FROM reminder_schedule_grant_revocations WHERE grant_id=?", [grantID]).isEmpty else {
            throw VoiceOSError("具体效果确认已失效、撤回或不属于本次变更")
        }
    }
    static func scheduleEffectDigest(intent: [String:String], linkID: String, calendarID: String,
                                     observationID: String, beforeJSON: String, accessVersion: Int) throws -> String {
        try actionHash(["reminder-due-effect-v1",intent["id"]!,intent["input_fingerprint"]!,linkID,calendarID,
                        observationID,String(accessVersion),beforeJSON,intent["due_json"]!])
    }
    static func scheduleOperationHash(intentID: String, observationID: String, accessVersion: Int, grantID: String?) throws -> String {
        var parts = [intentID,observationID,String(accessVersion)]
        if let grantID { parts += ["effect-grant-v1",grantID] }
        return try actionHash(parts)
    }
    static func validateReminderScheduleGrants(_ db: Database) throws {
        for row in try db.query("SELECT * FROM reminder_schedule_grants") {
            let before = try scheduleBefore(row)
            guard let intent = try db.query("SELECT * FROM action_schedule_intents WHERE id=?", [row["intent_id"]]).first,
                  let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [row["link_id"]]).first,
                  let observation = try db.query("SELECT * FROM reminder_observations WHERE id=?", [row["observation_id"]]).first,
                  let access = row["access_version"].flatMap(Int.init), access > 0,
                  intent["action_id"] == link["action_id"], row["access_version"] == intent["access_version"],
                  observation["link_id"] == link["id"], observation["external_id"] == before.id,
                  observation["marker_valid"] == "1", observation["completed"] == "0", !before.completed,
                  before.marker == link["marker"], before.title == observation["title"],
                  row["actor"] == "user", row["desired_json"] == intent["due_json"],
                  let dueJSON = try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [observation["id"]]).first?["due_json"],
                  before.dueDate == (try JSONDecoder().decode(ReminderDueDate.self, from: Data(dueJSON.utf8))),
                  row["effect_digest"] == (try scheduleEffectDigest(intent: intent,linkID: link["id"]!,calendarID: link["calendar_id"]!,observationID: observation["id"]!,beforeJSON: row["before_json"]!,accessVersion: access)),
                  row["input_fingerprint"] == (try actionHash([row["effect_digest"]!,"user"])) else { throw VoiceOSError("迁移具体效果确认的身份、权限或摘要不一致") }
            let due = try JSONDecoder().decode(ReminderDueDate.self, from: Data(row["desired_json"]!.utf8))
            _ = try due.writableComponents()
            let anchor = ISO8601DateFormatter(); anchor.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            let proposal = try ReminderScheduleProposal(due: due,authority: ScheduleAuthority(rawValue: intent["authority"]!)!,rawExpression: intent["raw_expression"]!,anchorEventTime: anchor.date(from: intent["anchor_event_time"]!)!)
            let baseJSON = try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [intent["base_observation_id"]]).first?["due_json"]
            let base = try baseJSON.map { try JSONDecoder().decode(ReminderDueDate.self, from: Data($0.utf8)) }
            guard try ReminderScheduleMerge.decide(base: base,baseAuthority: ScheduleAuthority(rawValue: intent["base_authority"]!)!,remote: before.dueDate,desired: proposal,
                                                   authorized: true,actionCurrent: true,uniqueIdentity: true).disposition == .requiresConfirmation else {
                throw VoiceOSError("迁移确认不能绕过重要效果分类或授权未知字段")
            }
            if let baseID = intent["base_observation_id"] {
                guard let sequence = try db.query("SELECT sequence FROM reminder_observations WHERE id=?", [baseID]).first?["sequence"].flatMap(Int.init),
                      sequence <= Int(observation["sequence"]!)! else { throw VoiceOSError("具体效果确认引用未来基线") }
            }
        }
        for row in try db.query("SELECT * FROM reminder_schedule_grant_revocations") {
            guard row["actor"] == "user", let reason = row["reason"], !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reason.unicodeScalars.count <= 2000,
                  try db.query("SELECT id FROM reminder_schedule_grants WHERE id=?", [row["grant_id"]]).count == 1,
                  row["input_fingerprint"] == (try actionHash([row["grant_id"]!,reason,"user"])) else { throw VoiceOSError("迁移确认撤回记录不一致") }
        }
    }
}
