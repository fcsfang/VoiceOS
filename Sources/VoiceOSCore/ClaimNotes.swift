import Foundation

public struct ClaimNote: Identifiable, Sendable {
    public let claimID, body, createdAt, updatedAt: String
    public var id: String { claimID }
}

extension VoiceOSStore {
    public func claimNotes() throws -> [String: ClaimNote] {
        var notes: [String: ClaimNote] = [:]
        for row in try db.query("SELECT claim_id,body,created_at,updated_at FROM claim_notes") {
            guard let claimID = row["claim_id"], let body = row["body"], let createdAt = row["created_at"], let updatedAt = row["updated_at"] else { continue }
            notes[claimID] = ClaimNote(claimID: claimID, body: body, createdAt: createdAt, updatedAt: updatedAt)
        }
        return notes
    }

    @discardableResult
    public func saveClaimNote(claimID: String, body: String) throws -> ClaimNote {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw VoiceOSError("旁注正文不能为空") }
        guard body.unicodeScalars.count <= 1000 else { throw VoiceOSError("旁注正文不能超过 1000 字") }
        guard try db.query("SELECT id FROM claims WHERE id=?", [claimID]).first != nil else { throw VoiceOSError("观点不存在") }
        let now = ISO8601DateFormatter().string(from: Date())
        if let existing = try db.query("SELECT created_at FROM claim_notes WHERE claim_id=?", [claimID]).first {
            let createdAt = existing["created_at"]!
            try db.execute("UPDATE claim_notes SET body=?,updated_at=? WHERE claim_id=?", [body, now, claimID])
            return ClaimNote(claimID: claimID, body: body, createdAt: createdAt, updatedAt: now)
        }
        try db.execute("INSERT INTO claim_notes(claim_id,body,created_at,updated_at) VALUES(?,?,?,?)", [claimID, body, now, now])
        return ClaimNote(claimID: claimID, body: body, createdAt: now, updatedAt: now)
    }

    public func deleteClaimNote(claimID: String) throws {
        try db.execute("DELETE FROM claim_notes WHERE claim_id=?", [claimID])
    }
}
