import Foundation

extension VoiceOSStore {
    public func actionEstimates() throws -> [String: Int] {
        var estimates: [String: Int] = [:]
        for row in try db.query("SELECT action_id,minutes FROM action_estimates") {
            guard let actionID = row["action_id"], let minutes = row["minutes"].flatMap(Int.init) else { throw VoiceOSError("行动时长记录损坏") }
            estimates[actionID] = minutes
        }
        return estimates
    }

    public func setActionEstimate(actionID: String, minutes: Int) throws {
        guard [15, 30, 60].contains(minutes) else { throw VoiceOSError("预计时长只能为 15、30 或 60 分钟") }
        guard try db.query("SELECT id FROM actions WHERE id=?", [actionID]).first != nil else { throw VoiceOSError("行动不存在") }
        try db.execute("""
        INSERT INTO action_estimates(action_id,minutes,updated_at) VALUES(?,?,?)
        ON CONFLICT(action_id) DO UPDATE SET minutes=excluded.minutes,updated_at=excluded.updated_at
        """, [actionID, String(minutes), Self.now()])
    }

    public func clearActionEstimate(actionID: String) throws {
        try db.execute("DELETE FROM action_estimates WHERE action_id=?", [actionID])
    }
}
