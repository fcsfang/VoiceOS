import Foundation
import CryptoKit

/// Explicitly selected personal practice text. This preview is not a send reservation.
public struct EnglishPracticeSnapshot:Codable,Sendable {
    public let id:String
    public let currentSourceID:String
    public let priorSourceIDs:[String]
    public let destination:ModelDestination
    public let context:LocalTranscriptContext
    public let contentDigest:String
}
public enum EnglishSuggestionKind:String,Codable,Sendable { case grammar,organisation,reusablePattern }
public struct EnglishSuggestionProposal:Codable,Sendable {
    public let kind:EnglishSuggestionKind
    public let original:OutcomeSourceEvidence
    public let suggestedText:String
    public let explanation:String
    public let possibleTranscriptIssue:Bool
    public init(kind:EnglishSuggestionKind,original:OutcomeSourceEvidence,suggestedText:String,explanation:String,possibleTranscriptIssue:Bool=false) {
        self.kind=kind;self.original=original;self.suggestedText=suggestedText;self.explanation=explanation;self.possibleTranscriptIssue=possibleTranscriptIssue
    }
}
public enum EnglishComparisonKind:String,Codable,Sendable { case similarIssue,differentExpression }
/// A text comparison proposal, never an automatic mastery or pronunciation judgement.
public struct EnglishComparisonProposal:Codable,Sendable {
    public let kind:EnglishComparisonKind
    public let currentSuggestionIndex:Int
    public let current:OutcomeSourceEvidence
    public let prior:OutcomeSourceEvidence
    public let explanation:String
    public init(kind:EnglishComparisonKind,currentSuggestionIndex:Int,current:OutcomeSourceEvidence,prior:OutcomeSourceEvidence,explanation:String) {
        self.kind=kind;self.currentSuggestionIndex=currentSuggestionIndex;self.current=current;self.prior=prior;self.explanation=explanation
    }
}
extension VoiceOSStore {
    /// No language guessing, model calls, candidates, actions or implicit cloud/audio permission.
    public func prepareEnglishPractice(currentSourceID:String,priorSourceIDs:[String]=[],destination:ModelDestination = .local,scalarBudget:Int=4000) throws -> EnglishPracticeSnapshot {
        guard ready,!currentSourceID.isEmpty,priorSourceIDs.count<=2,(1...8000).contains(scalarBudget),
              Set([currentSourceID]+priorSourceIDs).count==priorSourceIDs.count+1 else { throw VoiceOSError("练习来源重复或超出文字预算范围") }
        let context=try prepareLocalTranscriptContext(sourceIDs:[currentSourceID]+priorSourceIDs,scalarBudget:scalarBudget)
        guard context.sources.allSatisfy({ $0.origin == "user" && $0.speaker == "user" && !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) else { throw VoiceOSError("英文练习须使用明确的个人原话") }
        guard destination != .cloud || context.sources.allSatisfy({ !$0.localOnly }) else { throw VoiceOSError("选定练习文字尚未全部授权云端处理") }
        let digest=try Self.englishPracticeDigest(currentSourceID,priorSourceIDs,destination,context)
        return EnglishPracticeSnapshot(id:UUID().uuidString,currentSourceID:currentSourceID,priorSourceIDs:priorSourceIDs,destination:destination,context:context,contentDigest:digest)
    }
    /// Recheck before any future send and again before accepting asynchronous results.
    public func validateEnglishPractice(_ snapshot:EnglishPracticeSnapshot) throws {
        guard UUID(uuidString:snapshot.id) != nil else { throw VoiceOSError("练习快照身份无效") }
        try validateLocalTranscriptContext(snapshot.context)
        let actual=try prepareEnglishPractice(currentSourceID:snapshot.currentSourceID,priorSourceIDs:snapshot.priorSourceIDs,destination:snapshot.destination,scalarBudget:snapshot.context.scalarBudget)
        guard actual.contentDigest==snapshot.contentDigest,
              try Self.englishPracticeDigest(snapshot.currentSourceID,snapshot.priorSourceIDs,snapshot.destination,snapshot.context)==snapshot.contentDigest else { throw VoiceOSError("练习输入或角色目录已变化") }
    }
    static func englishPracticeDigest(_ current:String,_ prior:[String],_ destination:ModelDestination,_ context:LocalTranscriptContext) throws -> String {
        struct Payload:Encodable { let purpose="english-practice-input-v1";let current:String;let prior:[String];let destination:ModelDestination;let context:LocalTranscriptContext }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return SHA256.hash(data:try encoder.encode(Payload(current:current,prior:prior,destination:destination,context:context))).map { String(format:"%02x",$0) }.joined()
    }
    /// Pure structural validation; the Store must also revalidate the actual input snapshot.
    public static func validateEnglishProposals(suggestions:[EnglishSuggestionProposal],comparisons:[EnglishComparisonProposal],snapshot:EnglishPracticeSnapshot) throws {
        guard suggestions.count<=8,comparisons.count<=4,
              (1...8000).contains(snapshot.context.scalarBudget),
              snapshot.priorSourceIDs.count<=2,
              snapshot.context.sources.map(\.sourceID)==[snapshot.currentSourceID]+snapshot.priorSourceIDs,
              Set(snapshot.context.sources.map(\.sourceID)).count==snapshot.context.sources.count,
              snapshot.context.sources.allSatisfy({ $0.origin == "user" && $0.speaker == "user" && !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }),
              snapshot.context.sources.reduce(0,{ $0+$1.text.unicodeScalars.count })<=snapshot.context.scalarBudget,
              snapshot.destination != .cloud || snapshot.context.sources.allSatisfy({ !$0.localOnly }),
              try englishPracticeDigest(snapshot.currentSourceID,snapshot.priorSourceIDs,snapshot.destination,snapshot.context)==snapshot.contentDigest else { throw VoiceOSError("英文反馈输入范围或摘要不符") }
        func text(_ value:String,_ max:Int)->Bool { !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.unicodeScalars.count<=max }
        func validateQuote(_ evidence:OutcomeSourceEvidence,_ sourceID:String) throws {
            let ref=evidence.reference
            guard ref.sourceID==sourceID,text(evidence.quote,1000),let source=snapshot.context.sources.first(where:{ $0.sourceID==sourceID }),
                  ref.transcriptVersionID==source.transcriptVersionID,
                  let span=source.spans.first(where:{$0.id==ref.spanID}) else { throw VoiceOSError("英文反馈引用的练习版本或片段不符") }
            try SpeechText(text:source.text,spans:source.spans).validate(duration:source.spans.compactMap(\.endMS).max().map { Double($0)/1000 })
            let scalars=Array(source.text.unicodeScalars),part=String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd]))
            guard part.contains(evidence.quote) else { throw VoiceOSError("英文反馈引文不是练习原句") }
        }
        var seen=Set<String>()
        for s in suggestions {
            try validateQuote(s.original,snapshot.currentSourceID)
            guard text(s.suggestedText,1000),text(s.explanation,1000),
                  seen.insert(s.kind.rawValue+":"+s.original.reference.spanID+":"+s.original.quote+":"+s.suggestedText).inserted else { throw VoiceOSError("英文表达建议重复或为空/过长") }
        }
        seen.removeAll()
        for c in comparisons {
            guard suggestions.indices.contains(c.currentSuggestionIndex),snapshot.priorSourceIDs.contains(c.prior.reference.sourceID),text(c.explanation,1000) else { throw VoiceOSError("练习比较须引用本次建议和选定旧练习") }
            try validateQuote(c.current,snapshot.currentSourceID);try validateQuote(c.prior,c.prior.reference.sourceID)
            let suggestion=suggestions[c.currentSuggestionIndex]
            guard c.current.reference.sourceID==suggestion.original.reference.sourceID,c.current.reference.transcriptVersionID==suggestion.original.reference.transcriptVersionID,c.current.reference.spanID==suggestion.original.reference.spanID,c.current.quote==suggestion.original.quote,
                  seen.insert(c.kind.rawValue+":"+String(c.currentSuggestionIndex)+":"+c.prior.reference.sourceID+":"+c.prior.reference.spanID+":"+c.prior.quote).inserted else { throw VoiceOSError("练习比较与本次建议不符或重复") }
        }
    }
}
