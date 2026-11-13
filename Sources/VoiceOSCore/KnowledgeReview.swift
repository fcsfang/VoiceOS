import Foundation

public enum KnowledgeReviewIssueKind: String, Codable, Sendable {
    case factualError, missingCondition, unsupportedInference, disputed, transcriptionUncertain
}
public struct KnowledgeReviewInput: Codable, Sendable {
    public let sourceID: String
    public let transcriptVersionID: String
    public let policyVersion: Int
    public let context: LocalTranscriptContext
    public let claimReviewVersions: [String: Int]
    public let inputDigest: String
    public var continuousExpression:ContinuousRecordingContext? = nil
}
public struct KnowledgeReviewCandidate: Identifiable, Codable, Sendable {
    public let id: String
    public let quote: String
    public let reason: String
    public let publicQuery: String
    public let transcriptionUncertain: Bool
    public init(id: String, quote: String, reason: String, publicQuery: String = "", transcriptionUncertain: Bool = false) {
        self.id=id;self.quote=quote;self.reason=reason;self.publicQuery=publicQuery;self.transcriptionUncertain=transcriptionUncertain
    }
}
public struct KnowledgeReviewSelection: Codable, Sendable {
    public let candidates: [KnowledgeReviewCandidate]
    public let responseID: String
    public init(candidates: [KnowledgeReviewCandidate], responseID: String) { self.candidates=candidates;self.responseID=responseID }
}
public struct KnowledgeReviewIssue: Identifiable, Codable, Sendable {
    public let id: String
    public let quote: String
    public let kind: KnowledgeReviewIssueKind
    public let explanation: String
    public let betterUnderstanding: String
    public let boundary: String
    public let counterexample: String
    public let references: [AssistantReference]
    public let responseIDs: [String]
    public init(id: String, quote: String, kind: KnowledgeReviewIssueKind, explanation: String, betterUnderstanding: String, boundary: String, counterexample: String, references: [AssistantReference], responseIDs: [String]) {
        self.id=id;self.quote=quote;self.kind=kind;self.explanation=explanation;self.betterUnderstanding=betterUnderstanding;self.boundary=boundary;self.counterexample=counterexample;self.references=references;self.responseIDs=responseIDs
    }
}
public struct KnowledgeReviewCheck: Sendable {
    public let issue: KnowledgeReviewIssue?
    public let responseIDs: [String]
    public init(issue: KnowledgeReviewIssue?, responseIDs: [String]) { self.issue=issue;self.responseIDs=responseIDs }
}
public protocol KnowledgeReviewPort: Sendable {
    var configuration: ModelConfiguration { get }
    func identify(_ input: KnowledgeReviewInput) async throws -> KnowledgeReviewSelection
    func check(_ candidate: KnowledgeReviewCandidate, input: KnowledgeReviewInput) async throws -> KnowledgeReviewCheck
    func check(_ candidate: KnowledgeReviewCandidate, input: KnowledgeReviewInput, authorize: @escaping @Sendable () async throws -> Void) async throws -> KnowledgeReviewCheck
}
public extension KnowledgeReviewPort {
    func check(_ candidate: KnowledgeReviewCandidate, input: KnowledgeReviewInput, authorize: @escaping @Sendable () async throws -> Void) async throws -> KnowledgeReviewCheck {
        try await authorize()
        let result = try await check(candidate, input: input)
        try await authorize()
        return result
    }
}
public struct KnowledgeReviewRecord: Identifiable, Sendable {
    public let id: String
    public let sourceID: String
    public let inputDigest: String
    public let state: String
    public var validity: String { state == "frozen" ? "frozen" : "current" }
    public let issues: [KnowledgeReviewIssue]
    public let responseIDs: [String]
    public let error: String?
    public let createdAt: String
}
private struct KnowledgeReviewProgress: Codable {
    var selection: KnowledgeReviewSelection?
    var checkedIDs: [String] = []
    var issues: [KnowledgeReviewIssue] = []
}
struct KnowledgeReviewContinuousSignature: Equatable {
    struct Member: Equatable {
        let sourceID: String
        let sourceVersionID: String
        let transcriptVersionID: String
        let origin: String
        let speaker: String
        let localOnly: Bool
        let textLength: Int
        let transcriptionReviewJSON: String?
    }
    let expressionID: String
    let scalarBudget: Int
    let sources: [Member]
    let policies: [String: Int]
    let recordingContextsJSON: String?
}
extension KnowledgeReviewContinuousSignature {
    init?(_ value: ContinuousRecordingContext, sourceID: String, source: ContextTranscript) {
        let sourceReviewJSON = source.transcriptionReview.flatMap { try? VoiceOSStore.relevanceJSON($0) }
        guard source.transcriptionReview == nil || sourceReviewJSON != nil,
              !value.expressionID.isEmpty,
              value.digest == value.context.contentDigest,
              value.context.conversationFocus == nil,
              value.context.reflectionFocus == nil,
              !value.context.sources.isEmpty,
              Set(value.context.sources.map(\.sourceID)).count == value.context.sources.count,
              value.context.scalarBudget == max(1, value.context.sources.reduce(0) { $0 + $1.text.unicodeScalars.count }),
              Set(value.policies.keys) == Set(value.context.sources.map(\.sourceID)),
              value.policies.values.allSatisfy({ $0 > 0 }),
              let member = value.context.sources.first(where: { $0.sourceID == sourceID }),
              member.sourceVersionID == source.sourceVersionID,
              member.transcriptVersionID == source.transcriptVersionID,
              member.origin == source.origin,
              member.speaker == source.speaker,
              member.localOnly == source.localOnly,
              member.text == source.text,
              member.transcriptionReview.flatMap { try? VoiceOSStore.relevanceJSON($0) } == sourceReviewJSON,
              let contentJSON = try? VoiceOSStore.relevanceJSON(value.context.sources),
              VoiceOSStore.relevanceHash(Data(contentJSON.utf8)) == value.digest else { return nil }
        let contextsJSON = value.context.recordingContexts.flatMap { try? VoiceOSStore.relevanceJSON($0) }
        guard value.context.recordingContexts == nil || contextsJSON != nil else { return nil }
        var members: [Member] = []
        for item in value.context.sources {
            let reviewJSON = item.transcriptionReview.flatMap { try? VoiceOSStore.relevanceJSON($0) }
            guard item.transcriptionReview == nil || reviewJSON != nil else { return nil }
            members.append(.init(sourceID: item.sourceID, sourceVersionID: item.sourceVersionID, transcriptVersionID: item.transcriptVersionID, origin: item.origin, speaker: item.speaker, localOnly: item.localOnly, textLength: item.text.unicodeScalars.count, transcriptionReviewJSON: reviewJSON))
        }
        self.init(expressionID: value.expressionID, scalarBudget: value.context.scalarBudget, sources: members, policies: value.policies, recordingContextsJSON: contextsJSON)
    }
}
struct KnowledgeReviewSourceSignature: Equatable {
    let sourceVersionID: String
    let transcriptVersionID: String
    let origin: String
    let speaker: String
    let localOnly: Bool
    let policyVersion: Int
    let scalarBudget: Int
    let transcriptionReviewJSON: String?
    let claimReviewVersions: [String: Int]
    let continuous: KnowledgeReviewContinuousSignature?
}
extension KnowledgeReviewSourceSignature {
    init?(_ input: KnowledgeReviewInput, storedDigest: String) {
        guard input.inputDigest == storedDigest,
              input.policyVersion > 0,
              !input.claimReviewVersions.isEmpty,
              input.context.sources.count == 1,
              let source = input.context.sources.first,
              source.sourceID == input.sourceID,
              source.transcriptVersionID == input.transcriptVersionID,
              source.origin == "user",
              source.speaker == "user",
              input.context.scalarBudget == source.text.unicodeScalars.count,
              input.context.conversationFocus == nil,
              input.context.reflectionFocus == nil,
              input.context.recordingContexts == nil else { return nil }
        let sourceJSON: String
        do { sourceJSON = try VoiceOSStore.relevanceJSON(input.context.sources) } catch { return nil }
        let contentDigest = VoiceOSStore.relevanceHash(Data(sourceJSON.utf8))
        guard contentDigest == input.context.contentDigest else { return nil }
        let reviewJSON = source.transcriptionReview.flatMap { try? VoiceOSStore.relevanceJSON($0) }
        guard source.transcriptionReview == nil || reviewJSON != nil else { return nil }
        var continuous: KnowledgeReviewContinuousSignature?
        if let stored = input.continuousExpression {
            guard let value = KnowledgeReviewContinuousSignature(stored, sourceID: input.sourceID, source: source) else { return nil }
            continuous = value
        }
        self.init(sourceVersionID: source.sourceVersionID,transcriptVersionID: source.transcriptVersionID,origin: source.origin,speaker: source.speaker,localOnly: source.localOnly,policyVersion: input.policyVersion,scalarBudget: input.context.scalarBudget,transcriptionReviewJSON: reviewJSON,claimReviewVersions: input.claimReviewVersions,continuous: continuous)
    }
}

