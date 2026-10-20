import Foundation

public struct ExpressionActionAdoption: Codable, Sendable {
    public let fromClaimID:String
    public let fromReviewVersion:Int
    public let fromTitle:String
    public let fromNote:String
    public let fromKind:String
    public let fromAutoSend:Bool
    public let toClaimID:String
    public let replacedActionID:String
    public let responseIDs:[String]
}

public struct RecordingExpressionActionItem: Codable, Sendable {
    public let id:String
    public let claimID:String
    public let title:String
    public let kind:String
    public let note:String
    public let state:String
    public let version:Int
    public let claimReviewVersion:Int
    public let statement:String
}
public struct RecordingExpressionActionInput: Codable, Sendable {
    public let context:LocalTranscriptContext
    public let policies:[String:Int]
    public let oldActions:[RecordingExpressionActionItem]
    public let newActions:[RecordingExpressionActionItem]
    public var transcriptionCorrection:Bool? = nil
}
public struct RecordingExpressionActionDecision: Codable, Sendable {
    public let oldID:String
    public let newID:String
    public let relation:String
    public let sourceID:String
    public let quote:String
    public init(oldID:String,newID:String,relation:String,sourceID:String,quote:String) { self.oldID=oldID;self.newID=newID;self.relation=relation;self.sourceID=sourceID;self.quote=quote }
}
public protocol RecordingExpressionActionPort: Sendable {
    func reconcile(_ input:RecordingExpressionActionInput) async throws -> ([RecordingExpressionActionDecision],[String])
}
extension VoiceOSStore {
    func prepareExpressionActionReview(_ expression:RecordingExpression) throws -> RecordingExpressionActionInput {
        let catalog=try sources(),members=Set(expression.sourceIDs)
        let expanded=try recordingContextSourceIDs(sourceIDs:expression.sourceIDs),contextIDs=Set(expanded)
        let context=try prepareLocalTranscriptContext(sourceIDs:expanded,scalarBudget:max(1,catalog.filter { contextIDs.contains($0.id) }.reduce(0) { $0 + ($1.transcript?.unicodeScalars.count ?? 0) }))
        let claims=Dictionary(uniqueKeysWithValues:try candidateClaims(includeFrozen:true).map { ($0.id,$0) })
        let latest=try latestCandidateClaimsBySource()
        let currentClaims=Set(expression.sourceIDs.flatMap { latest[$0] ?? [] }.map(\.id))
        let previous=Set(expression.previousActionIDs)
        let all=try actions(includeHistory:true)
        func item(_ action:ActionRecord) -> RecordingExpressionActionItem? {
            guard let claim=claims[action.claimID] else { return nil }
            return .init(id:action.id,claimID:claim.id,title:action.title,kind:action.kind,note:action.note,state:action.state,version:action.version,claimReviewVersion:action.claimReviewVersion,statement:claim.statement)
        }
        let correction = catalog.contains { members.contains($0.id) && $0.presentation?.recordingUnderstandingIsCorrection == true }
        return .init(context:context,policies:Dictionary(uniqueKeysWithValues:catalog.filter { contextIDs.contains($0.id) }.map { ($0.id,$0.policyVersion) }),oldActions:all.filter { previous.contains($0.id) && $0.state != "dismissed" }.compactMap(item),newActions:all.filter { !previous.contains($0.id) && currentClaims.contains($0.claimID) && $0.validity == "current" && $0.state != "dismissed" }.compactMap(item),transcriptionCorrection:correction ? true : nil)
    }
    public static func validateExpressionActionReview(_ decisions:[RecordingExpressionActionDecision],input:RecordingExpressionActionInput) throws {
        let old=Dictionary(uniqueKeysWithValues:input.oldActions.map { ($0.id,$0) }),new=Dictionary(uniqueKeysWithValues:input.newActions.map { ($0.id,$0) })
        let sources=Dictionary(uniqueKeysWithValues:input.context.sources.map { ($0.sourceID,$0) })
        guard decisions.count == old.count,Set(decisions.map(\.oldID)) == Set(old.keys) else { throw VoiceOSError("补录接续没有逐项核对原有行动") }
        var adopted=Set<String>()
        for decision in decisions {
            guard input.transcriptionCorrection != true || decision.relation != "withdraw" else {
                throw VoiceOSError("原文纠错不能被解释为用户后来撤回真实任务")
            }
            guard let prior=old[decision.oldID],["same","withdraw","history","uncertain"].contains(decision.relation),!decision.quote.isEmpty,
                  sources[decision.sourceID]?.origin == "user",sources[decision.sourceID]?.speaker == "user",sources[decision.sourceID]?.text.contains(decision.quote) == true else { throw VoiceOSError("补录行动的接续缺少有效原话依据") }
            if decision.relation == "same" {
                guard let next=new[decision.newID] else { throw VoiceOSError("补录行动 \(prior.id) 的 newID=\(decision.newID) 不在本次新行动中") }
                guard next.kind == prior.kind else { throw VoiceOSError("补录行动 \(prior.id) 的 kind=\(prior.kind)，不能沿用 newID=\(next.id) 的 kind=\(next.kind)；无法同类接续时用 uncertain") }
                guard adopted.insert(next.id).inserted else { throw VoiceOSError("补录行动 newID=\(next.id) 被多个旧行动沿用；每个新行动只能接回一个旧身份，其余无法确定的旧行动用 uncertain") }
            } else {
                guard decision.newID.isEmpty,decision.relation != "history" || prior.state == "completed",decision.relation != "withdraw" || prior.state != "completed" else { throw VoiceOSError("补录不能撤销真实完成记录") }
            }
        }
    }
    func reconcileExpressionActions(_ decisions:[RecordingExpressionActionDecision],input:RecordingExpressionActionInput,responseIDs:[String]) throws -> Set<String> {
        let new=Dictionary(uniqueKeysWithValues:input.newActions.map { ($0.id,$0) })
        var adopted=Set<String>()
        for decision in decisions {
            if decision.relation == "same",let next=new[decision.newID] {
                guard let generated=try db.query("SELECT * FROM actions WHERE id=?",[next.id]).first else { throw VoiceOSError("补录行动缺失") }
                guard let original=try db.query("SELECT * FROM actions WHERE id=?",[decision.oldID]).first else { throw VoiceOSError("原任务缺失") }
                let prior=try original["intent_json"].map { try JSONDecoder().decode(ActionIntentMetadata.self,from:Data($0.utf8)) }
                var metadata=try generated["intent_json"].map { try JSONDecoder().decode(ActionIntentMetadata.self,from:Data($0.utf8)) } ?? ActionIntentMetadata(intentType:next.kind == "task" ? "task" : "idea",followupState:"pending",uncertain:false)
                metadata.goalID=metadata.goalID ?? prior?.goalID
                metadata.expressionHistory=(prior?.expressionHistory ?? []) + [.init(fromClaimID:original["claim_id"]!,fromReviewVersion:Int(original["claim_review_version"]!)!,fromTitle:original["title"]!,fromNote:original["note"]!,fromKind:original["kind"]!,fromAutoSend:original["auto_send"] == "1",toClaimID:next.claimID,replacedActionID:next.id,responseIDs:responseIDs)]
                // Keep the identity, completion, reminder link and real feedback. The old claim remains history.
                try db.execute("UPDATE actions SET claim_id=?,claim_review_version=?,title=?,note=?,intent_json=?,validity='current' WHERE id=?",[next.claimID,String(next.claimReviewVersion),next.title,next.note,try Self.relevanceJSON(metadata),decision.oldID])
                try dismissExpressionAction(next,note:"补录整体理解已接回原任务："+decision.oldID)
                try db.execute("UPDATE actions SET validity='frozen' WHERE id=?",[next.id])
                adopted.insert(next.id)
            } else {
                // Withdrawal and uncertainty are never a successful real-world completion.
                if decision.relation == "withdraw",let prior=input.oldActions.first(where: { $0.id == decision.oldID }) {
                    let original=try db.query("SELECT intent_json FROM actions WHERE id=?",[prior.id]).first
                    var metadata=try original?["intent_json"].map { try JSONDecoder().decode(ActionIntentMetadata.self,from:Data($0.utf8)) } ?? ActionIntentMetadata(intentType:"task",followupState:"pending",uncertain:false)
                    metadata.expressionWithdrawal=decision;metadata.expressionWithdrawalResponseIDs=responseIDs
                    metadata.expressionWithdrawalVersionID=input.context.sources.first { $0.sourceID == decision.sourceID }?.transcriptVersionID
                    try db.execute("UPDATE actions SET intent_json=? WHERE id=?",[try Self.relevanceJSON(metadata),prior.id])
                    try dismissExpressionAction(prior,note:"补录中明确撤回，依据见连续表达原文")
                }
                try db.execute("UPDATE actions SET validity='frozen' WHERE id=?",[decision.oldID])
            }
        }
        // Latest whole-expression claims replace prior partial extractions; the source audio/text is untouched.
        let oldClaimIDs=Set(input.oldActions.map(\.claimID)),retained=Set(input.newActions.map(\.claimID))
        for id in oldClaimIDs.subtracting(retained) { try db.execute("UPDATE claims SET validity='frozen' WHERE id=?",[id]) }
        return adopted
    }
    // The original extraction stays immutable. Every later interpretation must
    // link to another real extraction and the two independent model receipts.
    static func validatedExpressionHistory(_ database:Database,action:[String:String]) throws -> [ExpressionActionAdoption] {
        guard let raw=action["intent_json"],let history=try JSONDecoder().decode(ActionIntentMetadata.self,from:Data(raw.utf8)).expressionHistory,!history.isEmpty else { return [] }
        var prior:String?,seen=Set<String>()
        for (index,step) in history.enumerated() {
            guard prior == nil || prior == step.fromClaimID,seen.insert(step.fromClaimID).inserted,
                  step.responseIDs.count >= 2,Set(step.responseIDs).count == step.responseIDs.count,
                  let from=try database.query("SELECT action_json FROM claims WHERE id=?",[step.fromClaimID]).first,
                  let to=try database.query("SELECT c.*,m.provider FROM claims c JOIN model_attempts m ON m.id=c.attempt_id WHERE c.id=?",[step.toClaimID]).first,
                  to["provider"] == "organized_import",let json=to["action_json"],
                  let replacement=try database.query("SELECT claim_id,command_id FROM actions WHERE id=?",[step.replacedActionID]).first,
                  replacement["claim_id"] == step.toClaimID,replacement["command_id"] == "extracted:"+to["attempt_id"]!+":"+to["ordinal"]! else { throw VoiceOSError("连续表达的任务接续链缺少真实提取依据") }
            let next=try JSONDecoder().decode(ExtractedAction.self,from:Data(json.utf8))
            if index == 0,action["command_id"]?.hasPrefix("extracted:") != true {
                let fingerprint=try actionHash([step.fromClaimID,String(step.fromReviewVersion),step.fromTitle,step.fromKind,action["intent_actor"] ?? "",step.fromNote])
                guard action["input_fingerprint"] == fingerprint,!step.fromAutoSend else { throw VoiceOSError("连续表达的原用户任务身份不一致") }
            } else {
                guard let raw=from["action_json"] else { throw VoiceOSError("连续表达的任务提取缺失") }
                let original=try JSONDecoder().decode(ExtractedAction.self,from:Data(raw.utf8))
                guard step.fromTitle == original.title,step.fromNote == original.quote,step.fromKind == original.kind.rawValue else { throw VoiceOSError("连续表达的原任务记录与提取不一致") }
            }
            guard step.fromAutoSend == (action["auto_send"] == "1"),next.kind.rawValue == step.fromKind else { throw VoiceOSError("连续表达的任务归属不一致") }
            prior=step.toClaimID
        }
        guard let last=history.last,action["claim_id"] == last.toClaimID,
              let json=try database.query("SELECT action_json FROM claims WHERE id=?",[last.toClaimID]).first?["action_json"] else { throw VoiceOSError("连续表达任务的当前依据缺失") }
        let current=try JSONDecoder().decode(ExtractedAction.self,from:Data(json.utf8))
        guard action["title"] == current.title,action["note"] == current.quote,action["kind"] == current.kind.rawValue else { throw VoiceOSError("连续表达任务与最新理解不一致") }
        return history
    }
    private func dismissExpressionAction(_ action:RecordingExpressionActionItem,note:String) throws {
        guard action.state == "open",let row=try db.query("SELECT version,state FROM actions WHERE id=?",[action.id]).first,row["version"] == String(action.version),row["state"] == "open" else { throw VoiceOSError("接续期间行动状态已变化") }
        let fingerprint=try Self.actionHash([action.id,String(action.version),"dismissed",note])
        try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'dismissed',?,'user',?,?,?)",[UUID().uuidString,action.id,String(action.version+1),String(action.version),note,"expression-dismiss:"+action.id+":"+String(action.version),fingerprint,Self.now()])
        try db.execute("UPDATE actions SET state='dismissed',version=? WHERE id=?",[String(action.version+1),action.id])
    }
}
