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

extension VoiceOSStore {
    public func prepareKnowledgeReview(sourceID: String) throws -> KnowledgeReviewInput {
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
    @discardableResult
    public func enqueueKnowledgeReview(sourceID: String, retry: Bool = false) throws -> KnowledgeReviewRecord {
        _ = try knowledgeReviews(sourceID:sourceID)
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
        return try rows.map { row in
            var state = row["state"]!
            let input = try decodeWithPath(KnowledgeReviewInput.self,from:Data(row["input_json"]!.utf8),label:"知识核查输入")
            if state != "frozen",(try? validateKnowledgeReviewInput(input,destination:.local)) == nil {
                state="frozen";try db.execute("UPDATE knowledge_reviews SET state='frozen',error='原话、理解或授权已变化；保留历史核查' WHERE id=?",[row["id"]])
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
                try Self.validateKnowledgeSelection(selection,input:input)
                progress.selection=selection;responseIDs.append(selection.responseID)
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
    static func validateKnowledgeSelection(_ selection: KnowledgeReviewSelection,input:KnowledgeReviewInput) throws {
        guard !selection.responseID.isEmpty,Set(selection.candidates.map(\.id)).count == selection.candidates.count,
              selection.candidates.allSatisfy({ !$0.id.isEmpty && !$0.quote.isEmpty && input.context.sources[0].text.contains($0.quote) }) else { throw VoiceOSError("知识核查候选缺少真实连续原话或身份") }
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
                try validateKnowledgeSelection(selection,input:input)
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
