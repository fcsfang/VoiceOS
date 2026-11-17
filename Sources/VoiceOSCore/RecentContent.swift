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

/// One readable thread of a recording: its title and every thought in the
/// order it was recorded. Goals are a derived subset the page may group.
public struct RecentContentThread: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let thoughts: [RecentContentThought]
    public var goals: [RecentContentThought] { thoughts.filter { $0.kind == .goal } }
    public init(id: String, title: String, thoughts: [RecentContentThought]) {
        self.id = id; self.title = title; self.thoughts = thoughts
    }
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

    private static let timeMarkers = ["今天", "明天", "后天", "下周", "周一", "周二", "周三", "周四", "周五", "周末", "今晚"]

    public static func build(thoughts: [RecentContentThought], duration: TimeInterval, tasks: [RecentContentTask] = []) -> RecentContentDigest {
        let grouped = Dictionary(grouping: thoughts) { threadID(for: $0.statement) }
        let threads = rules.sorted { $0.displayOrder < $1.displayOrder }.compactMap { rule -> RecentContentThread? in
            guard let own = grouped[rule.id], !own.isEmpty else { return nil }
            return RecentContentThread(id: rule.id, title: rule.title, thoughts: own)
        }
        return RecentContentDigest(threads: threads, tasks: orderedTasks(tasks), duration: duration, thoughtCount: thoughts.count)
    }

    public static func threadID(for statement: String) -> String {
        rules.first { rule in rule.keywords.contains { statement.contains($0) } }?.id ?? "life"
    }

    public static func threadTitle(_ id: String) -> String {
        rules.first { $0.id == id }?.title ?? id
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

}

public struct RecentContentDay: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let items: [RecentContentItem]
    public init(id: String, date: Date, items: [RecentContentItem]) { self.id = id; self.date = date; self.items = items }
}

/// One thought in the cross-material home aggregate, carrying the material it
/// came from so the row can name its source and open the original words.
public struct RecentThoughtEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let statement: String
    public let sourceItemID: String
    public let sourceTitle: String
    public let date: Date
    public init(id: String, statement: String, sourceItemID: String, sourceTitle: String, date: Date) {
        self.id = id; self.statement = statement; self.sourceItemID = sourceItemID
        self.sourceTitle = sourceTitle; self.date = date
    }
}

public struct RecentThoughtDay: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let entries: [RecentThoughtEntry]
    public init(id: String, date: Date, entries: [RecentThoughtEntry]) {
        self.id = id; self.date = date; self.entries = entries
    }
}

