import Foundation

struct CorrectionInputVersion: Hashable {
    let sourceID: String
    let transcriptVersionID: String
}

extension VoiceOSStore {
    /// Follow saved processing inputs and immutable reuse edges, never topic similarity
    /// or the conversation's current/future turns. A citation is not the full input set.
    static func correctionInputVersions(_ db: Database, claimID: String) throws -> Set<CorrectionInputVersion> {
        guard let claim = try db.query("SELECT * FROM claims WHERE id=?", [claimID]).first else {
            throw VoiceOSError("纠错影响缺少原认知")
        }
        let refs = try JSONDecoder().decode([ClaimReference].self, from: Data(claim["refs_json"]!.utf8))
        var inputs = Set(refs.map { CorrectionInputVersion(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID) })
        var pending = [claim["attempt_id"]!]
        var visited = Set<String>()
        while let attemptID = pending.popLast() {
            guard visited.insert(attemptID).inserted else { continue }
            guard let contextID = try db.query("SELECT context_id FROM model_attempts WHERE id=?", [attemptID]).first?["context_id"] else {
                throw VoiceOSError("纠错影响缺少实际处理身份")
            }
            for row in try db.query("SELECT source_id,transcript_version_id FROM context_inputs WHERE context_id=?", [contextID]) {
                inputs.insert(.init(sourceID: row["source_id"]!, transcriptVersionID: row["transcript_version_id"]!))
            }
            // Shared outcomes retain dependencies on prior producers, including inputs
            // not present in the new conversation's own transcript selection.
            for row in try db.query("SELECT snapshot_json FROM conversation_outcome_attempts WHERE id=?", [attemptID]) {
                let snapshot = try JSONDecoder().decode(ConversationOutcomeSnapshot.self, from: Data(row["snapshot_json"]!.utf8))
                for prior in snapshot.reusePlan?.priorResults ?? [] {
                    guard try db.query("SELECT context_id FROM model_attempts WHERE id=?", [prior.attemptID]).first?["context_id"] == prior.contextID else {
                        throw VoiceOSError("纠错复用依赖与原处理身份不一致")
                    }
                    pending.append(prior.attemptID)
                }
            }
        }
        return inputs
    }

    static func correctionRoots(_ db: Database, claimID: String, pinnedReviewVersion: Int) throws -> [CorrectionImpactRoot] {
        var roots: [String: CorrectionImpactRoot] = [:]
        for row in try db.query("SELECT * FROM claim_reviews WHERE claim_id=? AND version>? AND reason='correction'", [claimID,String(pinnedReviewVersion)]) {
            roots[row["id"]!] = .init(id: row["id"]!, kind: "claim_correction", sourceID: nil,
                                      summary: "认知第\(row["version"]!)版明确纠错；行动引用第\(pinnedReviewVersion)版")
        }
        for input in try correctionInputVersions(db,claimID: claimID) {
            for row in try db.query("""
                SELECT r.id FROM transcript_revisions r JOIN transcripts t ON t.id=r.transcript_id
                JOIN transcript_versions old ON old.id=r.from_version_id
                JOIN transcript_versions pinned ON pinned.id=? AND pinned.transcript_id=t.id
                WHERE t.source_id=? AND old.version_no>=pinned.version_no AND r.reason='transcription_error'
                """, [input.transcriptVersionID,input.sourceID]) {
                roots[row["id"]!] = .init(id: row["id"]!, kind: "transcription_error", sourceID: input.sourceID,
                                          summary: "行动的已保存处理或复用输入随后已纠错；不代表该输入是用户承诺或逐字引文")
            }
        }
        return roots.values.sorted { $0.id < $1.id }
    }
}
