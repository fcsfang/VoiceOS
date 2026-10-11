import Foundation

public actor VoiceOSStore {
    public let root: URL
    private let lock: StoreLock
    let db: Database
    private let inspector: any MediaInspector
    var ready = false
    private var activeImports: Set<String> = []
    var activeCaptures: Set<String> = []
    func inspectRecording(_ file:URL) async throws -> MediaInfo { try await inspector.inspect(file) }
    private var processing = false
    var activeReminderLinks: Set<String> = []
    var activeEnglishAttempts: Set<String> = []
    let checkpoint: @Sendable (SaveCheckpoint) throws -> Void

    public init(root: URL, inspector: any MediaInspector,
                checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = { _ in }) throws {
        self.root = root.standardizedFileURL; self.inspector = inspector; self.checkpoint = checkpoint
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lock = try StoreLock(self.root.appendingPathComponent("store.lock"))
        for folder in ["assets", "staging"] {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent(folder), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        db = try Database(self.root.appendingPathComponent("voiceos.sqlite"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.root.appendingPathComponent("voiceos.sqlite").path)
    }
    public func recover() async throws {
        guard !ready, activeImports.isEmpty else { return }
        try db.execute("UPDATE reminder_links SET state='unknown' WHERE state='reserved'")
        // Startup only: the process lock proves the previous worker no longer owns a lease.
        try db.execute("UPDATE jobs SET state='queued', lease_token=NULL WHERE state='running'")
        try db.execute("UPDATE model_attempts SET state='unknown',error='进程退出前结果未登记；不会自动重发' WHERE state='reserved'")
        try db.execute("UPDATE relevance_attempts SET state='unknown',error='进程退出前相关性结果未登记；不会自动重发' WHERE state='reserved'")
        try db.execute("UPDATE discussion_attempts SET state='unknown',error='进程退出前讨论结果未登记；不自动重发' WHERE state='reserved'")
        try db.execute("UPDATE english_feedback_attempts SET state='unknown',error='进程退出前英文反馈未登记；不自动重发' WHERE state='reserved'")
        try db.execute("UPDATE expression_association_attempts SET state='unknown',error='进程退出前关联结果未登记；不自动重发' WHERE state='reserved'")
        for row in try db.query("SELECT * FROM sources ORDER BY created_at") {
            let id = row["id"]!
            if row["input_fingerprint"] == "microphone-v1:"+id, row["expected_bytes"] == "0" {
                try interruptDictation(sourceID:id); continue
            }
            if ["interrupted", "quarantined", "reference_only"].contains(row["state"]!) { continue }
            let final = try assetURL(relativePath: row["relative_path"]!)
            let staging = root.appendingPathComponent("staging/\(row["asset_id"]!).part.\(final.pathExtension)")
            let file = FileManager.default.fileExists(atPath: final.path) ? final : staging
            guard FileManager.default.fileExists(atPath: file.path) else {
                if row["state"] == "receiving" { try interrupt(id, "保存被中断，尚无完整副本") }
                else { try quarantine(id, "受管原件缺失") }
                continue
            }
            do {
                let (bytes, hash) = try DurableFiles.hash(file)
                guard String(bytes) == row["expected_bytes"], hash == row["expected_hash"] else {
                    if row["state"] == "receiving" { try interrupt(id, "保存被中断，副本不完整") }
                    else { try quarantine(id, "原件完整性核对失败") }
                    continue
                }
                let info = row["kind"] == "user_text" ? try Self.inspectUserText(file) : try await inspector.inspect(file)
                if row["state"] != "saved" {
                    try db.execute("UPDATE sources SET state='sealed', duration=?, kind=? WHERE id=?", [String(info.duration), info.kind, id])
                    if file != final { try place(staging, final) }
                    try sealAndQueue(row, info: info)
                }
            } catch { try quarantine(id, "无法验证媒体原件，请保留副本并检查文件") }
        }
        try db.execute("UPDATE claims SET validity='frozen' WHERE attempt_id IN (SELECT a.id FROM model_attempts a JOIN contexts x ON x.id=a.context_id WHERE x.state='stale')")
        try Self.validateStoredRelevance(db)
        try Self.validateStoredCognitiveFeedback(db)
        try Self.validateStoredRecordings(db)
        try Self.validateStoredConversations(db)
        try Self.validateStoredDiscussionAttempts(db)
        try freezeDiscussionDerivations()
        try Self.validateStoredDiscussionDerivations(db)
        try freezeConversationOutcomes()
        try Self.validateStoredConversationOutcomes(db)
        try Self.validateStoredEnglishFeedback(db)
        try Self.validateStoredExpressionAssociations(db)
        try Self.validateStoredExpressionAssociationIgnores(db)
        ready = true
    }
    @discardableResult
    public func importFile(_ input: URL, commandID: String = UUID().uuidString) async throws -> String {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        let extensionName = input.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac"].contains(extensionName) else { throw VoiceOSError("请选择音频或视频文件") }
        let (bytes, hash) = try DurableFiles.hash(input)
        guard bytes > 0 else { throw VoiceOSError("文件为空") }
        let fingerprint = "\(hash):\(bytes):\(extensionName):\(input.lastPathComponent)"
        if let old = try db.query("SELECT * FROM sources WHERE command_id=?", [commandID]).first {
            guard old["input_fingerprint"] == fingerprint else { throw VoiceOSError("同一导入命令不能更换文件内容") }
            return old["id"]!
        }
        let id = UUID().uuidString; let asset = UUID().uuidString; let version = UUID().uuidString
        let relative = "assets/\(asset).\(extensionName)"
        let staging = root.appendingPathComponent("staging/\(asset).part.\(extensionName)")
        let final = try assetURL(relativePath: relative)
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?,?,'receiving',?,?,?,?,?)
        """, [id,commandID,fingerprint,asset,version,input.lastPathComponent,"unknown",Self.now(),TimeZone.current.identifier,String(bytes),hash,relative])
        activeImports.insert(id)
        defer { activeImports.remove(id) }
        do {
            try checkpoint(.intent)
            try DurableFiles.copy(input, to: staging, checkpoint: checkpoint)
            try checkpoint(.copyComplete)
            let actual = try DurableFiles.hash(staging)
            guard actual.0 == bytes, actual.1 == hash else { throw VoiceOSError("复制期间输入发生变化，无法确认完整保存") }
            let info = try await inspector.inspect(staging)
            try db.execute("UPDATE sources SET state='sealed', duration=?, kind=? WHERE id=?", [String(info.duration),info.kind,id])
            try checkpoint(.sealed)
            try place(staging, final)
            try checkpoint(.renamed)
            let row = try db.query("SELECT * FROM sources WHERE id=?", [id]).first!
            try sealAndQueue(row, info: info)
            try checkpoint(.savedCommitted)
            return id
        } catch {
            // Keep sealed intent recoverable. Never erase evidence to hide an incomplete import.
            if try db.query("SELECT state FROM sources WHERE id=?", [id]).first?["state"] == "receiving" {
                try interrupt(id, "导入未完成，可重新选择原文件")
            }
            throw error
        }
    }
    public func sources() throws -> [SourceRecord] {
        try db.query("""
        SELECT s.*,j.state AS job_state,j.error AS job_error,v.text AS transcript,t.current_version_id AS transcript_version_id,v.spans_json
        FROM sources s LEFT JOIN jobs j ON j.source_id=s.id AND j.stage='transcription'
        LEFT JOIN transcripts t ON t.job_id=j.id LEFT JOIN transcript_versions v ON v.id=t.current_version_id ORDER BY s.created_at DESC,s.id
        """).map { row in
            let feedback = try Self.feedbackIntent(row["feedback_json"])
            return SourceRecord(id: row["id"]!, assetID: row["asset_id"]!, name: row["name"]!, state: row["state"]!, kind: row["kind"]!, createdAt: row["created_at"]!, bytes: Int64(row["expected_bytes"]!)!, duration: row["duration"].flatMap(Double.init), jobState: row["job_state"], transcript: ["saved", "reference_only"].contains(row["state"] ?? "") ? row["transcript"] : nil, error: row["error"] ?? row["job_error"], relativePath: row["relative_path"]!, transcriptVersionID: row["transcript_version_id"], spans: try row["spans_json"].map { try JSONDecoder().decode([TranscriptSpan].self, from: Data($0.utf8)) } ?? [], localOnly: row["local_only"] != "0", policyVersion: Int(row["policy_version"]!)!, origin: row["origin"]!, speaker: row["speaker"]!, feedbackActionID: feedback?.actionID, feedbackActionVersion: feedback?.actionVersion, feedbackKind: feedback?.kind.rawValue)
        }
    }
    public func playableURL(sourceID: String) throws -> URL {
        guard let row = try db.query("SELECT * FROM sources WHERE id=? AND state='saved'", [sourceID]).first else { throw VoiceOSError("此原件尚未可靠保存") }
        let url = try assetURL(relativePath: row["relative_path"]!)
        let actual = try DurableFiles.hash(url)
        guard actual.0 == Int64(row["expected_bytes"]!), actual.1 == row["expected_hash"]! else {
            try quarantine(sourceID, "原件完整性核对失败")
            throw VoiceOSError("原件完整性核对失败，已暂停后续处理")
        }
        return url
    }
    public func retryTranscription(sourceID: String) throws {
        try db.execute("UPDATE jobs SET state='queued',error=NULL WHERE source_id=? AND state IN ('failed','blocked') AND EXISTS(SELECT 1 FROM sources WHERE id=? AND state='saved')", [sourceID,sourceID])
    }
    public func processTranscriptions(using speech: any SpeechPort) async throws {
        guard ready, !processing else { return }
        let backend = speech.backendIdentity
        guard !backend.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, backend.utf8.count <= 160, !backend.contains("\n"), !backend.contains("\r") else { throw VoiceOSError("转写端口身份无效") }
        processing = true
        defer { processing = false }
        while let row = try db.query("""
        SELECT j.*,s.asset_id,s.relative_path FROM jobs j JOIN sources s ON s.id=j.source_id
        WHERE j.state='queued' AND s.state='saved' AND j.input_version_id=s.version_id ORDER BY s.created_at LIMIT 1
        """).first {
            let job = row["id"]!; let source = row["source_id"]!; let lease = UUID().uuidString
            try db.execute("UPDATE jobs SET state='running',lease_token=?,attempts=attempts+1 WHERE id=?", [lease,job])
            do {
                try checkpoint(.jobClaimed)
                let url = try playableURL(sourceID: source)
                let result = try await speech.transcribe(url, locale: "zh_CN")
                let duration = try db.query("SELECT duration FROM sources WHERE id=?", [source]).first?["duration"].flatMap(Double.init)
                try result.validate(duration: duration)
                let text = result.text
                _ = try playableURL(sourceID: source)
                try db.transaction {
                    guard !(try db.query("""
                    SELECT j.id FROM jobs j JOIN sources s ON s.id=j.source_id
                    WHERE j.id=? AND j.lease_token=? AND j.state='running' AND s.state='saved' AND s.version_id=j.input_version_id
                    """, [job,lease])).isEmpty else { return }
                    let transcriptID = UUID().uuidString
                    try db.execute("""
                    INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at)
                    VALUES(?,?,?,?,?,'verbatim',?,'zh_CN',?,?)
                    """, [transcriptID,source,row["asset_id"],row["input_version_id"],job,text,backend,Self.now()])
                    let versionID = UUID().uuidString
                    let spans = String(decoding: try JSONEncoder().encode(result.spans), as: UTF8.self)
                    try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,?, 'original','system',?)", [versionID,transcriptID,text,spans,Self.now()])
                    try db.execute("UPDATE transcripts SET current_version_id=? WHERE id=?", [versionID,transcriptID])
                    try db.execute("UPDATE jobs SET state='completed' ,lease_token=NULL,error=NULL WHERE id=?", [job])
                    try checkpoint(.transcriptUncommitted)
                }
                try checkpoint(.transcriptCommitted)
            } catch {
                try db.execute("UPDATE jobs SET state='failed',lease_token=NULL,error=? WHERE id=? AND lease_token=? AND state='running'", [error.localizedDescription,job,lease])
            }
        }
    }
    public func integrityCheck() throws -> Bool {
        try db.query("PRAGMA integrity_check").first?["integrity_check"] == "ok" && db.query("PRAGMA foreign_key_check").isEmpty
    }
    func sealAndQueue(_ row: [String: String], info: MediaInfo) throws {
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,?,?,'original')", [row["asset_id"],row["id"],row["relative_path"],row["expected_bytes"],row["expected_hash"]])
            try db.execute("UPDATE sources SET state='saved',duration=?,kind=?,error=NULL WHERE id=?", [String(info.duration),info.kind,row["id"]])
            if info.kind == "user_text" { try commitUserText(row) }
            else {
            try db.execute("INSERT OR IGNORE INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','apple-local-zh_CN-v1','queued')", [UUID().uuidString,row["id"],row["version_id"]])
            }
            try checkpoint(.savedUncommitted)
        }
    }
    private func interrupt(_ id: String, _ reason: String) throws { try db.execute("UPDATE sources SET state='interrupted',error=? WHERE id=?", [reason,id]) }
    private func quarantine(_ id: String, _ reason: String) throws {
        try db.transaction {
            try db.execute("UPDATE sources SET state='quarantined',error=? WHERE id=?", [reason,id])
            try db.execute("UPDATE jobs SET state='blocked',lease_token=NULL,error=? WHERE source_id=?", [reason,id])
            try invalidateCognition(sourceID: id)
        }
    }
    func place(_ staging: URL, _ final: URL) throws {
        try FileManager.default.moveItem(at: staging, to: final)
        try DurableFiles.syncDirectory(final.deletingLastPathComponent())
        try DurableFiles.syncDirectory(staging.deletingLastPathComponent())
    }
    func assetURL(relativePath: String) throws -> URL {
        let path = root.appendingPathComponent(relativePath).standardizedFileURL
        guard relativePath.hasPrefix("assets/"), path.deletingLastPathComponent() == root.appendingPathComponent("assets") else { throw VoiceOSError("非法资产路径") }
        return path
    }
    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
