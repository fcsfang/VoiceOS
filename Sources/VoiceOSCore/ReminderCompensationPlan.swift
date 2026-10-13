import Foundation

public struct ReminderCompensationPlan: Identifiable, Sendable {
    public let id: String
    public let actionID: String
    public let linkID: String
    public let observationID: String
    public let accessVersion: Int
    public let calendarTitle: String
    public let before: ReminderSnapshot
    public let desired: ReminderDueDate
    public let rootIDs: [String]
    public let operationIDs: [String]
    public let digest: String
    public let validity: String
    public let eligibleForConfirmation: Bool
}
public struct ReminderCompensationGrant: Identifiable, Sendable {
    public let id: String
    public let planID: String
    public let revoked: Bool
    public let validity: String
    public let eligibleForExecution: Bool
}
extension VoiceOSStore {
    /// Restore the field preceding a proven continuous chain of AI flexible
    /// schedules. A correction impact alone does not prove a task should vanish.
    @discardableResult
    public func recordReminderCompensationPlan(actionID: String, expectedImpactDigest: String, expectedAccessVersion: Int,
                                              commandID: String = UUID().uuidString) throws -> String {
        let hash = try Self.actionHash([actionID,expectedImpactDigest,String(expectedAccessVersion)])
        if let prior = try db.query("SELECT * FROM reminder_compensation_plans WHERE command_id=?", [commandID]).first {
            guard prior["input_fingerprint"] == hash else { throw VoiceOSError("同一补偿规划命令不能更换作用范围") }
            return prior["id"]!
        }
        let draft = try compensationDraft(actionID: actionID, expectedImpactDigest: expectedImpactDigest, accessVersion: expectedAccessVersion)
        guard !activeReminderLinks.contains(draft["link_id"]!),
              try db.query("SELECT id FROM reminder_compensation_operations WHERE link_id=? AND state IN ('reserved','unknown')", [draft["link_id"]]).isEmpty else {
            throw VoiceOSError("补偿效果正在执行或未知，先只读核对")
        }
        if let prior = try db.query("SELECT id FROM reminder_compensation_plans WHERE effect_digest=?", [draft["effect_digest"]]).first { return prior["id"]! }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("""
                INSERT INTO reminder_compensation_plans(id,action_id,action_version,schedule_version,link_id,observation_id,access_version,
                roots_json,operations_json,impact_digest,before_json,desired_json,effect_digest,validity,command_id,input_fingerprint,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'current',?,?,?)
                """, [id,actionID,draft["action_version"],draft["schedule_version"],draft["link_id"],draft["observation_id"],String(expectedAccessVersion),
                        draft["roots_json"],draft["operations_json"],expectedImpactDigest,draft["before_json"],draft["desired_json"],draft["effect_digest"],
                        commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try checkpoint(.compensationPlanUncommitted)
        }
        try checkpoint(.compensationPlanCommitted)
        return id
    }
    public func reminderCompensationPlans() throws -> [ReminderCompensationPlan] {
        try db.query("SELECT * FROM reminder_compensation_plans ORDER BY created_at,id").map { row in
            let live = try? liveCompensationPlan(row["id"]!)
            let calendar = try db.query("SELECT calendar_id FROM reminder_links WHERE id=?", [row["link_id"]]).first?["calendar_id"]
            let access = try reminderAccess()
            let unused = try db.query("SELECT id FROM reminder_compensation_operations WHERE plan_id=?", [row["id"]]).isEmpty
            let grants = try db.query("SELECT id FROM reminder_compensation_grants WHERE plan_id=?", [row["id"]])
            return .init(id: row["id"]!,actionID: row["action_id"]!,linkID: row["link_id"]!,observationID: row["observation_id"]!,
                         accessVersion: Int(row["access_version"]!)!,calendarTitle: access?.calendarID == calendar ? access!.title : "历史授权清单",
                         before: try Self.scheduleBefore(row),desired: try Self.compensationDesired(row),
                         rootIDs: try Self.compensationIDs(row["roots_json"]!),operationIDs: try Self.compensationIDs(row["operations_json"]!),
                         digest: row["effect_digest"]!,validity: row["validity"]!,eligibleForConfirmation: live != nil && unused && grants.isEmpty)
        }
    }
    @discardableResult
    public func confirmReminderCompensation(planID: String, displayedEffectDigest: String, actor: ActionScheduleActor,
                                           commandID: String = UUID().uuidString) throws -> String {
        guard actor == .user else { throw VoiceOSError("AI 不得把纠错影响等同于用户批准补偿") }
        let hash = try Self.actionHash([planID,displayedEffectDigest,"user"])
        if let prior = try db.query("SELECT * FROM reminder_compensation_grants WHERE command_id=?", [commandID]).first {
            guard prior["input_fingerprint"] == hash else { throw VoiceOSError("同一补偿确认不能更换具体效果") }
            return prior["id"]!
        }
        let plan = try liveCompensationPlan(planID)
        guard plan["effect_digest"] == displayedEffectDigest, !activeReminderLinks.contains(plan["link_id"]!),
              try db.query("SELECT id FROM reminder_compensation_operations WHERE plan_id=?", [planID]).isEmpty else {
            throw VoiceOSError("显示的补偿效果已变化或已尝试，停止旧确认")
        }
        if let prior = try db.query("SELECT * FROM reminder_compensation_grants WHERE plan_id=?", [planID]).first {
            guard prior["validity"] == "current",
                  try db.query("SELECT id FROM reminder_compensation_revocations WHERE grant_id=?", [prior["id"]]).isEmpty else {
                throw VoiceOSError("旧补偿确认已撤回或冻结，不能重新批准同一效果")
            }
            return prior["id"]!
        }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO reminder_compensation_grants(id,plan_id,effect_digest,actor,validity,command_id,input_fingerprint,created_at) VALUES(?,?,?,'user','current',?,?,?)",
                           [id,planID,displayedEffectDigest,commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try checkpoint(.compensationGrantUncommitted)
        }
        try checkpoint(.compensationGrantCommitted)
        return id
    }
    @discardableResult
    public func revokeReminderCompensation(grantID: String, reason: String, actor: ActionScheduleActor,
                                          commandID: String = UUID().uuidString) throws -> String {
        guard actor == .user, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.unicodeScalars.count <= 2000 else {
            throw VoiceOSError("补偿撤回须来自用户并保存原因")
        }
        let hash = try Self.actionHash([grantID,reason,"user"])
        if let prior = try db.query("SELECT * FROM reminder_compensation_revocations WHERE command_id=? OR grant_id=?", [commandID,grantID]).first {
            guard prior["input_fingerprint"] == hash else { throw VoiceOSError("已撤回补偿确认不能更换记录") }
            return prior["id"]!
        }
        guard try db.query("SELECT id FROM reminder_compensation_grants WHERE id=? AND validity='current'", [grantID]).count == 1 else {
            throw VoiceOSError("补偿确认不存在或为冻结历史")
        }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO reminder_compensation_revocations(id,grant_id,actor,reason,command_id,input_fingerprint,created_at) VALUES(?,?,'user',?,?,?,?)",
                           [id,grantID,reason,commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try checkpoint(.compensationRevocationUncommitted)
        }
        try checkpoint(.compensationRevocationCommitted)
        return id
    }
    public func reminderCompensationGrants() throws -> [ReminderCompensationGrant] {
        try db.query("SELECT * FROM reminder_compensation_grants ORDER BY created_at,id").map { row in
            let revoked = try !db.query("SELECT id FROM reminder_compensation_revocations WHERE grant_id=?", [row["id"]]).isEmpty
            let eligible = (try? authorizedCompensationPlan(row["plan_id"]!,grantID: row["id"]!)) != nil
            let unused = try db.query("SELECT id FROM reminder_compensation_operations WHERE plan_id=?", [row["plan_id"]]).isEmpty
            return .init(id: row["id"]!,planID: row["plan_id"]!,revoked: revoked,validity: row["validity"]!,eligibleForExecution: eligible && unused)
        }
    }
    func authorizedCompensationPlan(_ planID: String, grantID: String) throws -> [String:String] {
        let plan = try liveCompensationPlan(planID)
        guard let grant = try db.query("SELECT * FROM reminder_compensation_grants WHERE id=?", [grantID]).first,
              grant["plan_id"] == planID, grant["actor"] == "user", grant["validity"] == "current",
              grant["effect_digest"] == plan["effect_digest"],
              try db.query("SELECT id FROM reminder_compensation_revocations WHERE grant_id=?", [grantID]).isEmpty else {
            throw VoiceOSError("具体补偿许可已撤回、冻结或不属于本次效果")
        }
        return plan
    }
    func liveCompensationPlan(_ id: String) throws -> [String:String] {
        guard let row = try db.query("SELECT * FROM reminder_compensation_plans WHERE id=?", [id]).first, row["validity"] == "current" else {
            throw VoiceOSError("补偿计划不存在或为冻结历史")
        }
        let draft = try compensationDraft(actionID: row["action_id"]!,expectedImpactDigest: row["impact_digest"]!,accessVersion: Int(row["access_version"]!)!)
        guard draft["effect_digest"] == row["effect_digest"] else { throw VoiceOSError("纠错依据、外部字段或授权已变化，停止旧补偿") }
        return row
    }
    private func compensationDraft(actionID: String, expectedImpactDigest: String, accessVersion: Int) throws -> [String:String] {
        guard let impact = try correctionActionImpacts().first(where: { $0.action.id == actionID }),
              impact.digest == expectedImpactDigest, impact.action.state == "open",
              let link = impact.link, link.state == "linked", link.remoteMarkerValid == true, link.remoteCompleted == false,
              let observation = link.lastObservationID else { throw VoiceOSError("仅明确纠错的冻结未完成行动可规划；影响或外部现状已变化") }
        try checkReminderAccess(calendarID: link.calendarID,expectedVersion: accessVersion)
        guard try db.query("SELECT id FROM reminder_schedule_operations WHERE link_id=? AND state IN ('reserved','unknown')", [link.id]).isEmpty,
              let latest = try db.query("SELECT schedule_version FROM action_schedule_intents WHERE action_id=? ORDER BY schedule_version DESC LIMIT 1", [actionID]).first?["schedule_version"].flatMap(Int.init) else {
            throw VoiceOSError("没有可追溯排期，或旧改期尚未核对；不推断应删除任务")
        }
        let chain = try Self.compensationChain(db,observationID: observation,actionVersion: impact.action.version,scheduleVersion: latest)
        let before = try scheduleObservationSnapshot(observation,marker: "voiceos-action:"+link.id)
        guard before.dueDate != chain.desired else { throw VoiceOSError("期限已与补偿目标一致，无需外写") }
        _ = try chain.desired.writableComponents()
        var row = ["action_id": actionID,"action_version": String(impact.action.version),"schedule_version": String(latest),
                   "link_id": link.id,"observation_id": observation,"access_version": String(accessVersion),"impact_digest": expectedImpactDigest,
                   "roots_json": try Self.scheduleJSON(impact.roots.map(\.id)),"operations_json": try Self.scheduleJSON(chain.ids),
                   "before_json": try Self.scheduleJSON(before),"desired_json": try Self.scheduleJSON(chain.desired)]
        row["effect_digest"] = try Self.compensationDigest(row,calendarID: link.calendarID)
        return row
    }
    static func compensationChain(_ db: Database, observationID: String, actionVersion: Int, scheduleVersion: Int,
                                  includeFrozen: Bool = false) throws -> (ids: [String], desired: ReminderDueDate) {
        guard let observation = try db.query("SELECT * FROM reminder_observations WHERE id=?", [observationID]).first,
              let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [observation["link_id"]]).first,
              let latest = try db.query("SELECT authority FROM action_schedule_intents WHERE action_id=? AND schedule_version=?", [link["action_id"],String(scheduleVersion)]).first,
              latest["authority"] == "ai_flexible" else { throw VoiceOSError("明确承诺或无排期不进入AI期限补偿") }
        let basis = try reminderScheduleBasis(db,observationID: observationID,actionVersion: actionVersion,
                                             scheduleVersion: scheduleVersion+1,priorAuthority: .aiFlexible,includeFrozen: includeFrozen)
        guard basis.authority == .aiFlexible, var operationID = basis.operationID else { throw VoiceOSError("人工、未知或未归属期限不能自动推导补偿目标") }
        var ids: [String] = []
        var desired: ReminderDueDate?
        while true {
            guard !ids.contains(operationID),
                  let operation = try db.query("SELECT p.*,s.action_version,s.authority,s.schedule_version FROM reminder_schedule_operations p JOIN action_schedule_intents s ON s.id=p.intent_id WHERE p.id=?", [operationID]).first,
                  operation["link_id"] == link["id"], operation["state"] == "confirmed", operation["save_acknowledged"] == "1",
                  operation["authority"] == "ai_flexible", operation["action_version"] == String(actionVersion),
                  includeFrozen || operation["validity"] == "current",
                  let original = try scheduleBefore(operation).dueDate else { throw VoiceOSError("补偿链缺少连续已确认AI执行依据") }
            ids.insert(operationID,at: 0); desired = original
            guard let parent = try db.query("SELECT operation_id FROM reminder_schedule_bases WHERE intent_id=?", [operation["intent_id"]]).first?["operation_id"] else { break }
            operationID = parent
        }
        return (ids,desired!)
    }
    static func compensationDigest(_ row: [String:String], calendarID: String) throws -> String {
        try actionHash(["corrective-due-restore-v1",row["action_id"]!,row["action_version"]!,row["schedule_version"]!,row["link_id"]!,calendarID,
                        row["observation_id"]!,row["access_version"]!,row["roots_json"]!,row["operations_json"]!,row["impact_digest"]!,row["before_json"]!,row["desired_json"]!])
    }
    static func compensationDesired(_ row: [String:String]) throws -> ReminderDueDate {
        try JSONDecoder().decode(ReminderDueDate.self,from: Data(row["desired_json"]!.utf8))
    }
    static func compensationIDs(_ json: String) throws -> [String] {
        guard json.utf8.count <= 65536 else { throw VoiceOSError("补偿依据集合过大") }
        let ids = try JSONDecoder().decode([String].self,from: Data(json.utf8))
        guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy({ UUID(uuidString: $0) != nil }),
              try scheduleJSON(ids) == json else { throw VoiceOSError("补偿依据身份或编码无效") }
        return ids
    }
}
