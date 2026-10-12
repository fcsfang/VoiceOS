import Foundation

public enum ActionScheduleActor: String, Codable, Sendable { case user, ai }
public struct ActionScheduleIntent: Identifiable, Sendable {
    public let id: String
    public let actionID: String
    public let actionVersion: Int
    public let version: Int
    public let due: ReminderDueDate
    public let authority: ScheduleAuthority
    public let actor: ActionScheduleActor
    public let rawExpression: String
    public let anchorEventTime: Date
    public let anchorTimeZone: String
    public let baseObservationID: String?
    public let baseAuthority: ScheduleAuthority
    public let validity: String
    public let eligibleForPlanning: Bool
    public var anchorSummary: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: anchorTimeZone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: anchorEventTime) + " · " + anchorTimeZone
    }
}
extension VoiceOSStore {
    /// Local desired time only. No external write, endorsement, or completion.
    /// User commands can change a local pledge; AI plans cannot invent or erase it.
    @discardableResult
    public func recordActionSchedule(actionID: String, expectedActionVersion: Int, expectedScheduleVersion: Int,
                                     proposal: ReminderScheduleProposal, actor: ActionScheduleActor,
                                     anchorTimeZone: String, baseObservationID: String? = nil,
                                     expectedAccessVersion: Int? = nil, commandID: String = UUID().uuidString) throws -> String {
        try proposal.due.validate()
        let anchor = try Self.scheduleTime(proposal.anchorEventTime)
        guard TimeZone(identifier: anchorTimeZone) != nil, expectedScheduleVersion >= 0,
              actor != .ai || proposal.authority == .aiFlexible else { throw VoiceOSError("AI 排期不能成为用户明确承诺；锚点时区须有效") }
        if case .dateOnly(_, nil) = proposal.due { throw VoiceOSError("本地日期提案须固定解释时区，不能在重试时猜测") }
        let dueJSON = try Self.scheduleDueJSON(proposal.due)
        let hash = try Self.actionHash([actionID, String(expectedActionVersion), String(expectedScheduleVersion), dueJSON,
                                        proposal.authority.rawValue, actor.rawValue, proposal.rawExpression, anchor,
                                        anchorTimeZone, baseObservationID ?? "", expectedAccessVersion.map(String.init) ?? ""])
        if let receipt = try db.query("SELECT id,input_fingerprint FROM action_schedule_intents WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一排期命令不能更换内容") }
            return receipt["id"]!
        }
        guard let action = try actions(includeHistory: true).first(where: { $0.id == actionID }),
              action.version == expectedActionVersion, action.kind == "task", action.state == "open", action.validity == "current" else {
            throw VoiceOSError("只有当前有效且未完成任务可以记录排期提案")
        }
        let prior = try db.query("SELECT * FROM action_schedule_intents WHERE action_id=? ORDER BY schedule_version DESC LIMIT 1", [actionID]).first
        guard Int(prior?["schedule_version"] ?? "0") == expectedScheduleVersion else { throw VoiceOSError("排期版本已变化，请重新核对") }
        if actor == .ai, prior?["authority"] == ScheduleAuthority.userCommitment.rawValue {
            throw VoiceOSError("AI 不得改写或降级用户的明确期限；请保留承诺并另行提出变更")
        }
        var baseAuthority = ScheduleAuthority.unknown
        if let baseObservationID {
            guard let expectedAccessVersion, let observation = try db.query("""
                SELECT o.*,l.calendar_id,l.external_id AS link_external_id,l.action_id,l.state AS link_state
                FROM reminder_observations o JOIN reminder_links l ON l.id=o.link_id WHERE o.id=?
                """, [baseObservationID]).first, observation["action_id"] == actionID,
                  observation["link_state"] == "linked", observation["marker_valid"] == "1",
                  observation["completed"] == "0",
                  observation["external_id"] == observation["link_external_id"],
                  try db.query("SELECT id FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [observation["link_id"]]).first?["id"] == baseObservationID,
                  let baseDue = try storedReminderDue(observationID: baseObservationID) else {
                throw VoiceOSError("排期基线须来自已授权关联的最新明确时间观测")
            }
            try checkReminderAccess(calendarID: observation["calendar_id"]!, expectedVersion: expectedAccessVersion)
            // No confirmed VoiceOS time writes exist yet. Any existing remote
            // date is human/unknown-owned, never inferred to be AI flexible.
            baseAuthority = prior?["authority"] == ScheduleAuthority.userCommitment.rawValue ? .userCommitment : (baseDue == .none ? .aiFlexible : .externalManual)
        } else {
            guard expectedAccessVersion == nil else { throw VoiceOSError("没有外部时间基线时不得附加连接授权") }
        }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("""
                INSERT INTO action_schedule_intents(id,action_id,action_version,schedule_version,due_json,authority,actor,
                raw_expression,anchor_event_time,anchor_time_zone,base_observation_id,base_authority,access_version,
                validity,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'current',?,?,?)
                """, [id,actionID,String(expectedActionVersion),String(expectedScheduleVersion+1),dueJSON,proposal.authority.rawValue,
                        actor.rawValue,proposal.rawExpression,anchor,anchorTimeZone,baseObservationID,baseAuthority.rawValue,
                        expectedAccessVersion.map(String.init),commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try checkpoint(.actionScheduleUncommitted)
        }
        try checkpoint(.actionScheduleCommitted)
        return id
    }

    public func actionScheduleIntents(includeHistory: Bool = false) throws -> [ActionScheduleIntent] {
        let actions = Dictionary(uniqueKeysWithValues: try actions(includeHistory: true).map { ($0.id, $0) })
        try db.execute("UPDATE action_schedule_intents SET validity='frozen' WHERE action_id IN (SELECT id FROM actions WHERE validity!='current')")
        let clause = includeHistory ? "" : "WHERE schedule_version=(SELECT MAX(s.schedule_version) FROM action_schedule_intents s WHERE s.action_id=action_schedule_intents.action_id)"
        return try db.query("SELECT * FROM action_schedule_intents \(clause) ORDER BY action_id,schedule_version").map { row in
            let latest = try db.query("SELECT MAX(schedule_version) AS n FROM action_schedule_intents WHERE action_id=?", [row["action_id"]]).first?["n"]
            let action = actions[row["action_id"]!]
            return try Self.scheduleIntent(row, eligible: row["validity"] == "current" && row["schedule_version"] == latest && action?.state == "open" && action?.validity == "current" && row["action_version"] == action.map { String($0.version) })
        }
    }

    /// Preview from saved observations; never claims they are a fresh system read.
    /// The eventual executor must re-read and bind its operation to these versions.
    public func previewReminderSchedule(intentID: String, expectedAccessVersion: Int) throws -> ReminderScheduleDecision {
        guard let intent = try actionScheduleIntents().first(where: { $0.id == intentID }),
              let link = try reminderLinks().first(where: { $0.actionID == intent.actionID }) else { throw VoiceOSError("没有当前排期或提醒事项关联") }
        try checkReminderAccess(calendarID: link.calendarID, expectedVersion: expectedAccessVersion)
        let action = try actions(includeHistory: true).first { $0.id == intent.actionID }
        let sourcesAllowed = try action.map { try reminderSourceAllowed($0) && reminderCognitionIsLatest($0) } ?? false
        let proposal = try ReminderScheduleProposal(due: intent.due, authority: intent.authority,
                                                    rawExpression: intent.rawExpression, anchorEventTime: intent.anchorEventTime)
        return try ReminderScheduleMerge.decide(base: storedReminderDue(observationID: intent.baseObservationID), baseAuthority: intent.baseAuthority,
                                                remote: link.remoteDueDate, desired: proposal, authorized: true,
                                                actionCurrent: intent.eligibleForPlanning && sourcesAllowed,
                                                uniqueIdentity: link.state == "linked" && link.remoteMarkerValid == true)
    }

    static func scheduleTime(_ date: Date) throws -> String {
        guard date.timeIntervalSince1970.isFinite else { throw VoiceOSError("排期锚点时刻无效") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let text = formatter.string(from: date)
        guard date.timeIntervalSince1970.isFinite, text.utf8.count == 24, formatter.date(from: text) != nil else { throw VoiceOSError("排期锚点时刻无效") }
        return text
    }
    private static func scheduleDueJSON(_ due: ReminderDueDate) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(due), as: UTF8.self)
    }
    private static func scheduleIntent(_ row: [String: String], eligible: Bool) throws -> ActionScheduleIntent {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let id = row["id"], let actionID = row["action_id"], let actionVersion = row["action_version"].flatMap(Int.init),
              let version = row["schedule_version"].flatMap(Int.init), let json = row["due_json"], json.utf8.count <= 4096,
              let authority = row["authority"].flatMap(ScheduleAuthority.init(rawValue:)),
              authority == .aiFlexible || authority == .userCommitment,
              let actor = row["actor"].flatMap(ActionScheduleActor.init(rawValue:)), actor != .ai || authority == .aiFlexible,
              let raw = row["raw_expression"], let anchor = row["anchor_event_time"].flatMap(formatter.date(from:)),
              let zone = row["anchor_time_zone"], TimeZone(identifier: zone) != nil,
              let baseAuthority = row["base_authority"].flatMap(ScheduleAuthority.init(rawValue:)),
              let validity = row["validity"], ["current","frozen"].contains(validity) else { throw VoiceOSError("排期记录缺少有效字段或归属") }
        let due = try JSONDecoder().decode(ReminderDueDate.self, from: Data(json.utf8))
        _ = try ReminderScheduleProposal(due: due, authority: authority, rawExpression: raw, anchorEventTime: anchor)
        if case .dateOnly(_, nil) = due { throw VoiceOSError("排期日期缺少解释时区") }
        guard try scheduleDueJSON(due) == json, try scheduleTime(anchor) == row["anchor_event_time"] else { throw VoiceOSError("排期时间编码不规范") }
        return .init(id: id, actionID: actionID, actionVersion: actionVersion, version: version, due: due, authority: authority, actor: actor,
                     rawExpression: raw, anchorEventTime: anchor, anchorTimeZone: zone, baseObservationID: row["base_observation_id"],
                     baseAuthority: baseAuthority, validity: validity, eligibleForPlanning: eligible)
    }

    static func validateStoredActionSchedules(_ db: Database) throws {
        for action in try db.query("SELECT * FROM actions") {
            var prior: ActionScheduleIntent?
            var priorBaseSequence = 0
            for (index,row) in try db.query("SELECT * FROM action_schedule_intents WHERE action_id=? ORDER BY schedule_version", [action["id"]]).enumerated() {
                let intent = try scheduleIntent(row, eligible: false)
                guard action["kind"] == "task", intent.version == index+1, intent.actionVersion >= 1,
                      intent.actionVersion <= Int(action["version"]!)!,
                      intent.actionVersion >= (prior?.actionVersion ?? 1),
                      intent.actor != .ai || prior?.authority != .userCommitment else { throw VoiceOSError("排期版本链或承诺保护不一致") }
                if intent.actionVersion > 1 {
                    guard try db.query("SELECT state FROM action_revisions WHERE action_id=? AND version=?", [action["id"],String(intent.actionVersion)]).first?["state"] == "open" else {
                        throw VoiceOSError("排期引用的行动版本不是未完成任务")
                    }
                }
                let scope = row["access_version"].flatMap(Int.init)
                if let observationID = intent.baseObservationID {
                    guard let scope, scope > 0,
                          let observation = try db.query("SELECT o.*,l.action_id FROM reminder_observations o JOIN reminder_links l ON l.id=o.link_id WHERE o.id=?", [observationID]).first,
                          observation["action_id"] == action["id"], observation["marker_valid"] == "1", observation["completed"] == "0",
                          let sequence = observation["sequence"].flatMap(Int.init), sequence >= priorBaseSequence,
                          let timeRow = try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [observationID]).first else { throw VoiceOSError("排期基线缺少有效时间观测") }
                    let due = try JSONDecoder().decode(ReminderDueDate.self, from: Data(timeRow["due_json"]!.utf8)); try due.validate()
                    let expected: ScheduleAuthority = prior?.authority == .userCommitment ? .userCommitment : (due == .none ? .aiFlexible : .externalManual)
                    guard intent.baseAuthority == expected else { throw VoiceOSError("排期不能降级人工或承诺基线") }
                    guard try db.query("""
                        SELECT r.id FROM reminder_observations o JOIN action_revisions r ON r.id=o.feedback_revision_id
                        WHERE o.link_id=? AND o.sequence<=? AND r.version>?
                        """, [observation["link_id"],String(sequence),String(intent.actionVersion)]).isEmpty else {
                        throw VoiceOSError("排期基线引用了未来的行动观测")
                    }
                    priorBaseSequence = sequence
                } else {
                    guard scope == nil, intent.baseAuthority == .unknown else { throw VoiceOSError("无观测的排期不能携带授权或伪造基线") }
                }
                let hash = try actionHash([intent.actionID,String(intent.actionVersion),String(intent.version-1),row["due_json"]!,intent.authority.rawValue,
                                          intent.actor.rawValue,intent.rawExpression,row["anchor_event_time"]!,intent.anchorTimeZone,
                                          intent.baseObservationID ?? "",scope.map(String.init) ?? ""])
                guard row["input_fingerprint"] == hash else { throw VoiceOSError("排期命令与输入摘要不一致") }
                prior = intent
            }
        }
    }
}
