import Foundation

public struct ReminderCompensationOperation: Identifiable, Sendable {
    public let id: String
    public let planID: String
    public let state: ReminderScheduleOperationState
    public let attempted: Bool
    public let saveAcknowledged: Bool
    public let validity: String
    public let reason: String
}
extension VoiceOSStore {
    public func reminderCompensationOperations() throws -> [ReminderCompensationOperation] {
        try db.query("SELECT * FROM reminder_compensation_operations ORDER BY created_at,id").map {
            .init(id: $0["id"]!,planID: $0["plan_id"]!,state: ReminderScheduleOperationState(rawValue: $0["state"]!)!,
                  attempted: $0["attempted"] == "1",saveAcknowledged: $0["save_acknowledged"] == "1",validity: $0["validity"]!,reason: $0["reason"]!)
        }
    }
    /// A narrow corrective field write. The original action remains frozen;
    /// ordinary scheduling barriers are never relaxed to permit this operation.
    @discardableResult
    public func executeReminderCompensation(planID: String, grantID: String, using port: any RemindersSchedulingPort,
                                           commandID: String = UUID().uuidString) async throws -> String {
        try Task.checkCancellation()
        let hash = try Self.actionHash([planID,grantID])
        if let receipt = try db.query("SELECT * FROM reminder_compensation_operations WHERE command_id=? OR plan_id=?", [commandID,planID]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("已有补偿尝试，不能更换许可或重发") }
            return receipt["id"]!
        }
        let plan = try authorizedCompensationPlan(planID,grantID: grantID)
        let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [plan["link_id"]]).first!
        guard !activeReminderLinks.contains(link["id"]!),
              try db.query("SELECT id FROM reminder_compensation_operations WHERE link_id=? AND state IN ('reserved','unknown')", [link["id"]]).isEmpty else {
            throw VoiceOSError("外部关联已有补偿在途或未知，先只读核对")
        }
        let before = try Self.scheduleBefore(plan), desired = try Self.compensationDesired(plan)
        let id = UUID().uuidString
        try db.execute("INSERT INTO reminder_compensation_operations(id,plan_id,grant_id,link_id,state,attempted,save_acknowledged,validity,reason,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'reserved',0,0,'current','等待补偿写前核对',?,?,?)",
                       [id,planID,grantID,link["id"],commandID,hash,ISO8601DateFormatter().string(from: Date())])
        activeReminderLinks.insert(link["id"]!); defer { activeReminderLinks.remove(link["id"]!) }
        do {
            try checkpoint(.compensationOperationReserved)
            let matches = try await port.find(calendarID: link["calendar_id"]!,externalID: before.id,marker: before.marker)
            try Task.checkCancellation()
            _ = try authorizedCompensationPlan(planID,grantID: grantID)
            try applyReminder(matches,linkID: link["id"]!)
            guard matches.count == 1, matches[0] == before else {
                try setCompensationOperation(id,state: .conflict,reason: "补偿写前身份或人工字段变化；没有外写")
                return id
            }
            _ = try authorizedCompensationPlan(planID,grantID: grantID)
            try db.execute("UPDATE reminder_compensation_operations SET state='unknown',attempted=1,reason='补偿已准备派发，效果待核对' WHERE id=?", [id])
            try checkpoint(.compensationOperationAttempted)
            try await port.updateDue(calendarID: link["calendar_id"]!,expected: before,desired: desired) { [self] in
                try Task.checkCancellation()
                _ = try await self.authorizeCompensationOperation(id)
            }
            try db.execute("UPDATE reminder_compensation_operations SET save_acknowledged=1 WHERE id=?", [id])
            try checkpoint(.compensationOperationSaved)
            try Task.checkCancellation()
            _ = try authorizedCompensationPlan(planID,grantID: grantID)
            let after = try await port.find(calendarID: link["calendar_id"]!,externalID: before.id,marker: before.marker)
            try Task.checkCancellation()
            _ = try authorizedCompensationPlan(planID,grantID: grantID)
            try applyReminder(after,linkID: link["id"]!,includingCompensationOperation: id)
        } catch {
            if let row = try db.query("SELECT * FROM reminder_compensation_operations WHERE id=?", [id]).first,
               ["reserved","unknown"].contains(row["state"] ?? "") {
                try setCompensationOperation(id,state: row["attempted"] == "1" ? .unknown : .blocked,
                                             reason: row["attempted"] == "1" ? "补偿效果未知，仅允许只读核对" : "补偿写前核对未完成，没有派发")
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw VoiceOSError("补偿未完成，持久尝试保留；不重发外部写入")
        }
        return id
    }
    private func authorizeCompensationOperation(_ id: String) throws {
        try Task.checkCancellation()
        guard let row = try db.query("SELECT * FROM reminder_compensation_operations WHERE id=?", [id]).first,
              row["state"] == "unknown", row["attempted"] == "1", row["validity"] == "current" else { throw VoiceOSError("补偿尝试已失效") }
        _ = try authorizedCompensationPlan(row["plan_id"]!,grantID: row["grant_id"]!)
    }
    public func reconcileReminderCompensation(operationID: String, expectedAccessVersion: Int, using port: any RemindersPort) async throws {
        try Task.checkCancellation()
        guard let row = try db.query("SELECT * FROM reminder_compensation_operations WHERE id=?", [operationID]).first,
              row["validity"] == "current", row["attempted"] == "1", ["unknown","conflict"].contains(row["state"] ?? ""),
              let plan = try db.query("SELECT * FROM reminder_compensation_plans WHERE id=?", [row["plan_id"]]).first,
              let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [row["link_id"]]).first else {
            throw VoiceOSError("没有可只读核对的补偿尝试，或为冻结历史")
        }
        try checkReminderAccess(calendarID: link["calendar_id"]!,expectedVersion: expectedAccessVersion)
        guard !activeReminderLinks.contains(link["id"]!) else { throw VoiceOSError("关联任务正在操作") }
        let before = try Self.scheduleBefore(plan)
        activeReminderLinks.insert(link["id"]!); defer { activeReminderLinks.remove(link["id"]!) }
        do {
            let matches = try await port.find(calendarID: link["calendar_id"]!,externalID: before.id,marker: before.marker)
            try Task.checkCancellation()
            try checkReminderAccess(calendarID: link["calendar_id"]!,expectedVersion: expectedAccessVersion)
            try applyReminder(matches,linkID: link["id"]!,includingCompensationOperation: operationID)
        } catch {
            if let state = try db.query("SELECT state FROM reminder_compensation_operations WHERE id=?", [operationID]).first?["state"],
               !["confirmed","observed"].contains(state) {
                try setCompensationOperation(operationID,state: .unknown,reason: "补偿恢复回读未完成，没有重发或反向写入")
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw VoiceOSError("补偿只读核对失败，保留未知效果")
        }
    }
    /// Reused by ordinary authorized refresh, inside the observation transaction.
    func observePendingCompensationOperations(_ matches: [ReminderSnapshot], linkID: String, including: String?) throws -> [String] {
        var finished: [String] = []
        for row in try db.query("SELECT * FROM reminder_compensation_operations WHERE link_id=? AND attempted=1 AND validity='current' AND (state='unknown' OR (id=? AND state='conflict'))", [linkID,including]) {
            let plan = try db.query("SELECT * FROM reminder_compensation_plans WHERE id=?", [row["plan_id"]]).first!
            let before = try Self.scheduleBefore(plan)
            guard matches.count == 1, let remote = matches.first, remote.id == before.id, remote.marker == before.marker,
                  remote.title == before.title, remote.completed == before.completed else {
                try setCompensationOperation(row["id"]!,state: .conflict,reason: "补偿回读身份或人工字段变化；保留外部事实")
                continue
            }
            guard let due = remote.dueDate else {
                try setCompensationOperation(row["id"]!,state: .unknown,reason: "补偿期限未能无损回读")
                continue
            }
            guard due == (try Self.compensationDesired(plan)) else {
                try setCompensationOperation(row["id"]!,state: .conflict,reason: "补偿目标与回读不同；保留外部值，不重发")
                continue
            }
            let observationID = try db.query("SELECT id FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [linkID]).first?["id"]
            try setCompensationOperation(row["id"]!,state: row["save_acknowledged"] == "1" ? .confirmed : .observed,
                                         reason: row["save_acknowledged"] == "1" ? "补偿保存应答与目标期限回读已登记；旧行动仍冻结" : "仅观察到补偿目标，写入归属未确认；旧行动仍冻结",observationID: observationID)
            try checkpoint(.compensationOperationUncommitted)
            finished.append(row["id"]!)
        }
        return finished
    }
    private func setCompensationOperation(_ id: String, state: ReminderScheduleOperationState, reason: String, observationID: String? = nil) throws {
        try db.execute("UPDATE reminder_compensation_operations SET state=?,reason=?,result_observation_id=?,checked_at=? WHERE id=?",
                       [state.rawValue,reason,observationID,ISO8601DateFormatter().string(from: Date()),id])
    }
}
