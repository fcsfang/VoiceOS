import Foundation

/// Configuration identity only. Credentials never belong to a processing intent.
public struct ProcessingModelIdentity: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String
    public let promptVersion: String
    public let schemaVersion: String
    public let destination: ModelDestination
    init(_ configuration: ModelConfiguration) {
        provider = configuration.provider; model = configuration.model
        promptVersion = configuration.promptVersion; schemaVersion = configuration.schemaVersion
        destination = configuration.destination
    }
    var isValid: Bool {
        [provider, model, promptVersion, schemaVersion].allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 }
    }
}
/// Read-only scope preparation for one explicitly requested text-processing chain.
/// This value is not a dispatch authorization, durable queue item or source policy grant.
public struct ExpressionProcessingIntentSnapshot: Codable, Sendable {
    public let id: String
    public let context: LocalTranscriptContext
    public let policyVersion: Int
    public let cognition: ProcessingModelIdentity
    public let association: ProcessingModelIdentity
    public let contentDigest: String
}
extension VoiceOSStore {
    public func prepareExpressionProcessingIntent(sourceID: String, cognition: ModelConfiguration, association: ModelConfiguration) throws -> ExpressionProcessingIntentSnapshot {
        let cognitionIdentity = ProcessingModelIdentity(cognition), associationIdentity = ProcessingModelIdentity(association)
        guard cognitionIdentity.isValid, associationIdentity.isValid, cognition.destination == association.destination,
              let record = try sources().first(where: { $0.id == sourceID }), ["user_text", "audio"].contains(record.kind),
              record.origin == "user", record.speaker == "user" else { throw VoiceOSError("处理意图只覆盖明确的个人文字或个人录音逐字稿及有效的同目的地端口") }
        let context = try prepareLocalTranscriptContext(sourceIDs: [sourceID], scalarBudget: 4000)
        guard cognition.destination != .cloud || !record.needsTranscriptionReview else { throw VoiceOSError("请先完成整份语音文字的校正，再理解和提取任务") }
        let policy = try sourcePolicy(sourceID: sourceID)
        guard cognition.destination != .cloud || !policy.localOnly else { throw VoiceOSError("请先明确允许本次文字云端处理；处理意图不能自行授予权限") }
        let digest = try Self.expressionProcessingIntentDigest(context: context, policyVersion: policy.version, cognition: cognitionIdentity, association: associationIdentity)
        return .init(id: UUID().uuidString, context: context, policyVersion: policy.version, cognition: cognitionIdentity, association: associationIdentity, contentDigest: digest)
    }
    public func validateExpressionProcessingIntent(_ snapshot: ExpressionProcessingIntentSnapshot, cognition: ModelConfiguration, association: ModelConfiguration) throws {
        guard UUID(uuidString: snapshot.id) != nil, snapshot.context.sources.count == 1,
              snapshot.cognition == ProcessingModelIdentity(cognition), snapshot.association == ProcessingModelIdentity(association) else { throw VoiceOSError("处理端口身份已变化；原处理意图不能扩大到新配置") }
        let current = try prepareExpressionProcessingIntent(sourceID: snapshot.context.sources[0].sourceID, cognition: cognition, association: association)
        guard snapshot.context.scalarBudget == 4000,
              try Self.relevanceJSON(snapshot.context) == Self.relevanceJSON(current.context),
              snapshot.policyVersion == current.policyVersion, snapshot.contentDigest == current.contentDigest else { throw VoiceOSError("处理意图的原话、版本、授权或摘要已变化") }
    }
    static func expressionProcessingIntentDigest(context: LocalTranscriptContext, policyVersion: Int, cognition: ProcessingModelIdentity, association: ProcessingModelIdentity) throws -> String {
        relevanceHash(Data(try relevanceJSON(["expression-processing-intent-v1", context.contentDigest, String(policyVersion), relevanceJSON(cognition), relevanceJSON(association)]).utf8))
    }
}
