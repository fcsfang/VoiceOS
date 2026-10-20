import Foundation

/// Historical evidence of field provenance, not a continuing execution grant.
extension VoiceOSStore {
    static func reminderScheduleBasis(_ db: Database, observationID: String, actionVersion: Int,
                                      scheduleVersion: Int, priorAuthority: ScheduleAuthority?,
                                      includeFrozen: Bool = false) throws -> (authority: ScheduleAuthority, operationID: String?) {
        guard let observation = try db.query("SELECT * FROM reminder_observations WHERE id=?", [observationID]).first,
              let dueJSON = try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [observationID]).first?["due_json"] else {
            throw VoiceOSError("期限归属缺少时间观测")
        }
        if priorAuthority == .userCommitment { return (.userCommitment, nil) }
        let candidates = try db.query("""
            SELECT p.*,s.authority,s.action_version,s.schedule_version,o.sequence AS result_sequence
            FROM reminder_schedule_operations p JOIN action_schedule_intents s ON s.id=p.intent_id
            JOIN reminder_observations o ON o.id=p.result_observation_id
            WHERE p.link_id=? AND p.state='confirmed' AND p.save_acknowledged=1 AND p.attempted=1
            AND s.authority='ai_flexible' AND s.action_version=? AND s.schedule_version<?
            AND o.sequence<=? ORDER BY o.sequence DESC
            """, [observation["link_id"],String(actionVersion),String(scheduleVersion),observation["sequence"]])
        for candidate in candidates {
            guard (includeFrozen || candidate["validity"] == "current"), candidate["desired_json"] == dueJSON else { continue }
            // A later unknown/conflicting attempt must be reconciled, never
            // interpreted as proof that the earlier field still belongs to AI.
            guard try db.query("""
                SELECT p.id FROM reminder_schedule_operations p JOIN action_schedule_intents s ON s.id=p.intent_id
                WHERE p.link_id=? AND s.schedule_version>? AND s.schedule_version<? AND p.attempted=1
                """, [candidate["link_id"],candidate["schedule_version"],String(scheduleVersion)]).isEmpty else { continue }
            let before = try scheduleBefore(candidate)
            let history = try db.query("""
                SELECT o.*,t.due_json FROM reminder_observations o
                LEFT JOIN reminder_time_observations t ON t.id=o.id
                WHERE o.link_id=? AND o.sequence>=? AND o.sequence<=? ORDER BY o.sequence
                """, [observation["link_id"],candidate["result_sequence"],observation["sequence"]])
            guard !history.isEmpty, history.allSatisfy({
                $0["external_id"] == before.id && $0["marker_valid"] == "1" && $0["completed"] == "0" && $0["due_json"] == dueJSON
            }) else { continue }
            return (.aiFlexible, candidate["id"])
        }
        // An initial observed absence is schedulable. A human removal, unknown
        // interval, or an unattributed write is not converted back to AI ownership.
        let history = try db.query("""
            SELECT o.*,t.due_json FROM reminder_observations o LEFT JOIN reminder_time_observations t ON t.id=o.id
            WHERE o.link_id=? AND o.sequence<=? ORDER BY o.sequence
            """, [observation["link_id"],observation["sequence"]])
        let noneJSON = try scheduleJSON(ReminderDueDate.none)
        let attempted = try db.query("""
            SELECT p.id FROM reminder_schedule_operations p JOIN action_schedule_intents s ON s.id=p.intent_id
            WHERE p.link_id=? AND p.attempted=1 AND s.schedule_version<?
            """, [observation["link_id"],String(scheduleVersion)])
        let initialAbsence = attempted.isEmpty && !history.isEmpty && history.allSatisfy {
            $0["due_json"] == noneJSON && $0["external_id"] == observation["external_id"] && $0["marker_valid"] == "1" && $0["completed"] == "0"
        }
        return (initialAbsence ? .aiFlexible : .externalManual, nil)
    }

    static func validateReminderScheduleBases(_ db: Database) throws {
        for row in try db.query("SELECT * FROM reminder_schedule_bases") {
            guard let intent = try db.query("SELECT * FROM action_schedule_intents WHERE id=?", [row["intent_id"]]).first,
                  let observationID = intent["base_observation_id"],
                  let actionVersion = intent["action_version"].flatMap(Int.init),
                  let version = intent["schedule_version"].flatMap(Int.init) else { throw VoiceOSError("排期字段归属缺少对应意图") }
            let prior = try db.query("SELECT authority FROM action_schedule_intents WHERE action_id=? AND schedule_version=?", [intent["action_id"],String(version-1)]).first?["authority"].flatMap(ScheduleAuthority.init(rawValue:))
            // Conservative provenance remains valid if a formerly unknown
            // operation is only reconciled after this intent was recorded.
            if row["authority"] == "external_manual", prior != .userCommitment,
               row["operation_id"] == nil, intent["base_authority"] == "external_manual" { continue }
            let expected = try reminderScheduleBasis(db,observationID: observationID,actionVersion: actionVersion,
                                                     scheduleVersion: version,priorAuthority: prior,includeFrozen: true)
            guard row["authority"] == expected.authority.rawValue, intent["base_authority"] == row["authority"],
                  row["operation_id"] == expected.operationID else { throw VoiceOSError("排期基线归属与可追溯执行/观测历史不一致") }
        }
    }
}