extension VoiceOSStore {
    public func prepareKnowledgeReview(sourceID: String) throws -> KnowledgeReviewInput {
        knowledgeReviewPreparations += 1
        guard ready, let source = try sources().first(where: { $0.id == sourceID }),source.origin == "user",source.speaker == "user",!source.needsTranscriptionReview,let text = source.transcript,!text.isEmpty,let version = source.transcriptVersionID else { throw VoiceOSError("知识核查只接受已有完整原话的个人资料") }
        let claims = try latestCandidateClaims(for: sourceID)
        guard !claims.isEmpty else { throw VoiceOSError("请先完成这份原话的理解，再进行知识核查") }
        let context = try prepareLocalTranscriptContext(sourceIDs:[sourceID],scalarBudget:max(1,text.unicodeScalars.count))
        let policy = try sourcePolicy(sourceID: sourceID)
        let reviews = Dictionary(uniqueKeysWithValues: claims.map { ($0.id,$0.reviewVersion) })
        let continuous=try continuousRecordingContext(sourceID:sourceID)
        var digestParts=[try Self.relevanceJSON(context),String(policy.version),try Self.relevanceJSON(reviews)]
        if let continuous { digestParts.append(try Self.relevanceJSON(continuous)) }
        let digest = Self.relevanceHash(Data(try Self.relevanceJSON(digestParts).utf8))
        return .init(sourceID:sourceID,transcriptVersionID:version,policyVersion:policy.version,context:context,claimReviewVersions:reviews,inputDigest:digest,continuousExpression:continuous)
    }
    private func validateKnowledgeReviewInput(_ input: KnowledgeReviewInput, destination: ModelDestination) throws {
        let current = try prepareKnowledgeReview(sourceID:input.sourceID)
        guard try Self.relevanceJSON(current) == Self.relevanceJSON(input) else { throw VoiceOSError("原话、归属、理解或授权已变化，旧知识核查已暂停") }
        if destination == .cloud,input.context.sources.contains(where:\.localOnly) { throw VoiceOSError("仅本地原话不能用于云端知识核查") }
    }
    private struct KnowledgeReviewSourceFacts {
        let sourceID: String
        let state: String
        let kind: String
        let sourceVersionID: String
        let transcriptVersionID: String
        let origin: String
        let speaker: String
        let localOnly: Bool
        let policyVersion: Int
        let textLength: Int
        let presentation: RecordingPresentation?
        let transcriptionReview: TranscriptionReview?
        let transcriptionReviewJSON: String?
        let needsTranscriptionReview: Bool
    }
    private enum KnowledgeReviewContinuousLookup {
        case absent
        case present(KnowledgeReviewContinuousSignature)
        case unavailable
    }
    private static let knowledgeReviewSourceSelection = """
    SELECT s.id,s.state,s.kind,s.version_id AS source_version_id,s.origin,s.speaker,s.local_only,s.policy_version,s.duration,s.relative_path,s.presentation_json,
           t.input_version_id,t.current_version_id,t.backend,v.id AS transcript_version_id,length(v.text) AS text_length,v.spans_json,
           (SELECT COUNT(*) FROM transcripts t2 WHERE t2.source_id=s.id) AS transcript_count
    FROM sources s
    LEFT JOIN transcripts t ON t.source_id=s.id
    LEFT JOIN transcript_versions v ON v.id=t.current_version_id
    """
    private func knowledgeReviewSourceFacts(sourceID: String) throws -> KnowledgeReviewSourceFacts? {
        guard let row = try db.query(Self.knowledgeReviewSourceSelection + " WHERE s.id=?",[sourceID]).first else { return nil }
        return try knowledgeReviewSourceFacts(row)
    }
    private func knowledgeReviewSourceFacts(sourceIDs: [String]) throws -> [String: KnowledgeReviewSourceFacts]? {
        guard !sourceIDs.isEmpty,Set(sourceIDs).count == sourceIDs.count else { return nil }
        let placeholders = Array(repeating: "?",count: sourceIDs.count).joined(separator: ",")
        var result: [String: KnowledgeReviewSourceFacts] = [:]
        for row in try db.query(Self.knowledgeReviewSourceSelection + " WHERE s.id IN (\(placeholders))",sourceIDs) {
            guard let facts = try knowledgeReviewSourceFacts(row),result[facts.sourceID] == nil else { return nil }
            result[facts.sourceID] = facts
        }
        return result.count == sourceIDs.count ? result : nil
    }
    private func knowledgeReviewSourceFacts(_ row: [String: String]) throws -> KnowledgeReviewSourceFacts? {
        guard ["saved","reference_only"].contains(row["state"] ?? ""),
              let sourceID = row["id"],let kind = row["kind"],let sourceVersion = row["source_version_id"],let origin = row["origin"],let speaker = row["speaker"],
              let transcriptVersion = row["transcript_version_id"],transcriptVersion == row["current_version_id"],row["input_version_id"] == sourceVersion,
              let transcriptCount = row["transcript_count"].flatMap(Int.init),transcriptCount == 1,
              let textLength = row["text_length"].flatMap(Int.init),textLength >= 0,
              let policyVersion = row["policy_version"].flatMap(Int.init),policyVersion > 0,
              let spansJSON = row["spans_json"],
              let spans = try? JSONDecoder().decode([TranscriptSpan].self,from:Data(spansJSON.utf8)),
              Set(spans.map(\.id)).count == spans.count,spans.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { return nil }
        var offset = 0
        for span in spans {
            guard span.textStart == offset,span.textEnd > span.textStart,span.textEnd <= textLength else { return nil }
            if let start = span.startMS,let end = span.endMS {
                guard start >= 0,end >= start,let duration = row["duration"].flatMap(Double.init),Double(end) <= duration * 1000 + 1 else { return nil }
            } else if span.startMS != nil || span.endMS != nil { return nil }
            offset = span.textEnd
        }
        guard offset == textLength else { return nil }
        if row["state"] == "saved" {
            guard let relativePath = row["relative_path"],let url = try? assetURL(relativePath: relativePath),hasCurrentVerifiedFile(url) else { return nil }
        }
        var presentation: RecordingPresentation?
        if let json = row["presentation_json"] {
            guard let decoded = try? JSONDecoder().decode(RecordingPresentation.self,from:Data(json.utf8)) else { return nil }
            presentation = decoded
        }
        let review = presentation?.transcriptionReview.flatMap { $0.transcriptVersionID == transcriptVersion ? $0 : nil }
        let reviewJSON = review.flatMap { try? Self.relevanceJSON($0) }
        guard review == nil || reviewJSON != nil else { return nil }
        let needsReview = ["audio","video"].contains(kind) && row["backend"]?.hasPrefix("Qwen3-ASR") == true && !spans.isEmpty &&
            spans.allSatisfy { $0.startMS != nil && $0.endMS != nil } && review?.isCompleteFullTextReview != true
        return .init(sourceID: sourceID,state: row["state"]!,kind: kind,sourceVersionID: sourceVersion,transcriptVersionID: transcriptVersion,origin: origin,speaker: speaker,localOnly: row["local_only"] != "0",policyVersion: policyVersion,textLength: textLength,presentation: presentation,transcriptionReview: review,transcriptionReviewJSON: reviewJSON,needsTranscriptionReview: needsReview)
    }
    private func knowledgeReviewPairingIsValid(_ pair: RecordingContext, personal: KnowledgeReviewSourceFacts?, external: KnowledgeReviewSourceFacts?) -> Bool {
        guard let personal,let external,
              pair.personalSourceID == personal.sourceID,
              personal.origin == "user",personal.speaker == "user",
              external.origin == "external",external.speaker != "user",
              !personal.localOnly,!external.localOnly,
              !personal.needsTranscriptionReview,!external.needsTranscriptionReview,
              personal.transcriptVersionID == pair.personalVersionID,
              external.transcriptVersionID == pair.externalVersionID,
              personal.policyVersion == pair.personalPolicyVersion,
              external.policyVersion == pair.externalPolicyVersion else { return false }
        return true
    }
    private func knowledgeReviewContinuousSignature(sourceID: String, base: KnowledgeReviewSourceFacts) throws -> KnowledgeReviewContinuousLookup {
        let expression = base.presentation?.expression
        let memberIDs = expression?.sourceIDs ?? [sourceID]
        var facts: [String: KnowledgeReviewSourceFacts]
        if let expression {
            guard expression.state == "completed",!memberIDs.isEmpty,Set(memberIDs).count == memberIDs.count,
                  let memberFacts = try knowledgeReviewSourceFacts(sourceIDs: memberIDs) else { return .unavailable }
            for id in memberIDs {
                guard let member = memberFacts[id],
                      member.presentation?.expression?.id == expression.id,
                      member.transcriptVersionID == expression.versions[id],
                      member.policyVersion == expression.policies[id],
                      !member.localOnly,member.state == "saved",member.kind != "ai_text" else { return .unavailable }
                if let pair = member.presentation?.recordingContext {
                    guard expression.externalVersions?[pair.externalSourceID] == pair.externalVersionID,
                          expression.externalPolicies?[pair.externalSourceID] == pair.externalPolicyVersion else { return .unavailable }
                }
            }
            if let externalVersions = expression.externalVersions,!externalVersions.isEmpty {
                guard let externalFacts = try knowledgeReviewSourceFacts(sourceIDs: Array(externalVersions.keys)) else { return .unavailable }
                for (id,version) in externalVersions {
                    guard let external = externalFacts[id],external.transcriptVersionID == version,
                          external.policyVersion == expression.externalPolicies?[id],
                          !external.localOnly,!external.needsTranscriptionReview else { return .unavailable }
                }
            }
            facts = memberFacts
        } else {
            facts = [sourceID: base]
        }
        var expanded = memberIDs,seen = Set(memberIDs)
        for id in memberIDs {
            guard let pair = facts[id]?.presentation?.recordingContext else { continue }
            let external = try knowledgeReviewSourceFacts(sourceID: pair.externalSourceID)
            guard knowledgeReviewPairingIsValid(pair,personal: facts[id],external: external) else { return .unavailable }
            if seen.insert(pair.externalSourceID).inserted { expanded.append(pair.externalSourceID) }
        }
        guard expanded.count > 1 else { return .absent }
        let missing = expanded.filter { facts[$0] == nil }
        if !missing.isEmpty {
            guard let extra = try knowledgeReviewSourceFacts(sourceIDs: missing) else { return .unavailable }
            facts.merge(extra) { first,_ in first }
        }
        let expandedSet = Set(expanded)
        var members: [KnowledgeReviewContinuousSignature.Member] = [],policies: [String:Int] = [:],contexts: [RecordingContext] = []
        for id in expanded {
            guard let item = facts[id],item.kind != "ai_text" else { return .unavailable }
            members.append(.init(sourceID: item.sourceID,sourceVersionID: item.sourceVersionID,transcriptVersionID: item.transcriptVersionID,origin: item.origin,speaker: item.speaker,localOnly: item.localOnly,textLength: item.textLength,transcriptionReviewJSON: item.transcriptionReviewJSON))
            policies[id] = item.policyVersion
            if let pair = item.presentation?.recordingContext,expandedSet.contains(pair.externalSourceID) { contexts.append(pair) }
        }
        let contextsJSON: String?
        if contexts.isEmpty { contextsJSON = nil } else { contextsJSON = try Self.relevanceJSON(contexts) }
        return .present(.init(expressionID: expression?.id ?? base.presentation?.recordingContext?.sessionID ?? sourceID,scalarBudget: max(1,expanded.reduce(0) { $0 + (facts[$1]?.textLength ?? 0) }),sources: members,policies: policies,recordingContextsJSON: contextsJSON))
    }
    private func knowledgeReviewSignature(sourceID: String) throws -> KnowledgeReviewSourceSignature? {
        guard ready,knowledgeReviewScanFastPathEnabled else { return nil }
        guard let base = try knowledgeReviewSourceFacts(sourceID: sourceID),
              base.origin == "user",base.speaker == "user",base.kind != "ai_text",
              base.textLength > 0,!base.needsTranscriptionReview else { return nil }
        let continuous: KnowledgeReviewContinuousSignature?
        switch try knowledgeReviewContinuousSignature(sourceID: sourceID,base: base) {
        case .absent: continuous = nil
        case .present(let value): continuous = value
        case .unavailable: return nil
        }
        guard let claims = try knowledgeReviewClaimVersions(sourceID: sourceID),!claims.isEmpty else { return nil }
        return .init(sourceVersionID: base.sourceVersionID,transcriptVersionID: base.transcriptVersionID,origin: base.origin,speaker: base.speaker,localOnly: base.localOnly,policyVersion: base.policyVersion,scalarBudget: base.textLength,transcriptionReviewJSON: base.transcriptionReviewJSON,claimReviewVersions: claims,continuous: continuous)
    }
    private func knowledgeReviewClaimVersions(sourceID: String) throws -> [String: Int]? {
        guard let attempt = try db.query("""
        SELECT a.id FROM model_attempts a JOIN context_inputs i ON i.context_id=a.context_id
        WHERE i.source_id=? AND a.state='completed' AND a.provider NOT LIKE 'english_feedback:%'
        ORDER BY a.producer_sequence DESC,a.created_at DESC,a.id DESC LIMIT 1
        """,[sourceID]).first?["id"] else { return [:] }
        var result: [String: Int] = [:]
        for row in try db.query("""
        SELECT c.id,c.review_version,c.refs_json FROM claims c
        JOIN model_attempts a ON a.id=c.attempt_id JOIN contexts x ON x.id=a.context_id
        LEFT JOIN claim_reviews r ON r.claim_id=c.id AND r.version=c.review_version
        WHERE c.attempt_id=? AND c.validity='current' AND x.state='current' AND COALESCE(r.decision,'pending')!='rejected'
          AND json_extract(x.snapshot_json,'$.reflectionFocus') IS NULL
        """,[attempt]) {
            guard let id = row["id"],let version = row["review_version"].flatMap(Int.init),let refsJSON = row["refs_json"],
                  let refs = try? JSONDecoder().decode([ClaimReference].self,from:Data(refsJSON.utf8)) else { return nil }
            if refs.contains(where: { $0.sourceID == sourceID }) { result[id] = version }
        }
        return result
    }
    @discardableResult
    public func enqueueKnowledgeReview(sourceID: String, retry: Bool = false) throws -> KnowledgeReviewRecord {
        let reviews = try knowledgeReviews(sourceID:sourceID)
        if knowledgeReviewScanFastPathEnabled {
            let rows = try db.query("SELECT id,state,input_digest,input_json FROM knowledge_reviews WHERE source_id=? AND state!='frozen' ORDER BY created_at DESC,id",[sourceID])
            let current: KnowledgeReviewSourceSignature?
            do { current = try knowledgeReviewSignature(sourceID: sourceID) } catch { current = nil }
            if let current {
                for row in rows {
                    guard let storedJSON = row["input_json"],
                          let storedInput = try? decodeWithPath(KnowledgeReviewInput.self,from:Data(storedJSON.utf8),label:"知识核查输入"),
                          let stored = KnowledgeReviewSourceSignature(storedInput,storedDigest: row["input_digest"] ?? ""),
                          stored == current,let id = row["id"],let record = reviews.first(where: { $0.id == id }) else { continue }
                    if retry,record.state == "failed" {
                        try db.execute("UPDATE knowledge_reviews SET state='queued',error=NULL WHERE id=?",[id])
                        return try knowledgeReviews(sourceID:sourceID).first { $0.id == id }!
                    }
                    return record
                }
            }
        }
        let input = try prepareKnowledgeReview(sourceID:sourceID)
        if let row = try db.query("SELECT * FROM knowledge_reviews WHERE source_id=? AND input_digest=? AND state!='frozen' ORDER BY created_at DESC,id",[sourceID,input.inputDigest]).first {
            if retry,row["state"] == "failed" { try db.execute("UPDATE knowledge_reviews SET state='queued',error=NULL WHERE id=?",[row["id"]]) }
            return try knowledgeReviews(sourceID:sourceID).first { $0.id == row["id"] }!
        }
        let id = UUID().uuidString
        try db.execute("INSERT INTO knowledge_reviews(id,source_id,input_digest,input_json,state,response_ids_json,created_at) VALUES(?,?,?,?,'queued','[]',?)",[id,sourceID,input.inputDigest,try Self.relevanceJSON(input),Self.now()])
        return try knowledgeReviews(sourceID:sourceID).first { $0.id == id }!
    }
    public func knowledgeReviews(sourceID: String? = nil) throws -> [KnowledgeReviewRecord] {
        let rows = try db.query("SELECT * FROM knowledge_reviews \(sourceID == nil ? "" : "WHERE source_id=?") ORDER BY created_at DESC,id",sourceID.map { [$0] } ?? [])
        var signatures: [String: KnowledgeReviewSourceSignature] = [:]
        return try rows.map { row in
            var state = row["state"]!
            let input = try decodeWithPath(KnowledgeReviewInput.self,from:Data(row["input_json"]!.utf8),label:"知识核查输入")
            if state != "frozen" {
                var fresh = false
                if knowledgeReviewScanFastPathEnabled,let stored = KnowledgeReviewSourceSignature(input,storedDigest: row["input_digest"] ?? "") {
                    let current: KnowledgeReviewSourceSignature?
                    if let cached = signatures[input.sourceID] { current = cached }
                    else {
                        current = try? knowledgeReviewSignature(sourceID: input.sourceID)
                        if let current { signatures[input.sourceID] = current }
                    }
                    fresh = current == stored
                }
                if !fresh,(try? validateKnowledgeReviewInput(input,destination:.local)) == nil {
                    state="frozen";try db.execute("UPDATE knowledge_reviews SET state='frozen',error='原话、理解或授权已变化；保留历史核查' WHERE id=?",[row["id"]])
                }
            }
            let progress = try row["result_json"].map { try decodeWithPath(KnowledgeReviewProgress.self,from:Data($0.utf8),label:"知识核查进度") }
            let ids = try decodeWithPath([String].self,from:Data((row["response_ids_json"] ?? "[]").utf8),label:"知识核查回执")
            return .init(id:row["id"]!,sourceID:row["source_id"]!,inputDigest:row["input_digest"]!,state:state,issues:progress?.issues ?? [],responseIDs:ids,error:state == "frozen" ? "原话、理解或授权已变化；保留历史核查" : row["error"],createdAt:row["created_at"]!)
        }
    }
    public func pendingKnowledgeReviews() throws -> [KnowledgeReviewRecord] { try knowledgeReviews().filter { $0.state == "queued" } }
    public func recoverKnowledgeReviews() throws {
        try db.execute("UPDATE knowledge_reviews SET state='failed',error='核查因应用退出中断；可手动重试，已登记结果保留' WHERE state='running'")
    }
    @discardableResult
    public func processKnowledgeReview(sourceID: String, using port: any KnowledgeReviewPort, retry: Bool = false) async throws -> KnowledgeReviewRecord {
        let record = try enqueueKnowledgeReview(sourceID:sourceID,retry:retry)
        guard record.state == "queued" else { return record }
        guard let row = try db.query("SELECT * FROM knowledge_reviews WHERE id=? AND state='queued'",[record.id]).first else { throw VoiceOSError("这份知识核查已开始") }
        let input = try decodeWithPath(KnowledgeReviewInput.self,from:Data(row["input_json"]!.utf8),label:"知识核查输入")
        var progress = try row["result_json"].map { try decodeWithPath(KnowledgeReviewProgress.self,from:Data($0.utf8),label:"知识核查进度") } ?? KnowledgeReviewProgress()
        var responseIDs = try decodeWithPath([String].self,from:Data((row["response_ids_json"] ?? "[]").utf8),label:"知识核查回执")
        try db.execute("UPDATE knowledge_reviews SET state='running',error=NULL WHERE id=?",[record.id])
        do {
            try validateKnowledgeReviewInput(input,destination:port.configuration.destination)
            if progress.selection == nil {
                let selection = try await port.identify(input)
                try validateKnowledgeReviewInput(input,destination:port.configuration.destination)
                let checked = try Self.validateKnowledgeSelection(selection,input:input)
                progress.selection=checked;responseIDs.append(checked.responseID)
                try saveKnowledgeProgress(progress,responseIDs:responseIDs,id:record.id)
            }
            for candidate in progress.selection!.candidates where !progress.checkedIDs.contains(candidate.id) {
                try Task.checkCancellation();try validateKnowledgeReviewInput(input,destination:port.configuration.destination)
                let check: KnowledgeReviewCheck
                if candidate.transcriptionUncertain || Self.knowledgeQuoteNeedsTranscriptionReview(candidate.quote,input:input) {
                    check = .init(issue:.init(id:candidate.id,quote:candidate.quote,kind:.transcriptionUncertain,explanation:"这段原话仍有转写疑点，不能据此认定知识错误。",betterUnderstanding:"先核对原音和原意，再核查知识判断。",boundary:"尚未确认用户实际表达。",counterexample:"",references:[],responseIDs:[]),responseIDs:[])
                } else { check = try await port.check(candidate,input:input,authorize: { try await self.validateKnowledgeReviewInput(input,destination:port.configuration.destination) }) }
                try Task.checkCancellation();try validateKnowledgeReviewInput(input,destination:port.configuration.destination)
                try Self.validateKnowledgeCheck(check,candidate:candidate,input:input)
                if let issue = check.issue { progress.issues.append(issue) }
                progress.checkedIDs.append(candidate.id);responseIDs.append(contentsOf:check.responseIDs)
                try saveKnowledgeProgress(progress,responseIDs:responseIDs,id:record.id)
            }
            try db.execute("UPDATE knowledge_reviews SET state='completed' WHERE id=? AND state='running'",[record.id])
        } catch {
            let message: String
            if case ModelPortFailure.rejected(let reason,_,_) = error { message=reason } else { message=error.localizedDescription }
            try db.execute("UPDATE knowledge_reviews SET state='failed',error=? WHERE id=? AND state='running'",[message,record.id])
        }
        return try knowledgeReviews(sourceID:sourceID).first { $0.id == record.id }!
    }
    private func saveKnowledgeProgress(_ progress: KnowledgeReviewProgress, responseIDs:[String], id:String) throws {
        guard try db.query("SELECT state FROM knowledge_reviews WHERE id=?",[id]).first?["state"] == "running" else { throw VoiceOSError("核查已暂停，不接纳后续结果") }
        try db.execute("UPDATE knowledge_reviews SET result_json=?,response_ids_json=? WHERE id=?",[try Self.relevanceJSON(progress),try Self.relevanceJSON(responseIDs),id])
    }
    static func knowledgeQuoteNeedsTranscriptionReview(_ quote: String,input: KnowledgeReviewInput) -> Bool {
        guard let source=input.context.sources.first else { return true }
        let spans = Set(source.transcriptionReview?.unresolved_issues?.map(\.span_id) ?? [])
        guard !spans.isEmpty else { return false }
        let text = Array(source.text.unicodeScalars), query = Array(quote.unicodeScalars)
        guard !query.isEmpty,query.count<=text.count else { return true }
        for start in 0...(text.count-query.count) where Array(text[start..<(start+query.count)]) == query {
            if source.spans.contains(where: { spans.contains($0.id) && $0.textStart < start+query.count && $0.textEnd > start }) { return true }
        }
        return false
    }
    @discardableResult
    static func validateKnowledgeSelection(_ selection: KnowledgeReviewSelection,input:KnowledgeReviewInput) throws -> KnowledgeReviewSelection {
        guard !selection.responseID.isEmpty else { throw VoiceOSError("知识核查候选缺少真实连续原话或身份") }
        let text = input.context.sources[0].text
        var seen = Set<String>()
        let candidates = selection.candidates.filter {
            !$0.id.isEmpty && !$0.quote.isEmpty && text.contains($0.quote) && seen.insert($0.id).inserted
        }
        return .init(candidates: candidates, responseID: selection.responseID)
    }
    static func validateKnowledgeCheck(_ check:KnowledgeReviewCheck,candidate:KnowledgeReviewCandidate,input:KnowledgeReviewInput) throws {
        guard check.responseIDs.allSatisfy({ !$0.isEmpty }) else { throw VoiceOSError("知识核查缺少模型回执") }
        if let issue=check.issue {
            guard issue.id == candidate.id,issue.quote == candidate.quote,!issue.explanation.isEmpty,!issue.betterUnderstanding.isEmpty,
                  Set(issue.responseIDs).isSubset(of:Set(check.responseIDs)),issue.references.allSatisfy({ ref in guard let url=URL(string:ref.url) else { return false };return ["http","https"].contains(url.scheme ?? "") && url.host != nil }),
                  issue.kind == .transcriptionUncertain || !issue.references.isEmpty,
                  !(candidate.transcriptionUncertain || knowledgeQuoteNeedsTranscriptionReview(candidate.quote,input:input)) || issue.kind == .transcriptionUncertain else { throw VoiceOSError("知识核查引用、原话或转写不确定性不一致") }
        }
    }
    static func validateStoredKnowledgeReviews(_ database:Database) throws {
        for row in try database.query("SELECT * FROM knowledge_reviews") {
            let input=try JSONDecoder().decode(KnowledgeReviewInput.self,from:Data((row["input_json"] ?? "").utf8))
            guard row["source_id"] == input.sourceID,row["input_digest"] == input.inputDigest,input.context.sources.count == 1,
                  let source=input.context.sources.first,source.sourceID == input.sourceID,source.transcriptVersionID == input.transcriptVersionID,source.origin == "user",source.speaker == "user",input.policyVersion>0,
                  input.context.contentDigest == relevanceHash(Data(try relevanceJSON(input.context.sources).utf8)),
                  ["queued","running","completed","failed","frozen"].contains(row["state"] ?? "") else { throw VoiceOSError("知识核查原话身份或状态不一致") }
            guard let stored=try database.query("SELECT v.text,v.reason,v.actor,v.spans_json,t.current_version_id,s.duration FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=? AND t.source_id=?",[input.transcriptVersionID,input.sourceID]).first else { throw VoiceOSError("知识核查原话版本不存在") }
            let superseded=stored["reason"] == "ai_superseded" && stored["actor"] == "system" && stored["text"] == "" && stored["spans_json"] == "[]" && stored["current_version_id"] != input.transcriptVersionID
            guard stored["text"] == source.text || superseded else { throw VoiceOSError("知识核查原话快照与版本不一致") }
            try SpeechText(text:source.text,spans:source.spans).validate(duration:stored["duration"].flatMap(Double.init))
            if superseded {
                // Qwen replaces its earlier transcript with an identity-only
                // placeholder. Preserve this historical snapshot, never reuse it.
                try database.execute("UPDATE knowledge_reviews SET state='frozen',error='原转写已由音频核对取代；保留历史核查快照' WHERE id=?",[row["id"]])
            }
            var digestParts=[try Self.relevanceJSON(input.context),String(input.policyVersion),try Self.relevanceJSON(input.claimReviewVersions)]
            if let continuous=input.continuousExpression { digestParts.append(try Self.relevanceJSON(continuous)) }
            let expected=Self.relevanceHash(Data(try Self.relevanceJSON(digestParts).utf8))
            guard expected == input.inputDigest else { throw VoiceOSError("知识核查输入摘要损坏") }
            for (id,version) in input.claimReviewVersions {
                guard let claim=try database.query("SELECT review_version FROM claims WHERE id=?",[id]).first,version>=0,version<=(claim["review_version"].flatMap(Int.init) ?? -1) else { throw VoiceOSError("知识核查认知版本不存在") }
            }
            let responseIDs=try JSONDecoder().decode([String].self,from:Data((row["response_ids_json"] ?? "").utf8))
            if let raw=row["result_json"] {
                let progress=try JSONDecoder().decode(KnowledgeReviewProgress.self,from:Data(raw.utf8))
                guard let selection=progress.selection else { throw VoiceOSError("知识核查缺少候选识别回执") }
                let normalized = try validateKnowledgeSelection(selection,input:input)
                guard normalized.candidates.map(\.id) == selection.candidates.map(\.id),
                      normalized.candidates.map(\.quote) == selection.candidates.map(\.quote) else { throw VoiceOSError("知识核查进度链不完整") }
                guard responseIDs.contains(selection.responseID),Set(progress.checkedIDs).count == progress.checkedIDs.count,Set(progress.checkedIDs).isSubset(of:Set(selection.candidates.map(\.id))),Set(progress.issues.map(\.id)).count == progress.issues.count,
                      row["state"] != "completed" || Set(progress.checkedIDs) == Set(selection.candidates.map(\.id)) else { throw VoiceOSError("知识核查进度链不完整") }
                for issue in progress.issues {
                    guard let candidate=selection.candidates.first(where: { $0.id == issue.id }),progress.checkedIDs.contains(issue.id) else { throw VoiceOSError("知识核查引用未知候选") }
                    try validateKnowledgeCheck(.init(issue:issue,responseIDs:responseIDs),candidate:candidate,input:input)
                }
            } else if row["state"] == "completed" { throw VoiceOSError("知识核查完成记录缺少结果") }
        }
    }
}
