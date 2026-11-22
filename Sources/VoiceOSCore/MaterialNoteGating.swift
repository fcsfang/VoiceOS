import Foundation

/// 笔记生成前的许可门控与生成后的过期判定。两者都是纯函数，
/// 不碰存储与模型端口，便于 VoiceOSCoreTests 直接覆盖门控矩阵。
public enum MaterialNoteGating {
    /// 成员材料参与生成前必须满足的条件；按成员顺序返回首个不满足的原因。
    /// 「资料库尚未打开」「文本模型未配置」属于编排层条件，不在此判定。
    public static func unavailableReason(memberIDs: [String], catalog: [String: SourceRecord]) -> String? {
        for id in memberIDs {
            guard let record = catalog[id] else { return "材料已变化或已移出资料库" }
            guard ["saved", "reference_only"].contains(record.state) else { return "材料尚未保存完成" }
            guard !record.localOnly else { return "仅本机保存" }
            guard let transcript = record.transcript,
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.transcriptVersionID != nil else { return "尚无转写" }
        }
        return nil
    }

    /// 当前库中每位成员的转写版本映射；缺失的成员与没有版本的成员不参与映射。
    public static func transcriptVersions(memberIDs: [String], catalog: [String: SourceRecord]) -> [String: String] {
        var versions: [String: String] = [:]
        for id in memberIDs {
            if let version = catalog[id]?.transcriptVersionID { versions[id] = version }
        }
        return versions
    }
}

/// 生成前拍下的成员版本与许可快照。生成后逐字段比对，
/// 任一项变化即视为结果过期；材料离开资料库同样过期。
public struct MaterialNoteMemberSnapshot: Equatable, Sendable {
    public let sourceID: String
    public let transcriptVersionID: String?
    public let policyVersion: Int
    public let localOnly: Bool
    public let state: String

    public init(_ record: SourceRecord) {
        sourceID = record.id
        transcriptVersionID = record.transcriptVersionID
        policyVersion = record.policyVersion
        localOnly = record.localOnly
        state = record.state
    }

    /// 材料仍在库中、仍处于可参与生成的状态，且四个字段与快照一致。
    public func matches(_ record: SourceRecord?) -> Bool {
        guard let record else { return false }
        return record.state == state && record.transcriptVersionID == transcriptVersionID &&
            record.policyVersion == policyVersion && record.localOnly == localOnly &&
            ["saved", "reference_only"].contains(record.state)
    }
}