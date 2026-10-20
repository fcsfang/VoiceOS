import Foundation

public enum ActionFeedbackKind: String, Codable, Sendable { case outcome, reflection }
struct FeedbackIntent: Codable, Sendable {
    let actionID: String
    let actionVersion: Int
    let kind: ActionFeedbackKind
    var recordingSourceID: String? = nil
    var organizedClaimID: String? = nil
    var relation: String? = nil
}
public struct ActionFeedbackRecord: Identifiable, Codable, Sendable {
    public let id: String
    public let actionID: String
    public let actionVersion: Int
    public let sourceID: String
    public let kind: String
    public let text: String
    public let sourceState: String
    public let createdAt: String
    public let recordingSourceID: String?
    public let relation: String?
    public var label: String {
        switch relation {
        case "repeat": "再次提及"
        case "progress": "实际进展"
        case "outcome": "收获与结果"
        default: kind == "outcome" ? "实际结果" : "我的反思"
        }
    }
}
extension VoiceOSStore {
    /// Reuse the ordinary durable expression flow for explicitly authorized
    /// results, including after reopening or configuring a model later.
    public func enqueueActionFeedbackUnderstanding(cognition: ModelConfiguration, association: ModelConfiguration) throws {
        for source in try sources() where source.kind == "user_text" && source.feedbackActionID != nil && !source.localOnly && ["saved", "reference_only"].contains(source.state) {
            let raw = try db.query("SELECT feedback_json FROM sources WHERE id=?", [source.id]).first?["feedback_json"]
            guard try Self.feedbackIntent(raw)?.organizedClaimID == nil else { continue } // Full recordings already have organized knowledge.
            let snapshot = try prepareExpressionProcessingIntent(sourceID: source.id, cognition: cognition, association: association)
            _ = try enqueueExpressionProcessingIntent(snapshot, commandID: "feedback-understanding:" + source.id + ":" + snapshot.contentDigest,
                                                     cognition: cognition, association: association)
        }
    }

    @discardableResult
    public func recordActionFeedback(actionID: String, expectedVersion: Int, kind: ActionFeedbackKind, text: String, recordingSourceID: String? = nil, commandID: String = UUID().uuidString) throws -> String {
        if let recordingSourceID { try Self.validateFeedbackRecording(recordingSourceID, db: db) }
        return try recordExpression(text, commandID: commandID, feedback: FeedbackIntent(actionID: actionID, actionVersion: expectedVersion, kind: kind, recordingSourceID: recordingSourceID))
    }
    public func actionFeedback(actionID: String) throws -> [ActionFeedbackRecord] {
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims(includeFrozen: true).map { ($0.id, $0) })
        return try db.query("""
        SELECT f.*,s.state AS source_state,s.feedback_json,v.text FROM action_feedback f JOIN sources s ON s.id=f.source_id
        JOIN transcripts t ON t.source_id=s.id JOIN transcript_versions v ON v.id=t.current_version_id
        WHERE f.action_id=? ORDER BY f.sequence
        """, [actionID]).map {
            let intent = try Self.feedbackIntent($0["feedback_json"])
            let stale = intent?.organizedClaimID.map { claims[$0]?.validity != "current" } ?? false
            return ActionFeedbackRecord(id:$0["id"]!, actionID:$0["action_id"]!, actionVersion:Int($0["action_version"]!)!, sourceID:$0["source_id"]!, kind:$0["kind"]!, text:$0["text"]!, sourceState:stale ? "frozen" : $0["source_state"]!, createdAt:$0["created_at"]!, recordingSourceID:intent?.recordingSourceID, relation:intent?.relation)
        }
    }
    static func feedbackIntent(_ text: String?) throws -> FeedbackIntent? {
        guard let text else { return nil }
        let data = Data(text.utf8)
        guard data.count <= 1024, let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(["actionID","actionVersion","kind"]).isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: ["actionID","actionVersion","kind","recordingSourceID","organizedClaimID","relation"]) else { throw VoiceOSError("反馈关联身份格式无效") }
        let intent = try JSONDecoder().decode(FeedbackIntent.self,from:data)
        guard UUID(uuidString:intent.actionID) != nil, intent.actionVersion > 0 else { throw VoiceOSError("反馈行动版本无效") }
        if let claimID = intent.organizedClaimID {
            guard UUID(uuidString: claimID) != nil, intent.recordingSourceID != nil,
                  ["repeat", "progress", "outcome"].contains(intent.relation ?? "") else { throw VoiceOSError("录音接续身份无效") }
        } else if intent.relation != nil { throw VoiceOSError("录音接续缺少原话身份") }
        return intent
    }
    private static func validateFeedbackRecording(_ id: String, db: Database) throws {
        guard UUID(uuidString: id) != nil, let source = try db.query("SELECT * FROM sources WHERE id=?", [id]).first,
              source["kind"] == "audio", source["origin"] == "user", source["speaker"] == "user",
              ["saved", "reference_only"].contains(source["state"] ?? "") else { throw VoiceOSError("结果口述尚未可靠保存，不能关联到反馈") }
    }
    static func validateStoredActionFeedback(_ db: Database) throws {
        for source in try db.query("SELECT * FROM sources WHERE feedback_json IS NOT NULL") {
            guard source["kind"] == "user_text", let intent = try feedbackIntent(source["feedback_json"]),
                  let action = try db.query("SELECT version FROM actions WHERE id=?", [intent.actionID]).first,
                  let version = action["version"].flatMap(Int.init), intent.actionVersion <= version else { throw VoiceOSError("反馈关联行动或版本不存在") }
            if let recording = intent.recordingSourceID { try validateFeedbackRecording(recording, db: db) }
            if let claimID = intent.organizedClaimID {
                guard let row = try db.query("SELECT refs_json FROM claims WHERE id=?", [claimID]).first,
                      try JSONDecoder().decode([ClaimReference].self, from: Data(row["refs_json"]!.utf8)).contains(where: { $0.sourceID == intent.recordingSourceID }) else { throw VoiceOSError("录音接续缺少对应原话") }
            }
            let records = try db.query("SELECT * FROM action_feedback WHERE source_id=?", [source["id"]])
            let hasText = !(try db.query("SELECT id FROM transcripts WHERE source_id=?", [source["id"]])).isEmpty
            if ["saved","reference_only"].contains(source["state"] ?? "") || hasText {
                guard records.count == 1, let record = records.first, record["action_id"] == intent.actionID,
                      record["action_version"] == String(intent.actionVersion), record["kind"] == intent.kind.rawValue else { throw VoiceOSError("反馈原文与行动关联不完整") }
            } else if !records.isEmpty { throw VoiceOSError("未保存的反馈不应有完成关联") }
        }
        guard try db.query("SELECT f.id FROM action_feedback f JOIN sources s ON s.id=f.source_id WHERE s.feedback_json IS NULL").isEmpty else { throw VoiceOSError("反馈缺少原始关联意图") }
    }
}
