import AVFoundation
import Foundation

public struct MediaChapter: Sendable {
    public let title: String
    public let startMS: Int
    public init(title: String, startMS: Int) {
        self.title = title
        self.startMS = startMS
    }
}

public enum MediaChapters {
    public static func read(_ url: URL) async -> [MediaChapter] {
        do {
            let asset = AVURLAsset(url: url)
            let locales = try await asset.load(.availableChapterLocales)
            guard !locales.isEmpty else { return [] }
            var groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
            if groups.isEmpty, let fallback = locales.first {
                groups = try await asset.loadChapterMetadataGroups(withTitleLocale: fallback, containingItemsWithCommonKeys: [])
            }
            var chapters: [MediaChapter] = []
            for group in groups {
                guard chapters.count < 50,
                      let item = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                      let value = try? await item.load(.stringValue) else { continue }
                let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let seconds = group.timeRange.start.seconds
                guard !title.isEmpty, title.unicodeScalars.count <= 200, seconds.isFinite, seconds >= 0 else { continue }
                chapters.append(MediaChapter(title: title, startMS: Int((seconds * 1000).rounded())))
            }
            return chapters
        } catch {
            return []
        }
    }
}
