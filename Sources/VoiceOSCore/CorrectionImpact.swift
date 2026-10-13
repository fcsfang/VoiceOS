import Foundation

public struct CorrectionImpactRoot: Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let sourceID: String?
    public let summary: String
}
public struct CorrectionScheduleEffect: Identifiable, Sendable {
    public let id: String
    public let state: String
    public let before: ReminderDueDate?
    public let desired: ReminderDueDate
    public let saveAcknowledged: Bool
}
/// A current projection from durable correction/operation records, never an
/// external cancellation, new task, user outcome or compensation receipt.
public struct CorrectionActionImpact: Identifiable, Sendable {
    public var id: String { action.id }
    public let action: ActionRecord
    public let roots: [CorrectionImpactRoot]
    public let link: ReminderLink?
    public let scheduleEffects: [CorrectionScheduleEffect]
    public let summary: String
    public let digest: String
}
extension VoiceOSStore {
    /// Only explicit error corrections create impacts. Privacy restrictions,
    /// endorsement/rejection and migration freezing are not diagnoses of error.
    public func correctionActionImpacts() throws -> [CorrectionActionImpact] {
        let actions = try actions(includeHistory: true).filter { $0.validity == "frozen" }
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims(includeFrozen: true).map { ($0.id,$0) })
        let links = try reminderLinks()
        let access = try reminderAccess()
        return try actions.compactMap { action in
            guard let claim = claims[action.claimID] else { return nil }
            var roots: [String: CorrectionImpactRoot] = [:]
            for row in try db.query("SELECT * FROM claim_reviews WHERE claim_id=? AND version>? AND reason='correction' ORDER BY version",
                                    [claim.id,String(action.claimReviewVersion)]) {
                roots[row["id"]!] = .init(id: row["id"]!, kind: "claim_correction", sourceID: nil,
                                          summary: "认知第\(row["version"]!)版明确纠错；行动引用第\(action.claimReviewVersion)版")
            }
            for ref in claim.references {
                let revisions = try db.query("""
                    SELECT r.id FROM transcript_revisions r
                    JOIN transcripts t ON t.id=r.transcript_id
                    JOIN transcript_versions old ON old.id=r.from_version_id
                    JOIN transcript_versions pinned ON pinned.id=? AND pinned.transcript_id=t.id
                    WHERE t.source_id=? AND old.version_no>=pinned.version_no AND r.reason='transcription_error'
                    """, [ref.transcriptVersionID,ref.sourceID])
                for row in revisions {
                    roots[row["id"]!] = .init(id: row["id"]!, kind: "transcription_error", sourceID: ref.sourceID,
                                              summary: "行动引用的逐字稿随后已纠错；旧引用保留但不继续执行")
                }
            }
            guard !roots.isEmpty else { return nil }
            let link = links.first { $0.actionID == action.id }
            let operations = try link.map { try db.query("SELECT * FROM reminder_schedule_operations WHERE link_id=? ORDER BY created_at,id", [$0.id]) } ?? []
            let effects = try operations.map { row in
                CorrectionScheduleEffect(id: row["id"]!, state: row["state"]!, before: try Self.scheduleBefore(row).dueDate,
                                         desired: try JSONDecoder().decode(ReminderDueDate.self,from: Data(row["desired_json"]!.utf8)),
                                         saveAcknowledged: row["save_acknowledged"] == "1")
            }
            let compensations = try link.map { try db.query("SELECT * FROM reminder_compensation_operations WHERE link_id=? ORDER BY created_at,id", [$0.id]) } ?? []
            let summary: String
            if link == nil { summary = "旧行动已停止；没有关联外部任务，不需要外部撤销" }
            else if access?.enabled != true || access?.calendarID != link?.calendarID {
                summary = "旧行动已停止；外部连接未授权或已暂停，保留上次观测，现状未核对"
            }
            else if operations.contains(where: { $0["attempted"] == "1" && ["unknown","conflict"].contains($0["state"] ?? "") }) {
                summary = "旧行动已停止；外部改期效果待核对，先只读回读，不重发或反向写入"
            } else if link?.state != "linked" || link?.remoteMarkerValid != true {
                summary = "旧行动已停止；外部身份或现状未核对，不能假定已撤销或重建"
            } else if link?.remoteCompleted == true {
                summary = "旧依据已停止；保留外部已完成事实，纠错不自动撤回真实执行结果"
            } else if compensations.contains(where: { $0["validity"] == "current" && ["unknown","conflict"].contains($0["state"] ?? "") }) {
                summary = "旧行动已停止；期限补偿效果待只读核对，不重发或反向写入"
            } else if compensations.contains(where: { $0["state"] == "confirmed" }) {
                summary = "已记录期限补偿的保存应答与回读；任务仍保留，旧行动仍停止；当前期限以最新观测为准"
            } else if compensations.contains(where: { $0["state"] == "observed" }) {
                summary = "已观察到期限补偿目标，写入归属未确认；任务仍保留，旧行动仍停止；当前期限以最新观测为准"
            } else {
                summary = "旧行动已停止；上次观测的外部任务仍保留，需核对是否保留、改写或取消；尚未执行补偿"
            }
            let orderedRoots = roots.values.sorted { $0.id < $1.id }
            let operationState = operations.map { [$0["id"] ?? "",$0["state"] ?? "",$0["result_observation_id"] ?? "",$0["save_acknowledged"] ?? ""] }.flatMap { $0 }
            let fields = ["correction-action-impact-v1",action.id,String(action.version),action.state,action.validity,
                          link?.id ?? "",link?.state ?? "",link?.externalID ?? "",link?.lastObservationID ?? "",
                          access.map { String($0.version) } ?? "",access?.enabled == true ? "enabled" : "paused",access?.calendarID ?? "",
                          String(claim.reviewVersion)]
            var sourceState: [String] = []
            for id in Set(claim.references.map(\.sourceID)).sorted() {
                guard let source = try db.query("SELECT s.*,t.current_version_id FROM sources s LEFT JOIN transcripts t ON t.source_id=s.id WHERE s.id=?", [id]).first else {
                    throw VoiceOSError("纠错影响缺少引用来源")
                }
                sourceState += [id,source["state"] ?? "",source["policy_version"] ?? "",source["current_version_id"] ?? "",source["expected_hash"] ?? ""]
            }
            return .init(action: action,roots: orderedRoots,link: link,scheduleEffects: effects,summary: summary,
                         digest: try Self.actionHash(fields + orderedRoots.map(\.id) + operationState + sourceState))
        }
    }
}
