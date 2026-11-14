import Foundation

public struct CaptureTemplate: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let body: String
    public let createdAt: String
}

extension VoiceOSStore {
    public func captureTemplates() throws -> [CaptureTemplate] {
        try db.query("SELECT * FROM capture_templates ORDER BY created_at,rowid").map { row in
            guard let id = row["id"], let name = row["name"], let body = row["body"], let createdAt = row["created_at"] else {
                throw VoiceOSError("模板记录损坏")
            }
            return CaptureTemplate(id: id, name: name, body: body, createdAt: createdAt)
        }
    }

    @discardableResult
    public func saveCaptureTemplate(name: String, body: String) throws -> CaptureTemplate {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 40 else { throw VoiceOSError("模板名称需为 1 到 40 字") }
        guard try db.query("SELECT id FROM capture_templates WHERE name=?", [name]).isEmpty else { throw VoiceOSError("模板名称已存在") }
        let id = UUID().uuidString, now = Self.now()
        try db.execute("INSERT INTO capture_templates(id,name,body,created_at) VALUES(?,?,?,?)", [id, name, body, now])
        return CaptureTemplate(id: id, name: name, body: body, createdAt: now)
    }

    public func deleteCaptureTemplate(id: String) throws {
        try db.execute("DELETE FROM capture_templates WHERE id=?", [id])
    }
}