public enum RecentContentIndex {
    public static func build(sources: [SourceRecord], claims: [CandidateClaim], calendar: Calendar = .current) -> [RecentContentDay] {
        let usable = sources.filter { ["saved", "reference_only"].contains($0.state) && $0.origin == "user" && $0.speaker == "user" }
        let catalog = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let thoughtsBySource = claimsBySource(claims)
        let materialIDs = Set(usable.filter { $0.feedbackKind == nil && !$0.name.hasPrefix("行动反馈") }.map(\.id))
        let expressionsBySource = verifiedExpressions(usable, catalog: catalog, materialIDs: materialIDs)
        var materialItems: [RecentContentItem] = []
        var feedbackSources: [(SourceRecord, Date)] = []
        var builtExpressionIDs: Set<String> = []
        for source in usable {
            let date = date(of: source)
            if source.feedbackKind != nil || source.name.hasPrefix("行动反馈") {
                feedbackSources.append((source, date))
                continue
            }
            if let expression = expressionsBySource[source.id] {
                guard builtExpressionIDs.insert(expression.id).inserted else { continue }
                if let item = expressionItem(expression, catalog: catalog, thoughtsBySource: thoughtsBySource) {
                    materialItems.append(item)
                }
                continue
            }
            let parsed = thoughts(of: source, in: thoughtsBySource)
            let summary = source.contentSummary ?? ""
            let transcript = source.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !parsed.isEmpty || !summary.isEmpty || !transcript.isEmpty else { continue }
            materialItems.append(RecentContentItem(id: source.id, sourceIDs: [source.id], date: date,
                                                   title: source.displayTitle, summary: summary,
                                                   thoughts: dedupe(parsed), excerpts: [], kind: .material,
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

    /// Thoughts from the last `windowDays` days grouped by day, in the input's
    /// newest-first order. Each claim appears once; feedback groups carry none.
    public static func recentThoughts(days: [RecentContentDay], now: Date = Date(), windowDays: Int = 14,
                                      calendar: Calendar = .current) -> [RecentThoughtDay] {
        let start = calendar.date(byAdding: .day, value: 1 - max(windowDays, 1), to: calendar.startOfDay(for: now)) ?? now
        var order: [String] = []
        var grouped: [String: [RecentThoughtEntry]] = [:]
        var dayStart: [String: Date] = [:]
        var seen: Set<String> = []
        for item in days.flatMap(\.items) where item.kind == .material && item.date >= start {
            let key = dayKey(item.date, calendar: calendar)
            for thought in item.thoughts where seen.insert(thought.claimID).inserted {
                if grouped[key] == nil {
                    order.append(key)
                    dayStart[key] = calendar.startOfDay(for: item.date)
                }
                grouped[key, default: []].append(RecentThoughtEntry(
                    id: thought.claimID, statement: thought.statement, sourceItemID: item.id,
                    sourceTitle: item.title, date: item.date))
            }
        }
        return order.compactMap { key in
            guard let date = dayStart[key], let entries = grouped[key] else { return nil }
            return RecentThoughtDay(id: key, date: date, entries: entries)
        }
    }

    private static func thoughts(of source: SourceRecord, in thoughtsBySource: [String: [CandidateClaim]]) -> [RecentContentThought] {
        (thoughtsBySource[source.id] ?? []).compactMap { claim -> RecentContentThought? in
            guard let parsed = parse(claim.statement) else { return nil }
            return RecentContentThought(claimID: claim.id, statement: parsed.statement, kind: parsed.kind)
        }
    }

    /// Multi-segment recordings of one continuous expression read as one entry.
    /// A changed transcript or permission fails the catalog check, so those
    /// segments fall back to separate materials instead of merging stale text.
    private static func verifiedExpressions(_ usable: [SourceRecord], catalog: [String: SourceRecord],
                                            materialIDs: Set<String>) -> [String: RecordingExpression] {
        var result: [String: RecordingExpression] = [:]
        for source in usable where materialIDs.contains(source.id) {
            guard let expression = source.recordingExpression(in: catalog),
                  expression.sourceIDs.count > 1,
                  Set(expression.sourceIDs).isSubset(of: materialIDs) else { continue }
            result[source.id] = expression
        }
        return result
    }

    private static func expressionItem(_ expression: RecordingExpression, catalog: [String: SourceRecord],
                                       thoughtsBySource: [String: [CandidateClaim]]) -> RecentContentItem? {
        let members = expression.sourceIDs.compactMap { catalog[$0] }
        guard !members.isEmpty else { return nil }
        let mergedThoughts = dedupe(members.flatMap { thoughts(of: $0, in: thoughtsBySource) })
        let summary = expression.summary
        guard !mergedThoughts.isEmpty || !summary.isEmpty || members.contains(where: { !($0.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }) else { return nil }
        let title = expression.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? members[0].displayTitle : expression.title
        var seen: Set<String> = []
        let sourceIDs = expression.sourceIDs.filter { seen.insert($0).inserted }
        return RecentContentItem(id: expression.id, sourceIDs: sourceIDs,
                                 date: members.map { date(of: $0) }.max() ?? Date(),
                                 title: title, summary: summary, thoughts: mergedThoughts, excerpts: [],
                                 kind: .material, duration: members.compactMap(\.duration).reduce(0, +))
    }

    public static func thoughtStatement(_ raw: String) -> String? { parse(raw)?.statement }

    /// The shared parser owns the bracket vocabulary. A review marker keeps the
    /// thought off the home page even when it rides behind another tag.
    static func parse(_ raw: String) -> (kind: RecentThoughtKind, statement: String)? {
        var text = raw
        if let range = text.range(of: "说明：") { text = String(text[..<range.lowerBound]) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasSuffix("（待核对）"), !trimmed.hasSuffix("(待核对)") else { return nil }
        let tagged = StatementTagParser.split(text)
        let kind: RecentThoughtKind
        switch tagged.tag {
        case .insight: kind = .insight
        case .goal: kind = .goal
        case .review, .recordingActivity: return nil
        case .question, .idea, nil: kind = .note
        }
        let statement = tagged.text.trimmingCharacters(in: CharacterSet(charactersIn: "；;，, "))
        guard !statement.isEmpty, !statement.hasPrefix("说明："), !statement.hasPrefix("【录音中活动】"),
              !statement.hasPrefix("【待核对】"),
              !statement.hasSuffix("（待核对）"), !statement.hasSuffix("(待核对)") else { return nil }
        return (kind, statement)
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
                                     title: "任务进展", summary: "", thoughts: [],
                                     excerpts: excerpts, kind: .feedback)
        }
    }

    static func date(of source: SourceRecord) -> Date {
        source.expressedDate ?? ConversationReflectionFocus.date(source.createdAt) ?? Date()
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// One task feedback entry on the home page: the user's words plus the task
/// they belong to, so the row can open that task.
public struct RecentContentProgressRow: Identifiable, Equatable, Sendable {
    public static let unavailableTaskTitle = "任务已不可用"
    public let id: String
    public let actionID: String
    public let taskTitle: String
    public let relationLabel: String
    public let text: String
    public let date: Date
    public var isTaskAvailable: Bool { taskTitle != Self.unavailableTaskTitle }
    public init(id: String, actionID: String, taskTitle: String, relationLabel: String, text: String, date: Date) {
        self.id = id; self.actionID = actionID; self.taskTitle = taskTitle
        self.relationLabel = relationLabel; self.text = text; self.date = date
    }
}

/// The home content derived once per workspace reload: the day layout the
/// timeline shows, each material item's digest keyed by item id, and each
/// feedback item's task progress rows keyed by item id. A pure function of its
/// inputs, so a render only reads it.
public struct RecentContentHomeSnapshot: Equatable, Sendable {
    public let days: [RecentContentDay]
    public let digests: [String: RecentContentDigest]
    public let progressRows: [String: [RecentContentProgressRow]]

    public init(days: [RecentContentDay], digests: [String: RecentContentDigest],
                progressRows: [String: [RecentContentProgressRow]] = [:]) {
        self.days = days; self.digests = digests; self.progressRows = progressRows
    }

    public static func build(sources: [SourceRecord], claims: [CandidateClaim], actions: [ActionRecord],
                             calendar: Calendar = .current) -> RecentContentHomeSnapshot {
        let days = RecentContentIndex.build(sources: sources, claims: claims, calendar: calendar)
        var digests: [String: RecentContentDigest] = [:]
        for item in days.flatMap(\.items) where item.kind == .material {
            let claimIDs = Set(item.thoughts.map(\.claimID))
            let tasks = actions
                .filter { $0.state == "open" && $0.validity == "current" && $0.kind == "task" && claimIDs.contains($0.claimID) }
                .map { RecentContentTask(id: $0.id, title: StatementTagParser.split($0.title).text) }
            digests[item.id] = RecentContentDigest.build(thoughts: item.thoughts, duration: item.duration, tasks: tasks)
        }
        var progressRows: [String: [RecentContentProgressRow]] = [:]
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let taskTitles = Dictionary(actions.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for item in days.flatMap(\.items) where item.kind == .feedback {
            let rows = item.sourceIDs.compactMap { sourcesByID[$0] }.compactMap { source -> RecentContentProgressRow? in
                guard source.feedbackKind != nil, let actionID = source.feedbackActionID else { return nil }
                return RecentContentProgressRow(id: source.id, actionID: actionID,
                                                taskTitle: taskTitles[actionID] ?? RecentContentProgressRow.unavailableTaskTitle,
                                                relationLabel: ActionFeedbackLabel.text(relation: source.feedbackRelation, kind: source.feedbackKind),
                                                text: source.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                                date: RecentContentIndex.date(of: source))
            }
            progressRows[item.id] = rows.sorted { left, right in
                left.date == right.date ? left.id < right.id : left.date > right.date
            }
        }
        return RecentContentHomeSnapshot(days: days, digests: digests, progressRows: progressRows)
    }
}
