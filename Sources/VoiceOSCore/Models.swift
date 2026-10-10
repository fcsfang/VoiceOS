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
    func transcribe(_ url: URL, locale: String) async throws -> String
}
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
}
public enum SaveCheckpoint: String, Sendable {
    case intent, copyChunk, copyComplete, sealed, renamed, savedUncommitted, savedCommitted
    case jobClaimed, transcriptUncommitted, transcriptCommitted
}
