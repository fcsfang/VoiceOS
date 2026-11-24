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

/// A user override for one of the static home clues. The clue is a rule id
/// (`work`, `family`, ...), and an override may arrive before that clue has
/// any thought to group.
public struct RecentClueOverride: Equatable, Sendable {
    public var clue: String
    public var displayTitle: String?
    public var mergeInto: String?
    public var hidden: Bool
    public var updatedAt: String
    public init(clue: String, displayTitle: String? = nil, mergeInto: String? = nil, hidden: Bool = false, updatedAt: String) {
        self.clue = clue; self.displayTitle = displayTitle; self.mergeInto = mergeInto
        self.hidden = hidden; self.updatedAt = updatedAt
    }
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

    public static func build(thoughts: [RecentContentThought], duration: TimeInterval, tasks: [RecentContentTask] = [],
                             overrides: [RecentClueOverride] = []) -> RecentContentDigest {
        let overridesByClue = Dictionary(overrides.map { ($0.clue, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: thoughts) { threadID(for: $0.statement) }
        let orderedRules = rules.sorted { $0.displayOrder < $1.displayOrder }
        // One hop only: following a second merge would make the visible section
        // depend on insertion order rather than on what the user chose.
        var mergedInto: [String: [RecentContentThought]] = [:]
        for rule in orderedRules {
            guard let override = overridesByClue[rule.id], !override.hidden,
                  let target = override.mergeInto, target != rule.id else { continue }
            mergedInto[target, default: []].append(contentsOf: grouped[rule.id] ?? [])
        }
        let mergesAway = { (id: String) -> Bool in
            overridesByClue[id]?.mergeInto.map { $0 != id } ?? false
        }
        var threads: [RecentContentThread] = []
        for rule in orderedRules {
            let override = overridesByClue[rule.id]
            guard override?.hidden != true, !mergesAway(rule.id) else { continue }
            let own = (grouped[rule.id] ?? []) + (mergedInto[rule.id] ?? [])
            guard !own.isEmpty else { continue }
            threads.append(RecentContentThread(id: rule.id, title: override?.displayTitle ?? rule.title, thoughts: own))
        }
        // A merge target can be a clue the user named before it produced thoughts.
        for target in mergedInto.keys.sorted() where !rules.contains(where: { $0.id == target }) {
            let override = overridesByClue[target]
            guard override?.hidden != true, let own = mergedInto[target], !own.isEmpty else { continue }
            threads.append(RecentContentThread(id: target, title: override?.displayTitle ?? threadTitle(target), thoughts: own))
        }
        return RecentContentDigest(threads: threads, tasks: orderedTasks(tasks), duration: duration,
                                   thoughtCount: threads.reduce(0) { $0 + $1.thoughts.count })
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

/// One timeline row's precomputed reads: the icon, the count a feedback row
/// shows, and the status slot's non-default state. The reading state arrives
/// after the snapshot, so the view merges it in.
public struct RecentHomeRow: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case localOnly, organizing, needsReview, issues(Int)
    }
    public let icon: String
    public let count: Int
    public let status: Status?
    public init(icon: String, count: Int, status: Status?) {
        self.icon = icon; self.count = count; self.status = status
    }
}

/// The home content derived once per workspace reload: the day layout the
/// timeline shows, each material item's digest keyed by item id, each feedback
/// item's task progress rows keyed by item id, each row's icon, count and
/// status. A pure function of its inputs, so a render only reads it.
public struct RecentContentHomeSnapshot: Equatable, Sendable {
    public let days: [RecentContentDay]
    public let digests: [String: RecentContentDigest]
    public let progressRows: [String: [RecentContentProgressRow]]
    public let rows: [String: RecentHomeRow]

    public init(days: [RecentContentDay], digests: [String: RecentContentDigest],
                progressRows: [String: [RecentContentProgressRow]] = [:],
                rows: [String: RecentHomeRow] = [:]) {
        self.days = days; self.digests = digests; self.progressRows = progressRows
        self.rows = rows
    }

    public static func build(sources: [SourceRecord], claims: [CandidateClaim], actions: [ActionRecord],
                             calendar: Calendar = .current, overrides: [RecentClueOverride] = [],
                             reviewRequiredActionIDs: Set<String> = [], now: Date = Date()) -> RecentContentHomeSnapshot {
        let days = RecentContentIndex.build(sources: sources, claims: claims, calendar: calendar)
        let overridesByClue = Dictionary(overrides.map { ($0.clue, $0) }, uniquingKeysWith: { first, _ in first })
        // A section hidden even indirectly through its merge target takes its
        // tasks with it; the digest has no visible row to carry them.
        let hidesThought = { (statement: String) -> Bool in
            let id = RecentContentDigest.threadID(for: statement)
            if overridesByClue[id]?.hidden == true { return true }
            guard let target = overridesByClue[id]?.mergeInto, target != id else { return false }
            return overridesByClue[target]?.hidden == true
        }
        // One index for the whole snapshot. Positions keep the actions' own
        // order when an item's claims are gathered from a set.
        var actionPositionsByClaimID: [String: [Int]] = [:]
        for (position, action) in actions.enumerated()
        where action.state == "open" && action.validity == "current" && action.kind == "task"
            && !reviewRequiredActionIDs.contains(action.id) {
            actionPositionsByClaimID[action.claimID, default: []].append(position)
        }
        var digests: [String: RecentContentDigest] = [:]
        for item in days.flatMap(\.items) where item.kind == .material {
            let claimIDs = Set(item.thoughts.filter { !hidesThought($0.statement) }.map(\.claimID))
            let tasks = claimIDs.flatMap { actionPositionsByClaimID[$0] ?? [] }.sorted().map { position in
                let action = actions[position]
                return RecentContentTask(id: action.id, title: StatementTagParser.split(action.title).text)
            }
            digests[item.id] = RecentContentDigest.build(thoughts: item.thoughts, duration: item.duration,
                                                         tasks: tasks, overrides: overrides)
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
        var rows: [String: RecentHomeRow] = [:]
        for item in days.flatMap(\.items) {
            if item.kind == .feedback {
                rows[item.id] = RecentHomeRow(icon: "arrow.triangle.2.circlepath",
                                              count: progressRows[item.id]?.count ?? item.excerpts.count,
                                              status: nil)
                continue
            }
            let source = item.sourceIDs.first.flatMap { sourcesByID[$0] }
            let status: RecentHomeRow.Status?
            if let source, source.localOnly { status = .localOnly }
            else if let source, ["queued", "running", "reserved"].contains(source.jobState ?? "") { status = .organizing }
            else if let source, source.needsTranscriptionReview { status = .needsReview }
            else { status = nil }
            rows[item.id] = RecentHomeRow(icon: source?.kind.contains("text") == true ? "doc.text" : "waveform",
                                          count: 0, status: status)
        }
        return RecentContentHomeSnapshot(days: days, digests: digests, progressRows: progressRows, rows: rows,
                                         )
    }
}

extension VoiceOSStore {
    public func recentClueOverrides() throws -> [RecentClueOverride] {
        try db.query("SELECT clue,display_title,merge_into,hidden,updated_at FROM recent_clue_overrides ORDER BY clue").map { row in
            RecentClueOverride(clue: row["clue"]!, displayTitle: row["display_title"], mergeInto: row["merge_into"],
                               hidden: row["hidden"] == "1", updatedAt: row["updated_at"]!)
        }
    }

    public func setRecentClueTitle(clue: String, title: String?, commandID: String) throws {
        let normalized = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized?.isEmpty == false ? normalized : nil
        try writeRecentClueOverride(clue: clue, commandID: commandID, column: "display_title", value: value) {
            $0["display_title"] == value
        }
    }

    public func mergeRecentClue(_ clue: String, into target: String, commandID: String) throws {
        let source = clue.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty else { throw VoiceOSError("线索名称不能为空") }
        guard source != destination else { throw VoiceOSError("线索不能合并到自己") }
        try writeRecentClueOverride(clue: source, commandID: commandID, column: "merge_into", value: destination) {
            $0["merge_into"] == destination
        }
    }

    public func setRecentClueHidden(clue: String, hidden: Bool, commandID: String) throws {
        let value = hidden ? "1" : "0"
        try writeRecentClueOverride(clue: clue, commandID: commandID, column: "hidden", value: value) {
            $0["hidden"] == value
        }
    }

    private func writeRecentClueOverride(clue: String, commandID: String, column: String, value: String?,
                                         matchesReceipt: ([String: String]) -> Bool) throws {
        let normalized = clue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !commandID.isEmpty else { throw VoiceOSError("线索操作命令不能为空") }
        if let receipt = try db.query("SELECT * FROM recent_clue_overrides WHERE command_id=?", [commandID]).first {
            guard receipt["clue"] == normalized, matchesReceipt(receipt) else {
                throw VoiceOSError("同一次线索操作不能更换内容")
            }
            return
        }
        try db.transaction {
            try db.execute("""
            INSERT INTO recent_clue_overrides(clue,\(column),updated_at,command_id) VALUES(?,?,?,?)
            ON CONFLICT(clue) DO UPDATE SET \(column)=excluded.\(column),updated_at=excluded.updated_at,command_id=excluded.command_id
            """, [normalized, value, VoiceOSStore.now(), commandID])
        }
    }
}
