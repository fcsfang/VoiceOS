import Foundation

extension VoiceOSStore {
    public func focusedActionIDs() throws -> Set<String> {
        Set(try db.query("""
        SELECT f.action_id FROM action_focus f JOIN actions a ON a.id=f.action_id
        WHERE a.validity='current' AND a.state='open'
        """).compactMap { $0["action_id"] })
    }

    @discardableResult
    public func toggleActionFocus(actionID: String) throws -> Bool {
        let existing = try db.query("SELECT action_id FROM action_focus WHERE action_id=?", [actionID])
        if !existing.isEmpty {
            try db.execute("DELETE FROM action_focus WHERE action_id=?", [actionID])
            return false
        }
        guard let action = try db.query("SELECT validity,state FROM actions WHERE id=?", [actionID]).first,
              action["validity"] == "current", action["state"] == "open" else { throw VoiceOSError("行动不存在或已关闭") }
        try db.transaction {
            let focused = try db.query("""
            SELECT f.action_id FROM action_focus f JOIN actions a ON a.id=f.action_id
            WHERE a.validity='current' AND a.state='open'
            """).count
            guard focused < 3 else { throw VoiceOSError("最多只能置顶 3 条专注行动") }
            try db.execute("INSERT INTO action_focus(action_id,created_at) VALUES(?,?)", [actionID, ISO8601DateFormatter().string(from: Date())])
        }
        return true
    }
}
