import Foundation
import CSQLite

public enum ReadOnlyLibraryError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case incompatibleSchema(found: Int)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return message
        case let .incompatibleSchema(found):
            return "资料库格式不兼容（user_version=\(found)，需要 \(ReadOnlyLibrary.schemaVersion)）"
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
    static let schemaVersion = 78
    private let connection: ReadOnlyConnection
    private let databaseFile: URL

    public init(root: URL) throws {
        let file = root.appendingPathComponent("voiceos.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ReadOnlyLibraryError.unavailable("资料库不存在：\(file.path)")
        }
        let connection = try ReadOnlyConnection(url: file)
        let version = Int(try connection.query("PRAGMA user_version").first?["user_version"] ?? "") ?? -1
        guard version == Self.schemaVersion else {
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
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let rows = try connection.query("""
        SELECT a.id,COALESCE(a.edited_title,a.title) AS title,a.kind,a.state,a.validity,a.nature,a.version,a.parent_id,a.created_at,
         (SELECT MAX(r.created_at) FROM action_revisions r WHERE r.action_id=a.id AND r.state='completed') AS completed_at,
         (SELECT COUNT(*) FROM action_feedback f WHERE f.action_id=a.id) AS feedback_count,
         (SELECT MAX(f.created_at) FROM action_feedback f WHERE f.action_id=a.id) AS last_feedback_at,
         c.refs_json AS claim_refs,
         (SELECT l.state FROM reminder_links l WHERE l.action_id=a.id) AS reminder_state
        FROM actions a JOIN claims c ON c.id=a.claim_id
        \(whereClause) ORDER BY a.created_at,a.id LIMIT ? OFFSET ?
        """, arguments)
        return try rows.map { row in
            let actionID = row["id"] ?? ""
            let source = try sourceRecord(refsJSON: row["claim_refs"])
            return ReadOnlyActionRow(id: actionID,
                                     title: row["title"] ?? "",
                                     kind: row["kind"] ?? "",
                                     state: row["state"] ?? "",
                                     validity: row["validity"] ?? "",
                                     nature: row["nature"] ?? "unknown",
                                     version: Int(row["version"] ?? "1") ?? 1,
                                     parentID: row["parent_id"],
                                     createdAt: row["created_at"] ?? "",
                                     completedAt: row["completed_at"],
                                     feedbackCount: Int(row["feedback_count"] ?? "0") ?? 0,
                                     lastFeedbackAt: row["last_feedback_at"],
                                     sourceTitle: source?.title,
                                     reminderState: row["reminder_state"],
                                     due: try resolvedDue(actionID: actionID))
        }
    }

    public func action(id: String, includeFeedback: Bool = false, includeFeedbackText: Bool = false,
                       includeNote: Bool = false, includeTopics: Bool = false) throws -> ReadOnlyActionDetail? {
        guard let row = try connection.query("""
        SELECT a.id,COALESCE(a.edited_title,a.title) AS title,a.kind,a.state,a.validity,a.nature,a.version,a.parent_id,a.created_at,COALESCE(a.edited_note,a.note) AS note,
         (SELECT MAX(r.created_at) FROM action_revisions r WHERE r.action_id=a.id AND r.state='completed') AS completed_at,
         (SELECT COUNT(*) FROM action_feedback f WHERE f.action_id=a.id) AS feedback_count,
         (SELECT MAX(f.created_at) FROM action_feedback f WHERE f.action_id=a.id) AS last_feedback_at,
         c.refs_json AS claim_refs,
         (SELECT l.state FROM reminder_links l WHERE l.action_id=a.id) AS reminder_state
        FROM actions a JOIN claims c ON c.id=a.claim_id WHERE a.id=? AND a.removed=0
        """, [id]).first else { return nil }
        let revisions = try connection.query("""
        SELECT version,state,actor,created_at FROM action_revisions WHERE action_id=? ORDER BY version DESC
        """, [id]).map {
            ReadOnlyRevision(version: Int($0["version"] ?? "0") ?? 0, state: $0["state"] ?? "",
                             actor: $0["actor"] ?? "", createdAt: $0["created_at"] ?? "")
        }
        let source = try sourceRecord(refsJSON: row["claim_refs"])
        return ReadOnlyActionDetail(id: id,
                                    title: row["title"] ?? "",
                                    kind: row["kind"] ?? "",
                                    state: row["state"] ?? "",
                                    validity: row["validity"] ?? "",
                                    nature: row["nature"] ?? "unknown",
                                    version: Int(row["version"] ?? "1") ?? 1,
                                    parentID: row["parent_id"],
                                    createdAt: row["created_at"] ?? "",
                                    completedAt: row["completed_at"],
                                    feedbackCount: Int(row["feedback_count"] ?? "0") ?? 0,
                                    lastFeedbackAt: row["last_feedback_at"],
                                    sourceTitle: source?.title,
                                    reminderState: row["reminder_state"],
                                    due: try resolvedDue(actionID: id),
                                    note: includeNote ? row["note"] : nil,
                                    schedule: try scheduleRecord(actionID: id),
                                    reminder: try reminderRecord(actionID: id),
                                    revisions: revisions,
                                    feedback: includeFeedback ? try feedbackRecords(actionID: id, includeText: includeFeedbackText) : nil,
                                    source: source,
                                    topics: includeTopics ? try topicRecords(actionID: id) : nil)
    }

    public func status() throws -> ReadOnlyStatus {
        let version = Int(try connection.query("PRAGMA user_version").first?["user_version"] ?? "") ?? -1
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

    // Mirrors ActionTimeSurface: the newest current local schedule wins even
    // when it has no date; only an action without one reads its newest
    // reminder observation, and `.none` never counts as a date.
    private func resolvedDue(actionID: String, now: Date = Date()) throws -> ReadOnlyDue? {
        if let schedule = try scheduleRow(actionID: actionID) {
            return Self.dueValue(json: schedule["due_json"], source: "localSchedule", now: now)
        }
        let observation = try connection.query("""
        SELECT t.due_json FROM reminder_observations o
        JOIN reminder_links l ON l.id=o.link_id
        LEFT JOIN reminder_time_observations t ON t.id=o.id
        WHERE l.action_id=? ORDER BY o.sequence DESC LIMIT 1
        """, [actionID]).first
        return Self.dueValue(json: observation?["due_json"], source: "reminderObservation", now: now)
    }

    private func scheduleRow(actionID: String) throws -> [String: String]? {
        try connection.query("""
        SELECT schedule_version,due_json,authority,actor,raw_expression,anchor_event_time,anchor_time_zone,validity
        FROM action_schedule_intents WHERE action_id=? AND validity='current'
        ORDER BY schedule_version DESC LIMIT 1
        """, [actionID]).first
    }

    private func scheduleRecord(actionID: String, now: Date = Date()) throws -> ReadOnlySchedule? {
        guard let row = try scheduleRow(actionID: actionID) else { return nil }
        return ReadOnlySchedule(version: Int(row["schedule_version"] ?? "0") ?? 0,
                                due: Self.dueValue(json: row["due_json"], source: "localSchedule", now: now),
                                authority: row["authority"] ?? "",
                                actor: row["actor"] ?? "",
                                rawExpression: row["raw_expression"] ?? "",
                                anchorEventTime: row["anchor_event_time"] ?? "",
                                anchorTimeZone: row["anchor_time_zone"] ?? "",
                                validity: row["validity"] ?? "")
    }

    private func reminderRecord(actionID: String, now: Date = Date()) throws -> ReadOnlyReminder? {
        guard let link = try connection.query("SELECT state FROM reminder_links WHERE action_id=?", [actionID]).first else {
            return nil
        }
        let observation = try connection.query("""
        SELECT o.completed,o.created_at,t.due_json FROM reminder_observations o
        LEFT JOIN reminder_time_observations t ON t.id=o.id
        WHERE o.link_id=(SELECT id FROM reminder_links WHERE action_id=?)
        ORDER BY o.sequence DESC LIMIT 1
        """, [actionID]).first
        return ReadOnlyReminder(state: link["state"] ?? "",
                                completed: observation?["completed"].map { $0 == "1" },
                                observedAt: observation?["created_at"],
                                due: Self.dueValue(json: observation?["due_json"], source: "reminderObservation", now: now))
    }

    // LEFT JOINs: a feedback row without a current transcript must still list,
    // and its text stays out of the default output.
    private func feedbackRecords(actionID: String, includeText: Bool) throws -> [ReadOnlyFeedback] {
        let rows = try connection.query("""
        SELECT f.id,f.kind,f.created_at,s.feedback_json,v.text
        FROM action_feedback f JOIN sources s ON s.id=f.source_id
        LEFT JOIN transcripts t ON t.source_id=s.id
        LEFT JOIN transcript_versions v ON v.id=t.current_version_id
        WHERE f.action_id=? ORDER BY f.sequence
        """, [actionID])
        return rows.map { row in
            let kind = row["kind"] ?? ""
            let relation = Self.feedbackRelation(row["feedback_json"])
            return ReadOnlyFeedback(id: row["id"] ?? "", kind: kind,
                                    label: ActionFeedbackLabel.text(relation: relation, kind: kind),
                                    createdAt: row["created_at"] ?? "",
                                    text: includeText ? row["text"] : nil)
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
                     (SELECT t.current_version_id FROM transcripts t WHERE t.source_id=s.id ORDER BY t.created_at DESC LIMIT 1) AS transcript_version_id
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
        switch due {
        case .none:
            return ReadOnlyDue(kind: "none", localDate: nil, utc: nil, timeZone: nil, source: source, isOverdue: false)
        case let .dateOnly(localDate, timeZone):
            return ReadOnlyDue(kind: "dateOnly", localDate: localDate, utc: nil, timeZone: timeZone,
                               source: source, isOverdue: isOverdue(due, now: now))
        case let .instant(utc, timeZone):
            return ReadOnlyDue(kind: "instant", localDate: nil, utc: utc, timeZone: timeZone,
                               source: source, isOverdue: isOverdue(due, now: now))
        }
    }

    static func dueDate(_ due: ReminderDueDate) -> Date? {
        switch due {
        case .none:
            return nil
        case let .dateOnly(localDate, zoneID):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
            let parts = localDate.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        case let .instant(utc, _):
            if let date = ActionTimeFormatting.isoFractional.date(from: utc) { return date }
            return ActionTimeFormatting.iso.date(from: utc)
        }
    }

    static func isOverdue(_ due: ReminderDueDate, now: Date) -> Bool {
        guard let date = dueDate(due) else { return false }
        switch due {
        case .none:
            return false
        case .instant:
            return date < now
        case .dateOnly:
            return Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: now)
        }
    }
}

final class ReadOnlyConnection {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, handle != nil else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw ReadOnlyLibraryError.unavailable("无法只读打开资料库：\(url.path)")
        }
        sqlite3_busy_timeout(handle, 5000)
        do {
            try query("PRAGMA query_only=ON")
            try query("BEGIN")
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            sqlite3_close(handle)
        }
    }

    func query(_ sql: String, _ arguments: [String?] = []) throws -> [[String: String]] {
        guard let handle else { throw VoiceOSError("资料库连接已关闭") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VoiceOSError("查询失败：\(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in arguments.enumerated() {
            let code: Int32
            if let value {
                code = value.utf8CString.withUnsafeBufferPointer { bytes in
                    sqlite3_bind_text(statement, Int32(index + 1), bytes.baseAddress, Int32(bytes.count - 1), transient)
                }
            } else {
                code = sqlite3_bind_null(statement, Int32(index + 1))
            }
            guard code == SQLITE_OK else { throw VoiceOSError("查询参数绑定失败") }
        }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw VoiceOSError("查询失败：\(String(cString: sqlite3_errmsg(handle)))")
            }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, index) != SQLITE_NULL {
                let key = String(cString: sqlite3_column_name(statement, index))
                if let value = sqlite3_column_text(statement, index) {
                    row[key] = String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
                }
            }
            rows.append(row)
        }
    }
}
