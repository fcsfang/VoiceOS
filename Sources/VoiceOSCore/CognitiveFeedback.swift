import Foundation

/// Local presentation only. These settings never grant model or notification access.
public enum CognitiveFeedbackMode: String, Codable, Sendable, CaseIterable { case normal, reduced, paused }
public struct CognitiveFeedbackPreference: Sendable {
    public let version: Int
    public let mode: CognitiveFeedbackMode
}
public struct CognitiveFeedbackItem: Identifiable, Sendable {
    public let id: String
    public let attemptID: String
    public let query: String
    public let hit: RetrievalHit
    public let createdAt: String
}

extension VoiceOSStore {
    public func cognitiveFeedbackPreference() throws -> CognitiveFeedbackPreference {
        guard let row = try db.query("SELECT version,mode FROM cognitive_feedback_preferences ORDER BY version DESC LIMIT 1").first else {
            return CognitiveFeedbackPreference(version:0,mode:.normal)
        }
        return CognitiveFeedbackPreference(version:Int(row["version"]!)!,mode:CognitiveFeedbackMode(rawValue:row["mode"]!)!)
    }
    public func setCognitiveFeedbackMode(_ mode: CognitiveFeedbackMode, expectedVersion: Int, commandID: String = UUID().uuidString) throws {
        guard ready, !commandID.isEmpty, expectedVersion >= 0, expectedVersion < Int.max else { throw VoiceOSError("资料库尚未就绪或命令身份、版本无效") }
        if let row = try db.query("SELECT * FROM cognitive_feedback_preferences WHERE command_id=?", [commandID]).first {
            guard row["mode"] == mode.rawValue, row["version"] == String(expectedVersion + 1) else { throw VoiceOSError("同一偏好命令不能更换内容") }
            return
        }
        let current = try cognitiveFeedbackPreference()
        guard current.version == expectedVersion else { throw VoiceOSError("静默反馈设置已变化，请刷新") }
        try db.transaction {
            try db.execute("INSERT INTO cognitive_feedback_preferences(id,command_id,version,mode,created_at) VALUES(?,?,?,?,?)",
                           [UUID().uuidString,commandID,String(current.version+1),mode.rawValue,Self.now()])
            try checkpoint(.quietPreferenceUncommitted)
        }
        try checkpoint(.quietPreferenceCommitted)
    }

