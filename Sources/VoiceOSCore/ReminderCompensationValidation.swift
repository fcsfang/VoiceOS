import Foundation

extension VoiceOSStore {
    static func validateReminderCompensations(_ db: Database) throws {
        for row in try db.query("SELECT * FROM reminder_compensation_plans") {
            let before = try scheduleBefore(row), desired = try compensationDesired(row)
            let roots = try compensationIDs(row["roots_json"]!), operationIDs = try compensationIDs(row["operations_json"]!)
            guard roots == roots.sorted(),
                  let action = try db.query("SELECT * FROM actions WHERE id=?", [row["action_id"]]).first,
                  let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [row["link_id"]]).first,
                  link["action_id"] == action["id"], action["kind"] == "task",
                  let actionVersion = row["action_version"].flatMap(Int.init), actionVersion <= Int(action["version"]!)!,
                  let scheduleVersion = row["schedule_version"].flatMap(Int.init),
                  let access = row["access_version"].flatMap(Int.init), access > 0,
                  let observation = try db.query("SELECT * FROM reminder_observations WHERE id=?", [row["observation_id"]]).first,
                  observation["link_id"] == link["id"], observation["marker_valid"] == "1", observation["completed"] == "0",
                  before.id == observation["external_id"], before.marker == link["marker"], before.title == observation["title"], !before.completed,
                  let due = try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [observation["id"]]).first?["due_json"],
                  before.dueDate == (try JSONDecoder().decode(ReminderDueDate.self,from: Data(due.utf8))),
                  desired != before.dueDate, try scheduleJSON(desired) == row["desired_json"],
                  row["effect_digest"] == (try compensationDigest(row,calendarID: link["calendar_id"]!)),
                  row["input_fingerprint"] == (try actionHash([action["id"]!,row["impact_digest"]!,String(access)])) else {
                throw VoiceOSError("迁移补偿计划的行动、字段、观测或摘要不一致")
            }
            if actionVersion > 1 {
                guard try db.query("SELECT state FROM action_revisions WHERE action_id=? AND version=?", [action["id"],String(actionVersion)]).first?["state"] == "open" else {
                    throw VoiceOSError("补偿不能改写已完成或暂放的历史行动")
                }
            }
            _ = try desired.writableComponents()
            let chain = try compensationChain(db,observationID: observation["id"]!,actionVersion: actionVersion,
                                               scheduleVersion: scheduleVersion,includeFrozen: true)
            guard chain.ids == operationIDs, chain.desired == desired else { throw VoiceOSError("补偿目标不能脱离已确认的AI排期链") }
            let actualRoots = Set(try correctionRoots(db,claimID: action["claim_id"]!,pinnedReviewVersion: Int(action["claim_review_version"]!)!).map(\.id))
            guard Set(roots).isSubset(of: actualRoots) else { throw VoiceOSError("补偿计划缺少实际明确纠错与版本依赖") }
        }
        for row in try db.query("SELECT * FROM reminder_compensation_grants") {
            guard row["actor"] == "user",
                  let plan = try db.query("SELECT * FROM reminder_compensation_plans WHERE id=?", [row["plan_id"]]).first,
                  row["effect_digest"] == plan["effect_digest"],
                  row["input_fingerprint"] == (try actionHash([plan["id"]!,row["effect_digest"]!,"user"])) else {
                throw VoiceOSError("迁移补偿许可与具体效果不一致")
            }
        }
        for row in try db.query("SELECT * FROM reminder_compensation_revocations") {
            guard row["actor"] == "user", let reason = row["reason"], !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reason.unicodeScalars.count <= 2000,
                  try db.query("SELECT id FROM reminder_compensation_grants WHERE id=?", [row["grant_id"]]).count == 1,
                  row["input_fingerprint"] == (try actionHash([row["grant_id"]!,reason,"user"])) else { throw VoiceOSError("迁移补偿撤回记录无效") }
        }
        for row in try db.query("SELECT * FROM reminder_compensation_operations") {
            guard let plan = try db.query("SELECT * FROM reminder_compensation_plans WHERE id=?", [row["plan_id"]]).first,
                  let grant = try db.query("SELECT * FROM reminder_compensation_grants WHERE id=?", [row["grant_id"]]).first,
                  grant["plan_id"] == plan["id"], row["link_id"] == plan["link_id"],
                  row["input_fingerprint"] == (try actionHash([plan["id"]!,grant["id"]!])),
                  let state = row["state"].flatMap(ReminderScheduleOperationState.init(rawValue:)),
                  row["save_acknowledged"] != "1" || row["attempted"] == "1",
                  state != .reserved || row["attempted"] == "0", state != .blocked || row["attempted"] == "0",
                  ![.unknown,.confirmed,.observed].contains(state) || row["attempted"] == "1" else { throw VoiceOSError("迁移补偿尝试缺少具体许可或派发边界") }
            if state == .confirmed || state == .observed {
                let before = try scheduleBefore(plan)
                guard (state == .confirmed) == (row["save_acknowledged"] == "1"),
                      let result = try db.query("SELECT * FROM reminder_observations WHERE id=?", [row["result_observation_id"]]).first,
                      result["link_id"] == plan["link_id"], result["external_id"] == before.id, result["marker_valid"] == "1",
                      result["title"] == before.title, result["completed"] == "0",
                      let initialSequence = try db.query("SELECT sequence FROM reminder_observations WHERE id=?", [plan["observation_id"]]).first?["sequence"].flatMap(Int.init),
                      Int(result["sequence"]!)! > initialSequence,
                      try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [result["id"]]).first?["due_json"] == plan["desired_json"] else {
                    throw VoiceOSError("补偿成功缺少唯一对应期限回读")
                }
            } else if row["result_observation_id"] != nil { throw VoiceOSError("未成功核对补偿不能携带成功观测") }
        }
    }
}
