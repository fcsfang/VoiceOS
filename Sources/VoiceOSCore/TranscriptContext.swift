import Foundation
import CryptoKit

/// Locally constructed snapshot; persist it with destination and policy versions before use.
/// The snapshot alone is neither a cloud grant nor evidence that the speaker is the user.
public struct LocalTranscriptContext: Codable, Sendable {
    public let sources: [ContextTranscript]
    public let scalarBudget: Int
    public let contentDigest: String
    public var recordingContexts: [RecordingContext]? = nil
}
public struct ContextTranscript: Codable, Sendable {
    public let sourceID: String
    public let sourceVersionID: String
    public let transcriptVersionID: String
    public let origin: String
    public let speaker: String
    public let localOnly: Bool
    public let text: String
    public let spans: [TranscriptSpan]
    public var transcriptionReview: TranscriptionReview? = nil
}
extension VoiceOSStore {
    /// An actor turn captures only explicitly selected, usable, current transcripts.
    /// Budget overflow rejects the selection rather than silently omitting evidence.
    public func prepareLocalTranscriptContext(sourceIDs: [String], scalarBudget: Int = 4000) throws -> LocalTranscriptContext {
        guard !sourceIDs.isEmpty, Set(sourceIDs).count == sourceIDs.count,
              scalarBudget > 0 else { throw VoiceOSError("请选择不重复的来源并设置有效上下文预算") }
        var selected: [ContextTranscript] = []
        var selectedPairings:[RecordingContext]=[]
        var remaining = scalarBudget
        for id in sourceIDs {
            guard let row = try db.query("""
            SELECT s.id,s.state,s.version_id,s.kind,s.origin,s.speaker,s.local_only,s.duration,s.presentation_json,v.id AS transcript_version_id,v.text,v.spans_json
            FROM sources s JOIN transcripts t ON t.source_id=s.id
            JOIN transcript_versions v ON v.id=t.current_version_id AND v.transcript_id=t.id
            WHERE s.id=? AND s.state IN ('saved','reference_only') AND t.input_version_id=s.version_id
            """, [id]).first else { throw VoiceOSError("来源没有可用的当前逐字稿") }
            if row["state"] == "saved" { _ = try playableURL(sourceID: id) }
            let text = row["text"]!
            let spans = try JSONDecoder().decode([TranscriptSpan].self, from: Data(row["spans_json"]!.utf8))
            try SpeechText(text: text, spans: spans).validate(duration: row["duration"].flatMap(Double.init))
            guard text.unicodeScalars.count <= remaining else { throw VoiceOSError("选定文字超过上下文预算，请缩小来源范围") }
            remaining -= text.unicodeScalars.count
            var item = ContextTranscript(sourceID: id, sourceVersionID: row["version_id"]!, transcriptVersionID: row["transcript_version_id"]!, origin: row["origin"]!, speaker: row["speaker"]!, localOnly: row["local_only"] != "0", text: text, spans: spans)
            if let json=row["presentation_json"] {
                let presentation=try JSONDecoder().decode(RecordingPresentation.self,from:Data(json.utf8))
                if let review=presentation.transcriptionReview,review.transcriptVersionID == item.transcriptVersionID { item.transcriptionReview=review }
                if let pair=presentation.recordingContext,sourceIDs.contains(pair.externalSourceID) { selectedPairings.append(pair) }
            }
            selected.append(item)
        }
        var context=LocalTranscriptContext(sources:selected,scalarBudget:scalarBudget,contentDigest:try contextDigest(selected))
        if !selectedPairings.isEmpty { context.recordingContexts=selectedPairings }
        return context
    }

    /// Invoke again before consuming the snapshot or accepting an asynchronous result.
    /// Persistent model boundaries also check policy versions and attempt state.
    public func validateLocalTranscriptContext(_ context: LocalTranscriptContext) throws {
        let current = try prepareLocalTranscriptContext(sourceIDs: context.sources.map(\.sourceID), scalarBudget: context.scalarBudget)
        guard try Self.relevanceJSON(current.recordingContexts) == Self.relevanceJSON(context.recordingContexts) else { throw VoiceOSError("录制配对、时间偏移或节目上下文已变化，请重新准备") }
        guard try contextDigest(context.sources) == context.contentDigest,
              current.contentDigest == context.contentDigest else { throw VoiceOSError("上下文来源或逐字稿已变化，请重新准备") }
    }
    private func contextDigest(_ sources: [ContextTranscript]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(sources)).map { String(format: "%02x", $0) }.joined()
    }
}
