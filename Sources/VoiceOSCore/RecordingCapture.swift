import Foundation

public struct RecordingIntent: Sendable {
    public let sourceID: String
    public let stagingURL: URL
}
extension VoiceOSStore {
    /// Explicitly initiated personal dictation. The caller must obtain microphone permission
    /// before this method and must stop the device before sealing. No implicit upload grant.
    public func beginDictation(commandID: String = UUID().uuidString) throws -> RecordingIntent {
        guard ready, !commandID.isEmpty else { throw VoiceOSError("资料库未就绪或录制命令为空") }
        if let old = try db.query("SELECT * FROM sources WHERE command_id=?",[commandID]).first {
            guard old["input_fingerprint"] == "microphone-v1:" + old["id"]!, old["state"] == "receiving", old["expected_bytes"] == "0" else { throw VoiceOSError("录制命令已使用，不重新开始") }
            return try recordingIntent(old)
        }
        guard try db.query("SELECT id FROM sources WHERE input_fingerprint LIKE 'microphone-v1:%' AND state='receiving' AND expected_bytes=0").isEmpty else { throw VoiceOSError("已有未结束录制，请先停止或核对") }
        let id = UUID().uuidString, asset = UUID().uuidString
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?,'audio','user','user','receiving',?,?,0,?,?)
        """,[id,commandID,"microphone-v1:"+id,asset,UUID().uuidString,"我的口述 · "+Self.now(),Self.now(),TimeZone.current.identifier,String(repeating:"0",count:64),"assets/"+asset+".caf"])
        try checkpoint(.intent)
        return try recordingIntent(try db.query("SELECT * FROM sources WHERE id=?",[id]).first!)
    }
    private func recordingIntent(_ row:[String:String]) throws -> RecordingIntent {
        guard let id = row["id"], let asset = row["asset_id"], UUID(uuidString:asset) != nil,
              row["input_fingerprint"] == "microphone-v1:"+id, row["relative_path"] == "assets/"+asset+".caf" else { throw VoiceOSError("录制身份或路径不一致") }
        return RecordingIntent(sourceID:id,stagingURL:root.appendingPathComponent("staging/"+asset+".part.caf"))
    }
    public func interruptDictation(sourceID:String) throws {
        guard let row = try db.query("SELECT * FROM sources WHERE id=?",[sourceID]).first,
              row["input_fingerprint"] == "microphone-v1:"+sourceID else { throw VoiceOSError("录制身份不符") }
        if row["state"] == "receiving", row["expected_bytes"] == "0" {
            try db.execute("UPDATE sources SET state='interrupted',error='录制未正常封存，片段保留待核对；未显示保存成功' WHERE id=?",[sourceID])
        }
    }
    /// Normal finish or explicit recovery of an interrupted draft. A decodable fragment can be
    /// saved, but automatic startup never promotes it to a complete recording.
    public func sealDictation(sourceID:String) async throws {
        guard ready, let row = try db.query("SELECT * FROM sources WHERE id=?",[sourceID]).first,
              row["input_fingerprint"] == "microphone-v1:"+sourceID else { throw VoiceOSError("录制不存在") }
        if row["state"] == "saved" { _ = try playableURL(sourceID:sourceID); return }
        guard ["receiving","interrupted"].contains(row["state"] ?? ""), row["expected_bytes"] == "0",
              !activeCaptures.contains(sourceID) else { throw VoiceOSError("录制已封存或正在核对") }
        activeCaptures.insert(sourceID); defer { activeCaptures.remove(sourceID) }
        let intent = try recordingIntent(row), file = intent.stagingURL
        guard file.resolvingSymlinksInPath() == file.standardizedFileURL else { throw VoiceOSError("录制暂存不能是符号链接") }
        let handle = try FileHandle(forWritingTo:file); try handle.synchronize(); try handle.close()
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        try DurableFiles.syncDirectory(file.deletingLastPathComponent())
        try checkpoint(.copyComplete)
        let hash = try DurableFiles.hash(file)
        guard hash.0 > 0 else { throw VoiceOSError("录制为空，未保存为原件") }
        let info = try await inspectRecording(file)
        let after = try DurableFiles.hash(file)
        guard info.kind == "audio", info.duration > 0, hash.0 == after.0, hash.1 == after.1 else { throw VoiceOSError("录制核对期间文件变化或无音轨") }
        try db.execute("UPDATE sources SET state='sealed',duration=?,expected_bytes=?,expected_hash=?,error=NULL WHERE id=?",[String(info.duration),String(hash.0),hash.1,sourceID])
        try checkpoint(.sealed)
        try place(file,try assetURL(relativePath:row["relative_path"]!)); try checkpoint(.renamed)
        let sealed = try db.query("SELECT * FROM sources WHERE id=?",[sourceID]).first!
        try sealAndQueue(sealed,info:info); try checkpoint(.savedCommitted)
    }
    static func isPersonalAudioImport(_ row: [String: String]) -> Bool {
        guard let path = row["relative_path"], let hash = row["expected_hash"], let bytes = row["expected_bytes"], let name = row["name"] else { return false }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac"].contains(ext)
            && path == "assets/" + (row["asset_id"] ?? "") + "." + ext
            && row["input_fingerprint"] == "personal-audio-v1:" + hash + ":" + bytes + ":" + ext + ":" + name
    }
    static func validateStoredRecordings(_ db:Database) throws {
        for row in try db.query("SELECT * FROM sources WHERE input_fingerprint LIKE 'personal-audio-v1:%'") {
            guard isPersonalAudioImport(row), row["origin"] == "user", row["speaker"] == "user",
                  ["audio", "unknown"].contains(row["kind"] ?? ""), row["feedback_json"] == nil else {
                throw VoiceOSError("用户提供录音的归属或原件身份不一致")
            }
        }
        for row in try db.query("SELECT * FROM sources WHERE input_fingerprint LIKE 'microphone-v1:%'") {
            guard row["input_fingerprint"] == "microphone-v1:"+row["id"]!, row["kind"] == "audio",
                  row["origin"] == "user", row["speaker"] == "user", row["relative_path"] == "assets/"+row["asset_id"]!+".caf",
                  row["feedback_json"] == nil else { throw VoiceOSError("口述录制身份不一致") }
            if row["expected_bytes"] == "0" {
                guard ["receiving","interrupted"].contains(row["state"] ?? ""), row["expected_hash"] == String(repeating:"0",count:64),
                      try db.query("SELECT id FROM assets WHERE source_id=? UNION ALL SELECT id FROM jobs WHERE source_id=?",[row["id"],row["id"]]).isEmpty else { throw VoiceOSError("未封存录制不能有原件或处理任务") }
            }
        }
    }
}
