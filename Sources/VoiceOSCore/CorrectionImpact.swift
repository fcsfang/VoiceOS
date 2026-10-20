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
public struct CorrectionUnderstandingProgress: Identifiable, Sendable {
    public let id: String
    public let sourceID: String?
    public let summary: String
}
/// A current projection from durable correction/operation records, never an
/// external cancellation, new task, user outcome or compensation receipt.
public struct CorrectionActionImpact: Identifiable, Sendable {
    public var id: String { action.id }
    public let action: ActionRecord
    public let roots: [CorrectionImpactRoot]
    public let link: ReminderLink?
    public let scheduleEffects: [CorrectionScheduleEffect]
    public let understandingProgress: [CorrectionUnderstandingProgress]
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
            let orderedRoots = try Self.correctionRoots(db,claimID: claim.id,pinnedReviewVersion: action.claimReviewVersion)
            guard !orderedRoots.isEmpty else { return nil }
            var understandingProgress: [CorrectionUnderstandingProgress] = []
            if orderedRoots.contains(where: { $0.kind == "claim_correction" }) {
                understandingProgress.append(.init(id: "claim:" + claim.id, sourceID: nil,
                    summary: claim.validity == "current" ? "你的观点更正已保存，当前显示更正后的内容。旧任务保留为历史，没有自动套用到新内容。" : "观点更正已保存；它引用的原文或处理权限也已变化，需先更新对应资料的理解。"))
            }
            for sourceID in Set(orderedRoots.compactMap(\.sourceID)).sorted() {
                understandingProgress.append(try correctionUnderstandingProgress(sourceID: sourceID))
            }
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
            let operationState = operations.map { [$0["id"] ?? "",$0["state"] ?? "",$0["result_observation_id"] ?? "",$0["save_acknowledged"] ?? ""] }.flatMap { $0 }
            let fields = ["correction-action-impact-v1",action.id,String(action.version),action.state,action.validity,
                          link?.id ?? "",link?.state ?? "",link?.externalID ?? "",link?.lastObservationID ?? "",
                          access.map { String($0.version) } ?? "",access?.enabled == true ? "enabled" : "paused",access?.calendarID ?? "",
                          String(claim.reviewVersion)]
            var sourceState: [String] = []
            for id in Set(try Self.correctionInputVersions(db,claimID: claim.id).map(\.sourceID)).sorted() {
                guard let source = try db.query("SELECT s.*,t.current_version_id FROM sources s LEFT JOIN transcripts t ON t.source_id=s.id WHERE s.id=?", [id]).first else {
                    throw VoiceOSError("纠错影响缺少引用来源")
                }
                sourceState += [id,source["state"] ?? "",source["policy_version"] ?? "",source["current_version_id"] ?? "",source["expected_hash"] ?? ""]
            }
            return .init(action: action,roots: orderedRoots,link: link,scheduleEffects: effects,understandingProgress: understandingProgress,summary: summary,
                         digest: try Self.actionHash(fields + orderedRoots.map(\.id) + operationState + sourceState))
        }
    }

    private func correctionUnderstandingProgress(sourceID: String) throws -> CorrectionUnderstandingProgress {
        guard let row = try db.query("SELECT s.state,s.local_only,s.policy_version,t.current_version_id FROM sources s LEFT JOIN transcripts t ON t.source_id=s.id WHERE s.id=?", [sourceID]).first,
              let version = row["current_version_id"] else {
            return .init(id: sourceID, sourceID: sourceID, summary: "原文更正已保留，目前没有可继续处理的文字。")
        }
        let summary: String
        if row["local_only"] != "0" {
            summary = "更正已保存在本机；当前文字未允许云端处理，不会自动发送。"
        } else if row["state"] != "saved" && row["state"] != "reference_only" {
            summary = "更正已保留；资料当前不可用，未继续处理。"
        } else if try db.query("""
            SELECT a.id FROM model_attempts a JOIN contexts c ON c.id=a.context_id
            JOIN context_inputs i ON i.context_id=c.id
            WHERE i.source_id=? AND i.transcript_version_id=? AND COALESCE(i.policy_version,1)=CAST(? AS INTEGER)
              AND c.state='current' AND a.state='completed' LIMIT 1
            """, [sourceID, version, row["policy_version"]]).first != nil {
            summary = "当前原文已有新的理解记录。旧任务的完成和反馈仍按原记录保留。"
        } else if let intent = try db.query("""
            SELECT state FROM processing_intents WHERE source_id=? AND transcript_version_id=? AND policy_version=CAST(? AS INTEGER)
            ORDER BY created_at DESC,id DESC LIMIT 1
            """, [sourceID, version, row["policy_version"]]).first {
            switch intent["state"] {
            case "queued", "running": summary = "正在根据更正后的原文更新理解，完成后会自动显示。"
            case "unknown": summary = "本次理解请求的结果尚未确认；原文已保存，为避免重复执行暂未重发。"
            case "cancelled": summary = "本次理解已停止，更正后的原文仍保留。"
            default: summary = "更正后的原文已保存，理解更新尚未完成；可在资料中查看处理情况。"
            }
        } else {
            summary = "更正后的原文已保存，尚未生成对应的新理解。"
        }
        return .init(id: sourceID, sourceID: sourceID, summary: summary)
    }
}
