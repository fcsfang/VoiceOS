import Foundation

public enum FolderWatchKind: String, Sendable {
    case pdf, image, text, media, unsupported
}

public struct FolderWatchEntry: Equatable, Sendable {
    public let path: String
    public let fingerprint: String
    public let kind: FolderWatchKind

    public init(path: String, size: Int64, modified: Date) {
        self.path = path
        self.kind = FolderWatchLedger.kind(forFileExtension: URL(fileURLWithPath: path).pathExtension)
        self.fingerprint = FolderWatchLedger.fingerprint(path: path, size: size, modified: modified)
    }
}

public struct FolderWatchLedger: Equatable, Sendable {
    public private(set) var fingerprints: Set<String>
    public private(set) var initialized: Bool

    public init(fingerprints: Set<String> = [], initialized: Bool = false) {
        self.fingerprints = fingerprints
        self.initialized = initialized
    }

    public mutating func adoptBaseline(_ entries: [FolderWatchEntry]) {
        initialized = true
        record(entries)
    }

    public mutating func record(_ entries: [FolderWatchEntry]) {
        fingerprints.formUnion(entries.filter { $0.kind != .unsupported }.map(\.fingerprint))
    }

    public func newEntries(in entries: [FolderWatchEntry]) -> [FolderWatchEntry] {
        Self.unseen(entries, known: fingerprints)
    }

    public static func unseen(_ entries: [FolderWatchEntry], known: Set<String>) -> [FolderWatchEntry] {
        var seen = known
        var result: [FolderWatchEntry] = []
        for entry in entries where entry.kind != .unsupported {
            if seen.insert(entry.fingerprint).inserted { result.append(entry) }
        }
        return result
    }

    public static func fingerprint(path: String, size: Int64, modified: Date) -> String {
        "\(path)|\(size)|\(Int64(modified.timeIntervalSince1970 * 1000))"
    }

    public static func kind(forFileExtension fileExtension: String) -> FolderWatchKind {
        let ext = fileExtension.lowercased()
        if pdfExtensions.contains(ext) { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if textExtensions.contains(ext) { return .text }
        if mediaExtensions.contains(ext) { return .media }
        return .unsupported
    }

    private static let pdfExtensions: Set<String> = ["pdf"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
    private static let textExtensions: Set<String> = ["txt", "md"]
    private static let mediaExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "mp4", "mov", "m4v"]
}
