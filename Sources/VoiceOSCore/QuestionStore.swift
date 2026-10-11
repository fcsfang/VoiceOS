import Foundation

public struct QuestionRecord: Identifiable, Sendable {
    public let id: String
    public let seed: QuestionSeedSnapshot
    public let version: Int
    public let status: QuestionStatus
    public let validity: String
    /// Only a changed active answer can be repaired by explicit reopen; migration/seed freezes cannot.
    public let canReopen: Bool
}
public struct QuestionRevision: Identifiable, Sendable {
    public let id: String
    public let questionID: String
    public let commandID: String
    public let input: QuestionTransitionSnapshot
    public let createdAt: String
}
extension VoiceOSStore {
    /// Explicit registration of an already typed question; no punctuation inference or model call.
    @discardableResult
    public func registerQuestion(_ seed: QuestionSeedSnapshot) throws -> String {
        try validateQuestionSeed(seed)
        if let existing = try db.query("SELECT id FROM questions WHERE claim_id=?", [seed.claimID]).first { return existing["id"]! }
        guard seed.contentKind == .question else { throw VoiceOSError("仅已分类的问题可以登记生命周期") }
        return try db.transaction { try insertQuestion(seed) }
    }
    func insertQuestion(_ seed: QuestionSeedSnapshot) throws -> String {
        let id = UUID().uuidString
        try db.execute("INSERT INTO questions(id,claim_id,seed_json,seed_digest,version,status,validity,created_at) VALUES(?,?,?,?,1,'open','current',?)", [id, seed.claimID, try Self.relevanceJSON(seed), seed.contentDigest, Self.now()])
        return id
    }
    /// Benign endorsement does not replace identity; provenance/content/ownership changes freeze it.
    func validateCurrentQuestionSeed(_ seed: QuestionSeedSnapshot) throws {
        guard let claim = try candidateClaims().first(where: { $0.id == seed.claimID }) else { throw VoiceOSError("问题候选已拒绝或依据冻结") }
        let fresh = try prepareQuestionSeed(claimID: claim.id, expectedReviewVersion: claim.reviewVersion, original: seed.original)
        guard fresh.statement == seed.statement, fresh.ownership == seed.ownership, fresh.contentKind == seed.contentKind,
              try Self.relevanceJSON(fresh.context) == Self.relevanceJSON(seed.context), fresh.policyVersions == seed.policyVersions else { throw VoiceOSError("问题内容、归属或出处已变化") }
    }
    public func questions(claimID: String? = nil) throws -> [QuestionRecord] {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        try Self.validateStoredQuestions(db)
        return try db.query("SELECT * FROM questions ORDER BY created_at,id").filter { claimID == nil || $0["claim_id"] == claimID }.map { row in
            let seed = try JSONDecoder().decode(QuestionSeedSnapshot.self, from: Data(row["seed_json"]!.utf8))
            var validity = row["validity"]!, canReopen = false
            if validity == "current" {
                do {
                    try validateCurrentQuestionSeed(seed)
                    // Earlier answers are history. Only the current resolved state depends on its answer.
                    if row["status"] == QuestionStatus.resolved.rawValue {
                        guard let active = try questionHistory(questionID: row["id"]!).last,
                              active.input.to == .resolved, let evidence = active.input.resolution,
                              let context = active.input.resolutionContext, let policy = active.input.resolutionPolicyVersion else { throw VoiceOSError("当前解决状态缺少答案") }
                        do {
                            try validateLocalTranscriptContext(context)
                            guard try sourcePolicy(sourceID: evidence.reference.sourceID).version == policy else { throw VoiceOSError("答案权限已变化") }
                        } catch { validity = "frozen"; canReopen = true }
                    }
                } catch { validity = "frozen" }
            }
            return .init(id: row["id"]!, seed: seed, version: Int(row["version"]!)!, status: QuestionStatus(rawValue: row["status"]!)!, validity: validity, canReopen: canReopen)
        }
    }
    public func questionHistory(questionID: String) throws -> [QuestionRevision] {
        try db.query("SELECT * FROM question_revisions WHERE question_id=? ORDER BY to_version", [questionID]).map {
            .init(id: $0["id"]!, questionID: questionID, commandID: $0["command_id"]!, input: try JSONDecoder().decode(QuestionTransitionSnapshot.self, from: Data($0["input_json"]!.utf8)), createdAt: $0["created_at"]!)
        }
    }
    public func prepareStoredQuestionTransition(questionID: String, expectedVersion: Int, to: QuestionStatus, reason: String, resolution: OutcomeSourceEvidence? = nil) throws -> QuestionTransitionSnapshot {
        guard let question = try questions().first(where: { $0.id == questionID }), (question.validity == "current" || (question.canReopen && to == .open)), question.version == expectedVersion,
              let claim = try candidateClaims().first(where: { $0.id == question.seed.claimID }) else { throw VoiceOSError("问题版本或依据已变化") }
        let fresh = try prepareQuestionSeed(claimID: claim.id, expectedReviewVersion: claim.reviewVersion, original: question.seed.original)
        return try prepareQuestionTransition(seed: fresh, expectedVersion: expectedVersion, from: question.status, to: to, reason: reason, resolution: resolution)
    }
    @discardableResult
    public func transitionQuestion(questionID: String, input: QuestionTransitionSnapshot, commandID: String = UUID().uuidString) throws -> Int {
        guard ready, !commandID.isEmpty else { throw VoiceOSError("问题转移命令无效") }
        let json = try Self.relevanceJSON(input), fingerprint = Self.relevanceHash(Data((questionID + ":" + json).utf8))
        if let old = try db.query("SELECT * FROM question_revisions WHERE command_id=?", [commandID]).first {
            guard old["question_id"] == questionID, old["input_digest"] == fingerprint else { throw VoiceOSError("同一问题命令不能更换内容") }
            return Int(old["to_version"]!)!
        }
        guard let question = try questions().first(where: { $0.id == questionID }), (question.validity == "current" || (question.canReopen && input.to == .open)),
              question.seed.claimID == input.seed.claimID, question.version == input.expectedVersion, question.status == input.from else { throw VoiceOSError("问题已更新或依据冻结，请重新读取") }
        try validateQuestionTransition(input)
        let next = input.expectedVersion + 1
        try db.transaction {
            try db.execute("INSERT INTO question_revisions(id,question_id,command_id,from_version,to_version,from_status,to_status,input_json,input_digest,actor,created_at) VALUES(?,?,?,?,?,?,?,?,?,'user',?)", [UUID().uuidString, questionID, commandID, String(input.expectedVersion), String(next), input.from.rawValue, input.to.rawValue, json, fingerprint, Self.now()])
            try db.execute("UPDATE questions SET version=?,status=? WHERE id=? AND version=?", [String(next), input.to.rawValue, questionID, String(input.expectedVersion)])
            try checkpoint(.questionUncommitted)
        }
        try checkpoint(.questionCommitted)
        return next
    }
    static func validateStoredQuestions(_ db: Database) throws {
        for row in try db.query("SELECT * FROM questions") {
            guard UUID(uuidString: row["id"] ?? "") != nil, ["current", "frozen"].contains(row["validity"] ?? ""),
                  let json = row["seed_json"], let version = row["version"].flatMap(Int.init), version > 0,
                  let claim = try db.query("SELECT * FROM claims WHERE id=?", [row["claim_id"]]).first else { throw VoiceOSError("问题历史身份缺失") }
            let seed = try JSONDecoder().decode(QuestionSeedSnapshot.self, from: Data(json.utf8))
            try validateStoredQuestionSeed(db, seed: seed, claim: claim)
            guard row["seed_digest"] == seed.contentDigest else { throw VoiceOSError("问题摘要不一致") }
            var expectedVersion = 1, status = QuestionStatus.open
            for revision in try db.query("SELECT * FROM question_revisions WHERE question_id=? ORDER BY to_version", [row["id"]]) {
                guard let inputJSON = revision["input_json"], UUID(uuidString: revision["id"] ?? "") != nil,
                      !(revision["command_id"] ?? "").isEmpty, revision["actor"] == "user",
                      revision["input_digest"] == relevanceHash(Data((row["id"]! + ":" + inputJSON).utf8)) else { throw VoiceOSError("问题转移历史身份或摘要不一致") }
                let input = try JSONDecoder().decode(QuestionTransitionSnapshot.self, from: Data(inputJSON.utf8))
                try validateStoredQuestionSeed(db, seed: input.seed, claim: claim)
                guard input.seed.statement == seed.statement, input.seed.ownership == seed.ownership,
                      try relevanceJSON(input.seed.original) == relevanceJSON(seed.original),
                      try relevanceJSON(input.seed.context) == relevanceJSON(seed.context), input.seed.policyVersions == seed.policyVersions,
                      input.expectedVersion == expectedVersion, input.from == status, input.to != status,
                      revision["from_version"] == String(expectedVersion), revision["to_version"] == String(expectedVersion + 1),
                      revision["from_status"] == input.from.rawValue, revision["to_status"] == input.to.rawValue,
                      ![QuestionStatus.resolved, .closed].contains(status) || input.to == .open,
                      !input.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.reason.unicodeScalars.count <= 2000 else { throw VoiceOSError("问题版本或状态链不完整") }
                if input.to == .resolved {
                    guard let evidence = input.resolution, let context = input.resolutionContext, let policy = input.resolutionPolicyVersion,
                          try relevanceJSON(evidence.reference) != relevanceJSON(seed.original.reference) else { throw VoiceOSError("问题解决历史缺少新增答案") }
                    try validateStoredQuestionContext(db, context: context, policies: [evidence.reference.sourceID: policy])
                    try validateQuestionEvidence(evidence, context: context, personal: true)
                } else { guard input.resolution == nil, input.resolutionContext == nil, input.resolutionPolicyVersion == nil else { throw VoiceOSError("非解决事件包含答案") } }
                expectedVersion += 1; status = input.to
            }
            guard version == expectedVersion, row["status"] == status.rawValue else { throw VoiceOSError("问题当前版本与历史不一致") }
        }
    }
    private static func validateStoredQuestionSeed(_ db: Database, seed: QuestionSeedSnapshot, claim: [String: String]) throws {
        let review = try db.query("SELECT * FROM claim_reviews WHERE claim_id=? AND version=?", [seed.claimID, String(seed.claimReviewVersion)]).first
        guard UUID(uuidString: seed.id) != nil, seed.claimID == claim["id"], seed.contentKind == .question, claim["content_kind"] == "question",
              seed.claimReviewVersion >= 0, seed.claimReviewVersion == 0 || review != nil,
              seed.statement == (review?["statement"] ?? claim["statement"]), seed.ownership == (review?["ownership"] ?? claim["ownership"]),
              seed.statement == claim["statement"], review?["decision"] != "rejected", try questionSeedDigest(seed) == seed.contentDigest else { throw VoiceOSError("问题与原认知历史不一致") }
        let references = try JSONDecoder().decode([ClaimReference].self, from: Data(claim["refs_json"]!.utf8))
        guard references.contains(where: { $0.sourceID == seed.original.reference.sourceID && $0.transcriptVersionID == seed.original.reference.transcriptVersionID && $0.spanID == seed.original.reference.spanID }),
              Set(references.map(\.sourceID)) == Set(seed.context.sources.map(\.sourceID)) else { throw VoiceOSError("问题引用未选入原认知") }
        try validateStoredQuestionContext(db, context: seed.context, policies: seed.policyVersions)
        try validateQuestionEvidence(seed.original, context: seed.context, personal: seed.ownership == "user_tentative")
    }
    private static func validateStoredQuestionContext(_ db: Database, context: LocalTranscriptContext, policies: [String: Int]) throws {
        guard context.scalarBudget > 0, context.sources.reduce(0, { $0 + $1.text.unicodeScalars.count }) <= context.scalarBudget,
              context.contentDigest == (try relevanceHash(Data(relevanceJSON(context.sources).utf8))),
              !context.sources.isEmpty, Set(context.sources.map(\.sourceID)).count == context.sources.count, Set(policies.keys) == Set(context.sources.map(\.sourceID)) else { throw VoiceOSError("问题上下文身份无效") }
        for source in context.sources {
            guard let row = try db.query("SELECT v.text,v.spans_json,t.source_id,t.input_version_id,s.origin,s.speaker,s.policy_version,s.local_only FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?", [source.transcriptVersionID]).first,
                  row["source_id"] == source.sourceID, row["input_version_id"] == source.sourceVersionID,
                  row["origin"] == source.origin, row["speaker"] == source.speaker, row["text"] == source.text,
                  try relevanceJSON(JSONDecoder().decode([TranscriptSpan].self, from: Data(row["spans_json"]!.utf8))) == relevanceJSON(source.spans),
                  let policy = policies[source.sourceID], policy > 0, policy <= Int(row["policy_version"]!)! else { throw VoiceOSError("问题原话版本不一致") }
            let local = row["policy_version"] == String(policy) ? row["local_only"] : try db.query("SELECT from_local_only FROM source_policy_revisions WHERE source_id=? AND from_version=?", [source.sourceID, String(policy)]).first?["from_local_only"]
            guard local == (source.localOnly ? "1" : "0") else { throw VoiceOSError("问题历史权限不一致") }
        }
    }
}
