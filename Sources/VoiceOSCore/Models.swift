import Foundation

public struct VoiceOSError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct MediaInfo: Sendable {
    public let duration: Double
    public let kind: String
    public init(duration: Double, kind: String) { self.duration = duration; self.kind = kind }
}
public protocol MediaInspector: Sendable {
    func inspect(_ url: URL) async throws -> MediaInfo
}
public protocol SpeechPort: Sendable {
    var backendIdentity: String { get }
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText
}
public extension SpeechPort { var backendIdentity: String { "unspecified-speech-port" } }
public struct SourceRecord: Identifiable, Sendable {
    public let id: String
    public let assetID: String
    public let name: String
    public let state: String
    public let kind: String
    public let createdAt: String
    public let bytes: Int64
    public let duration: Double?
    public let jobState: String?
    public let transcript: String?
    public let error: String?
    public let relativePath: String
    public let transcriptVersionID: String?
    public let spans: [TranscriptSpan]
    public let localOnly: Bool
    public let policyVersion: Int
    public let origin: String
    public let speaker: String
    public let feedbackActionID: String?
    public let feedbackActionVersion: Int?
    public let feedbackKind: String?
}
public enum SaveCheckpoint: String, Sendable {
    case intent, copyChunk, copyComplete, sealed, renamed, savedUncommitted, savedCommitted
    case jobClaimed, transcriptUncommitted, transcriptCommitted
    case modelReserved, claimsUncommitted, claimsCommitted, correctionUncommitted, correctionCommitted
    case relevanceReserved, relevanceUncommitted, relevanceCommitted
    case associationReserved, associationUncommitted, associationCommitted
    case associationIgnoreUncommitted, associationIgnoreCommitted
    case quietPreferenceUncommitted, quietPreferenceCommitted, quietIgnoreUncommitted, quietIgnoreCommitted
    case conversationUncommitted, conversationCommitted, conversationTurnUncommitted, conversationTurnCommitted
    case conversationEndUncommitted, conversationEndCommitted
    case discussionCandidateReserved, discussionCandidateUncommitted, discussionCandidateCommitted, outcomeReserved, outcomeUncommitted, outcomeCommitted
    case discussionReserved, discussionUncommitted, discussionCommitted
    case policyUncommitted, policyCommitted
    case reviewUncommitted, reviewCommitted
    case reminderReserved, reminderSaved, reminderFeedbackUncommitted, reminderFeedbackCommitted
    case actionUncommitted, actionCommitted, actionStateUncommitted, actionStateCommitted
}

public struct TranscriptSpan: Codable, Sendable, Identifiable {
    public let id: String
    public let textStart: Int
    public let textEnd: Int
    public let startMS: Int?
    public let endMS: Int?
    public init(id: String = UUID().uuidString, textStart: Int, textEnd: Int, startMS: Int? = nil, endMS: Int? = nil) {
        self.id = id; self.textStart = textStart; self.textEnd = textEnd; self.startMS = startMS; self.endMS = endMS
    }
}
public struct SpeechText: Sendable {
    public let text: String
    public let spans: [TranscriptSpan]
    public init(text: String, spans: [TranscriptSpan]? = nil) {
        self.text = text
        self.spans = spans ?? (text.isEmpty ? [] : [TranscriptSpan(textStart: 0, textEnd: text.unicodeScalars.count)])
    }
    public func validate(duration: Double?) throws {
        let count = text.unicodeScalars.count
        var offset = 0
        guard Set(spans.map(\.id)).count == spans.count else { throw VoiceOSError("逐字稿片段身份重复") }
        for span in spans {
            guard UUID(uuidString: span.id) != nil, span.textStart == offset, span.textEnd > span.textStart, span.textEnd <= count else { throw VoiceOSError("逐字稿文字定位不一致") }
            if let start = span.startMS, let end = span.endMS {
                guard start >= 0, end >= start, let duration, Double(end) <= duration * 1000 + 1 else { throw VoiceOSError("逐字稿媒体定位越界") }
            } else if span.startMS != nil || span.endMS != nil { throw VoiceOSError("逐字稿媒体定位不完整") }
            offset = span.textEnd
        }
        guard offset == count else { throw VoiceOSError("逐字稿片段未覆盖实际文字") }
    }
}
public struct TranscriptVersion: Identifiable, Sendable {
    public let id: String
    public let number: Int
    public let text: String
    public let reason: String
    public let createdAt: String
    public let isCurrent: Bool
}
