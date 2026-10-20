import Foundation

public struct SourceUnderstandingContinuation: Sendable {
    public let state: String
    public let claimIDs: [String]
    public let reused: Bool
}
extension VoiceOSStore {
    /// Explicit continuation only. A completed understanding can proceed to independent
    /// association without regenerating cognition; unknown/rejected/in-flight work is terminal here.
    public func continueSourceUnderstanding(sourceID: String, using port: any ModelPort) async throws -> SourceUnderstandingContinuation {
        try Task.checkCancellation()
        let context = try prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let policy = try sourcePolicy(sourceID: sourceID)
        if let attempt = try db.query("""
            SELECT a.id,a.state,c.state AS context_state FROM model_attempts a
            JOIN contexts c ON c.id=a.context_id JOIN context_inputs i ON i.context_id=a.context_id
            WHERE i.source_id=? AND i.transcript_version_id=? AND COALESCE(i.policy_version,1)=CAST(? AS INTEGER)
              AND a.execution_kind='model_request' AND a.provider NOT LIKE 'discussion_outcome:%'
            ORDER BY a.producer_sequence LIMIT 1
            """, [sourceID, context.sources[0].transcriptVersionID, String(policy.version)]).first {
            let state = attempt["context_state"] == "current" ? attempt["state"]! : "frozen"
            let ids = try db.query("SELECT id FROM claims WHERE attempt_id=? ORDER BY ordinal", [attempt["id"]]).map { $0["id"]! }
            return .init(state: state, claimIDs: ids, reused: true)
        }
        // Shared discussion outcomes keep their own provenance and once-only extraction barrier.
        // Do not silently reinterpret one turn, or invent successful understanding on an unknown outcome.
        if let attempt = try db.query("""
            SELECT m.state,c.state AS context_state FROM conversation_outcome_attempts o
            JOIN model_attempts m ON m.id=o.id JOIN contexts c ON c.id=m.context_id
            JOIN conversation_user_turns t ON t.conversation_id=o.conversation_id
            JOIN context_inputs i ON i.context_id=t.context_id
            WHERE t.source_id=? AND i.transcript_version_id=? ORDER BY m.producer_sequence LIMIT 1
            """, [sourceID, context.sources[0].transcriptVersionID]).first {
            return .init(state: attempt["context_state"] == "current" ? "discussion_" + attempt["state"]! : "frozen", claimIDs: [], reused: true)
        }
        let ids = try await understandSource(sourceID: sourceID, using: port)
        return .init(state: "completed", claimIDs: ids, reused: false)
    }
}
