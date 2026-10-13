import Foundation
import CryptoKit

public enum ActionKind: String, Codable, Sendable { case task, opportunity, aiSuggestion = "ai_suggestion" }
public enum ActionIntentActor: String, Sendable { case user, ai }
public enum LocalActionState: String, Sendable { case open, completed, dismissed }
public struct ActionIntentMetadata: Codable, Sendable {
    public let intentType: String
    public let followupState: String
    public let uncertain: Bool
}
public struct ActionRecord: Identifiable, Sendable {
    public let id: String
    public let claimID: String
    public let claimReviewVersion: Int
    public let title: String
    public let kind: String
    public let intentActor: String
    public let note: String
    public let state: String
    public let validity: String
    public let version: Int
    public let autoSend: Bool
    public let intent: ActionIntentMetadata?
}
public struct ActionRevision: Identifiable, Sendable {
    public let id: String
    public let version: Int
    public let state: String
    public let note: String
    public let createdAt: String
    public let actor: String
}
extension VoiceOSStore {
    /// Explicit local intent; endorsement alone never creates a task or external reminder.
    @discardableResult
    public func createAction(claimID: String, expectedClaimReviewVersion: Int, title: String, kind: ActionKind, intentActor: ActionIntentActor = .user, note: String = "", commandID: String = UUID().uuidString) throws -> String {
        let hash = try Self.actionHash([claimID,String(expectedClaimReviewVersion),title,kind.rawValue,intentActor.rawValue,note])
        if let receipt = try db.query("SELECT id,input_fingerprint FROM actions WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一行动命令不能更换内容") }
            return receipt["id"]!
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.unicodeScalars.count <= 2000, note.unicodeScalars.count <= 2000 else { throw VoiceOSError("行动内容为空或过长") }
        guard let claim = try candidateClaims().first(where: { $0.id == claimID }), claim.reviewVersion == expectedClaimReviewVersion else { throw VoiceOSError("认知已更正、拒绝或失效，请重新核对行动依据") }
        guard (kind == .aiSuggestion) == (intentActor == .ai), intentActor != .ai || claim.ownership == "ai_candidate" else { throw VoiceOSError("AI 建议不能成为用户承诺的任务或探索意图") }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,?,'open','current',?,?,?)", [id,claimID,String(expectedClaimReviewVersion),title,kind.rawValue,intentActor.rawValue,note,commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try checkpoint(.actionUncommitted)
        }
        try checkpoint(.actionCommitted)
        return id
    }
    public func actions(includeHistory: Bool = false) throws -> [ActionRecord] {
        _ = try candidateClaims(includeFrozen: true) // Dynamic source/hash/policy barrier also freezes actions.
        let clause = includeHistory ? "" : "WHERE validity='current' AND state='open'"
        return try db.query("SELECT * FROM actions \(clause) ORDER BY created_at,id").map(Self.actionRecord)
    }
    private static func actionRecord(_ row: [String: String]) throws -> ActionRecord {
        ActionRecord(id: row["id"]!, claimID: row["claim_id"]!, claimReviewVersion: Int(row["claim_review_version"]!)!, title: row["title"]!, kind: row["kind"]!, intentActor: row["intent_actor"]!, note: row["note"]!, state: row["state"]!, validity: row["validity"]!, version: Int(row["version"]!)!, autoSend: row["auto_send"] == "1", intent: try row["intent_json"].map { try JSONDecoder().decode(ActionIntentMetadata.self, from: Data($0.utf8)) })
    }
    @discardableResult
    public func setActionState(actionID: String, expectedVersion: Int, state: LocalActionState, note: String = "", commandID: String = UUID().uuidString) throws -> Int {
        guard !commandID.hasPrefix("reminder-status-resolution:") else { throw VoiceOSError("提醒事项状态恢复须绑定回读依据，不能使用普通状态命令") }
        let hash = try Self.actionHash([actionID,String(expectedVersion),state.rawValue,note])
        if let receipt = try db.query("SELECT * FROM action_revisions WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一行动状态命令不能更换内容") }
            return Int(receipt["version"]!)!
        }
        guard let current = try actions(includeHistory: true).first(where: { $0.id == actionID }), current.validity == "current",
              current.version == expectedVersion else { throw VoiceOSError("行动版本或依据已变化，请重新核对") }
        guard state.rawValue != current.state, state != .completed || current.kind == "task", note.unicodeScalars.count <= 2000 else { throw VoiceOSError("探索意图与 AI 建议不能标成任务完成，或状态没有变化") }
        let next = expectedVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,'user',?,?,?)", [UUID().uuidString,actionID,String(next),String(expectedVersion),state.rawValue,note,commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET state=?,version=? WHERE id=?", [state.rawValue,String(next),actionID])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return next
    }
    public func actionHistory(actionID: String) throws -> [ActionRevision] {
        guard let initial = try db.query("SELECT * FROM actions WHERE id=?", [actionID]).first else { throw VoiceOSError("行动不存在") }
        return [ActionRevision(id: actionID, version: 1, state: "open", note: initial["note"]!, createdAt: initial["created_at"]!, actor: initial["intent_actor"]!)] + (try db.query("SELECT * FROM action_revisions WHERE action_id=? ORDER BY version", [actionID])).map {
            ActionRevision(id: $0["id"]!, version: Int($0["version"]!)!, state: $0["state"]!, note: $0["note"]!, createdAt: $0["created_at"]!, actor: $0["actor"]!)
        }
    }
    static func actionHash(_ fields: [String]) throws -> String {
        SHA256.hash(data: try JSONSerialization.data(withJSONObject: fields)).map { String(format: "%02x", $0) }.joined()
    }
    static func validateStoredActions(_ db: Database) throws {
        for action in try db.query("SELECT a.*,c.review_version AS latest_review,c.validity AS claim_validity,c.ownership AS original_owner FROM actions a JOIN claims c ON c.id=a.claim_id") {
            guard let pinned = action["claim_review_version"].flatMap(Int.init), let latest = action["latest_review"].flatMap(Int.init), pinned >= 0, pinned <= latest,
                  let title = action["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.unicodeScalars.count <= 2000,
                  (action["note"]?.unicodeScalars.count ?? 2001) <= 2000 else { throw VoiceOSError("迁移行动内容或认知版本不完整") }
            let review = try db.query("SELECT * FROM claim_reviews WHERE claim_id=? AND version=?", [action["claim_id"],String(pinned)]).first
            guard pinned == 0 || review != nil, review?["decision"] != "rejected",
                  action["kind"] != "ai_suggestion" || (review?["ownership"] ?? action["original_owner"]) == "ai_candidate" else { throw VoiceOSError("迁移行动引用了拒绝或错误归属的认知") }
            if action["validity"] == "current" {
                guard action["claim_validity"] == "current", pinned == latest else { throw VoiceOSError("迁移的当前行动引用旧认知，必须冻结") }
            }
            let revisions = try db.query("SELECT * FROM action_revisions WHERE action_id=? ORDER BY version", [action["id"]])
            guard action["version"] == String(revisions.count+1) else { throw VoiceOSError("迁移行动状态历史不完整") }
            var state = "open"
            for (index, revision) in revisions.enumerated() {
                guard revision["version"] == String(index+2), revision["from_version"] == String(index+1), let next = revision["state"], next != state,
                      next != "completed" || action["kind"] == "task", (revision["note"]?.unicodeScalars.count ?? 2001) <= 2000 else { throw VoiceOSError("迁移行动状态链不一致") }
                state = next
            }
            guard state == action["state"] else { throw VoiceOSError("迁移行动当前状态与历史不一致") }
        }
        try validateStoredActionSchedules(db)
        try validateReminderScheduleBases(db)
        try validateReminderScheduleGrants(db)
        try validateReminderScheduleOperations(db)
        try validateReminderCompensations(db)
    }
}
