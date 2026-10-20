import Foundation
import CryptoKit

public struct RecordingProcessingRequest: Identifiable, Sendable {
    public let id: String
    public let sourceID: String
    public let state: String
    public let processingIntentID: String?
    public let error: String?
}
extension VoiceOSStore {
    /// Explicit record-and-process choice. Source, text-only consent and request commit
    /// together before the caller opens the device. Ordinary beginDictation stays local.
    public func beginProcessingDictation(commandID: String = UUID().uuidString, cognition: ModelConfiguration, association: ModelConfiguration) throws -> RecordingIntent {
        let c = ProcessingModelIdentity(cognition), a = ProcessingModelIdentity(association)
        guard c.isValid, a.isValid, c.destination == a.destination else { throw VoiceOSError("录制处理端口身份无效") }
        let cj = try Self.relevanceJSON(c), aj = try Self.relevanceJSON(a)
        if let old = try db.query("SELECT * FROM recording_processing_requests WHERE command_id=?", [commandID]).first {
            guard old["cognition_json"] == cj, old["association_json"] == aj, old["state"] == "waiting" else { throw VoiceOSError("录制处理命令已使用或端口改变") }
            return try beginDictation(commandID: commandID)
        }
        guard try db.query("SELECT id FROM sources WHERE command_id=?", [commandID]).isEmpty else { throw VoiceOSError("普通录制不能升级为自动处理请求") }
        let intent = try db.transaction {
            let intent = try beginDictation(commandID: commandID)
            guard try db.query("SELECT id FROM recording_processing_requests WHERE source_id=?", [intent.sourceID]).isEmpty,
                  try sourcePolicy(sourceID: intent.sourceID).version == 1 else { throw VoiceOSError("录制命令不能改变既有处理范围") }
            // New source only, inside this transaction; no derived cognition exists yet.
            let policyVersion = c.destination == .cloud ? 2 : 1
            if c.destination == .cloud {
                let fingerprint = SHA256.hash(data: try JSONSerialization.data(withJSONObject: [intent.sourceID,"1","false"])).map { String(format:"%02x", $0) }.joined()
                try db.execute("INSERT INTO source_policy_revisions(id,source_id,from_version,to_version,from_local_only,to_local_only,command_id,input_fingerprint,actor,created_at) VALUES(?,?,1,2,1,0,?,?,'user',?)", [UUID().uuidString,intent.sourceID,"record-consent:"+commandID,fingerprint,Self.processingNow()])
                try db.execute("UPDATE sources SET local_only=0,policy_version=2 WHERE id=?", [intent.sourceID])
            }
            let version = try db.query("SELECT version_id FROM sources WHERE id=?", [intent.sourceID]).first!["version_id"]!
            let now = Self.processingNow()
            try db.execute("INSERT INTO recording_processing_requests(id,command_id,source_id,source_version_id,policy_version,cognition_json,association_json,state,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'waiting',?,?)", [UUID().uuidString,commandID,intent.sourceID,version,String(policyVersion),cj,aj,now,now])
            try checkpoint(.recordingRequestUncommitted)
            return intent
        }
        try checkpoint(.recordingRequestCommitted)
        return intent
    }
    public func recordingProcessingRequests() throws -> [RecordingProcessingRequest] {
        try db.query("SELECT * FROM recording_processing_requests ORDER BY created_at,id").map {
            .init(id:$0["id"]!,sourceID:$0["source_id"]!,state:$0["state"]!,processingIntentID:$0["processing_intent_id"],error:$0["error"])
        }
    }
    private func setRecordingRequest(_ id: String, state: String, error: String? = nil, queueID: String? = nil) throws {
        try db.execute("UPDATE recording_processing_requests SET state=?,error=?,processing_intent_id=COALESCE(?,processing_intent_id),updated_at=? WHERE id=?", [state,error,queueID,Self.processingNow(),id])
    }
    @discardableResult
    public func cancelRecordingProcessingRequest(id: String) throws -> Bool {
        guard let row = try db.query("SELECT * FROM recording_processing_requests WHERE id=?", [id]).first else { throw VoiceOSError("录音处理请求不存在") }
        guard ["waiting","enqueued"].contains(row["state"] ?? "") else { return false }
        return try db.transaction {
            let queue = try row["processing_intent_id"] ?? db.query("SELECT id FROM processing_intents WHERE command_id=?", ["record-process:"+id]).first?["id"]
            if let queue {
                let receipt = try processingIntent(id:queue)
                guard [.queued,.running].contains(receipt.state) else {
                    try setRecordingRequest(id,state:"enqueued",queueID:queue)
                    return false
                }
                _ = try cancelExpressionProcessingIntent(id:queue,reason:"用户取消录音处理请求")
            }
            try setRecordingRequest(id,state:"cancelled",error:"用户取消；原件与本地逐字稿保留",queueID:queue)
            return true
        }
    }
    /// No await or model dispatch here. A failed local transcript remains waiting for
    /// explicit transcription retry; interrupted recordings require explicit sealing.
    public func reconcileRecordingProcessingRequests(cognition: ModelConfiguration, association: ModelConfiguration) throws {
        for row in try db.query("SELECT * FROM recording_processing_requests WHERE state='waiting' ORDER BY created_at,id") {
            let id = row["id"]!, source = row["source_id"]!
            if let queue = try db.query("SELECT * FROM processing_intents WHERE command_id=?", ["record-process:"+id]).first {
                guard queue["source_id"] == source, queue["policy_version"] == row["policy_version"],
                      let snapshot = try? JSONDecoder().decode(ExpressionProcessingIntentSnapshot.self,from:Data(queue["snapshot_json"]!.utf8)),
                      try Self.relevanceJSON(snapshot.cognition) == row["cognition_json"],
                      try Self.relevanceJSON(snapshot.association) == row["association_json"] else { throw VoiceOSError("录音队列归属或处理范围不符") }
                try setRecordingRequest(id, state: "enqueued", queueID:queue["id"]); continue
            }
            guard let current = try sources().first(where: {$0.id == source}) else { throw VoiceOSError("录音来源不存在") }
            let sourceVersion = try db.query("SELECT version_id FROM sources WHERE id=?", [source]).first?["version_id"]
            guard sourceVersion == row["source_version_id"], current.policyVersion == Int(row["policy_version"]!),
                  current.origin == "user", current.speaker == "user" else {
                try setRecordingRequest(id, state:"blocked", error:"录音身份或授权已变化；未发起模型请求"); continue
            }
            guard row["cognition_json"] == (try Self.relevanceJSON(ProcessingModelIdentity(cognition))),
                  row["association_json"] == (try Self.relevanceJSON(ProcessingModelIdentity(association))) else {
                try setRecordingRequest(id, state:"blocked", error:"模型身份已变化；请另行明确处理"); continue
            }
            if current.state == "quarantined" || current.state == "reference_only" {
                try setRecordingRequest(id, state:"blocked", error:"录音原件不可用"); continue
            }
            guard current.state == "saved", current.jobState == "completed" else { continue }
            do {
                guard !(current.transcript ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VoiceOSError("逐字稿为空") }
                // Only the original local transcription may satisfy the automatic request.
                guard try db.query("SELECT version_no FROM transcript_versions WHERE id=?", [current.transcriptVersionID]).first?["version_no"] == "1" else { throw VoiceOSError("逐字稿已更正；需重新明确处理") }
                let snapshot = try prepareExpressionProcessingIntent(sourceID:source,cognition:cognition,association:association)
                let queue = try enqueueExpressionProcessingIntent(snapshot,commandID:"record-process:"+id,cognition:cognition,association:association)
                try checkpoint(.recordingRequestQueueCommitted)
                try setRecordingRequest(id,state:"enqueued",queueID:queue.id)
            } catch {
                // If the queue committed, retain waiting for idempotent reconciliation;
                // never mark a committed queue as absent or dispatch another request.
                if try db.query("SELECT id FROM processing_intents WHERE command_id=?", ["record-process:"+id]).isEmpty {
                    try setRecordingRequest(id,state:"blocked",error:error.localizedDescription)
                } else { throw error }
            }
        }
    }
    static func validateStoredRecordingProcessingRequests(_ db: Database) throws {
        for row in try db.query("SELECT r.*,s.command_id AS source_command_id,s.input_fingerprint,s.version_id,s.origin,s.speaker FROM recording_processing_requests r JOIN sources s ON s.id=r.source_id") {
            guard UUID(uuidString:row["id"]!) != nil, !(row["command_id"] ?? "").isEmpty,
                  row["input_fingerprint"] == "microphone-v1:"+row["source_id"]!, row["source_version_id"] == row["version_id"],
                  row["command_id"] == row["source_command_id"], row["origin"] == "user", row["speaker"] == "user", let epoch = Int(row["policy_version"]!), [1,2].contains(epoch),
                  let c = try? JSONDecoder().decode(ProcessingModelIdentity.self,from:Data(row["cognition_json"]!.utf8)),
                  let a = try? JSONDecoder().decode(ProcessingModelIdentity.self,from:Data(row["association_json"]!.utf8)), c.isValid,a.isValid,c.destination == a.destination,
                  epoch == (c.destination == .cloud ? 2 : 1) else { throw VoiceOSError("录音处理请求身份或初始授权不一致") }
            if epoch == 2 {
                guard let grant = try db.query("SELECT * FROM source_policy_revisions WHERE source_id=? AND to_version=2", [row["source_id"]]).first,
                      grant["from_version"] == "1", grant["from_local_only"] == "1", grant["to_local_only"] == "0",
                      grant["command_id"] == "record-consent:"+row["command_id"]!, grant["actor"] == "user",
                      grant["input_fingerprint"] == SHA256.hash(data:try JSONSerialization.data(withJSONObject:[row["source_id"]!,"1","false"])).map({String(format:"%02x",$0)}).joined() else { throw VoiceOSError("录音处理缺少明确的文本授权历史") }
            }
            if let queueID = row["processing_intent_id"] {
                guard let queue = try db.query("SELECT * FROM processing_intents WHERE id=?", [queueID]).first,
                      queue["source_id"] == row["source_id"], queue["command_id"] == "record-process:"+row["id"]!, queue["policy_version"] == row["policy_version"],
                      let snapshot = try? JSONDecoder().decode(ExpressionProcessingIntentSnapshot.self, from:Data(queue["snapshot_json"]!.utf8)), snapshot.cognition == c, snapshot.association == a else { throw VoiceOSError("录音请求与持久队列不一致") }
            } else if row["state"] == "enqueued" { throw VoiceOSError("已入队录音请求缺少回执") }
        }
    }
}
