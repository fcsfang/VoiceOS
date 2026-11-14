import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import VoiceOSCore

@MainActor
public final class SpotlightIndexer {
    private struct Entry {
        let id: String
        let title: String
        let summary: String
    }

    public static let domainIdentifier = "VoiceOS"
    private let minimumInterval: TimeInterval
    private var lastIndexedAt: Date?
    private var lastPayload = ""
    private var lastIdentifiers: Set<String> = []

    public init(minimumInterval: TimeInterval = 60) {
        self.minimumInterval = minimumInterval
    }

    public func index(sources: [SourceRecord], claims: [CandidateClaim], actions: [ActionRecord]) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let entries = makeEntries(sources: sources, claims: claims, actions: actions)
        let payload = entries.map { $0.id + "\u{1F}" + $0.title + "\u{1F}" + $0.summary }.joined(separator: "\u{1E}")
        if payload == lastPayload { return }
        let now = Date()
        if let lastIndexedAt, now.timeIntervalSince(lastIndexedAt) < minimumInterval { return }
        let identifiers = Set(entries.map { $0.id })
        let removed = lastIdentifiers.subtracting(identifiers)
        let items = entries.map { entry -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .plainText)
            attributes.title = entry.title
            attributes.contentDescription = entry.summary
            return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: Self.domainIdentifier, attributeSet: attributes)
        }
        guard !items.isEmpty else {
            finish(payload: payload, identifiers: identifiers, removed: removed)
            return
        }
        CSSearchableIndex.default().indexSearchableItems(items) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    NSLog("VoiceOS Spotlight 索引失败：\(error.localizedDescription)")
                    return
                }
                self.finish(payload: payload, identifiers: identifiers, removed: removed)
            }
        }
    }

    private func finish(payload: String, identifiers: Set<String>, removed: Set<String>) {
        lastPayload = payload
        lastIdentifiers = identifiers
        lastIndexedAt = Date()
        guard !removed.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: Array(removed)) { error in
            if let error { NSLog("VoiceOS Spotlight 清理失败：\(error.localizedDescription)") }
        }
    }

    private func makeEntries(sources: [SourceRecord], claims: [CandidateClaim], actions: [ActionRecord]) -> [Entry] {
        var entries: [Entry] = []
        for source in sources where ["saved", "reference_only"].contains(source.state) {
            let excerpt = excerpt(from: source.transcript ?? "", limit: 200)
            entries.append(Entry(id: "source-" + source.id, title: singleLine(source.name), summary: excerpt.isEmpty ? "材料" : excerpt))
        }
        for claim in claims where claim.validity == "current" {
            entries.append(Entry(id: "claim-" + claim.id, title: singleLine(claim.statement), summary: "观点"))
        }
        for action in actions where action.state == "open" && action.validity == "current" {
            let note = singleLine(action.note)
            entries.append(Entry(id: "action-" + action.id, title: singleLine(action.title), summary: note.isEmpty ? "开放行动" : note))
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
