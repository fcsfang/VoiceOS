import Foundation

public enum ReadOnlyLibraryError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case incompatibleSchema(found: Int)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return message
        case let .incompatibleSchema(found):
            return "资料库格式不兼容（user_version=\(found)，需要 \(Database.schemaVersion)）"
        }
    }
}

public struct ReadOnlyDue: Codable, Sendable, Equatable {
    public let kind: String
    public let localDate: String?
    public let utc: String?
    public let timeZone: String?
    public let source: String
    public let isOverdue: Bool
}

public struct ReadOnlyActionRow: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let kind: String
    public let state: String
    public let validity: String
    public let nature: String
    public let version: Int
    public let parentID: String?
    public let createdAt: String
    public let completedAt: String?
    public let feedbackCount: Int
    public let lastFeedbackAt: String?
    public let sourceTitle: String?
    public let reminderState: String?
    public let due: ReadOnlyDue?
}

public struct ReadOnlySchedule: Codable, Sendable, Equatable {
    public let version: Int
    public let due: ReadOnlyDue?
    public let authority: String
    public let actor: String
    public let rawExpression: String
    public let anchorEventTime: String
    public let anchorTimeZone: String
    public let validity: String
}

public struct ReadOnlyReminder: Codable, Sendable, Equatable {
    public let state: String
    public let completed: Bool?
    public let observedAt: String?
    public let due: ReadOnlyDue?
}

public struct ReadOnlyRevision: Codable, Sendable, Equatable {
    public let version: Int
    public let state: String
    public let actor: String
    public let createdAt: String
}

public struct ReadOnlyFeedback: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let label: String
    public let createdAt: String
    public let text: String?
}

public struct ReadOnlySource: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let title: String
    public let kind: String
    public let state: String
    public let createdAt: String
}

public struct ReadOnlyTopic: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
}

public struct ReadOnlyActionDetail: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let kind: String
    public let state: String
    public let validity: String
    public let nature: String
    public let version: Int
    public let parentID: String?
    public let createdAt: String
    public let completedAt: String?
    public let feedbackCount: Int
    public let lastFeedbackAt: String?
    public let sourceTitle: String?
    public let reminderState: String?
    public let due: ReadOnlyDue?
    public let note: String?
    public let schedule: ReadOnlySchedule?
    public let reminder: ReadOnlyReminder?
    public let revisions: [ReadOnlyRevision]
    public let feedback: [ReadOnlyFeedback]?
    public let source: ReadOnlySource?
    public let topics: [ReadOnlyTopic]?
    fileprivate init(summary: ReadOnlyActionRow, note: String?, schedule: ReadOnlySchedule?,
                     reminder: ReadOnlyReminder?, revisions: [ReadOnlyRevision], feedback: [ReadOnlyFeedback]?,
                     source: ReadOnlySource?, topics: [ReadOnlyTopic]?) {
        id = summary.id
        title = summary.title
        kind = summary.kind
        state = summary.state
        validity = summary.validity
        nature = summary.nature
        version = summary.version
        parentID = summary.parentID
        createdAt = summary.createdAt
        completedAt = summary.completedAt
        feedbackCount = summary.feedbackCount
        lastFeedbackAt = summary.lastFeedbackAt
        sourceTitle = summary.sourceTitle
        reminderState = summary.reminderState
        due = summary.due
        self.note = note
        self.schedule = schedule
        self.reminder = reminder
        self.revisions = revisions
        self.feedback = feedback
        self.source = source
        self.topics = topics
    }
}

public struct ReadOnlyStatus: Codable, Sendable, Equatable {
    public let userVersion: Int
    public let walPresent: Bool
    public let sources: Int
    public let actionsOpen: Int
    public let actionsCompleted: Int
    public let actionsDismissed: Int
    public let actionsSomeday: Int
    public let actionsCurrent: Int
    public let actionsFrozen: Int
    public let feedback: Int
    public let topics: Int
}

/// A second, read-only door into the library. `VoiceOSStore` owns migrations,
/// recovery and an exclusive flock, so an agent process must not open it;
/// this type reads the same file directly and never writes.
public struct ReadOnlyLibrary {
    private let connection: SQLiteConnection
    private let databaseFile: URL