    /// A projection of accepted, still-current relevance receipts. Reading never calls a model,
    /// creates a claim/action, acknowledges a view or queues a notification.
    public func cognitiveFeedback(limit: Int = 20) throws -> [CognitiveFeedbackItem] {
        guard ready, (1...50).contains(limit) else { throw VoiceOSError("静默反馈读取范围无效") }
        let mode = try cognitiveFeedbackPreference().mode
        if mode == .paused { return [] }
        let ignored = Set(try db.query("SELECT fingerprint FROM cognitive_feedback_ignores").compactMap { $0["fingerprint"] })
        var seen: Set<String> = []; var items: [CognitiveFeedbackItem] = []
        let target = mode == .reduced ? 1 : limit
        for row in try db.query("SELECT * FROM relevance_attempts WHERE state='completed' AND validity='current' ORDER BY created_at DESC,id DESC") {
            let snapshot = try JSONDecoder().decode(RelevanceSnapshot.self,from:Data(row["snapshot_json"]!.utf8))
            // The full input, including excluded candidates, can have changed since completion.
            // A stale receipt is omitted; malformed stored JSON/digests remain errors, not new facts.
            do { try validateRelevanceSnapshot(snapshot,currentQueryID:snapshot.queryID) }
            catch { continue }
            let hits = try relevanceResult(attemptID:row["id"]!,currentQueryID:snapshot.queryID)
            for hit in hits {
                let fingerprint = try Self.feedbackFingerprint(query:snapshot.query,hit:hit)
                guard !ignored.contains(fingerprint), seen.insert(fingerprint).inserted else { continue }
                items.append(CognitiveFeedbackItem(id:fingerprint,attemptID:row["id"]!,query:snapshot.query,hit:hit,createdAt:row["created_at"]!))
                if items.count == target { return items }
            }
        }
        return items
    }
    public func cognitiveFeedbackHit(attemptID: String, candidateID: String) throws -> RetrievalHit {
        guard let row = try db.query("SELECT snapshot_json FROM relevance_attempts WHERE id=?",[attemptID]).first else { throw VoiceOSError("静默反馈不存在") }
        let s = try JSONDecoder().decode(RelevanceSnapshot.self,from:Data(row["snapshot_json"]!.utf8))
        guard let hit = try relevanceResult(attemptID:attemptID,currentQueryID:s.queryID).first(where: { $0.id == candidateID }) else { throw VoiceOSError("静默反馈已失效或未接纳") }
        return hit
    }
    public func ignoreCognitiveFeedback(attemptID: String, candidateID: String, commandID: String = UUID().uuidString) throws {
        guard ready, !commandID.isEmpty,
              let row = try db.query("SELECT snapshot_json FROM relevance_attempts WHERE id=?",[attemptID]).first else { throw VoiceOSError("静默反馈不存在") }
        let snapshot = try JSONDecoder().decode(RelevanceSnapshot.self,from:Data(row["snapshot_json"]!.utf8))
        guard let hit = snapshot.candidates.first(where: { $0.id == candidateID }) else { throw VoiceOSError("静默反馈引用不存在") }
        let fingerprint = try Self.feedbackFingerprint(query:snapshot.query,hit:hit)
        if let old = try db.query("SELECT * FROM cognitive_feedback_ignores WHERE command_id=?",[commandID]).first {
            guard old["attempt_id"] == attemptID, old["candidate_id"] == candidateID, old["fingerprint"] == fingerprint else { throw VoiceOSError("同一忽略命令不能更换内容") }
            return
        }
        guard try relevanceResult(attemptID:attemptID,currentQueryID:snapshot.queryID).contains(where: { $0.id == candidateID }) else { throw VoiceOSError("只能忽略已接纳且仍有效的相关原文") }
        if !(try db.query("SELECT id FROM cognitive_feedback_ignores WHERE fingerprint=?",[fingerprint])).isEmpty { return }
        try db.transaction {
            try db.execute("INSERT INTO cognitive_feedback_ignores(id,command_id,attempt_id,candidate_id,fingerprint,created_at) VALUES(?,?,?,?,?,?)",
                           [UUID().uuidString,commandID,attemptID,candidateID,fingerprint,Self.now()])
            try checkpoint(.quietIgnoreUncommitted)
        }
        try checkpoint(.quietIgnoreCommitted)
    }
    static func feedbackFingerprint(query: String, hit: RetrievalHit) throws -> String {
        // Stable across repeat requests, but a new question or revised quote is a different item.
        relevanceHash(Data(try relevanceJSON(["quiet-feedback-v1",query.trimmingCharacters(in:.whitespacesAndNewlines),
                                             hit.document.sourceID,hit.document.transcriptVersionID,hit.document.spanID,
                                             String(hit.document.textStart),String(hit.document.textEnd),hit.document.text]).utf8))
    }
    static func validateStoredCognitiveFeedback(_ db: Database) throws {
        for (index,row) in try db.query("SELECT * FROM cognitive_feedback_preferences ORDER BY version").enumerated() {
            guard row["version"] == String(index+1), CognitiveFeedbackMode(rawValue:row["mode"] ?? "") != nil,
                  !(row["command_id"] ?? "").isEmpty else { throw VoiceOSError("静默反馈偏好历史不一致") }
        }
        for row in try db.query("SELECT * FROM cognitive_feedback_ignores") {
            guard !(row["command_id"] ?? "").isEmpty,
                  let attempt = try db.query("SELECT * FROM relevance_attempts WHERE id=? AND state='completed'",[row["attempt_id"]]).first,
                  let json = attempt["selection_json"] else { throw VoiceOSError("忽略反馈缺少已接纳调用") }
            let s = try JSONDecoder().decode(RelevanceSnapshot.self,from:Data(attempt["snapshot_json"]!.utf8))
            let ids = try JSONDecoder().decode([String].self,from:Data(json.utf8))
            guard let hit = s.candidates.first(where: { $0.id == row["candidate_id"] }), ids.contains(hit.id),
                  row["fingerprint"] == (try feedbackFingerprint(query:s.query,hit:hit)) else { throw VoiceOSError("忽略反馈的查询或出处不一致") }
        }
    }
}
