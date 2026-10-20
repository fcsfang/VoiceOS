import Foundation

public struct ExpressionAssociationRequest: Sendable {
    public let attemptID: String
    public let snapshot: ExpressionAssociationSnapshot
    public let configuration: ModelConfiguration
}
public struct ExpressionAssociationResponse: Sendable {
    public let proposals: [ExpressionAssociationProposal]
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(proposals: [ExpressionAssociationProposal], inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.proposals = proposals; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}
public protocol ExpressionAssociationPort: Sendable {
    var configuration: ModelConfiguration { get }
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse
}
public struct ExpressionAssociationAttempt: Identifiable, Sendable {
    public let id: String
    public let currentSourceID: String
    public let snapshot: ExpressionAssociationSnapshot
    public let state: String
    public let validity: String
    public let proposals: [ExpressionAssociationProposal]
    public let usage: [String: Int]?
    public let error: String?
}
extension VoiceOSStore {
    // Preference/candidate changes must not resend the same current expression/configuration.
    static func expressionAssociationKey(_ snapshot: ExpressionAssociationSnapshot, _ config: ModelConfiguration) throws -> String {
        let source = snapshot.current.sources[0]
        return relevanceHash(try relevanceJSON(["association-request-v1", source.sourceID, source.sourceVersionID, source.transcriptVersionID, String(snapshot.policyVersion), config.provider, config.model, config.promptVersion, config.schemaVersion, config.destination.rawValue]).data(using: .utf8)!)
    }
    func existingExpressionAssociation(_ snapshot: ExpressionAssociationSnapshot) throws -> ExpressionAssociationAttempt? {
        let source = snapshot.current.sources[0]
        return try expressionAssociationAttempts().first {
            $0.currentSourceID == source.sourceID && $0.snapshot.policyVersion == snapshot.policyVersion &&
            $0.snapshot.current.sources[0].transcriptVersionID == source.transcriptVersionID &&
            $0.snapshot.current.sources[0].sourceVersionID == source.sourceVersionID
        }
    }
    public func reserveExpressionAssociation(_ snapshot: ExpressionAssociationSnapshot, configuration: ModelConfiguration) throws -> String {
        try validateExpressionAssociation(snapshot)
        guard configuration.destination == snapshot.destination, !configuration.provider.isEmpty,
              !configuration.model.isEmpty, !configuration.promptVersion.isEmpty, !configuration.schemaVersion.isEmpty,
              !snapshot.candidates.isEmpty else { throw VoiceOSError("关联没有候选或端口身份/目的地不符；无需发送") }
        let key = try Self.expressionAssociationKey(snapshot, configuration)
        if let existing = try existingExpressionAssociation(snapshot) { return existing.id }
        let snapshotJSON = try Self.relevanceJSON(snapshot)
        guard snapshotJSON.utf8.count <= 160000 else { throw VoiceOSError("关联快照超过字节预算；不发送") }
        let contextID = try persistLocalContext(snapshot.current, commandID: "expression-association:" + key, destination: snapshot.destination)
        let id = UUID().uuidString
        try db.execute("""
        INSERT INTO expression_association_attempts(id,request_key,context_id,current_source_id,destination,provider,model,prompt_version,schema_version,snapshot_json,snapshot_digest,state,validity,created_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,'reserved','current',?)
        """, [id, key, contextID, snapshot.current.sources[0].sourceID, configuration.destination.rawValue, configuration.provider, configuration.model, configuration.promptVersion, configuration.schemaVersion, snapshotJSON, snapshot.contentDigest, Self.now()])
        try checkpoint(.associationReserved)
        return id
    }
    public func performExpressionAssociation(_ snapshot: ExpressionAssociationSnapshot, using port: any ExpressionAssociationPort) async throws -> ExpressionAssociationAttempt {
        try Task.checkCancellation()
        try validateExpressionAssociation(snapshot)
        if let existing = try existingExpressionAssociation(snapshot) {
            guard existing.state != "reserved" else { throw VoiceOSError("关联请求已有预留；不重复发送") }
            return existing
        }
        let id = try reserveExpressionAssociation(snapshot, configuration: port.configuration)
        let response: ExpressionAssociationResponse
        do {
            try Task.checkCancellation()
            try validateExpressionAssociation(snapshot)
            response = try await port.associate(ExpressionAssociationRequest(attemptID: id, snapshot: snapshot, configuration: port.configuration))
        } catch ModelPortFailure.rejected(_, let input, let output) {
            try settleExpressionAssociation(id, reason: "关联响应未接纳；不自动重发", input: input, output: output)
            throw VoiceOSError("关联响应未接纳，已保留已知用量")
        } catch {
            try settleExpressionAssociation(id, reason: "关联结果未知；不自动重发")
            throw error
        }
        do {
            try Task.checkCancellation()
            try validateExpressionAssociation(snapshot)
            guard (response.inputTokens ?? 0) >= 0, (response.outputTokens ?? 0) >= 0 else { throw VoiceOSError("关联用量无效") }
            try Self.validateExpressionAssociationProposals(response.proposals, snapshot: snapshot)
            let result = try Self.relevanceJSON(response.proposals)
            try db.transaction {
                guard try db.query("SELECT state,validity FROM expression_association_attempts WHERE id=?", [id]).first == ["state": "reserved", "validity": "current"] else { throw VoiceOSError("关联预留已失效") }
                try db.execute("UPDATE expression_association_attempts SET state='completed',result_json=?,result_digest=?,usage_json=? WHERE id=?", [result, Self.relevanceHash(Data(result.utf8)), try associationUsage(response.inputTokens, response.outputTokens), id])
                try checkpoint(.associationUncommitted)
            }
        } catch {
            try settleExpressionAssociation(id, reason: "关联结果因来源、权限、偏好或取消未接纳；不自动重发", input: response.inputTokens, output: response.outputTokens)
            throw error
        }
        try checkpoint(.associationCommitted)
        guard let record = try expressionAssociationAttempts().first(where: { $0.id == id }) else { throw VoiceOSError("关联结果缺失") }
        return record
    }
    private func associationUsage(_ input: Int?, _ output: Int?) throws -> String {
        try Self.relevanceJSON(["input_tokens": input, "output_tokens": output].compactMapValues { value in value.flatMap { $0 >= 0 ? $0 : nil } })
    }
    private func settleExpressionAssociation(_ id: String, reason: String, input: Int? = nil, output: Int? = nil) throws {
        try db.execute("UPDATE expression_association_attempts SET state='unknown',error=?,usage_json=? WHERE id=? AND state='reserved'", [reason, try associationUsage(input, output), id])
    }
    public func expressionAssociationAttempts() throws -> [ExpressionAssociationAttempt] {
        try Self.validateStoredExpressionAssociations(db)
        return try db.query("SELECT * FROM expression_association_attempts ORDER BY created_at,id").map { row in
            let snapshot = try JSONDecoder().decode(ExpressionAssociationSnapshot.self, from: Data(row["snapshot_json"]!.utf8))
            var validity = row["validity"]!
            if validity == "current" {
                do {
                    if row["state"] == "completed" { try validateExpressionAssociationSources(snapshot) }
                    else { try validateExpressionAssociation(snapshot) }
                    _ = try localContext(id: row["context_id"]!)
                }
                catch { validity = "frozen"; try db.execute("UPDATE expression_association_attempts SET validity='frozen' WHERE id=?", [row["id"]]) }
            }
            return ExpressionAssociationAttempt(id: row["id"]!, currentSourceID: row["current_source_id"]!, snapshot: snapshot, state: row["state"]!, validity: validity,
                proposals: try row["result_json"].map { try JSONDecoder().decode([ExpressionAssociationProposal].self, from: Data($0.utf8)) } ?? [],
                usage: try row["usage_json"].map { try JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) }, error: row["error"])
        }
    }
    static func validateStoredExpressionAssociations(_ db: Database) throws {
        for row in try db.query("SELECT * FROM expression_association_attempts") {
            guard let json = row["snapshot_json"], json.utf8.count <= 160000 else { throw VoiceOSError("关联快照超限") }
            let snapshot = try JSONDecoder().decode(ExpressionAssociationSnapshot.self, from: Data(json.utf8))
            try validateExpressionAssociationProposals([], snapshot: snapshot)
            let config = ModelConfiguration(provider: row["provider"]!, model: row["model"]!, promptVersion: row["prompt_version"]!, schemaVersion: row["schema_version"]!, destination: snapshot.destination)
            guard UUID(uuidString: row["id"]!) != nil, !snapshot.candidates.isEmpty, !config.provider.isEmpty, !config.model.isEmpty, !config.promptVersion.isEmpty, !config.schemaVersion.isEmpty,
                  row["destination"] == snapshot.destination.rawValue, row["snapshot_digest"] == snapshot.contentDigest,
                  row["current_source_id"] == snapshot.current.sources[0].sourceID,
                  row["request_key"] == (try expressionAssociationKey(snapshot, config)),
                  let context = try db.query("SELECT * FROM contexts WHERE id=?", [row["context_id"]]).first,
                  context["destination"] == snapshot.destination.rawValue, context["digest"] == snapshot.current.contentDigest,
                  context["snapshot_json"] == (try relevanceJSON(snapshot.current)),
                  let input = try db.query("SELECT * FROM context_inputs WHERE context_id=?", [row["context_id"]]).first,
                  input["source_id"] == snapshot.current.sources[0].sourceID, input["policy_version"] == String(snapshot.policyVersion) else { throw VoiceOSError("关联身份、上下文或调用配置不一致") }
            guard try db.query("SELECT id FROM context_inputs WHERE context_id=?", [row["context_id"]]).count == 1,
                  input["transcript_version_id"] == snapshot.current.sources[0].transcriptVersionID else { throw VoiceOSError("关联当前上下文目录不一致") }
            if snapshot.preferenceVersion == 0 {
                guard snapshot.preferenceMode == .normal else { throw VoiceOSError("关联默认偏好不一致") }
            } else {
                guard try db.query("SELECT mode FROM cognitive_feedback_preferences WHERE version=?", [String(snapshot.preferenceVersion)]).first?["mode"] == snapshot.preferenceMode.rawValue else { throw VoiceOSError("关联偏好历史不一致") }
            }
            let source = snapshot.current.sources[0]
            guard let version = try db.query("SELECT v.*,t.current_version_id,t.source_id,t.input_version_id,s.origin,s.speaker,s.duration FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?", [source.transcriptVersionID]).first,
                  version["source_id"] == source.sourceID, version["input_version_id"] == source.sourceVersionID,
                  version["origin"] == source.origin, version["speaker"] == source.speaker,
                  try isPrunedHistoricalTranscript(version, historical: context["state"] == "stale") ||
                    (version["text"] == source.text && relevanceJSON(JSONDecoder().decode([TranscriptSpan].self, from: Data(version["spans_json"]!.utf8))) == relevanceJSON(source.spans)) else { throw VoiceOSError("关联当前原话历史不一致") }
            try SpeechText(text: source.text, spans: source.spans).validate(duration: version["duration"].flatMap(Double.init))
            try validateAssociationPolicy(db, sourceID: source.sourceID, version: snapshot.policyVersion, localOnly: source.localOnly)
            for hit in snapshot.candidates { try validateAssociationHistoricalHit(db, hit: hit) }
            if row["state"] == "completed" {
                guard let result = row["result_json"], row["result_digest"] == relevanceHash(Data(result.utf8)) else { throw VoiceOSError("关联结果摘要不一致") }
                try validateExpressionAssociationProposals(JSONDecoder().decode([ExpressionAssociationProposal].self, from: Data(result.utf8)), snapshot: snapshot)
            } else { guard row["result_json"] == nil, row["result_digest"] == nil else { throw VoiceOSError("未完成关联不能含接纳结果") } }
            if let usage = row["usage_json"] {
                let values = try JSONDecoder().decode([String: Int].self, from: Data(usage.utf8))
                guard Set(values.keys).isSubset(of: ["input_tokens", "output_tokens"]), values.values.allSatisfy({ $0 >= 0 }) else { throw VoiceOSError("关联历史用量无效") }
            }
        }
    }
    private static func validateAssociationPolicy(_ db: Database, sourceID: String, version: Int, localOnly: Bool) throws {
        guard let source = try db.query("SELECT policy_version,local_only FROM sources WHERE id=?", [sourceID]).first,
              version > 0, version <= Int(source["policy_version"]!)! else { throw VoiceOSError("关联历史授权身份无效") }
        let local = source["policy_version"] == String(version) ? source["local_only"] : try db.query("SELECT from_local_only FROM source_policy_revisions WHERE source_id=? AND from_version=?", [sourceID, String(version)]).first?["from_local_only"]
        guard local == (localOnly ? "1" : "0") else { throw VoiceOSError("关联历史授权不一致") }
    }
    private static func validateAssociationHistoricalHit(_ db: Database, hit: RetrievalHit) throws {
        let d = hit.document
        guard d.id == d.sourceID + ":" + d.transcriptVersionID + ":" + String(d.textStart),
              let version = try db.query("SELECT v.*,t.current_version_id,t.source_id,t.input_version_id,s.name,s.origin,s.created_at FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?", [d.transcriptVersionID]).first,
              version["source_id"] == d.sourceID, version["input_version_id"] == d.sourceVersionID,
              version["name"] == d.name, version["origin"] == d.origin, version["created_at"] == d.createdAt else { throw VoiceOSError("关联历史窗口身份不一致") }
        let text = Array(version["text"]!.unicodeScalars), spans = try JSONDecoder().decode([TranscriptSpan].self, from: Data(version["spans_json"]!.utf8))
        guard d.textStart >= 0, d.textEnd > d.textStart, d.textEnd - d.textStart == d.text.unicodeScalars.count, !d.spanID.isEmpty,
              isPrunedHistoricalTranscript(version, historical: true) ||
                (d.textEnd <= text.count && spans.contains(where: { $0.id == d.spanID && $0.textStart <= d.textStart && $0.textEnd >= d.textEnd }) &&
                 String(String.UnicodeScalarView(text[d.textStart..<d.textEnd])) == d.text) else { throw VoiceOSError("关联历史窗口内容不一致") }
        try validateAssociationPolicy(db, sourceID: d.sourceID, version: d.policyVersion, localOnly: d.localOnly)
    }
}
