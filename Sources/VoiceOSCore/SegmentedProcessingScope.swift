import Foundation

/// Preparation for an explicitly selected long personal transcript. No dispatch,
/// source policy mutation, queue persistence or raw audio belongs to this value.
public struct SegmentedExpressionProcessingScope: Codable, Sendable {
    public let id: String
    public let plan: TranscriptSegmentationPlan
    public let extraction: ProcessingModelIdentity
    public let aggregation: ProcessingModelIdentity
    public let evidenceScalarBudget: Int
    public let contentDigest: String
}

extension VoiceOSStore {
    public func prepareSegmentedExpressionProcessingScope(sourceID: String, extraction: ModelConfiguration,
        aggregation: ModelConfiguration, segmentScalarBudget: Int = 4000,
        evidenceScalarBudget: Int? = nil) throws -> SegmentedExpressionProcessingScope {
        let extractIdentity = ProcessingModelIdentity(extraction), aggregateIdentity = ProcessingModelIdentity(aggregation)
        let maxBudget=Self.segmentEvidenceBudgetLimit(extractIdentity, aggregateIdentity)
        let evidenceScalarBudget=evidenceScalarBudget ?? maxBudget
        guard extractIdentity.isValid, aggregateIdentity.isValid,
              extraction.destination == aggregation.destination,
              (1...maxBudget).contains(evidenceScalarBudget),
              let record = try sources().first(where: { $0.id == sourceID }),
              ["user_text", "audio"].contains(record.kind), record.origin == "user", record.speaker == "user" else {
            throw VoiceOSError("分段处理范围需要明确的个人表达、有效的同目的地端口及证据预算")
        }
        let plan = try prepareTranscriptSegmentation(sourceID:sourceID,scalarBudget:segmentScalarBudget)
        guard !plan.source.text.isEmpty, plan.segments.count > 1 else {
            throw VoiceOSError("分段处理范围需要超过所选单段预算的非空原话")
        }
        guard extraction.destination != .cloud || !plan.source.localOnly else {
            throw VoiceOSError("分段计划不能授予云端权限，请先明确允许这份文字云端处理")
        }
        let digest = try Self.segmentedScopeDigest(plan:plan, extraction:extractIdentity,
            aggregation:aggregateIdentity, evidenceBudget:evidenceScalarBudget)
        return .init(id:UUID().uuidString,plan:plan,extraction:extractIdentity,aggregation:aggregateIdentity,
            evidenceScalarBudget:evidenceScalarBudget,contentDigest:digest)
    }

    /// Rebuild the entire canonical plan and configuration scope. Comparing only
    /// a self-reported digest would accept forged segment text or references.
    public func validateSegmentedExpressionProcessingScope(_ scope: SegmentedExpressionProcessingScope,
        extraction: ModelConfiguration, aggregation: ModelConfiguration) throws {
        guard UUID(uuidString:scope.id) != nil,
              scope.extraction == ProcessingModelIdentity(extraction),
              scope.aggregation == ProcessingModelIdentity(aggregation) else {
            throw VoiceOSError("分段处理身份或端口已变化")
        }
        let current = try prepareSegmentedExpressionProcessingScope(sourceID:scope.plan.source.sourceID,
            extraction:extraction,aggregation:aggregation,segmentScalarBudget:scope.plan.scalarBudget,
            evidenceScalarBudget:scope.evidenceScalarBudget)
        guard try Self.relevanceJSON(scope.plan) == Self.relevanceJSON(current.plan),
              scope.contentDigest == current.contentDigest else {
            throw VoiceOSError("分段处理的原话、授权、引用或摘要已变化")
        }
    }

    static func segmentEvidenceBudgetLimit(_ extraction: ProcessingModelIdentity, _ aggregation: ProcessingModelIdentity) -> Int {
        ["segment-extraction-v2","segment-extraction-v3"].contains(extraction.promptVersion) && extraction.schemaVersion == extraction.promptVersion
            && ["segment-aggregation-v2","segment-aggregation-v3"].contains(aggregation.promptVersion) && aggregation.schemaVersion == aggregation.promptVersion ? 32000:4000
    }
    static func segmentedScopeDigest(plan: TranscriptSegmentationPlan, extraction: ProcessingModelIdentity,
        aggregation: ProcessingModelIdentity, evidenceBudget: Int) throws -> String {
        // The random preparation ID is intentionally absent from semantic scope.
        relevanceHash(Data(try relevanceJSON(["segmented-processing-scope-v1",relevanceJSON(plan),
            relevanceJSON(extraction),relevanceJSON(aggregation),String(evidenceBudget)]).utf8))
    }
}
