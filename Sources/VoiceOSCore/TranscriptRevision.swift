import Foundation
import CryptoKit

extension VoiceOSStore {
    public func transcriptHistory(sourceID: String) throws -> [TranscriptVersion] {
        try db.query("""
        SELECT v.*,t.current_version_id FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id
        JOIN sources s ON s.id=t.source_id WHERE s.id=? AND s.state IN ('saved','reference_only') ORDER BY v.version_no DESC
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
            SELECT t.* FROM transcripts t JOIN sources s ON s.id=t.source_id
            WHERE s.id=? AND s.state IN ('saved','reference_only') AND t.current_version_id=?
            """, [sourceID,expectedVersionID]).first else { throw VoiceOSError("逐字稿已经更新，请重新打开当前版本再更正") }
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
