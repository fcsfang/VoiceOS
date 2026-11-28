import Foundation
import CryptoKit

public struct SourcePolicy: Sendable {
    public let localOnly: Bool
    public let version: Int
}

extension VoiceOSStore {
    public func sourcePolicy(sourceID: String) throws -> SourcePolicy {
        guard let row = try db.query("SELECT local_only,policy_version FROM sources WHERE id=?", [sourceID]).first else { throw VoiceOSError("来源不存在") }
        guard let version = row["policy_version"].flatMap(Int.init), version > 0 else { throw VoiceOSError("来源授权版本无效") }
        return SourcePolicy(localOnly: row["local_only"] != "0", version: version)
    }
    @discardableResult
    public func setSourceLocalOnly(sourceID: String, expectedVersion: Int, localOnly: Bool, commandID: String = UUID().uuidString) throws -> Int {
        if !localOnly {
            guard try db.query("SELECT state FROM sources WHERE id=?", [sourceID]).first?["state"] != "trashed" else { throw VoiceOSError("请先从回收站恢复材料，再允许云端处理") }
        }
        let fingerprint = try Self.sourcePolicyFingerprint(sourceID: sourceID, version: expectedVersion, localOnly: localOnly)
        if let receipt = try db.query("SELECT * FROM source_policy_revisions WHERE command_id=?", [commandID]).first {
            guard receipt["input_fingerprint"] == fingerprint else { throw VoiceOSError("同一授权命令不能改变内容") }
            return Int(receipt["to_version"]!)!
        }
        let result = try db.transaction {
            let old = try sourcePolicy(sourceID: sourceID)
            guard old.version == expectedVersion else { throw VoiceOSError("来源授权已经更新，请重新读取") }
            let next = try recordSourcePolicyChange(sourceID: sourceID, from: old, localOnly: localOnly,
                                                    commandID: commandID, fingerprint: fingerprint)
            try invalidateCognition(sourceID: sourceID)
            try checkpoint(.policyUncommitted)
            return next
        }
        try checkpoint(.policyCommitted)
        return result
    }
    static func sourcePolicyFingerprint(sourceID: String, version: Int, localOnly: Bool) throws -> String {
        let fields = [sourceID, String(version), String(localOnly)]
        return SHA256.hash(data: try JSONSerialization.data(withJSONObject: fields)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Used inside the caller's transaction so the policy and its revision commit together.
    func recordSourcePolicyChange(sourceID: String, from old: SourcePolicy, localOnly: Bool,
                                  commandID: String, fingerprint: String) throws -> Int {
        guard old.localOnly != localOnly else { throw VoiceOSError("来源授权没有变化") }
        let next = old.version + 1
        let value = localOnly ? "1" : "0"
        try db.execute("""
        INSERT INTO source_policy_revisions(id,source_id,from_version,to_version,from_local_only,to_local_only,command_id,input_fingerprint,actor,created_at)
        VALUES(?,?,?,?,?,?,?,?,'user',?)
        """, [UUID().uuidString, sourceID, String(old.version), String(next), old.localOnly ? "1" : "0",
              value, commandID, fingerprint, TimestampFormatting.iso.string(from: Date())])
        try db.execute("UPDATE sources SET local_only=?,policy_version=? WHERE id=?", [value, String(next), sourceID])
        return next
    }

    /// The caller already holds the current source row from its identity check.
    static func historicalSourcePolicyMatches(_ db: Database, source: [String: String],
                                              sourceID: String, version: Int, localOnly: Bool) throws -> Bool {
        let stored: String?
        if source["policy_version"] == String(version) {
            stored = source["local_only"]
        } else {
            stored = try db.query("""
            SELECT from_local_only FROM source_policy_revisions WHERE source_id=? AND from_version=?
            """, [sourceID, String(version)]).first?["from_local_only"]
        }
        return stored == (localOnly ? "1" : "0")
    }
}
