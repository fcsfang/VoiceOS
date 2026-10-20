import Foundation

public struct TranscriptSegmentReference: Codable, Equatable, Sendable {
    public let spanID: String
    public let textStart: Int
    public let textEnd: Int
    /// Original containing span's time range, never an interpolated segment timestamp.
    public let containingSpanStartMS: Int?
    public let containingSpanEndMS: Int?
}
public struct TranscriptSegment: Codable, Identifiable, Sendable {
    public let id: String
    public let ordinal: Int
    public let textStart: Int
    public let textEnd: Int
    public let text: String
    public let references: [TranscriptSegmentReference]
}
/// A local, lossless planning artifact. Not an execution intent or an upload grant.
public struct TranscriptSegmentationPlan: Codable, Sendable {
    public let algorithm: String
    public let source: ContextTranscript
    public let policyVersion: Int
    public let scalarBudget: Int
    public let segments: [TranscriptSegment]
    public let contentDigest: String
}
extension VoiceOSStore {
    public func prepareTranscriptSegmentation(sourceID: String, scalarBudget: Int = 4000) throws -> TranscriptSegmentationPlan {
        guard (1...4000).contains(scalarBudget), let record = try sources().first(where: {$0.id == sourceID}),
              let text = record.transcript else { throw VoiceOSError("分段需要当前逐字稿和1至4000的预算") }
        // Full transcript validation, with an explicit planning-only budget. Never
        // route this larger snapshot to the fixed-budget processing queue.
        let context = try prepareLocalTranscriptContext(sourceIDs:[sourceID],scalarBudget:max(1,text.unicodeScalars.count))
        return try Self.segmentTranscript(context.sources[0], policyVersion:record.policyVersion,scalarBudget:scalarBudget)
    }
    public func validateTranscriptSegmentation(_ plan: TranscriptSegmentationPlan) throws {
        let current = try prepareTranscriptSegmentation(sourceID:plan.source.sourceID,scalarBudget:plan.scalarBudget)
        guard try Self.relevanceJSON(plan) == Self.relevanceJSON(current) else { throw VoiceOSError("分段的逐字稿、原件、授权或内容已变化，请重新准备") }
    }
    static func segmentTranscript(_ source: ContextTranscript, policyVersion: Int, scalarBudget: Int) throws -> TranscriptSegmentationPlan {
        guard (1...4000).contains(scalarBudget), policyVersion > 0 else { throw VoiceOSError("分段预算或授权版本无效") }
        let scalars = Array(source.text.unicodeScalars)
        var boundaries = [0], preferred = Set<Int>(), offset = 0
        // Segment boundaries always fall between Characters. A scalar budget must
        // not split emoji sequences or combining marks into invalid user text.
        for character in source.text {
            let length = String(character).unicodeScalars.count
            guard length <= scalarBudget else { throw VoiceOSError("单个完整字符超过分段预算，未拆坏或截断原话") }
            offset += length; boundaries.append(offset)
            if character.isWhitespace || "。！？.!?；;\n".contains(character) { preferred.insert(offset) }
        }
        let spanEnds = Set(source.spans.map(\.textEnd))
        let identity = Self.relevanceHash(Data(try Self.relevanceJSON(["transcript-segmentation-v1",try Self.relevanceJSON(source),String(policyVersion),String(scalarBudget)]).utf8))
        var segments: [TranscriptSegment] = [], start = 0, boundaryIndex = 0
        while start < scalars.count {
            let limit = min(scalars.count,start+scalarBudget)
            var endIndex = boundaryIndex
            while endIndex+1 < boundaries.count, boundaries[endIndex+1] <= limit { endIndex += 1 }
            guard endIndex > boundaryIndex else { throw VoiceOSError("无法在预算内保留完整字符") }
            var end = boundaries[endIndex]
            if end < scalars.count {
                // Prefer sentence/space boundaries in the latter half; then an
                // original speech span boundary. Never drop short trailing text.
                let minimum = start + max(1,scalarBudget/2)
                let candidates = boundaries[(boundaryIndex+1)...endIndex].filter { $0 >= minimum }
                if let natural = candidates.last(where: { preferred.contains($0) }) { end = natural }
                else if let original = candidates.last(where: { spanEnds.contains($0) }) { end = original }
            }
            let refs = source.spans.compactMap { span -> TranscriptSegmentReference? in
                let lower = max(start,span.textStart), upper = min(end,span.textEnd)
                guard lower < upper else { return nil }
                return .init(spanID:span.id,textStart:lower,textEnd:upper,containingSpanStartMS:span.startMS,containingSpanEndMS:span.endMS)
            }
            let text = String(String.UnicodeScalarView(scalars[start..<end]))
            let id = Self.relevanceHash(Data("\(identity):\(start):\(end)".utf8))
            segments.append(.init(id:id,ordinal:segments.count+1,textStart:start,textEnd:end,text:text,references:refs))
            start = end
            while boundaryIndex < boundaries.count, boundaries[boundaryIndex] < start { boundaryIndex += 1 }
        }
        return .init(algorithm:"transcript-segmentation-v1",source:source,policyVersion:policyVersion,scalarBudget:scalarBudget,segments:segments,contentDigest:identity)
    }
}
