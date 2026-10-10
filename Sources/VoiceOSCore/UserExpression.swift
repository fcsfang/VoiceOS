import Foundation
import CryptoKit

extension VoiceOSStore {
    /// Explicit user-authored text, separate from imported/unknown-speaker media.
    /// Saving never grants cloud processing or writes an external task.
    @discardableResult
    public func recordUserExpression(_ text: String, commandID: String = UUID().uuidString) throws -> String {
        try recordExpression(text, commandID: commandID, feedback: nil)
    }
    func recordExpression(_ text: String, commandID: String, feedback: FeedbackIntent?) throws -> String {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        let data = Data(text.utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 4000 else { throw VoiceOSError("请填写不超过 4000 字的表达") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fingerprint = try Self.expressionFingerprint(text, feedback: feedback)
        if let old = try db.query("SELECT * FROM sources WHERE command_id=?", [commandID]).first {
            guard old["input_fingerprint"] == fingerprint else { throw VoiceOSError("同一表达命令不能更换内容") }
            guard ["saved","reference_only"].contains(old["state"] ?? "") else { throw VoiceOSError("表达保存尚未完成，请重开核对；不会报告完整保存") }
            return old["id"]!
        }
        if let feedback {
            guard let action = try db.query("SELECT version FROM actions WHERE id=?", [feedback.actionID]).first,
                  action["version"] == String(feedback.actionVersion) else { throw VoiceOSError("行动版本已变化，请重新核对反馈关联") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let recipe = try feedback.map { String(decoding:try encoder.encode($0),as:UTF8.self) }
        let id = UUID().uuidString, asset = UUID().uuidString, version = UUID().uuidString
        let relative = "assets/\(asset).txt"
        let staged = root.appendingPathComponent("staging/\(asset).part.txt")
        let final = try assetURL(relativePath: relative)
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path,feedback_json)
        VALUES(?,?,?,?,?,?,'user_text','user','user','receiving',?,?,?,?,?,?)
        """, [id,commandID,fingerprint,asset,version,(feedback == nil ? "我的表达 · " : "行动反馈 · ") + Self.now(),Self.now(),TimeZone.current.identifier,String(data.count),hash,relative,recipe])
        try checkpoint(.intent)
        try data.write(to: staged, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let handle = try FileHandle(forWritingTo: staged); defer { try? handle.close() }
        try handle.synchronize(); try DurableFiles.syncDirectory(staged.deletingLastPathComponent())
        try checkpoint(.copyComplete)
        try db.execute("UPDATE sources SET state='sealed',duration=0 WHERE id=?", [id])
        try checkpoint(.sealed)
        try place(staged,final); try checkpoint(.renamed)
        let row = try db.query("SELECT * FROM sources WHERE id=?", [id]).first!
        try sealAndQueue(row, info: MediaInfo(duration: 0, kind: "user_text"))
        try checkpoint(.savedCommitted)
        return id
    }
    static func validateStoredUserExpressions(_ db: Database) throws {
        for row in try db.query("SELECT s.*,t.text AS original_text,t.backend,j.config FROM sources s JOIN transcripts t ON t.source_id=s.id JOIN jobs j ON j.id=t.job_id WHERE s.kind='user_text'") {
            guard row["origin"] == "user", row["speaker"] == "user", row["backend"] == "user-authored-text", row["config"] == "user-text-v1",
                  let text = row["original_text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 4000 else { throw VoiceOSError("表达原文与来源身份不一致") }
            let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            guard row["expected_hash"] == hash, row["expected_bytes"] == String(Data(text.utf8).count), row["input_fingerprint"] == (try expressionFingerprint(text, feedback: feedbackIntent(row["feedback_json"]))) else { throw VoiceOSError("表达原文与原件摘要不一致") }
        }
        guard try db.query("SELECT s.id FROM sources s WHERE s.kind='user_text' AND s.state IN ('saved','reference_only') AND NOT EXISTS(SELECT 1 FROM transcripts t WHERE t.source_id=s.id)").isEmpty else { throw VoiceOSError("表达缺少原文记录") }
    }
    static func expressionFingerprint(_ text: String, feedback: FeedbackIntent?) throws -> String {
        guard let feedback else { return "user-text-v1:" + SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
        let values = [text,feedback.actionID,String(feedback.actionVersion),feedback.kind.rawValue]
        return "user-text-feedback-v1:" + SHA256.hash(data:try JSONSerialization.data(withJSONObject:values)).map { String(format:"%02x",$0) }.joined()
    }
    static func inspectUserText(_ file: URL) throws -> MediaInfo {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 16000, let text = String(data: try Data(contentsOf: file), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 4000 else { throw VoiceOSError("表达原文不是有效的有限 UTF-8 文本") }
        return MediaInfo(duration: 0, kind: "user_text")
    }
    func commitUserText(_ row: [String: String]) throws {
        guard row["origin"] == "user", row["speaker"] == "user" else { throw VoiceOSError("表达来源身份不符") }
        let original = try assetURL(relativePath: row["relative_path"]!)
        _ = try Self.inspectUserText(original)
        let actual = try DurableFiles.hash(original)
        guard String(actual.0) == row["expected_bytes"], actual.1 == row["expected_hash"] else { throw VoiceOSError("表达原件保存期间发生变化") }
        let text = try String(contentsOf: original, encoding: .utf8)
        let job = UUID().uuidString, transcript = UUID().uuidString, version = UUID().uuidString
        // No speech job: the original is already authored text. Keep the common text-version contract.
        try db.execute("INSERT INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','user-text-v1','completed')", [job,row["id"],row["version_id"]])
        try db.execute("INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at,current_version_id) VALUES(?,?,?,?,?,'verbatim',?,'zh_CN','user-authored-text',?,?)", [transcript,row["id"],row["asset_id"],row["version_id"],job,text,Self.now(),version])
        let spans = String(decoding: try JSONEncoder().encode(SpeechText(text: text).spans), as: UTF8.self)
        try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,?,'original','system',?)", [version,transcript,text,spans,Self.now()])
        if let feedback = try Self.feedbackIntent(row["feedback_json"]) {
            guard let current = try db.query("SELECT version FROM actions WHERE id=?", [feedback.actionID]).first,
                  let version = current["version"].flatMap(Int.init), feedback.actionVersion <= version else { throw VoiceOSError("反馈原始行动版本不存在") }
            try db.execute("INSERT INTO action_feedback(id,action_id,action_version,source_id,kind,created_at,sequence) VALUES(?,?,?,?,?,?,?)", [UUID().uuidString,feedback.actionID,String(feedback.actionVersion),row["id"],feedback.kind.rawValue,row["created_at"],try db.query("SELECT COALESCE(MAX(sequence),0)+1 AS next FROM action_feedback WHERE action_id=?", [feedback.actionID]).first?["next"]])
        }
    }
}
