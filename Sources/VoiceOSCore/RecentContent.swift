import Foundation

/// The extraction's leading bracket tag decides how a thought reads: an
/// observation about the world, a long-term intention, or a passing note.
public enum RecentThoughtKind: String, Codable, Sendable { case insight, goal, note }

/// One user thought shown under its source material. Statements are cleaned of
/// bookkeeping prefixes and the "说明：" annotations the extraction adds.
public struct RecentContentThought: Identifiable, Equatable, Sendable {
    public let claimID: String
    public let statement: String
    public let kind: RecentThoughtKind
    public var id: String { claimID }
    public init(claimID: String, statement: String, kind: RecentThoughtKind = .note) {
        self.claimID = claimID; self.statement = statement; self.kind = kind
    }
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
    public let duration: TimeInterval
    public init(id: String, sourceIDs: [String], date: Date, title: String, summary: String,
                thoughts: [RecentContentThought], excerpts: [String], kind: Kind, duration: TimeInterval = 0) {
        self.id = id; self.sourceIDs = sourceIDs; self.date = date; self.title = title
        self.summary = summary; self.thoughts = thoughts; self.excerpts = excerpts; self.kind = kind
        self.duration = duration
    }
}

/// One readable thread of a recording: its lead quote, up to two supporting
/// thoughts, every goal, and everything else behind an in-place expander.
public struct RecentContentThread: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let thoughts: [RecentContentThought]
    public let lead: RecentContentThought?
    public let supporting: [RecentContentThought]
    public let goals: [RecentContentThought]
    public var remaining: [RecentContentThought] {
        let shown = Set(([lead].compactMap { $0 } + supporting + Array(goals.prefix(2))).map(\.id))
        return thoughts.filter { !shown.contains($0.id) }
    }
    public var hiddenCount: Int { remaining.count }
}

public struct RecentContentTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct RecentContentDigest: Equatable, Sendable {
    public let threads: [RecentContentThread]
    public let tasks: [RecentContentTask]
    public let duration: TimeInterval
    public let thoughtCount: Int

    /// Array order is match precedence: family statements win over a life
    /// signal, which wins over work, career and self; no match falls to life.
    /// `displayOrder` is the reading order on the page.
    private struct ThreadRule {
        let id: String
        let title: String
        let displayOrder: Int
        let keywords: [String]
    }

    private static let lifeSignals = ["播客", "录制", "视频", "游戏", "短视频", "耳机", "AirPods", "网易云", "结婚", "作息", "提醒事项", "助听"]

    private static let rules: [ThreadRule] = [
        ThreadRule(id: "family", title: "家人", displayOrder: 0,
                   keywords: ["父", "母", "家人", "爸", "妈", "亲戚", "交流", "长谈"]),
        ThreadRule(id: "life", title: "生活杂记", displayOrder: 4, keywords: lifeSignals),
        ThreadRule(id: "work", title: "实习与交付", displayOrder: 1,
                   keywords: ["实习", "领导", "项目", "汇报", "交付", "完美", "闭门", "同事", "成果", "打磨", "展示", "任务"]),
        ThreadRule(id: "career", title: "职业与学习", displayOrder: 2,
                   keywords: ["AI", "GPT", "代码", "技术", "职业", "工程师", "学习", "简历", "开题", "答辩", "决策", "能力"]),
        ThreadRule(id: "self", title: "对自己的认识", displayOrder: 3,
                   keywords: ["自信", "自卑", "悲观", "勇敢", "改变", "藏锋", "犯错", "思考", "自我", "探索", "值得", "价值", "逃避", "谦虚"]),
    ]

    private static let reflectingWords = ["认为", "觉得", "应该", "不应", "不必", "意识", "发现", "长期", "过去", "改变", "学习", "值得", "重要", "可能", "包容", "自信", "自卑", "勇气", "完美", "交付", "汇报", "沟通", "思考", "逃避", "价值", "成长", "更好", "真正"]
    private static let concreteWords = ["项目是", "功能", "AirPods", "网易云", "耳机", "第一个", "第二个", "今天", "明天", "下周", "上周", "提醒事项", "PPT", "答辩"]
    private static let timeMarkers = ["今天", "明天", "后天", "下周", "周一", "周二", "周三", "周四", "周五", "周末", "今晚"]

