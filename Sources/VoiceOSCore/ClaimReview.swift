import Foundation
import CryptoKit

public enum ClaimReviewAction: String, Sendable { case endorse, reject, correct }
public struct ClaimReviewVersion: Identifiable, Sendable {
    public let id: String
    public let version: Int
    public let statement: String
    public let ownership: String
    public let decision: String
    public let reason: String
    public let note: String
    public let createdAt: String
}
extension VoiceOSStore {
    /// Explicit user review; original model proposals, result digest and citations stay immutable.
    @discardableResult
    public func reviewClaim(claimID: String, expectedVersion: Int, action: ClaimReviewAction, statement: String? = nil, ownership: CandidateOwnership? = nil, note: String = "", commandID: String = UUID().uuidString) throws -> Int {
        let fingerprint = try Self.reviewFingerprint(claimID, expectedVersion, action, statement, ownership?.rawValue, note)
        if let receipt = try db.query("SELECT * FROM claim_reviews WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == fingerprint else { throw VoiceOSError("同一审阅命令不能更换内容") }
            return Int(receipt["version"]!)!
        }
        guard let current = try candidateClaims(includeFrozen: true).first(where: { $0.id == claimID }),
              current.validity == "current" else { throw VoiceOSError("候选依据或授权已失效，不能继续认可或更正") }
        guard current.reviewVersion == expectedVersion else { throw VoiceOSError("审阅已更新，请重新读取候选") }
        let text: String, owner: String, decision: String, reason: String
        switch action {
        case .endorse, .reject:
            guard statement == nil, ownership == nil else { throw VoiceOSError("认可或拒绝不能同时改写内容") }
            text = current.statement; owner = current.ownership
            decision = action == .endorse ? "endorsed" : "rejected"
            reason = action == .endorse ? "explicit_endorsement" : "explicit_rejection"
            guard decision != current.reviewState else { throw VoiceOSError("审阅状态没有变化") }
        case .correct:
            text = statement ?? current.statement; owner = ownership?.rawValue ?? current.ownership
            guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text != current.statement || owner != current.ownership else { throw VoiceOSError("更正需要说明原因并修改文字或归属") }
            decision = "pending"; reason = "correction"
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 2000, note.unicodeScalars.count <= 2000 else { throw VoiceOSError("审阅内容为空或过长") }
        let next = current.reviewVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO claim_reviews(id,claim_id,version,from_version,decision,statement,ownership,reason,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,?,?,?,'user',?,?,?)", [UUID().uuidString,claimID,String(next),String(expectedVersion),decision,text,owner,reason,note,commandID,fingerprint,ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE claims SET review_version=? WHERE id=? AND review_version=?", [String(next),claimID,String(expectedVersion)])
            if action == .endorse {
                // Endorsement changes confidence, not the action's meaning.
                // Never revive an action frozen by an earlier correction or rejection.
                try db.execute("UPDATE actions SET claim_review_version=? WHERE claim_id=? AND claim_review_version=? AND validity='current'", [String(next),claimID,String(expectedVersion)])
            } else {
                try db.execute("UPDATE actions SET validity='frozen' WHERE claim_id=?", [claimID])
            }
            try checkpoint(.reviewUncommitted)
        }
        try checkpoint(.reviewCommitted)
        return next
    }
    public func claimReviewHistory(claimID: String) throws -> [ClaimReviewVersion] {
        guard let original = try db.query("SELECT * FROM claims WHERE id=?", [claimID]).first else { throw VoiceOSError("候选不存在") }
        let derived = try db.query("SELECT id FROM discussion_claim_derivations WHERE claim_id=?", [claimID]).first != nil
        let first = ClaimReviewVersion(id: claimID, version: 0, statement: original["statement"]!, ownership: original["ownership"]!, decision: "pending", reason: derived ? "discussion_ai_original" : "model_original", note: "", createdAt: original["created_at"]!)
        return [first] + (try db.query("SELECT * FROM claim_reviews WHERE claim_id=? ORDER BY version", [claimID])).map {
            ClaimReviewVersion(id: $0["id"]!, version: Int($0["version"]!)!, statement: $0["statement"]!, ownership: $0["ownership"]!, decision: $0["decision"]!, reason: $0["reason"]!, note: $0["note"]!, createdAt: $0["created_at"]!)
        }
    }
    private static func reviewFingerprint(_ claimID: String, _ expected: Int, _ action: ClaimReviewAction, _ statement: String?, _ ownership: String?, _ note: String) throws -> String {
        let payload: [String: Any] = ["claimID": claimID, "expected": expected, "action": action.rawValue, "statement": statement as Any? ?? NSNull(), "ownership": ownership as Any? ?? NSNull(), "note": note]
        return SHA256.hash(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
    }
    static func validateStoredClaimReviews(_ db: Database) throws {
        for claim in try db.query("SELECT * FROM claims") {
            let reviews = try db.query("SELECT * FROM claim_reviews WHERE claim_id=? ORDER BY version", [claim["id"]])
            guard claim["review_version"] == String(reviews.count) else { throw VoiceOSError("迁移审阅历史不完整") }
            var text = claim["statement"]!, owner = claim["ownership"]!, decision = "pending"
            for (index, row) in reviews.enumerated() {
                guard row["version"] == String(index+1), row["from_version"] == String(index), row["actor"] == "user",
                      let newText = row["statement"], !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, newText.unicodeScalars.count <= 2000,
                      let newOwner = row["ownership"], CandidateOwnership(rawValue: newOwner) != nil,
                      let note = row["note"], note.unicodeScalars.count <= 2000 else { throw VoiceOSError("迁移审阅版本或内容无效") }
                switch row["reason"] {
                case "explicit_endorsement", "explicit_rejection":
                    let expected = row["reason"] == "explicit_endorsement" ? "endorsed" : "rejected"
                    guard newText == text, newOwner == owner, row["decision"] == expected, decision != expected else { throw VoiceOSError("迁移审阅决策与内容不一致") }
                case "correction":
                    guard row["decision"] == "pending", !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          newText != text || newOwner != owner else { throw VoiceOSError("迁移认知更正原因或内容不一致") }
                default: throw VoiceOSError("迁移审阅原因无效")
                }
                text = newText; owner = newOwner; decision = row["decision"]!
            }
        }
    }
}
