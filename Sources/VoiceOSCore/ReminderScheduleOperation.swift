import Foundation

/// Scheduling is optional for a connector; existing read/create ports remain reusable.
public protocol RemindersSchedulingPort: RemindersPort {
    /// Reacquire the unique item, compare the expected fields, call the local
    /// authorization barrier after any awaits, then change only its due date.
    /// A throw may mean the save succeeded; callers must never retry the write.
    func updateDue(calendarID: String, expected: ReminderSnapshot, desired: ReminderDueDate,
                   authorize: @escaping @Sendable () async throws -> Void) async throws
}

public enum ReminderScheduleOperationState: String, Sendable {
    case reserved, unknown, confirmed, observed, conflict, blocked
    public var summary: String {
        switch self {
        case .reserved: return "写前核对中"
        case .unknown: return "改期结果未知，只能回读"
        case .confirmed: return "保存已应答，目标期限已回读"
        case .observed: return "目标期限已观察，写入来源未确认"
        case .conflict: return "外部身份或字段变化，保留外部值"
        case .blocked: return "未派发，已停止"
        }
    }
}
public struct ReminderScheduleOperation: Identifiable, Sendable {
    public let id: String
    public let intentID: String
    public let linkID: String
    public let state: ReminderScheduleOperationState
    public let attempted: Bool
    public let saveAcknowledged: Bool
    public let resultObservationID: String?
    public let validity: String
    public let reason: String
}

extension VoiceOSStore {
    public func reminderScheduleOperations() throws -> [ReminderScheduleOperation] {
        try db.query("SELECT * FROM reminder_schedule_operations ORDER BY created_at,id").map { row in
            guard let state = row["state"].flatMap(ReminderScheduleOperationState.init(rawValue:)) else { throw VoiceOSError("改期操作状态无效") }
            return .init(id: row["id"]!, intentID: row["intent_id"]!, linkID: row["link_id"]!, state: state,
                         attempted: row["attempted"] == "1", saveAcknowledged: row["save_acknowledged"] == "1",
                         resultObservationID: row["result_observation_id"], validity: row["validity"]!, reason: row["reason"]!)
        }
    }

    /// One attempt per intent, reserved before the first await. Replaying this
    /// command returns its durable identity, never invokes another external write.
    @discardableResult
    public func executeReminderSchedule(intentID: String, expectedObservationID: String, expectedAccessVersion: Int,
                                        grantID: String? = nil, using port: any RemindersSchedulingPort,
                                        commandID: String = UUID().uuidString) async throws -> String {
        try Task.checkCancellation()
        let hash = try Self.scheduleOperationHash(intentID: intentID, observationID: expectedObservationID, accessVersion: expectedAccessVersion, grantID: grantID)
        if let receipt = try db.query("SELECT * FROM reminder_schedule_operations WHERE command_id=? OR intent_id=?", [commandID,intentID]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("已有改期尝试；不能更换作用范围或依据重发，请只读核对") }
            return receipt["id"]!
        }
        let input = try scheduleExecutionInput(intentID: intentID, observationID: expectedObservationID, accessVersion: expectedAccessVersion, grantID: grantID)
        guard !activeReminderLinks.contains(input.link.id),
              try db.query("SELECT id FROM reminder_schedule_operations WHERE link_id=? AND state IN ('reserved','unknown')", [input.link.id]).isEmpty else {
            throw VoiceOSError("关联项有进行中或未知改期，先只读核对")
        }
        _ = try input.intent.due.writableComponents()
        let before = try scheduleObservationSnapshot(expectedObservationID, marker: input.marker)
        let id = UUID().uuidString
        try db.execute("""
            INSERT INTO reminder_schedule_operations(id,intent_id,link_id,expected_observation_id,access_version,before_json,desired_json,
            state,attempted,save_acknowledged,validity,reason,command_id,input_fingerprint,created_at,grant_id)
            VALUES(?,?,?,?,?,?,?,'reserved',0,0,'current','等待新鲜回读',?,?,?,?)
            """, [id,intentID,input.link.id,expectedObservationID,String(expectedAccessVersion),try Self.scheduleJSON(before),
                    try Self.scheduleJSON(input.intent.due),commandID,hash,ISO8601DateFormatter().string(from: Date()),grantID])
        activeReminderLinks.insert(input.link.id); defer { activeReminderLinks.remove(input.link.id) }
        do {
            try checkpoint(.scheduleOperationReserved)
            let matches = try await port.find(calendarID: input.link.calendarID, externalID: before.id, marker: before.marker)
            try Task.checkCancellation()
            _ = try scheduleExecutionInput(intentID: intentID, observationID: expectedObservationID, accessVersion: expectedAccessVersion, grantID: grantID)
            try applyReminder(matches, linkID: input.link.id)
            guard matches.count == 1, matches[0] == before else {
                try setScheduleOperation(id, state: .conflict, reason: "写前身份或字段已变化；没有外写")
                return id
            }
            _ = try scheduleExecutionInput(intentID: intentID, observationID: expectedObservationID, accessVersion: expectedAccessVersion, grantID: grantID)
            // This is committed BEFORE the connector call. Any lost receipt,
            // exception or process exit from here onward prohibits resending.
            try db.execute("UPDATE reminder_schedule_operations SET state='unknown',attempted=1,reason='已准备派发；写入效果尚未核对' WHERE id=?", [id])
            try checkpoint(.scheduleOperationAttempted)
            try await port.updateDue(calendarID: input.link.calendarID, expected: before, desired: input.intent.due) { [self] in
                try await self.authorizeScheduleOperation(id)
            }
            try db.execute("UPDATE reminder_schedule_operations SET save_acknowledged=1 WHERE id=?", [id])
            try checkpoint(.scheduleOperationSaved)
            try Task.checkCancellation()
            _ = try scheduleExecutionInput(intentID: intentID, observationID: expectedObservationID, accessVersion: expectedAccessVersion, grantID: grantID)
            let after = try await port.find(calendarID: input.link.calendarID, externalID: before.id, marker: before.marker)
            try Task.checkCancellation()
            _ = try scheduleExecutionInput(intentID: intentID, observationID: expectedObservationID, accessVersion: expectedAccessVersion, grantID: grantID)
            try finishScheduleRead(id, matches: after)
        } catch {
            // Do not overwrite a committed receipt when a post-commit checkpoint throws.
            if let row = try db.query("SELECT * FROM reminder_schedule_operations WHERE id=?", [id]).first,
               ["reserved","unknown"].contains(row["state"] ?? "") {
                try setScheduleOperation(id, state: row["attempted"] == "1" ? .unknown : .blocked,
                                         reason: row["attempted"] == "1" ? "写入或回读未完成；仅允许只读核对，不自动重发" : "写前核对未完成或依据变化；没有派发")
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw VoiceOSError("改期未完成；持久尝试已保留，不会自动重发")
        }
        return id
    }

