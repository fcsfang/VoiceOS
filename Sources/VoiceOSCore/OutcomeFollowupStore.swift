import Foundation

extension VoiceOSStore {
    /// Results remain useful after a task is reopened. Their actionVersion keeps
    /// that history distinct from the task's current attempt.
    public func recentActionOutcomes() throws -> [ActionFeedbackRecord] {
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims(includeFrozen: true).map { ($0.id, $0) })
        return try db.query("""
        SELECT f.*,s.state AS source_state,s.feedback_json,v.text
        FROM action_feedback f JOIN actions a ON a.id=f.action_id
        JOIN sources s ON s.id=f.source_id
        JOIN transcripts t ON t.source_id=s.id JOIN transcript_versions v ON v.id=t.current_version_id
        WHERE a.kind='task' AND a.validity='current' AND s.state IN ('saved','reference_only')
        AND f.kind IN ('outcome','reflection') ORDER BY f.created_at DESC,f.sequence DESC
        """).compactMap { row in
            let intent = try Self.feedbackIntent(row["feedback_json"])
            guard (intent?.relation == nil || intent?.relation == "outcome"),
                  intent?.organizedClaimID.map({ claims[$0]?.validity == "current" }) ?? true,
                  let text = row["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ActionFeedbackRecord(id: row["id"]!, actionID: row["action_id"]!, actionVersion: Int(row["action_version"]!)!, sourceID: row["source_id"]!, kind: row["kind"]!, text: text, sourceState: row["source_state"]!, createdAt: row["created_at"]!, recordingSourceID: intent?.recordingSourceID, relation: intent?.relation)
        }
    }

    /// Completion is an action status, not evidence that a result was learned.
    /// A reopened task starts another version, so prior results stay in history.
    public func pendingOutcomeFollowups() throws -> [ActionRecord] {
        let results = Dictionary(grouping: try recentActionOutcomes(), by: \.actionID)
        let completed = try actions(includeHistory: true).filter {
            $0.kind == "task" && $0.state == "completed" && $0.validity == "current"
        }
        return completed.filter { action in
            !(results[action.id] ?? []).contains { feedback in
                feedback.actionVersion == action.version
            }
        }
    }
}
