import Foundation

public struct ActionSubtask: Identifiable, Sendable {
    public let id: String
    public let actionID: String
    public let title: String
    public let done: Bool
    public let ordinal: Int
    public let createdAt: String
    public let completedAt: String?
}

extension VoiceOSStore {
    public func subtasks(actionID: String) throws -> [ActionSubtask] {
        try db.query("SELECT * FROM action_subtasks WHERE action_id=? ORDER BY ordinal", [actionID]).map { row in
            guard let id = row["id"], let actionID = row["action_id"], let title = row["title"], let done = row["done"],
                  let ordinal = row["ordinal"].flatMap(Int.init), let createdAt = row["created_at"] else {
                throw VoiceOSError("子任务记录损坏")
            }
            return ActionSubtask(id: id, actionID: actionID, title: title, done: done == "1", ordinal: ordinal, createdAt: createdAt, completedAt: row["completed_at"])
        }
    }

    @discardableResult
    public func addSubtask(actionID: String, title: String) throws -> ActionSubtask {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= 200 else { throw VoiceOSError("子任务标题需为 1 到 200 字") }
        guard try db.query("SELECT id FROM actions WHERE id=?", [actionID]).first != nil else { throw VoiceOSError("行动不存在") }
        let id = UUID().uuidString, now = Self.now()
        var ordinal = 0
        try db.transaction {
            guard let next = try db.query("SELECT COALESCE(MAX(ordinal),-1)+1 AS next FROM action_subtasks WHERE action_id=?", [actionID]).first?["next"].flatMap(Int.init) else {
                throw VoiceOSError("子任务顺序损坏")
            }
            ordinal = next
            try db.execute("INSERT INTO action_subtasks(id,action_id,title,done,ordinal,created_at) VALUES(?,?,?,0,?,?)", [id, actionID, title, String(ordinal), now])
        }
        return ActionSubtask(id: id, actionID: actionID, title: title, done: false, ordinal: ordinal, createdAt: now, completedAt: nil)
    }

    @discardableResult
    public func setSubtaskDone(id: String, done: Bool) throws -> ActionSubtask {
        guard let row = try db.query("SELECT * FROM action_subtasks WHERE id=?", [id]).first else { throw VoiceOSError("子任务不存在") }
        guard let actionID = row["action_id"], let title = row["title"], let ordinal = row["ordinal"].flatMap(Int.init), let createdAt = row["created_at"] else {
            throw VoiceOSError("子任务记录损坏")
        }
        let completedAt = done ? (row["completed_at"] ?? Self.now()) : nil
        try db.execute("UPDATE action_subtasks SET done=?,completed_at=? WHERE id=?", [done ? "1" : "0", completedAt, id])
        return ActionSubtask(id: id, actionID: actionID, title: title, done: done, ordinal: ordinal, createdAt: createdAt, completedAt: completedAt)
    }

    public func deleteSubtask(id: String) throws {
        try db.execute("DELETE FROM action_subtasks WHERE id=?", [id])
    }
}
