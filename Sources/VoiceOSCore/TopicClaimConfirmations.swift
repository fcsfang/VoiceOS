import Foundation

extension VoiceOSStore {
    @discardableResult
    public func confirmTopicClaim(topicID: String, claimID: String, commandID: String = UUID().uuidString) throws -> Bool {
        if let receipt = try db.query("SELECT topic_id,claim_id FROM topic_claim_confirmations WHERE command_id=?", [commandID]).first {
            guard receipt["topic_id"] == topicID, receipt["claim_id"] == claimID else { throw VoiceOSError("同一确认命令不能更换主题或观点") }
            return false
        }
        guard try db.query("SELECT claim_id FROM topic_claim_confirmations WHERE topic_id=? AND claim_id=?", [topicID, claimID]).isEmpty else { return false }
        guard try db.query("SELECT id FROM claims WHERE id=?", [claimID]).first != nil else { throw VoiceOSError("观点不存在") }
        try db.execute("INSERT INTO topic_claim_confirmations(topic_id,claim_id,command_id,created_at) VALUES(?,?,?,?)", [topicID, claimID, commandID, ISO8601DateFormatter().string(from: Date())])
        return true
    }

    public func unconfirmTopicClaim(topicID: String, claimID: String) throws {
        try db.execute("DELETE FROM topic_claim_confirmations WHERE topic_id=? AND claim_id=?", [topicID, claimID])
    }

    public func confirmedTopicClaimIDs(topicID: String) throws -> [String] {
        try db.query("SELECT claim_id FROM topic_claim_confirmations WHERE topic_id=? ORDER BY created_at,claim_id", [topicID]).compactMap { $0["claim_id"] }
    }
}
