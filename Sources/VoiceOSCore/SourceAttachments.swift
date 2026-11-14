import Foundation

public struct SourceAttachment: Sendable {
    public let sourceID: String
    public let relativePath: String
    public let mime: String
    public let bytes: Int64
    public let createdAt: String
}

extension SourceAttachment {
    public static func mime(forFileExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "tiff": return "image/tiff"
        default: return nil
        }
    }
}

extension VoiceOSStore {
    public func attachSourceFile(sourceID: String, fileURL: URL) throws -> SourceAttachment {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        guard try db.query("SELECT id FROM sources WHERE id=?", [sourceID]).first != nil else { throw VoiceOSError("来源不存在") }
        let ext = fileURL.pathExtension.lowercased()
        guard let mime = SourceAttachment.mime(forFileExtension: ext) else { throw VoiceOSError("仅支持 png、jpg、jpeg、heic、tiff 图片") }
        let data = try Data(contentsOf: fileURL)
        let asset = UUID().uuidString, relative = "assets/\(asset).\(ext)"
        let staged = root.appendingPathComponent("staging/\(asset).part.\(ext)")
        let final = try assetURL(relativePath: relative)
        try data.write(to: staged, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let handle = try FileHandle(forWritingTo: staged); defer { try? handle.close() }
        try handle.synchronize(); try DurableFiles.syncDirectory(staged.deletingLastPathComponent())
        try place(staged, final)
        let createdAt = Self.now()
        try db.execute("""
        INSERT INTO source_attachments(source_id,relative_path,mime,bytes,created_at) VALUES(?,?,?,?,?)
        ON CONFLICT(source_id) DO UPDATE SET relative_path=excluded.relative_path,mime=excluded.mime,bytes=excluded.bytes,created_at=excluded.created_at
        """, [sourceID, relative, mime, String(data.count), createdAt])
        return SourceAttachment(sourceID: sourceID, relativePath: relative, mime: mime, bytes: Int64(data.count), createdAt: createdAt)
    }

    public func sourceAttachment(sourceID: String) throws -> SourceAttachment? {
        guard let row = try db.query("SELECT relative_path,mime,bytes,created_at FROM source_attachments WHERE source_id=?", [sourceID]).first else { return nil }
        guard let relative = row["relative_path"], let mime = row["mime"], let rawBytes = row["bytes"],
              let bytes = Int64(rawBytes), let createdAt = row["created_at"] else { throw VoiceOSError("图片来源记录损坏") }
        return SourceAttachment(sourceID: sourceID, relativePath: relative, mime: mime, bytes: bytes, createdAt: createdAt)
    }
}
