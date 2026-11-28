import Foundation
import CryptoKit

public enum ActionKind: String, Codable, Sendable { case task, opportunity, aiSuggestion = "ai_suggestion" }
public enum ActionIntentActor: String, Sendable { case user, ai }
public enum LocalActionState: String, Sendable { case open, completed, dismissed, someday }
public enum ActionClarificationDecision: String, Sendable { case commit, opportunity, not }
/// The four exits of the one-at-a-time outcome queue.
public enum ActionClarifyExit: String, Sendable { case complete, abandon, someday, next }
public struct ActionIntentMetadata: Codable, Sendable {
    public let intentType: String
    public let followupState: String
    public let uncertain: Bool
    public var goalID: String? = nil
    public var reminderFields: ReminderFieldReceipt? = nil
    public var expressionHistory: [ExpressionActionAdoption]? = nil
    public var expressionWithdrawal: RecordingExpressionActionDecision? = nil
    public var expressionWithdrawalVersionID: String? = nil
    public var expressionWithdrawalResponseIDs: [String]? = nil
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
    public let commandID: String
    public let createdAt: String
    public let parentID: String?
    public let nature: String
    /// Latest revision time that entered `completed`; nil when it never did.
    public let completedAt: String?
    public init(id: String, claimID: String, claimReviewVersion: Int, title: String, kind: String, intentActor: String, note: String, state: String, validity: String, version: Int, autoSend: Bool, intent: ActionIntentMetadata?, commandID: String, createdAt: String, parentID: String?, nature: String = "unknown", completedAt: String? = nil) {
        self.id = id; self.claimID = claimID; self.claimReviewVersion = claimReviewVersion; self.title = title; self.kind = kind; self.intentActor = intentActor; self.note = note; self.state = state; self.validity = validity; self.version = version; self.autoSend = autoSend; self.intent = intent; self.commandID = commandID; self.createdAt = createdAt; self.parentID = parentID; self.nature = nature; self.completedAt = completedAt
    }
    public var isExtracted: Bool { commandID.hasPrefix("extracted:") }
    public var isCurrentTask: Bool { kind == ActionKind.task.rawValue && validity == "current" }
    public var isCurrentOpenTask: Bool { isCurrentTask && state == LocalActionState.open.rawValue }
}
public struct ActionRevision: Identifiable, Codable, Sendable {
    public let id: String
    public let version: Int
    public let state: String
    public let note: String
    public let createdAt: String
    public let actor: String
}
/// One user-visible ledger row; the app never edits it, only reads it.
public struct ActionRevisionRecord: Identifiable, Sendable {
    public let id: String
    public let version: Int
    public let fromVersion: Int
    public let state: String
    public let note: String
    public let actor: String
    public let commandID: String
    public let createdAt: String
}
/// The goal detail header's read-only derivation; no row is written.
public struct GoalProgress: Equatable, Sendable {
    public let nextSteps: Int
    public let completedSteps: Int
    public let lastActivityAt: String?
    public init(nextSteps: Int, completedSteps: Int, lastActivityAt: String?) {
        self.nextSteps = nextSteps; self.completedSteps = completedSteps; self.lastActivityAt = lastActivityAt
    }
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
        guard let claim = try candidateClaim(id: claimID), claim.reviewVersion == expectedClaimReviewVersion else { throw VoiceOSError("认知已更正、拒绝或失效，请重新核对行动依据") }
        guard (kind == .aiSuggestion) == (intentActor == .ai), intentActor != .ai || claim.ownership == "ai_candidate" else { throw VoiceOSError("AI 建议不能成为用户承诺的任务或探索意图") }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,?,'open','current',?,?,?)", [id,claimID,String(expectedClaimReviewVersion),title,kind.rawValue,intentActor.rawValue,note,commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try checkpoint(.actionUncommitted)
        }
        try checkpoint(.actionCommitted)
        return id
    }
    /// The newest revision that entered completed supplies the 已完成 order and the row date.
    private static let completedAtColumn = "(SELECT MAX(r.created_at) FROM action_revisions r WHERE r.action_id=a.id AND r.state='completed') AS completed_at"
    public func actions(includeHistory: Bool = false) throws -> [ActionRecord] {
        try readActions(includeHistory: includeHistory)
    }

    public func action(id: String, includeHistory: Bool = false) throws -> ActionRecord? {
        try readActions(includeHistory: includeHistory, id: id).first
    }

    private func readActions(includeHistory: Bool, id: String? = nil) throws -> [ActionRecord] {
        // A conversation or earlier outcome can invalidate actions in another
        // context. Refresh the complete claim-context verdict before applying the
        // row scope, without decoding claims that the caller will not use.
        try validateClaimContexts()
        let visibility = includeHistory ? "" : " AND a.validity='current' AND a.state='open'"
        let identity = id == nil ? "" : " AND a.id=?"
        let bindings = id.map { [$0] } ?? []
        return try db.query("SELECT a.*,\(Self.completedAtColumn) FROM actions a WHERE a.removed=0\(visibility)\(identity) ORDER BY a.created_at,a.id", bindings).map(Self.actionRecord)
    }

    private static func actionRecord(_ row: [String: String]) throws -> ActionRecord {
        var row = row
        if let title = row["edited_title"] { row["title"] = title }
        if let note = row["edited_note"] { row["note"] = note }
        return ActionRecord(id: row["id"]!, claimID: row["claim_id"]!, claimReviewVersion: Int(row["claim_review_version"]!)!, title: row["title"]!, kind: row["kind"]!, intentActor: row["intent_actor"]!, note: row["note"]!, state: row["state"]!, validity: row["validity"]!, version: Int(row["version"]!)!, autoSend: row["auto_send"] == "1", intent: try row["intent_json"].map { try JSONDecoder().decode(ActionIntentMetadata.self, from: Data($0.utf8)) }, commandID: row["command_id"]!, createdAt: row["created_at"]!, parentID: row["parent_id"], nature: row["nature"] ?? "unknown", completedAt: row["completed_at"])
    }
    public func editAction(_ action: ActionRecord, title: String, note: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= 2000, note.unicodeScalars.count <= 2000 else {
            throw VoiceOSError("请填写标题，标题和说明各可保存 2000 字。")
        }
        try writeActionContent(action, title: title, note: note)
    }

    public func removeAction(_ action: ActionRecord) throws {
        try writeActionContent(action, title: nil, note: nil)
    }

    private func writeActionContent(_ action: ActionRecord, title: String?, note: String?) throws {
        try db.transaction {
            guard let row = try db.query("SELECT state FROM actions WHERE id=? AND version=? AND validity='current' AND removed=0",
                                         [action.id, String(action.version)]).first else {
                throw VoiceOSError("行动已变化，请重新打开后编辑。")
            }
            let next = String(action.version + 1)
            let hash = try Self.actionHash([action.id, String(action.version), title ?? "", note ?? ""])
            if let title {
                try db.execute("UPDATE actions SET edited_title=?,edited_note=?,version=? WHERE id=?", [title, note, next, action.id])
            } else {
                try db.execute("DELETE FROM action_recurrence WHERE action_id=?", [action.id])
                try db.execute("UPDATE actions SET removed=1,validity='frozen',version=? WHERE id=?", [next, action.id])
            }
            try db.execute("""
                INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at)
                VALUES(?,?,?,?,?,?,'user',?,?,?)
                """, [UUID().uuidString, action.id, next, String(action.version), row["state"], title ?? "已删除",
                      "content:" + UUID().uuidString, hash, Self.now()])
        }
    }

    /// Active outcomes with no open next action.
    public func stalledOutcomes() throws -> [ActionRecord] {
        _ = try candidateClaims(includeFrozen: true)
        return try db.query("""
            SELECT a.*,\(Self.completedAtColumn) FROM actions a
            WHERE a.kind='opportunity' AND a.nature='goal' AND a.state='open' AND a.validity='current'
              AND NOT EXISTS (SELECT 1 FROM actions c WHERE c.parent_id=a.id AND c.state='open' AND c.removed=0)
            ORDER BY a.created_at,a.id
            """).map(Self.actionRecord)
    }
    public func openQuestions() throws -> [ActionRecord] { try scopedOutcomes(nature: .question) }
    public func openGoals() throws -> [ActionRecord] { try scopedOutcomes(nature: .goal) }
    public func untriagedSuggestions() throws -> [ActionRecord] { try scopedOutcomes(nature: .unknown) }
    private func scopedOutcomes(nature: ActionNature) throws -> [ActionRecord] {
        _ = try candidateClaims(includeFrozen: true)
        return try db.query("SELECT a.*,\(Self.completedAtColumn) FROM actions a WHERE a.kind='opportunity' AND a.nature=? AND a.state='open' AND a.validity='current' ORDER BY a.created_at,a.id", [nature.rawValue]).map(Self.actionRecord)
    }
    /// Next steps are the goal's open, current children; completed steps are its
    /// completed children. The clock is the newest revision across the goal and
    /// its children, falling back to when the goal was created.
    public func goalProgress(actionID: String) throws -> GoalProgress {
        _ = try candidateClaims(includeFrozen: true)
        guard let goalCreatedAt = try db.query("SELECT created_at FROM actions WHERE id=?", [actionID]).first?["created_at"] else {
            return GoalProgress(nextSteps: 0, completedSteps: 0, lastActivityAt: nil)
        }
        let counts = try db.query("""
            SELECT
              (SELECT COUNT(*) FROM actions WHERE parent_id=? AND state='open' AND validity='current') AS next_steps,
              (SELECT COUNT(*) FROM actions WHERE parent_id=? AND state='completed' AND removed=0) AS completed_steps
            """, [actionID, actionID]).first
        let lastRevision = try db.query("""
            SELECT MAX(created_at) AS last_at FROM action_revisions
            WHERE action_id=? OR action_id IN (SELECT id FROM actions WHERE parent_id=?)
            """, [actionID, actionID]).first?["last_at"]
        return GoalProgress(nextSteps: Int(counts?["next_steps"] ?? "") ?? 0,
                            completedSteps: Int(counts?["completed_steps"] ?? "") ?? 0,
                            lastActivityAt: lastRevision ?? goalCreatedAt)
    }
    @discardableResult
    public func confirmOpportunityAsTask(actionID: String, expectedVersion: Int, title: String, commandID: String = UUID().uuidString) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "confirmed-intent:" + commandID, sourceCommand = "confirmed-intent-source:" + commandID
        if let receipt = try db.query("SELECT * FROM actions WHERE command_id=?", [command]).first {
            guard receipt["title"] == title, let revision = try db.query("SELECT * FROM action_revisions WHERE command_id=?", [sourceCommand]).first,
                  revision["action_id"] == actionID, revision["from_version"] == String(expectedVersion) else { throw VoiceOSError("同一次核对不能更换事项或标题") }
            return receipt["id"]!
        }
        guard !title.isEmpty, title.unicodeScalars.count <= 2000,
              let original = try self.action(id: actionID, includeHistory: true),
              original.validity == "current", original.state == "open", original.kind == "opportunity", original.intentActor == "user", original.version == expectedVersion,
              let claim = try candidateClaim(id: original.claimID), claim.reviewVersion == original.claimReviewVersion else { throw VoiceOSError("事项或原话已变化，请重新核对") }
        let id = UUID().uuidString, now = ISO8601DateFormatter().string(from: Date())
        let fingerprint = try Self.actionHash([claim.id,String(claim.reviewVersion),title,"task","user",original.note])
        let note = "已核对为明确待办：" + id
        let revisionHash = try Self.actionHash([actionID,String(expectedVersion),"dismissed",note])
        let metadata = ActionIntentMetadata(intentType: "task", followupState: "pending", uncertain: false)
        // Keep the model's original opportunity; the user's decision creates a task and retires its old card together.
        try db.transaction {
            try db.execute("INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,command_id,input_fingerprint,created_at,intent_json) VALUES(?,?,?,?,'task','user',?,'open','current',?,?,?,?)", [id,claim.id,String(claim.reviewVersion),title,original.note,command,fingerprint,now,String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)])
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'dismissed',?,'user',?,?,?)", [UUID().uuidString,actionID,String(expectedVersion+1),String(expectedVersion),note,sourceCommand,revisionHash,now])
            try db.execute("UPDATE actions SET state='dismissed',version=? WHERE id=?", [String(expectedVersion+1),actionID])
        }
        return id
    }
    @discardableResult
    public func setActionState(actionID: String, expectedVersion: Int, state: LocalActionState, note: String = "", commandID: String = UUID().uuidString) throws -> Int {
        guard !commandID.hasPrefix("reminder-status-resolution:") else { throw VoiceOSError("提醒事项状态恢复须绑定回读依据，不能使用普通状态命令") }
        let hash = try Self.actionHash([actionID,String(expectedVersion),state.rawValue,note])
        if let receipt = try db.query("SELECT * FROM action_revisions WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一行动状态命令不能更换内容") }
            return Int(receipt["version"]!)!
        }
        guard let current = try self.action(id: actionID, includeHistory: true), current.validity == "current",
              current.version == expectedVersion else { throw VoiceOSError("行动版本或依据已变化，请重新核对") }
        guard state.rawValue != current.state, note.unicodeScalars.count <= 2000 else { throw VoiceOSError("行动状态没有变化或备注过长") }
        guard state != .completed || current.kind == "task" else { throw VoiceOSError("探索意图与 AI 建议不能标成任务完成；问题与目标的完成请使用 completeOutcome") }
        guard state != .someday || current.kind != "task" else { throw VoiceOSError("待办不能留到将来也许；请完成或不再跟进") }
        let next = expectedVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,'user',?,?,?)", [UUID().uuidString,actionID,String(next),String(expectedVersion),state.rawValue,note,commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET state=?,version=? WHERE id=?", [state.rawValue,String(next),actionID])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return next
    }
    /// Retracts a user-confirmed external completion. The task returns to open
    /// and stays frozen, because only the confirmation is withdrawn; the
    /// read-back evidence and the external reminder are untouched.
    @discardableResult
    public func revertExternalCompletion(actionID: String, expectedVersion: Int, commandID: String = UUID().uuidString) throws -> Int {
        let command = "external-completion-undo:" + commandID
        let note = "撤销外部完成确认；任务保持冻结，Apple 提醒事项未修改"
        let hash = try Self.actionHash([actionID, String(expectedVersion), LocalActionState.open.rawValue])
        if let receipt = try db.query("SELECT version,input_fingerprint FROM action_revisions WHERE command_id=?", [command]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一次撤销外部完成不能更换任务或版本") }
            return Int(receipt["version"]!)!
        }
        guard let current = try self.action(id: actionID, includeHistory: true),
              current.kind == "task", current.validity == "frozen",
              current.state == LocalActionState.completed.rawValue, current.version == expectedVersion,
              let latest = try db.query("SELECT state,command_id FROM action_revisions WHERE action_id=? ORDER BY version DESC LIMIT 1", [actionID]).first,
              latest["state"] == LocalActionState.completed.rawValue,
              latest["command_id"]?.hasPrefix(Self.externalCompletionCommandPrefix) == true else {
            throw VoiceOSError("只有刚确认外部完成、且没有后续变更的任务可以撤销")
        }
        let next = expectedVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,'user',?,?,?)", [UUID().uuidString, actionID, String(next), String(expectedVersion), LocalActionState.open.rawValue, note, command, hash, ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET state=?,version=? WHERE id=?", [LocalActionState.open.rawValue, String(next), actionID])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return next
    }
    /// Reclassifies an action's pool membership. The revision ledger records the
    /// same-state change so a replay stays idempotent.
    @discardableResult
    public func setActionNature(id: String, expectedVersion: Int, nature: ActionNature, commandID: String = UUID().uuidString) throws -> Int {
        let revisionCommand = "nature:" + commandID
        let note = "归类：" + nature.label
        let hash = try Self.actionHash([id,String(expectedVersion),nature.rawValue])
        if let receipt = try db.query("SELECT * FROM action_revisions WHERE command_id=?", [revisionCommand]).first {
            guard receipt["input_fingerprint"] == hash, receipt["action_id"] == id, receipt["from_version"] == String(expectedVersion) else { throw VoiceOSError("同一次归类不能更换行动或归类") }
            return Int(receipt["version"]!)!
        }
        guard let current = try self.action(id: id, includeHistory: true) else { throw VoiceOSError("行动不存在") }
        guard current.validity == "current" else { throw VoiceOSError("已失效的行动不能归类") }
        guard current.version == expectedVersion else { throw VoiceOSError("行动版本已变化，请重新核对") }
        guard current.nature != nature.rawValue else { throw VoiceOSError("行动归类没有变化") }
        let next = expectedVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,'user',?,?,?)", [UUID().uuidString,id,String(next),String(expectedVersion),current.state,note,revisionCommand,hash,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET nature=?,version=? WHERE id=?", [nature.rawValue,String(next),id])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return next
    }
    /// Completing an outcome is separate from completing a task. A task keeps
    /// using `setActionState`; only an opportunity goal takes this path.
    @discardableResult
    public func completeOutcome(actionID: String, expectedVersion: Int, commandID: String = UUID().uuidString) throws -> Int {
        let note = "目标达成"
        let hash = try Self.actionHash([actionID,String(expectedVersion),LocalActionState.completed.rawValue,note])
        if let receipt = try db.query("SELECT version,input_fingerprint FROM action_revisions WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一完成目标命令不能更换内容") }
            return Int(receipt["version"]!)!
        }
        guard let current = try self.action(id: actionID, includeHistory: true) else { throw VoiceOSError("行动不存在") }
        guard current.kind == "opportunity" else { throw VoiceOSError("只有问题与目标可以达成") }
        guard current.state == "open" else { throw VoiceOSError("只有未完成的问题与目标可以达成") }
        guard current.validity == "current" else { throw VoiceOSError("已失效的问题与目标不能达成") }
        guard current.version == expectedVersion else { throw VoiceOSError("行动版本已变化，请重新核对") }
        let next = expectedVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'completed',?,'user',?,?,?)", [UUID().uuidString,actionID,String(next),String(expectedVersion),note,commandID,hash,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET state='completed',version=? WHERE id=?", [String(next),actionID])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return next
    }
    /// Hangs a task under an outcome. The child starts unattached, so the same
    /// command cannot silently re-target an already attached task.
    @discardableResult
    public func attachNextAction(outcomeID: String, actionID: String, commandID: String = UUID().uuidString) throws -> Int {
        let note = "添加下一步"
        let revisionCommand = "attach:" + commandID
        let hash = try Self.actionHash([outcomeID,actionID,note])
        if let receipt = try db.query("SELECT action_id,version,input_fingerprint FROM action_revisions WHERE command_id=?", [revisionCommand]).first {
            guard receipt["action_id"] == actionID, receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一添加下一步命令不能更换目标或行动") }
            return Int(receipt["version"]!)!
        }
        guard let outcome = try self.action(id: outcomeID, includeHistory: true) else { throw VoiceOSError("目标不存在") }
        guard outcome.kind == "opportunity" else { throw VoiceOSError("下一步只能挂在问题与目标下") }
        guard outcome.state == "open", outcome.validity == "current" else { throw VoiceOSError("只有未完成且有效的问题与目标可以添加下一步") }
        guard let child = try self.action(id: actionID, includeHistory: true) else { throw VoiceOSError("行动不存在") }
        guard child.kind == "task" else { throw VoiceOSError("只有待办可以作为下一步") }
        guard child.state == "open", child.validity == "current" else { throw VoiceOSError("只有未完成且有效的待办可以作为下一步") }
        guard child.parentID == nil else { throw VoiceOSError("这条待办已经挂在目标下") }
        try Self.rejectNextActionCycle(db, outcomeID: outcomeID, actionID: actionID)
        let next = child.version + 1
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'open',?,'user',?,?,?)", [UUID().uuidString,actionID,String(next),String(child.version),note,revisionCommand,hash,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET parent_id=?,version=? WHERE id=?", [outcomeID,String(next),actionID])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return next
    }
    @discardableResult
    public func detachNextAction(actionID: String, expectedVersion: Int, commandID: String = UUID().uuidString) throws -> Int {
        let note = "摘除下一步"
        let revisionCommand = "detach:" + commandID
        let hash = try Self.actionHash([actionID,String(expectedVersion),note])
        if let receipt = try db.query("SELECT version,input_fingerprint FROM action_revisions WHERE command_id=?", [revisionCommand]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一摘除下一步命令不能更换行动") }
            return Int(receipt["version"]!)!
        }
        guard let child = try self.action(id: actionID, includeHistory: true) else { throw VoiceOSError("行动不存在") }
        guard child.kind == "task" else { throw VoiceOSError("只有待办可以作为目标下一步") }
        guard child.parentID != nil else { throw VoiceOSError("这条待办没有挂在目标下") }
        guard child.version == expectedVersion else { throw VoiceOSError("行动版本已变化，请重新核对") }
        let next = expectedVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,'user',?,?,?)", [UUID().uuidString,actionID,String(next),String(expectedVersion),child.state,note,revisionCommand,hash,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET parent_id=NULL,version=? WHERE id=?", [String(next),actionID])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return next
    }
    /// Kind changes would strand children: a goal owning open next actions must
    /// stay an opportunity, and a task under a goal must not become one. The
    /// export validator rejects either shape on restore.
    private static func rejectNextActionKindChange(_ db: Database, action: ActionRecord) throws {
        guard action.parentID == nil else { throw VoiceOSError("这条行动属于某个目标") }
        if action.kind == "opportunity" {
            let openChildren = try db.query("SELECT id FROM actions WHERE parent_id=? AND state='open' LIMIT 1", [action.id])
            guard openChildren.isEmpty else { throw VoiceOSError("目标已有下一步，请先摘除") }
        }
    }
    private static func rejectNextActionCycle(_ db: Database, outcomeID: String, actionID: String) throws {
        var seen: Set<String> = []
        var cursor: String? = outcomeID
        while let current = cursor {
            guard seen.insert(current).inserted, current != actionID else { throw VoiceOSError("下一步归属不能成环") }
            cursor = try db.query("SELECT parent_id FROM actions WHERE id=?", [current]).first?["parent_id"]
        }
    }
    /// Receipts are authoritative; the revision marker also keeps restored
    /// packages valid, because the older package format omits the receipt table.
    static func clarifiedOpportunityActionIDs(_ db: Database) throws -> Set<String> {
        var ids = Set(try db.query("SELECT action_id FROM action_clarifications WHERE decision='opportunity'").compactMap { $0["action_id"] })
        ids.formUnion(try db.query("SELECT action_id FROM action_revisions WHERE command_id LIKE 'clarify:%' AND note='澄清为问题与目标'").compactMap { $0["action_id"] })
        return ids
    }
    /// Kind overrides the user made in place; the claim keeps its extracted kind.
    static func promotedActionIDs(_ db: Database) throws -> Set<String> {
        Set(try db.query("SELECT action_id FROM action_revisions WHERE command_id LIKE 'promote:%' AND note='转为待办'").compactMap { $0["action_id"] })
    }
    /// One additive clarification per extracted action. The receipt is the
    /// idempotency boundary; opportunity and not also append a revision so the
    /// action version chain stays complete.
    @discardableResult
    public func clarifyAction(actionID: String, expectedVersion: Int, decision: ActionClarificationDecision, commandID: String = UUID().uuidString) throws -> Int {
        if let receipt = try db.query("SELECT action_id,decision FROM action_clarifications WHERE command_id=?", [commandID]).first {
            guard receipt["action_id"] == actionID, receipt["decision"] == decision.rawValue else { throw VoiceOSError("同一澄清命令不能更换行动或判断") }
            return try db.query("SELECT version FROM actions WHERE id=?", [actionID]).first?["version"].flatMap(Int.init) ?? expectedVersion
        }
        guard let action = try self.action(id: actionID, includeHistory: true) else { throw VoiceOSError("行动不存在") }
        try Self.rejectNextActionKindChange(db, action: action)
        guard action.isExtracted, action.state == "open", action.validity == "current", action.version == expectedVersion else {
            throw VoiceOSError("只有抽取得到且仍有效的未完成行动可以澄清")
        }
        guard try db.query("SELECT action_id FROM action_clarifications WHERE action_id=?", [actionID]).isEmpty else {
            throw VoiceOSError("这条行动已经澄清过一次")
        }
        let now = ISO8601DateFormatter().string(from: Date())
        try db.transaction {
            try db.execute("INSERT INTO action_clarifications(action_id,decision,command_id,created_at) VALUES(?,?,?,?)", [actionID,decision.rawValue,commandID,now])
            guard decision != .commit else { return }
            guard decision != .opportunity || action.kind != "opportunity" else { return }
            let next = expectedVersion + 1
            let state = decision == .opportunity ? "open" : "dismissed"
            let note = decision == .opportunity ? "澄清为问题与目标" : "澄清后不再跟进"
            let revisionCommand = "clarify:" + commandID
            let hash = try Self.actionHash([actionID,String(expectedVersion),decision.rawValue,note])
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,'user',?,?,?)", [UUID().uuidString,actionID,String(next),String(expectedVersion),state,note,revisionCommand,hash,now])
            if decision == .opportunity {
                let actor = action.intentActor == "ai" ? "user" : action.intentActor
                try db.execute("UPDATE reminder_compensation_plans SET validity='frozen' WHERE action_id=? AND validity='current'", [actionID])
                try db.execute("UPDATE actions SET kind='opportunity',intent_actor=?,version=? WHERE id=?", [actor,String(next),actionID])
            } else {
                try db.execute("UPDATE actions SET state='dismissed',version=? WHERE id=?", [String(next),actionID])
            }
        }
        let bumped = decision == .not || (decision == .opportunity && action.kind != "opportunity")
        return bumped ? expectedVersion + 1 : expectedVersion
    }
    /// One-way user promotion. The revision is the receipt, so a repeat with the
    /// same command returns the same version without writing again.
    @discardableResult
    public func promoteAction(actionID: String, expectedVersion: Int, commandID: String = UUID().uuidString) throws -> Int {
        let note = "转为待办"
        let revisionCommand = "promote:" + commandID
        let hash = try Self.actionHash([actionID,String(expectedVersion),note])
        if let receipt = try db.query("SELECT version,input_fingerprint FROM action_revisions WHERE command_id=?", [revisionCommand]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一提升命令不能更换行动或内容") }
            return Int(receipt["version"]!)!
        }
        guard let action = try self.action(id: actionID, includeHistory: true) else { throw VoiceOSError("行动不存在") }
        try Self.rejectNextActionKindChange(db, action: action)
        guard action.kind == "opportunity" else { throw VoiceOSError("只有问题与目标可以转为待办") }
        guard action.state == "open" else { throw VoiceOSError("只有未完成的问题与目标可以转为待办") }
        guard action.validity == "current" else { throw VoiceOSError("已失效的问题与目标不能转为待办") }
        guard action.version == expectedVersion else { throw VoiceOSError("行动版本已变化，请重新核对") }
        let next = expectedVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'open',?,'user',?,?,?)", [UUID().uuidString,actionID,String(next),String(expectedVersion),note,revisionCommand,hash,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET kind='task',intent_actor='user',version=? WHERE id=?", [String(next),actionID])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return next
    }
    /// The clarify queue's command identity. A retry with the same goal, exit,
    /// and version resolves to the same receipt; anything else is a new command.
    public static func clarifyCommandID(actionID: String, exit: ActionClarifyExit, version: Int) -> String {
        "clarify:\(actionID):\(exit.rawValue):\(String(version))"
    }
    /// Keeps a someday goal in place and stamps the ledger so the review clock
    /// restarts. Same-state revisions need the dedicated `revisit:` receipt.
    @discardableResult
    public func revisitSomeday(actionID: String, expectedVersion: Int, commandID: String = UUID().uuidString) throws -> Int {
        let note = "回看"
        let revisionCommand = "revisit:" + commandID
        let hash = try Self.actionHash([actionID,String(expectedVersion),note])
        if let receipt = try db.query("SELECT version,input_fingerprint FROM action_revisions WHERE command_id=?", [revisionCommand]).first {
            guard receipt["input_fingerprint"] == hash else { throw VoiceOSError("同一次回看命令不能更换行动") }
            return Int(receipt["version"]!)!
        }
        guard let current = try self.action(id: actionID, includeHistory: true) else { throw VoiceOSError("行动不存在") }
        guard current.state == LocalActionState.someday.rawValue, current.validity == "current" else { throw VoiceOSError("只有留到以后的行动可以回看") }
        guard current.version == expectedVersion else { throw VoiceOSError("行动版本已变化，请重新核对") }
        let next = expectedVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'someday',?,'user',?,?,?)", [UUID().uuidString,actionID,String(next),String(expectedVersion),note,revisionCommand,hash,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET version=? WHERE id=?", [String(next),actionID])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return next
    }
    /// Someday goals not revisited within `unreviewedDays`. Falls back to when
    /// the goal entered someday, then to its creation date.
    public func somedayReviewCandidates(unreviewedDays: Int = 60, now: Date = Date()) throws -> [ActionRecord] {
        _ = try candidateClaims(includeFrozen: true)
        let cutoff = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(unreviewedDays) * 86400))
        return try db.query("""
            SELECT a.* FROM actions a
            WHERE a.state='someday' AND a.validity='current'
              AND COALESCE(
                (SELECT MAX(r.created_at) FROM action_revisions r WHERE r.action_id=a.id AND r.note LIKE '回看%'),
                (SELECT MAX(r.created_at) FROM action_revisions r WHERE r.action_id=a.id AND r.state='someday'),
                a.created_at) < ?
            ORDER BY a.created_at,a.id
            """, [cutoff]).map(Self.actionRecord)
    }
    public func actionClarifications() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT action_id,decision FROM action_clarifications").map { ($0["action_id"]!, $0["decision"]!) })
    }
    public func actionHistory(actionID: String) throws -> [ActionRevision] {
        guard let initial = try db.query("SELECT * FROM actions WHERE id=?", [actionID]).first else { throw VoiceOSError("行动不存在") }
        return [ActionRevision(id: actionID, version: 1, state: "open", note: initial["note"]!, createdAt: initial["created_at"]!, actor: initial["intent_actor"]!)] + (try db.query("SELECT * FROM action_revisions WHERE action_id=? ORDER BY version", [actionID])).map {
            ActionRevision(id: $0["id"]!, version: Int($0["version"]!)!, state: $0["state"]!, note: $0["note"]!, createdAt: $0["created_at"]!, actor: $0["actor"]!)
        }
    }
    /// Read-only ledger for the detail views. Newest first; writes within the
    /// same second fall back to version so the order stays stable.
    public func actionRevisions(actionID: String) throws -> [ActionRevisionRecord] {
        try db.query("SELECT id,version,from_version,state,note,actor,command_id,created_at FROM action_revisions WHERE action_id=? ORDER BY created_at DESC,version DESC", [actionID]).map {
            ActionRevisionRecord(id: $0["id"]!, version: Int($0["version"]!)!, fromVersion: Int($0["from_version"]!)!, state: $0["state"]!, note: $0["note"]!, actor: $0["actor"]!, commandID: $0["command_id"]!, createdAt: $0["created_at"]!)
        }
    }
    static func actionHash(_ fields: [String]) throws -> String {
        SHA256.hash(data: try JSONSerialization.data(withJSONObject: fields)).map { String(format: "%02x", $0) }.joined()
    }
    static func validateStoredActions(_ db: Database) throws {
        for action in try db.query("SELECT a.*,c.review_version AS latest_review,c.validity AS claim_validity,c.ownership AS original_owner FROM actions a JOIN claims c ON c.id=a.claim_id") {
            _ = try validatedExpressionHistory(db,action:action)
            guard let pinned = action["claim_review_version"].flatMap(Int.init), let latest = action["latest_review"].flatMap(Int.init), pinned >= 0, pinned <= latest,
                  let title = action["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.unicodeScalars.count <= 2000,
                  ActionNature(rawValue: action["nature"] ?? "") != nil,
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
                let kindClarification = revision["state"] == state && revision["command_id"]?.hasPrefix("clarify:") == true
                let kindPromotion = revision["state"] == state && revision["command_id"]?.hasPrefix("promote:") == true
                let attachLink = revision["command_id"]?.hasPrefix("attach:") == true
                let detachLink = revision["command_id"]?.hasPrefix("detach:") == true
                let nextActionLink = revision["state"] == state && (attachLink || detachLink)
                let revisit = revision["state"] == state && revision["command_id"]?.hasPrefix("revisit:") == true
                let contentChange = revision["command_id"]?.hasPrefix("content:") == true && revision["state"] == state
                let natureChange = revision["state"] == state && revision["command_id"]?.hasPrefix("nature:") == true
                guard revision["version"] == String(index+2), revision["from_version"] == String(index+1), let next = revision["state"], next != state || kindClarification || kindPromotion || nextActionLink || revisit || natureChange || contentChange,
                      next != "completed" || action["kind"] == "task" || action["kind"] == "opportunity", (revision["note"]?.unicodeScalars.count ?? 2001) <= 2000 else { throw VoiceOSError("迁移行动状态链不一致") }
                if kindClarification, revision["note"] != "澄清为问题与目标" {
                    throw VoiceOSError("行动版本升级缺少澄清依据")
                }
                if kindPromotion, revision["note"] != "转为待办" {
                    throw VoiceOSError("行动版本升级缺少提升依据")
                }
                if attachLink, revision["note"] != "添加下一步" {
                    throw VoiceOSError("行动版本升级缺少添加下一步依据")
                }
                if detachLink, revision["note"] != "摘除下一步" {
                    throw VoiceOSError("行动版本升级缺少摘除下一步依据")
                }
                if revisit, revision["note"] != "回看" {
                    throw VoiceOSError("行动版本升级缺少回看依据")
                }
                if natureChange, !(revision["note"]?.hasPrefix("归类：") == true && ActionNature(label: String((revision["note"] ?? "").dropFirst("归类：".count))) != nil) {
                    throw VoiceOSError("行动版本升级缺少归类依据")
                }
                state = next
            }
            guard state == action["state"] else { throw VoiceOSError("迁移行动当前状态与历史不一致") }
        }
        let links = try db.query("SELECT id,kind,parent_id FROM actions")
        var parentByID: [String: String] = [:]
        var kindByID: [String: String] = [:]
        for row in links {
            kindByID[row["id"]!] = row["kind"]
            if let parent = row["parent_id"] { parentByID[row["id"]!] = parent }
        }
        for (id, parent) in parentByID {
            guard kindByID[parent] == "opportunity" else { throw VoiceOSError("迁移行动的下一步必须指向存在的问题与目标") }
            var seen: Set<String> = [id]
            var cursor = parent
            while true {
                guard seen.insert(cursor).inserted else { throw VoiceOSError("迁移行动的下一步归属成环") }
                guard let next = parentByID[cursor] else { break }
                cursor = next
            }
        }
        try validateStoredActionSchedules(db)
        try validateReminderScheduleBases(db)
        try validateReminderScheduleGrants(db)
        try validateReminderScheduleOperations(db)
        try validateReminderCompensations(db)
    }
}
