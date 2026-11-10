import Foundation

/// One user thought shown under its source material. Statements are cleaned of
/// bookkeeping prefixes and the "说明：" annotations the extraction adds.
public struct RecentContentThought: Identifiable, Equatable, Sendable {
    public let claimID: String
    public let statement: String
    public var id: String { claimID }
    public init(claimID: String, statement: String) { self.claimID = claimID; self.statement = statement }
}

/// One readable entry in the content-first home. A feedback group merges the
/// day's short action reactions so they do not flood the timeline.
public struct RecentContentItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case material, feedback }
    public let id: String
    public let sourceIDs: [String]
    public let date: Date
    public let title: String
    public let summary: String
    public let thoughts: [RecentContentThought]
    public let excerpts: [String]
    public let kind: Kind
    public init(id: String, sourceIDs: [String], date: Date, title: String, summary: String,
                thoughts: [RecentContentThought], excerpts: [String], kind: Kind) {
        self.id = id; self.sourceIDs = sourceIDs; self.date = date; self.title = title
        self.summary = summary; self.thoughts = thoughts; self.excerpts = excerpts; self.kind = kind
    }
}

public struct RecentContentDay: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let items: [RecentContentItem]
    public init(id: String, date: Date, items: [RecentContentItem]) { self.id = id; self.date = date; self.items = items }
}

public enum RecentContentIndex {
    public static func build(sources: [SourceRecord], claims: [CandidateClaim], calendar: Calendar = .current) -> [RecentContentDay] {
        let usable = sources.filter { ["saved", "reference_only"].contains($0.state) && $0.origin == "user" && $0.speaker == "user" }
        let thoughtsBySource = claimsBySource(claims)
        var materialItems: [RecentContentItem] = []
        var feedbackSources: [(SourceRecord, Date)] = []
        for source in usable {
            let date = source.expressedDate ?? ConversationReflectionFocus.date(source.createdAt) ?? Date()
            if source.feedbackKind != nil || source.name.hasPrefix("行动反馈") {
                feedbackSources.append((source, date))
                continue
            }
            let thoughts = (thoughtsBySource[source.id] ?? []).compactMap { claim -> RecentContentThought? in
                guard let statement = thoughtStatement(claim.statement) else { return nil }
                return RecentContentThought(claimID: claim.id, statement: statement)
            }
            let summary = source.contentSummary ?? ""
            let transcript = source.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !thoughts.isEmpty || !summary.isEmpty || !transcript.isEmpty else { continue }
            materialItems.append(RecentContentItem(id: source.id, sourceIDs: [source.id], date: date,
                                                   title: source.displayTitle, summary: summary,
                                                   thoughts: dedupe(thoughts), excerpts: [], kind: .material))
        }
        let feedbackItems = feedbackGroups(feedbackSources, calendar: calendar)
        let allItems = (materialItems + feedbackItems).sorted { $0.date > $1.date }
        var order: [String] = []
        var byDay: [String: [RecentContentItem]] = [:]
        var dayStart: [String: Date] = [:]
        for item in allItems {
            let key = dayKey(item.date, calendar: calendar)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(item)
            dayStart[key] = calendar.startOfDay(for: item.date)
        }
        return order.compactMap { key in
            guard let date = dayStart[key], let items = byDay[key] else { return nil }
            return RecentContentDay(id: key, date: date, items: items)
        }
    }

    /// Repeated extraction attempts can store the same statement several times.
    public static func dedupe(_ thoughts: [RecentContentThought]) -> [RecentContentThought] {
        var seen: Set<String> = []
        return thoughts.filter { seen.insert($0.statement).inserted }
    }

    public static func thoughtStatement(_ raw: String) -> String? {
        var text = raw
        if let range = text.range(of: "说明：") { text = String(text[..<range.lowerBound]) }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "；;，, "))
        guard !trimmed.hasPrefix("说明："), !trimmed.hasPrefix("【录音中活动】"), !trimmed.hasPrefix("【待核对】"),
              !trimmed.hasSuffix("（待核对）"), !trimmed.hasSuffix("(待核对)") else { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func claimsBySource(_ claims: [CandidateClaim]) -> [String: [CandidateClaim]] {
        var result: [String: [CandidateClaim]] = [:]
        for claim in claims where claim.validity == "current" && claim.ownership == "user_tentative" && claim.reviewState != "rejected" {
            for sourceID in Set(claim.references.map(\.sourceID)) {
                result[sourceID, default: []].append(claim)
            }
        }
        return result
    }

    private static func feedbackGroups(_ sources: [(SourceRecord, Date)], calendar: Calendar) -> [RecentContentItem] {
        var order: [String] = []
        var grouped: [String: [(SourceRecord, Date)]] = [:]
        for entry in sources {
            let key = dayKey(entry.1, calendar: calendar)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(entry)
        }
        return order.compactMap { key in
            guard let entries = grouped[key], let latest = entries.map(\.1).max() else { return nil }
            let excerpts = entries.sorted { $0.1 > $1.1 }.compactMap { $0.0.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !excerpts.isEmpty else { return nil }
            return RecentContentItem(id: "feedback-" + key, sourceIDs: entries.map(\.0.id), date: latest,
                                     title: "\(entries.count) 条行动反馈", summary: "", thoughts: [],
                                     excerpts: excerpts, kind: .feedback)
        }
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