    /// Recovery reads only. The current connection grant may differ from the
    /// historical operation grant, but it must cover the same explicit list.
    public func reconcileReminderSchedule(operationID: String, expectedAccessVersion: Int, using port: any RemindersPort) async throws {
        try Task.checkCancellation()
        guard let operation = try db.query("SELECT * FROM reminder_schedule_operations WHERE id=?", [operationID]).first,
              let link = try reminderLinks().first(where: { $0.id == operation["link_id"] }),
              operation["validity"] == "current" else { throw VoiceOSError("改期记录不存在或为迁移冻结历史") }
        try checkReminderAccess(calendarID: link.calendarID, expectedVersion: expectedAccessVersion)
        guard operation["attempted"] == "1", ["unknown","conflict"].contains(operation["state"] ?? "") else { return }
        guard !activeReminderLinks.contains(link.id) else { throw VoiceOSError("提醒事项操作正在进行") }
        let before = try Self.scheduleBefore(operation)
        activeReminderLinks.insert(link.id); defer { activeReminderLinks.remove(link.id) }
        do {
            let matches = try await port.find(calendarID: link.calendarID, externalID: before.id, marker: before.marker)
            try Task.checkCancellation()
            try checkReminderAccess(calendarID: link.calendarID, expectedVersion: expectedAccessVersion)
            try finishScheduleRead(operationID, matches: matches)
        } catch {
            // A failed read cannot turn an old observation into a success.
            if try db.query("SELECT state FROM reminder_schedule_operations WHERE id=?", [operationID]).first?["state"] != "confirmed",
               try db.query("SELECT state FROM reminder_schedule_operations WHERE id=?", [operationID]).first?["state"] != "observed" {
                try setScheduleOperation(operationID, state: .unknown, reason: "恢复回读未完成；没有外写或重新派发")
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw VoiceOSError("改期恢复回读失败；没有修改外部任务")
        }
    }

    func schedulePlanningInput(intentID: String, observationID: String, accessVersion: Int) throws -> (intent: ActionScheduleIntent, link: ReminderLink, marker: String) {
        guard let intent = try actionScheduleIntents().first(where: { $0.id == intentID }), intent.eligibleForPlanning,
              let link = try reminderLinks().first(where: { $0.actionID == intent.actionID }),
              link.state == "linked", link.remoteMarkerValid == true, link.remoteCompleted == false,
              link.lastObservationID == observationID,
              let raw = try db.query("SELECT * FROM reminder_links WHERE id=?", [link.id]).first,
              let action = try actions().first(where: { $0.id == intent.actionID }),
              try reminderSourceAllowed(action), try reminderCognitionIsLatest(action),
              let grant = try db.query("SELECT access_version FROM action_schedule_intents WHERE id=?", [intentID]).first,
              grant["access_version"] == String(accessVersion) else { throw VoiceOSError("行动、排期版本、出处、外部基线或授权已变化，停止旧改期") }
        try checkReminderAccess(calendarID: link.calendarID, expectedVersion: accessVersion)
        return (intent, link, raw["marker"]!)
    }
    private func scheduleExecutionInput(intentID: String, observationID: String, accessVersion: Int, grantID: String? = nil) throws -> (intent: ActionScheduleIntent, link: ReminderLink, marker: String) {
        let input = try schedulePlanningInput(intentID: intentID, observationID: observationID, accessVersion: accessVersion)
        let decision = try previewReminderSchedule(intentID: intentID, expectedAccessVersion: accessVersion)
        if let grantID {
            guard decision.disposition == .requiresConfirmation else { throw VoiceOSError("具体确认不能用于另一类变更") }
            try validateActiveScheduleGrant(grantID, intentID: intentID, observationID: observationID, accessVersion: accessVersion)
        } else {
            guard decision.disposition == .writeFlexible else { throw VoiceOSError("当前变化需要具体效果确认或重新规划；保留外部值") }
        }
        return input
    }
    private func authorizeScheduleOperation(_ id: String) throws {
        try Task.checkCancellation()
        guard let row = try db.query("SELECT * FROM reminder_schedule_operations WHERE id=?", [id]).first,
              row["state"] == "unknown", row["attempted"] == "1", row["validity"] == "current" else { throw VoiceOSError("改期操作已失效") }
        _ = try scheduleExecutionInput(intentID: row["intent_id"]!, observationID: row["expected_observation_id"]!, accessVersion: Int(row["access_version"]!)!, grantID: row["grant_id"])
    }
    /// Reuse the ordinary authorized fresh read; no extra network read per timer.
    /// Called inside the observation transaction: effect receipt and observation
    /// are committed together, including ordinary timer-driven recovery.
    func observePendingScheduleOperations(_ matches: [ReminderSnapshot], linkID: String, including: String? = nil) throws -> [String] {
        var completed: [String] = []
        for row in try db.query("SELECT * FROM reminder_schedule_operations WHERE link_id=? AND (state='unknown' OR (id=? AND state='conflict')) AND attempted=1 AND validity='current'", [linkID,including]) {
            if try recordScheduleRead(row, matches: matches) { completed.append(row["id"]!) }
        }
        return completed
    }
    private func finishScheduleRead(_ id: String, matches: [ReminderSnapshot]) throws {
        let row = try db.query("SELECT * FROM reminder_schedule_operations WHERE id=?", [id]).first!
        try applyReminder(matches, linkID: row["link_id"]!, includingScheduleOperation: id)
    }
    private func recordScheduleRead(_ row: [String:String], matches: [ReminderSnapshot]) throws -> Bool {
        let id = row["id"]!
        let before = try Self.scheduleBefore(row)
        let desired = try JSONDecoder().decode(ReminderDueDate.self, from: Data(row["desired_json"]!.utf8))
        let observation = try db.query("SELECT id FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [row["link_id"]]).first?["id"]
        guard matches.count == 1, let remote = matches.first,
              remote.id == before.id, remote.marker == before.marker, remote.title == before.title, remote.completed == before.completed else {
            try setScheduleOperation(id, state: .conflict, reason: "回读身份或其他字段变化；没有重新外写")
            return false
        }
        guard let due = remote.dueDate else {
            try setScheduleOperation(id, state: .unknown, reason: "期限未能无损回读；没有重新外写"); return false
        }
        guard due == desired else {
            try setScheduleOperation(id, state: .conflict, reason: "回读期限与目标不同；保留外部值，不重发"); return false
        }
        try setScheduleOperation(id, state: row["save_acknowledged"] == "1" ? .confirmed : .observed,
                                 reason: row["save_acknowledged"] == "1" ? "保存应答与唯一目标期限回读均已登记；不证明不存在人工竞态" : "观察到目标期限，但保存应答缺失；不能推断由 AI 写入", observationID: observation)
        try checkpoint(.scheduleOperationUncommitted)
        return true
    }
    private func setScheduleOperation(_ id: String, state: ReminderScheduleOperationState, reason: String, observationID: String? = nil) throws {
        try db.execute("UPDATE reminder_schedule_operations SET state=?,reason=?,result_observation_id=?,checked_at=? WHERE id=?",
                       [state.rawValue,reason,observationID,ISO8601DateFormatter().string(from: Date()),id])
    }
    func scheduleObservationSnapshot(_ id: String, marker: String) throws -> ReminderSnapshot {
        guard let row = try db.query("SELECT * FROM reminder_observations WHERE id=?", [id]).first,
              row["marker_valid"] == "1", let due = try storedReminderDue(observationID: id) else { throw VoiceOSError("改期缺少明确唯一时间基线") }
        return .init(id: row["external_id"]!, title: row["title"]!, completed: row["completed"] == "1", marker: marker, dueDate: due)
    }
    static func scheduleJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func scheduleBefore(_ row: [String:String]) throws -> ReminderSnapshot {
        guard let json = row["before_json"], json.utf8.count <= 65536 else { throw VoiceOSError("改期快照无效") }
        let before = try JSONDecoder().decode(ReminderSnapshot.self, from: Data(json.utf8))
        guard try scheduleJSON(before) == json else { throw VoiceOSError("改期快照编码不规范") }
        return before
    }

    static func validateReminderScheduleOperations(_ db: Database) throws {
        for row in try db.query("SELECT * FROM reminder_schedule_operations") {
            let before = try scheduleBefore(row)
            guard let intent = try db.query("SELECT * FROM action_schedule_intents WHERE id=?", [row["intent_id"]]).first,
                  let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [row["link_id"]]).first,
                  let observation = try db.query("SELECT * FROM reminder_observations WHERE id=?", [row["expected_observation_id"]]).first,
                  row["access_version"] == intent["access_version"], row["desired_json"] == intent["due_json"],
                  intent["action_id"] == link["action_id"],
                  observation["link_id"] == link["id"], observation["marker_valid"] == "1", observation["completed"] == "0",
                  before.id == observation["external_id"], before.title == observation["title"], before.marker == link["marker"], !before.completed,
                  let dueJSON = try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [observation["id"]]).first?["due_json"],
                  before.dueDate == (try JSONDecoder().decode(ReminderDueDate.self, from: Data(dueJSON.utf8))),
                  let baseJSON = try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [intent["base_observation_id"]]).first?["due_json"],
                  let baseSequence = try db.query("SELECT sequence FROM reminder_observations WHERE id=?", [intent["base_observation_id"]]).first?["sequence"].flatMap(Int.init),
                  Int(observation["sequence"]!)! >= baseSequence,
                  row["input_fingerprint"] == (try scheduleOperationHash(intentID: intent["id"]!,observationID: observation["id"]!,accessVersion: Int(row["access_version"]!)!,grantID: row["grant_id"])),
                  let state = row["state"].flatMap(ReminderScheduleOperationState.init(rawValue:)),
                  row["save_acknowledged"] != "1" || row["attempted"] == "1",
                  state != .reserved || row["attempted"] == "0",
                  state != .blocked || row["attempted"] == "0",
                  ![.unknown,.confirmed,.observed].contains(state) || row["attempted"] == "1" else { throw VoiceOSError("迁移改期操作的意图、基线或尝试边界不一致") }
            let desired = try JSONDecoder().decode(ReminderDueDate.self, from: Data(row["desired_json"]!.utf8))
            if let grantID = row["grant_id"] {
                guard let grant = try db.query("SELECT * FROM reminder_schedule_grants WHERE id=?", [grantID]).first,
                      grant["intent_id"] == row["intent_id"], grant["link_id"] == row["link_id"],
                      grant["observation_id"] == row["expected_observation_id"], grant["access_version"] == row["access_version"],
                      grant["before_json"] == row["before_json"], grant["desired_json"] == row["desired_json"] else {
                    throw VoiceOSError("迁移重要改期缺少对应具体效果确认")
                }
            } else {
                guard intent["authority"] == "ai_flexible", intent["base_authority"] == "ai_flexible", dueJSON == baseJSON else {
                    throw VoiceOSError("迁移改期不能绕过重要效果确认")
                }
            }
            _ = try desired.writableComponents()
            guard desired != before.dueDate else { throw VoiceOSError("改期操作没有实际时间差异") }
            if state == .confirmed || state == .observed {
                guard (state == .confirmed) == (row["save_acknowledged"] == "1"),
                      let result = try db.query("SELECT * FROM reminder_observations WHERE id=?", [row["result_observation_id"]]).first,
                      result["link_id"] == link["id"], result["external_id"] == before.id, result["title"] == before.title,
                      result["completed"] == "0", result["marker_valid"] == "1",
                      Int(result["sequence"]!)! > Int(observation["sequence"]!)!,
                      try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [result["id"]]).first?["due_json"] == row["desired_json"] else { throw VoiceOSError("改期成功记录缺少唯一对应时间回读") }
            } else if row["result_observation_id"] != nil { throw VoiceOSError("未核对成功的改期不能携带成功观测") }
        }
    }
}
