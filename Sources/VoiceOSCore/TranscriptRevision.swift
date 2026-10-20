import Foundation
import CryptoKit

extension VoiceOSStore {
    static func isPrunedHistoricalTranscript(_ version: [String: String], historical: Bool) -> Bool {
        guard historical, let id = version["id"], let current = version["current_version_id"], id != current else { return false }
        return version["reason"] == "ai_superseded" && version["actor"] == "system"
            && version["text"] == "" && version["spans_json"] == "[]"
    }

    @discardableResult
    public func applyReviewedQwenTranscript(sourceID: String, expectedVersionID: String, speech: SpeechText, responseID: String) throws -> String {
        guard !responseID.isEmpty else { throw VoiceOSError("转写核对缺少回执") }
        return try db.transaction {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let current = try db.query("SELECT v.* FROM transcript_versions v JOIN transcripts t ON t.current_version_id=v.id WHERE t.source_id=?", [sourceID]).first,
               current["reason"] == "ai_corrected", current["text"] == speech.text,
               try db.query("SELECT id FROM transcript_versions WHERE id=? AND transcript_id=? AND reason='ai_superseded'", [expectedVersionID,current["transcript_id"]]).first != nil,
               let saved = current["spans_json"], try encoder.encode(JSONDecoder().decode([TranscriptSpan].self, from: Data(saved.utf8))) == encoder.encode(speech.spans) {
                return current["id"]!
            }
            guard let row = try db.query("SELECT t.*,s.duration,v.text AS current_text FROM transcripts t JOIN sources s ON s.id=t.source_id JOIN transcript_versions v ON v.id=t.current_version_id WHERE s.id=? AND s.state='saved' AND t.current_version_id=?", [sourceID,expectedVersionID]).first,
                  row["backend"]?.hasPrefix("Qwen3-ASR") == true else { throw VoiceOSError("核对期间文字已变化，请重新整理") }
            try speech.validate(duration: row["duration"].flatMap(Double.init))
            guard !speech.text.isEmpty, speech.spans.allSatisfy({ $0.startMS != nil && $0.endMS != nil }) else { throw VoiceOSError("转写核对必须保留实际录音时间范围") }
            if speech.text == row["current_text"] { return expectedVersionID }
            try invalidateCognition(sourceID: sourceID)
            let spans = String(decoding: try JSONEncoder().encode(speech.spans), as: UTF8.self)
            let id = UUID().uuidString, next = Int(row["version"]!)! + 1
            try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,?,?,?,'ai_corrected','system',?)", [id,row["id"],String(next),speech.text,spans,Self.now()])
            try db.execute("UPDATE transcript_versions SET text='',spans_json='[]',reason='ai_superseded',actor='system' WHERE id=?", [expectedVersionID])
            if row["version"] == "1" { try db.execute("UPDATE transcripts SET text='' WHERE id=?", [row["id"]]) }
            try db.execute("UPDATE transcripts SET current_version_id=?,version=? WHERE id=?", [id,String(next),row["id"]])
            return id
        }
    }

    public func transcriptHistory(sourceID: String) throws -> [TranscriptVersion] {
        try db.query("""
        SELECT v.*,t.current_version_id FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id
        JOIN sources s ON s.id=t.source_id WHERE s.id=? AND s.state IN ('saved','reference_only') AND v.reason!='ai_superseded' ORDER BY v.version_no DESC
        """, [sourceID]).map { row in
            TranscriptVersion(id: row["id"]!, number: Int(row["version_no"]!)!, text: row["text"]!, reason: row["reason"]!, createdAt: row["created_at"]!, isCurrent: row["id"] == row["current_version_id"])
        }
    }
    @discardableResult
    public func correctTranscript(sourceID: String, expectedVersionID: String, text: String, commandID: String = UUID().uuidString) throws -> String {
        let input = try JSONSerialization.data(withJSONObject: [sourceID,expectedVersionID,text])
        let fingerprint = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        if let existing = try db.query("SELECT * FROM transcript_revisions WHERE command_id=?", [commandID]).first {
            guard existing["input_fingerprint"] == fingerprint else { throw VoiceOSError("同一更正命令不能更换内容") }
            return existing["to_version_id"]!
        }
        let result = try db.transaction {
            guard let row = try db.query("""
            SELECT t.*,v.text AS current_text FROM transcripts t JOIN sources s ON s.id=t.source_id
            JOIN transcript_versions v ON v.id=t.current_version_id
            WHERE s.id=? AND s.state IN ('saved','reference_only') AND t.current_version_id=?
            """, [sourceID,expectedVersionID]).first else { throw VoiceOSError("逐字稿已经更新，请重新打开当前版本再更正") }
            guard text != row["current_text"] else { throw VoiceOSError("文字未改变，无需保存更正") }
            let versionID = UUID().uuidString
            let next = Int(row["version"]!)! + 1
            // Editing changes text alignment. Keep the original timed version; do not invent new timestamps.
            let corrected = SpeechText(text: text)
            let spans = String(decoding: try JSONEncoder().encode(corrected.spans), as: UTF8.self)
            let now = ISO8601DateFormatter().string(from: Date())
            try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,?,?,?,'transcription_error','user',?)", [versionID,row["id"],String(next),text,spans,now])
            try db.execute("INSERT INTO transcript_revisions(id,transcript_id,from_version_id,to_version_id,command_id,input_fingerprint,reason,actor,created_at) VALUES(?,?,?,?,?,?,'transcription_error','user',?)", [UUID().uuidString,row["id"],expectedVersionID,versionID,commandID,fingerprint,now])
            try db.execute("UPDATE transcripts SET current_version_id=?,version=? WHERE id=?", [versionID,String(next),row["id"]])
            try invalidateCognition(sourceID: sourceID)
            try checkpoint(.correctionUncommitted)
            return versionID
        }
        try checkpoint(.correctionCommitted)
        return result
    }
    public func isCurrentTranscriptVersion(_ id: String) throws -> Bool {
        !(try db.query("""
        SELECT v.id FROM transcript_versions v JOIN transcripts t ON t.current_version_id=v.id
        JOIN sources s ON s.id=t.source_id WHERE v.id=? AND s.state IN ('saved','reference_only')
        """, [id])).isEmpty
    }
}
