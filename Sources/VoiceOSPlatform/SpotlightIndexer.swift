import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import VoiceOSCore

public actor SpotlightIndexer {
    private struct Entry: Sendable {
        let id: String
        let title: String
        let summary: String
        let modified: String
        let url: URL?
        var fingerprint: String { id + "\u{1F}" + modified }
    }

    public static let domainIdentifier = "VoiceOS"
    private let minimumInterval: TimeInterval
    private var lastIndexedAt: Date?
    private var fingerprints: [String: String] = [:]
    private var purged = false

    public init(minimumInterval: TimeInterval = 60) {
        self.minimumInterval = minimumInterval
    }

    public func index(sources: [SourceRecord], claims: [CandidateClaim], actions: [ActionRecord], topics: [ReflectionQuestion] = []) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        if !purged {
            purged = true
            do { try await purgeDomain() } catch { NSLog("VoiceOS Spotlight 清理旧索引失败：\(error.localizedDescription)") }
        }
        let entries = makeEntries(sources: sources, claims: claims, actions: actions, topics: topics)
        let current = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.fingerprint) })
        let changed = entries.filter { fingerprints[$0.id] != $0.fingerprint }
        let removed = Set(fingerprints.keys).subtracting(current.keys)
        guard !changed.isEmpty || !removed.isEmpty else { return }
        let now = Date()
        if let lastIndexedAt, now.timeIntervalSince(lastIndexedAt) < minimumInterval { return }
        if !changed.isEmpty {
            let items = changed.map { entry -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .plainText)
                attributes.title = entry.title
                attributes.contentDescription = entry.summary
                attributes.contentURL = entry.url
                return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: Self.domainIdentifier, attributeSet: attributes)
            }
            do { try await submit(items) }
            catch {
                NSLog("VoiceOS Spotlight 索引失败：\(error.localizedDescription)")
                return
            }
            for entry in changed { fingerprints[entry.id] = entry.fingerprint }
        }
        if !removed.isEmpty {
            do { try await delete(Array(removed)) }
            catch {
                NSLog("VoiceOS Spotlight 清理失败：\(error.localizedDescription)")
                return
            }
            for id in removed { fingerprints[id] = nil }
        }
        lastIndexedAt = now
    }

    private func submit(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func purgeDomain() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func delete(_ identifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func makeEntries(sources: [SourceRecord], claims: [CandidateClaim], actions: [ActionRecord], topics: [ReflectionQuestion]) -> [Entry] {
        var entries: [Entry] = []
        for source in sources where ["saved", "reference_only"].contains(source.state) {
            let excerpt = excerpt(from: source.transcript ?? "", limit: 200)
            entries.append(Entry(id: "source-" + source.id, title: singleLine(source.name), summary: excerpt.isEmpty ? "材料" : excerpt,
                                 modified: [source.createdAt, source.state, source.transcriptVersionID ?? "", source.name].joined(separator: "\u{1F}"),
                                 url: URL(string: "voiceos://source/" + source.id)))
        }
        for claim in claims where claim.validity == "current" {
            entries.append(Entry(id: "claim-" + claim.id, title: singleLine(claim.statement), summary: "观点",
                                 modified: [String(claim.reviewVersion), claim.validity, claim.statement, claim.references.first?.sourceID ?? ""].joined(separator: "\u{1F}"),
                                 url: claim.references.first.flatMap { URL(string: "voiceos://source/" + $0.sourceID) }))
        }
        for action in actions where action.state == "open" && action.validity == "current" {
            let note = singleLine(action.note)
            entries.append(Entry(id: "action-" + action.id, title: singleLine(action.title), summary: note.isEmpty ? "开放行动" : note,
                                 modified: [String(action.version), action.state, action.validity, action.title, action.note].joined(separator: "\u{1F}"),
                                 url: URL(string: "voiceos://action/" + action.id)))
        }
        for topic in topics {
            entries.append(Entry(id: "topic-" + topic.id, title: singleLine(topic.title), summary: "主题",
                                 modified: [topic.title, topic.updatedAt].joined(separator: "\u{1F}"),
                                 url: URL(string: "voiceos://topic/" + topic.id)))
        }
        return entries
    }

    private func excerpt(from text: String, limit: Int) -> String {
        let collapsed = singleLine(text)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    private func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
