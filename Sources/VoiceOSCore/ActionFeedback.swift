import Foundation

public enum ActionFeedbackKind: String, Codable, Sendable { case outcome, reflection }
struct FeedbackIntent: Codable, Sendable {
    let actionID: String
    let actionVersion: Int
    let kind: ActionFeedbackKind
    var recordingSourceID: String? = nil
}
public struct ActionFeedbackRecord: Identifiable, Sendable {
    public let id: String
    public let actionID: String
    public let actionVersion: Int
    public let sourceID: String
    public let kind: String
    public let text: String
    public let sourceState: String
    public let createdAt: String
    public let recordingSourceID: String?
}
extension VoiceOSStore {
    @discardableResult
    public func recordActionFeedback(actionID: String, expectedVersion: Int, kind: ActionFeedbackKind, text: String, recordingSourceID: String? = nil, commandID: String = UUID().uuidString) throws -> String {
        if let recordingSourceID { try Self.validateFeedbackRecording(recordingSourceID, db: db) }
        return try recordExpression(text, commandID: commandID, feedback: FeedbackIntent(actionID: actionID, actionVersion: expectedVersion, kind: kind, recordingSourceID: recordingSourceID))
    }
    public func actionFeedback(actionID: String) throws -> [ActionFeedbackRecord] {
        try db.query("""
        SELECT f.*,s.state AS source_state,s.feedback_json,v.text FROM action_feedback f JOIN sources s ON s.id=f.source_id
        JOIN transcripts t ON t.source_id=s.id JOIN transcript_versions v ON v.id=t.current_version_id
        WHERE f.action_id=? ORDER BY f.sequence
        """, [actionID]).map {
            ActionFeedbackRecord(id:$0["id"]!, actionID:$0["action_id"]!, actionVersion:Int($0["action_version"]!)!, sourceID:$0["source_id"]!, kind:$0["kind"]!, text:$0["text"]!, sourceState:$0["source_state"]!, createdAt:$0["created_at"]!, recordingSourceID:try Self.feedbackIntent($0["feedback_json"])?.recordingSourceID)
        }
    }
    static func feedbackIntent(_ text: String?) throws -> FeedbackIntent? {
        guard let text else { return nil }
        let data = Data(text.utf8)
        guard data.count <= 1024, let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(["actionID","actionVersion","kind"]).isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: ["actionID","actionVersion","kind","recordingSourceID"]) else { throw VoiceOSError("反馈关联身份格式无效") }
        let intent = try JSONDecoder().decode(FeedbackIntent.self,from:data)
        guard UUID(uuidString:intent.actionID) != nil, intent.actionVersion > 0 else { throw VoiceOSError("反馈行动版本无效") }
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