    public init(root: URL) throws {
        let file = LibraryLayout.database(in: root)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ReadOnlyLibraryError.unavailable("资料库不存在：\(file.path)")
        }
        let connection = try SQLiteConnection(file, access: .readOnly,
                                              openError: ReadOnlyLibraryError.unavailable("无法只读打开资料库：\(file.path)"))
        try connection.query("PRAGMA query_only=ON")
        // The version check establishes the WAL snapshot all later reads use.
        try connection.query("BEGIN")
        let version = try connection.schemaVersion
        guard version == Database.schemaVersion else {
            throw ReadOnlyLibraryError.incompatibleSchema(found: version)
        }
        self.connection = connection
        self.databaseFile = file
    }

    func query(_ sql: String, _ arguments: [String?] = []) throws -> [[String: String]] {
        try connection.query(sql, arguments)
    }

    public func actions(state: String? = nil, validity: String? = nil, kind: String? = nil,
                        limit: Int = 100, offset: Int = 0) throws -> [ReadOnlyActionRow] {
        var conditions: [String] = ["a.removed=0"]
        var arguments: [String?] = []
        if let state { conditions.append("a.state=?"); arguments.append(state) }
        if let validity { conditions.append("a.validity=?"); arguments.append(validity) }
        if let kind { conditions.append("a.kind=?"); arguments.append(kind) }
        arguments.append(String(max(1, min(limit, 1000))))
        arguments.append(String(max(0, offset)))
        let filter = conditions.joined(separator: " AND ")
        let rows = try connection.query("""
        SELECT \(Self.actionColumns)
        \(Self.actionTables)
        WHERE \(filter) ORDER BY a.created_at,a.id LIMIT ? OFFSET ?
        """, arguments)
        return try rows.map { row in
            let source = try sourceRecord(refsJSON: row["claim_refs"])
            return Self.actionSummary(row, sourceTitle: source?.title, now: Date())
        }
    }

    public func action(id: String, includeFeedback: Bool = false, includeFeedbackText: Bool = false,
                       includeNote: Bool = false, includeTopics: Bool = false) throws -> ReadOnlyActionDetail? {
        let noteColumn = includeNote ? ",COALESCE(a.edited_note,a.note) AS note" : ""
        guard let row = try connection.query("""
        SELECT \(Self.actionColumns),s.authority,s.actor,s.raw_expression,s.anchor_event_time,s.anchor_time_zone,
               s.validity AS schedule_validity,o.completed AS reminder_completed,o.created_at AS reminder_observed_at
               \(noteColumn)
        \(Self.actionTables)
        WHERE a.id=? AND a.removed=0
        """, [id]).first else { return nil }
        let revisions = try connection.query("""
        SELECT version,state,actor,created_at FROM action_revisions WHERE action_id=? ORDER BY version DESC
        """, [id]).map {
            ReadOnlyRevision(version: Int($0["version"] ?? "0") ?? 0, state: $0["state"] ?? "",
                             actor: $0["actor"] ?? "", createdAt: $0["created_at"] ?? "")
        }
        let source = try sourceRecord(refsJSON: row["claim_refs"])
        let now = Date()
        let summary = Self.actionSummary(row, sourceTitle: source?.title, now: now)
        let schedule = row["schedule_version"].map { version in
            ReadOnlySchedule(version: Int(version) ?? 0, due: summary.due,
                             authority: row["authority"] ?? "", actor: row["actor"] ?? "",
                             rawExpression: row["raw_expression"] ?? "", anchorEventTime: row["anchor_event_time"] ?? "",
                             anchorTimeZone: row["anchor_time_zone"] ?? "", validity: row["schedule_validity"] ?? "")
        }
        let reminder = row["reminder_state"].map { state in
            ReadOnlyReminder(state: state, completed: row["reminder_completed"].map { $0 == "1" },
                             observedAt: row["reminder_observed_at"],
                             due: schedule == nil ? summary.due :
                                Self.dueValue(json: row["reminder_due_json"], source: "reminderObservation", now: now))
        }
        return ReadOnlyActionDetail(summary: summary, note: row["note"], schedule: schedule, reminder: reminder,
                                    revisions: revisions,
                                    feedback: includeFeedback ? try feedbackRecords(actionID: id, includeText: includeFeedbackText) : nil,
                                    source: source, topics: includeTopics ? topicRecords(actionID: id) : nil)
    }

    private static let actionColumns = """
    a.id,COALESCE(a.edited_title,a.title) AS title,a.kind,a.state,a.validity,a.nature,a.version,a.parent_id,a.created_at,
    (SELECT MAX(r.created_at) FROM action_revisions r WHERE r.action_id=a.id AND r.state='completed') AS completed_at,
    (SELECT COUNT(*) FROM action_feedback f WHERE f.action_id=a.id) AS feedback_count,
    (SELECT MAX(f.created_at) FROM action_feedback f WHERE f.action_id=a.id) AS last_feedback_at,
    c.refs_json AS claim_refs,l.state AS reminder_state,s.schedule_version,s.due_json AS local_due_json,
    t.due_json AS reminder_due_json
    """

    private static let actionTables = """
    FROM actions a JOIN claims c ON c.id=a.claim_id
    LEFT JOIN action_schedule_intents s ON s.id=(
        SELECT id FROM action_schedule_intents WHERE action_id=a.id AND validity='current'
        ORDER BY schedule_version DESC LIMIT 1
    )
    LEFT JOIN reminder_links l ON l.action_id=a.id
    LEFT JOIN reminder_observations o ON o.id=(
        SELECT id FROM reminder_observations WHERE link_id=l.id ORDER BY sequence DESC LIMIT 1
    )
    LEFT JOIN reminder_time_observations t ON t.id=o.id
    """

    private static func actionSummary(_ row: [String: String], sourceTitle: String?, now: Date) -> ReadOnlyActionRow {
        // A current schedule is authoritative even when its due date is explicitly absent.
        // This CLI continues to expose the latest reminder observation regardless of link state.
        let due = row["schedule_version"] != nil
            ? dueValue(json: row["local_due_json"], source: "localSchedule", now: now)
            : dueValue(json: row["reminder_due_json"], source: "reminderObservation", now: now)
        return ReadOnlyActionRow(id: row["id"] ?? "", title: row["title"] ?? "", kind: row["kind"] ?? "",
                                 state: row["state"] ?? "", validity: row["validity"] ?? "",
                                 nature: row["nature"] ?? "unknown", version: Int(row["version"] ?? "1") ?? 1,
                                 parentID: row["parent_id"], createdAt: row["created_at"] ?? "",
                                 completedAt: row["completed_at"], feedbackCount: Int(row["feedback_count"] ?? "0") ?? 0,
                                 lastFeedbackAt: row["last_feedback_at"], sourceTitle: sourceTitle,
                                 reminderState: row["reminder_state"], due: due)
    }

    public func status() throws -> ReadOnlyStatus {
        let version = try connection.schemaVersion
        func count(_ sql: String) throws -> Int {
            Int(try connection.query(sql).first?["n"] ?? "0") ?? 0
        }
        let states = Dictionary(try connection.query("SELECT state,COUNT(*) AS n FROM actions WHERE removed=0 GROUP BY state").map {
            ($0["state"] ?? "", Int($0["n"] ?? "0") ?? 0)
        }, uniquingKeysWith: { $1 })
        let validities = Dictionary(try connection.query("SELECT validity,COUNT(*) AS n FROM actions WHERE removed=0 GROUP BY validity").map {
            ($0["validity"] ?? "", Int($0["n"] ?? "0") ?? 0)
        }, uniquingKeysWith: { $1 })
        return ReadOnlyStatus(userVersion: version,
                              walPresent: FileManager.default.fileExists(atPath: databaseFile.path + "-wal"),
                              sources: try count("SELECT COUNT(*) AS n FROM sources"),
                              actionsOpen: states["open"] ?? 0,
                              actionsCompleted: states["completed"] ?? 0,
                              actionsDismissed: states["dismissed"] ?? 0,
                              actionsSomeday: states["someday"] ?? 0,
                              actionsCurrent: validities["current"] ?? 0,
                              actionsFrozen: validities["frozen"] ?? 0,
                              feedback: try count("SELECT COUNT(*) AS n FROM action_feedback"),
                              topics: try count("SELECT COUNT(*) AS n FROM reflection_questions"))
    }

    private func feedbackRecords(actionID: String, includeText: Bool) throws -> [ReadOnlyFeedback] {
        let textJoin = includeText ? "LEFT JOIN transcript_versions v ON v.id=\(Database.latestTranscriptVersionForSource)" : ""
        let rows = try connection.query("""
        SELECT f.id,f.kind,f.created_at,s.feedback_json\(includeText ? ",v.text" : "")
        FROM action_feedback f JOIN sources s ON s.id=f.source_id
        \(textJoin)
        WHERE f.action_id=? ORDER BY f.sequence
        """, [actionID])
        return rows.map { row in
            let kind = row["kind"] ?? ""
            let relation = Self.feedbackRelation(row["feedback_json"])
            return ReadOnlyFeedback(id: row["id"] ?? "", kind: kind,
                                    label: ActionFeedbackLabel.text(relation: relation, kind: kind),
                                    createdAt: row["created_at"] ?? "",
                                    text: row["text"])
        }
    }

    private static func feedbackRelation(_ json: String?) -> String? {
        guard let json else { return nil }
        return (try? JSONDecoder().decode(FeedbackIntent.self, from: Data(json.utf8)))?.relation
    }

    private func topicRecords(actionID: String) -> [ReadOnlyTopic] {
        guard let rows = try? connection.query("SELECT id,title,organization_json FROM reflection_questions WHERE organization_json IS NOT NULL ORDER BY id") else {
            return []
        }
        return rows.compactMap { row in
            guard let json = row["organization_json"],
                  let summary = try? JSONDecoder().decode(TopicOrganizationSummary.self, from: Data(json.utf8)),
                  let sections = summary.sections,
                  sections.contains(where: { $0.actionIDs.contains(actionID) }) else { return nil }
            return ReadOnlyTopic(id: row["id"] ?? "", title: row["title"] ?? "")
        }
    }

    private func sourceRecord(refsJSON: String?) throws -> ReadOnlySource? {
        guard let refsJSON,
              let references = try? JSONDecoder().decode([ClaimReference].self, from: Data(refsJSON.utf8)),
              let sourceID = references.first?.sourceID,
              let row = try connection.query("""
              SELECT s.id,s.name,s.kind,s.state,s.created_at,s.timezone,s.presentation_json,
                     \(Database.latestTranscriptVersionForSource) AS transcript_version_id
              FROM sources s WHERE s.id=?
              """, [sourceID]).first else {
            return nil
        }
        return ReadOnlySource(id: row["id"] ?? sourceID,
                              name: row["name"] ?? "",
                              title: Self.displayTitle(row),
                              kind: row["kind"] ?? "",
                              state: row["state"] ?? "",
                              createdAt: row["created_at"] ?? "")
    }

    static func displayTitle(_ row: [String: String]) -> String {
        let name = row["name"] ?? ""
        // The read-only door never loads a transcript, so the app's
        // content-derived fallback is replaced by the humanized name.
        let presentation = row["presentation_json"].flatMap {
            try? JSONDecoder().decode(RecordingPresentation.self, from: Data($0.utf8))
        }
        if let title = MaterialDisplayTitle.explicitTitle(
            presentation: presentation, transcriptVersionID: row["transcript_version_id"]) {
            return title
        }
        guard ["audio", "video"].contains(row["kind"]) else { return MaterialNaming.displayName(name) }
        return MaterialDisplayTitle.recordingFallbackTitle(
            name: name, kind: row["kind"] ?? "", createdAt: row["created_at"] ?? "",
            timeZone: row["timezone"] ?? TimeZone.current.identifier)
    }

    static func dueValue(json: String?, source: String, now: Date) -> ReadOnlyDue? {
        guard let json, let due = try? JSONDecoder().decode(ReminderDueDate.self, from: Data(json.utf8)) else {
            return nil
        }
        let overdue = due.actionTimeProjection(now: now, calendar: .current)?.isOverdue ?? false
        switch due {
        case .none:
            return ReadOnlyDue(kind: "none", localDate: nil, utc: nil, timeZone: nil, source: source, isOverdue: false)
        case let .dateOnly(localDate, timeZone):
            return ReadOnlyDue(kind: "dateOnly", localDate: localDate, utc: nil, timeZone: timeZone,
                               source: source, isOverdue: overdue)
        case let .instant(utc, timeZone):
            return ReadOnlyDue(kind: "instant", localDate: nil, utc: utc, timeZone: timeZone,
                               source: source, isOverdue: overdue)
        }
    }
}
