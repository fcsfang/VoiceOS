import Foundation

/// The one UI entry for a frozen open task whose linked reminder was completed
/// outside VoiceOS. It derives eligibility from the same evidence the store
/// re-checks, so the button cannot offer a confirmation the store refuses.
public struct ExternalCompletionCandidate: Sendable, Equatable {
    public let actionID: String
    public let expectedVersion: Int
    public let linkID: String
    public let observationID: String
    public var commandID: String { "external-completion-ui:" + actionID + ":" + observationID }

    public init?(action: ActionRecord, link: ReminderLink?) {
        guard action.kind == "task", action.validity == "frozen", action.state == "open",
              let link, link.actionID == action.id, link.state == "linked",
              link.remoteMarkerValid == true, link.remoteCompleted == true,
              let observationID = link.lastObservationID, !observationID.isEmpty else { return nil }
        self.actionID = action.id
        self.expectedVersion = action.version
        self.linkID = link.id
        self.observationID = observationID
    }
}

extension VoiceOSStore {
    /// A frozen task stays in the result queue only through a revision carrying
    /// this prefix at its current version; the observation row alone proves nothing.
    static let externalCompletionCommandPrefix = "external-completion:"

    /// Records the user's explicit confirmation that a frozen task's linked
    /// reminder was completed outside VoiceOS. It never unfreezes claims or
    /// understanding, never changes validity, and never writes external data.
    @discardableResult
    public func confirmExternalCompletion(actionID: String, expectedVersion: Int, linkID: String,
                                          expectedObservationID: String,
                                          commandID: String = UUID().uuidString) throws -> Int {
        let command = Self.externalCompletionCommandPrefix + commandID
        let fingerprint = try Self.actionHash([actionID, String(expectedVersion), linkID, expectedObservationID])
        if let receipt = try db.query("SELECT version,input_fingerprint FROM action_revisions WHERE command_id=?", [command]).first {
            guard receipt["input_fingerprint"] == fingerprint else { throw VoiceOSError("同一次外部完成确认不能更换任务、版本或观测") }
            return Int(receipt["version"]!)!
        }
        guard let action = try db.query("SELECT * FROM actions WHERE id=?", [actionID]).first else { throw VoiceOSError("任务不存在") }
        guard action["kind"] == "task" else { throw VoiceOSError("只有明确任务可以登记外部完成") }
        guard action["validity"] == "frozen" else { throw VoiceOSError("只有已冻结的任务需要登记外部完成") }
        guard let version = action["version"].flatMap(Int.init), version == expectedVersion else { throw VoiceOSError("任务版本已变化，请重新核对") }
        switch action["state"] {
        case "open": break
        case "completed": throw VoiceOSError("任务已完成，不能重复登记外部完成")
        default: throw VoiceOSError("已撤回的任务不能登记外部完成")
        }
        guard let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [linkID]).first else { throw VoiceOSError("提醒事项关联不存在") }
        guard link["action_id"] == actionID else { throw VoiceOSError("提醒事项关联与任务不符") }
        guard link["state"] == "linked" else { throw VoiceOSError("提醒事项关联尚未确认，请先回读后再登记") }
        guard let observation = try db.query("SELECT * FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [linkID]).first,
              observation["id"] == expectedObservationID else { throw VoiceOSError("提醒事项观测已变化，请查看最新回读后再确认") }
        guard observation["marker_valid"] == "1" else { throw VoiceOSError("提醒事项标记无效，不能确认是同一任务") }
        guard observation["completed"] == "1" else { throw VoiceOSError("最新观测尚未显示提醒事项完成") }
        guard let externalID = observation["external_id"], externalID == link["external_id"], !externalID.isEmpty else { throw VoiceOSError("提醒事项外部身份不一致，不能登记完成") }
        let next = version + 1
        let note = "用户确认提醒事项观测 " + expectedObservationID + " 已完成；原始冻结声明与理解继续保留"
        try db.transaction {
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'completed',?,'user',?,?,?)",
                           [UUID().uuidString, actionID, String(next), String(version), note, command, fingerprint, ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET state='completed',version=? WHERE id=?", [String(next), actionID])
        }
        return next
    }
}
