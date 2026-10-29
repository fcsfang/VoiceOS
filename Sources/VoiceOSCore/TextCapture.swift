import Foundation

public enum TextCaptureOwnership: String, CaseIterable, Identifiable, Codable, Sendable {
    case personal, external
    public var id: String { rawValue }
}

extension VoiceOSStore {
    /// Full text is saved before any cloud processing. Attribution is chosen explicitly,
    /// and imported external text never becomes a personal expression by extraction.
    @discardableResult
    public func recordCapturedText(_ text: String, title: String, ownership: TextCaptureOwnership,
                                   commandID: String = UUID().uuidString) throws -> String {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 100, !cleanTitle.contains(where: \.isNewline) else { throw VoiceOSError("请填写一行、不超过 100 字的来源标题") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceOSError("请填写完整原文") }
        if ownership == .personal {
            if let previous = try db.query("SELECT origin,speaker FROM sources WHERE command_id=?", [commandID]).first {
                guard previous["origin"] == "user", previous["speaker"] == "user" else { throw VoiceOSError("同一次保存不能改变原文归属") }
            }
            let sourceID = try recordUserExpression(text, commandID: commandID)
            try renameRecording(sourceID: sourceID, title: cleanTitle)
            return sourceID
        }
        let data = Data(text.utf8), hash = Self.relevanceHash(data), fingerprint = "external-text-v1:" + hash
        if let previous = try db.query("SELECT * FROM sources WHERE command_id=?", [commandID]).first {
            guard previous["input_fingerprint"] == fingerprint, previous["origin"] == "external", previous["speaker"] == "unknown" else { throw VoiceOSError("同一次保存不能更换原文或归属") }
            guard ["saved", "reference_only"].contains(previous["state"] ?? "") else { throw VoiceOSError("文字保存尚未完成，请重新打开核对") }
            try renameRecording(sourceID: previous["id"]!, title: cleanTitle)
            return previous["id"]!
        }
        let id = UUID().uuidString, asset = UUID().uuidString, version = UUID().uuidString
        let relative = "assets/\(asset).txt", staged = root.appendingPathComponent("staging/\(asset).part.txt")
        let final = try assetURL(relativePath: relative), now = Self.now()
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?,'external_text','unknown','external','receiving',?,?,?,?,?)
        """, [id,commandID,fingerprint,asset,version,cleanTitle,now,TimeZone.current.identifier,String(data.count),hash,relative])
        try checkpoint(.intent)
        try data.write(to: staged, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let handle = try FileHandle(forWritingTo: staged); defer { try? handle.close() }
        try handle.synchronize(); try DurableFiles.syncDirectory(staged.deletingLastPathComponent())
        try checkpoint(.copyComplete)
        try db.execute("UPDATE sources SET state='sealed',duration=0 WHERE id=?", [id])
        try checkpoint(.sealed)
        try place(staged, final); try checkpoint(.renamed)
        let row = try db.query("SELECT * FROM sources WHERE id=?", [id]).first!
        try sealAndQueue(row, info: MediaInfo(duration: 0, kind: "external_text"))
        try checkpoint(.savedCommitted)
        return id
    }

    static func inspectExternalText(_ file: URL) throws -> MediaInfo {
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceOSError("外部文字原件不是有效的 UTF-8 文本") }
        return MediaInfo(duration: 0, kind: "external_text")
    }

    func commitExternalText(_ row: [String: String]) throws {
        guard row["origin"] == "external", row["speaker"] == "unknown" else { throw VoiceOSError("外部文字来源归属不符") }
        let file = try assetURL(relativePath: row["relative_path"]!)
        _ = try Self.inspectExternalText(file)
        let actual = try DurableFiles.hash(file)
        guard String(actual.0) == row["expected_bytes"], actual.1 == row["expected_hash"] else { throw VoiceOSError("外部原文保存期间发生变化") }
        let text = try String(contentsOf: file, encoding: .utf8)
        let job = UUID().uuidString, transcript = UUID().uuidString, version = UUID().uuidString
        try db.execute("INSERT INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','external-text-v1','completed')", [job,row["id"],row["version_id"]])
        try db.execute("INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at,current_version_id) VALUES(?,?,?,?,?,'verbatim',?,'zh_CN','external-original-text',?,?)", [transcript,row["id"],row["asset_id"],row["version_id"],job,text,Self.now(),version])
        let spans = try Self.relevanceJSON(SpeechText(text: text).spans)
        try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,?,'original','system',?)", [version,transcript,text,spans,Self.now()])
    }

    static func validateStoredExternalTexts(_ db: Database) throws {
        for row in try db.query("SELECT s.*,t.text AS original_text,t.backend,j.config FROM sources s JOIN transcripts t ON t.source_id=s.id JOIN jobs j ON j.id=t.job_id WHERE s.kind='external_text'") {
            guard row["origin"] == "external", row["speaker"] == "unknown", row["backend"] == "external-original-text", row["config"] == "external-text-v1",
                  let text = row["original_text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceOSError("外部原文与来源归属不一致") }
            let data = Data(text.utf8), hash = relevanceHash(data)
            guard row["expected_hash"] == hash, row["expected_bytes"] == String(data.count), row["input_fingerprint"] == "external-text-v1:" + hash else { throw VoiceOSError("外部原文与原件摘要不一致") }
        }
        guard try db.query("SELECT id FROM sources WHERE kind='external_text' AND state IN ('saved','reference_only') AND NOT EXISTS(SELECT 1 FROM transcripts WHERE source_id=sources.id)").isEmpty else { throw VoiceOSError("外部资料缺少原文记录") }
    }
}