    public static func build(thoughts: [RecentContentThought], duration: TimeInterval, tasks: [RecentContentTask] = []) -> RecentContentDigest {
        let grouped = Dictionary(grouping: thoughts) { threadID(for: $0.statement) }
        let threads = rules.sorted { $0.displayOrder < $1.displayOrder }.compactMap { rule -> RecentContentThread? in
            guard let own = grouped[rule.id], !own.isEmpty else { return nil }
            let insights = own.filter { $0.kind == .insight }
            let lead = ranked(insights.isEmpty ? own.filter { $0.kind != .goal } : insights).first
            let supporting = lead.map { lead in Array(ranked(insights.filter { $0.id != lead.id }).prefix(2)) } ?? []
            return RecentContentThread(id: rule.id, title: rule.title, thoughts: own, lead: lead,
                                       supporting: supporting, goals: own.filter { $0.kind == .goal })
        }
        return RecentContentDigest(threads: threads, tasks: orderedTasks(tasks), duration: duration, thoughtCount: thoughts.count)
    }

    public static func threadID(for statement: String) -> String {
        rules.first { rule in rule.keywords.contains { statement.contains($0) } }?.id ?? "life"
    }

    public static func threadTitle(_ id: String) -> String {
        rules.first { $0.id == id }?.title ?? id
    }

    public static func leadScore(_ statement: String) -> Double {
        let positive = reflectingWords.reduce(0) { $0 + occurrences(of: $1, in: statement) * 3 }
        let negative = concreteWords.reduce(0) { $0 + occurrences(of: $1, in: statement) * 4 }
        return Double(positive - negative) + Double(min(statement.count, 40)) / 10
    }

    public static func orderedTasks(_ tasks: [RecentContentTask]) -> [RecentContentTask] {
        let isScheduled = { (task: RecentContentTask) in timeMarkers.contains { task.title.contains($0) } }
        return tasks.filter(isScheduled) + tasks.filter { !isScheduled($0) }
    }

    public static func durationLabel(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "" }
        guard duration >= 60 else { return "不到 1 分钟" }
        let minutes = Int((duration / 60).rounded())
        return minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private static func ranked(_ thoughts: [RecentContentThought]) -> [RecentContentThought] {
        thoughts.enumerated().sorted { left, right in
            let scores = (leadScore(left.element.statement), leadScore(right.element.statement))
            return scores.0 == scores.1 ? left.offset < right.offset : scores.0 > scores.1
        }.map(\.element)
    }

    private static func occurrences(of word: String, in text: String) -> Int {
        var count = 0, remainder = text[...]
        while let range = remainder.range(of: word) {
            count += 1
            remainder = remainder[range.upperBound...]
        }
        return count
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
                guard let parsed = parse(claim.statement) else { return nil }
                return RecentContentThought(claimID: claim.id, statement: parsed.statement, kind: parsed.kind)
            }
            let summary = source.contentSummary ?? ""
            let transcript = source.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !thoughts.isEmpty || !summary.isEmpty || !transcript.isEmpty else { continue }
            materialItems.append(RecentContentItem(id: source.id, sourceIDs: [source.id], date: date,
                                                   title: source.displayTitle, summary: summary,
                                                   thoughts: dedupe(thoughts), excerpts: [], kind: .material,
                                                   duration: source.duration ?? 0))
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

    public static func thoughtStatement(_ raw: String) -> String? { parse(raw)?.statement }

    static func parse(_ raw: String) -> (kind: RecentThoughtKind, statement: String)? {
        var text = raw
        if let range = text.range(of: "说明：") { text = String(text[..<range.lowerBound]) }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind = RecentThoughtKind.note
        let tags: [(String, RecentThoughtKind)] = [("【观点】", .insight), ("【长期目标】", .goal), ("【问题】", .note), ("【想法】", .note)]
        if let tag = tags.first(where: { trimmed.hasPrefix($0.0) }) {
            kind = tag.1
            trimmed = String(trimmed.dropFirst(tag.0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "；;，, "))
        guard !trimmed.hasPrefix("说明："), !trimmed.hasPrefix("【录音中活动】"), !trimmed.hasPrefix("【待核对】"),
              !trimmed.hasSuffix("（待核对）"), !trimmed.hasSuffix("(待核对)") else { return nil }
        return trimmed.isEmpty ? nil : (kind, trimmed)
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
