import Foundation

public enum RecurrencePeriod: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case daily, weekly, biweekly, monthly
    public var display: String {
        switch self {
        case .daily: return "每天"
        case .weekly: return "每周"
        case .biweekly: return "每两周"
        case .monthly: return "每月"
        }
    }
    func advanced(_ date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .daily: return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date)
        case .biweekly: return calendar.date(byAdding: .day, value: 14, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }
    public static func nextDue(after date: Date, period: RecurrencePeriod, calendar: Calendar) -> Date? {
        period.advanced(date, calendar: calendar)
    }
    public static func nextLocalDate(after localDate: String, period: RecurrencePeriod, calendar: Calendar) -> String {
        let parts = localDate.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 3, let start = calendar.date(from: DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              let next = period.advanced(start, calendar: calendar) else { return localDate }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: next)
    }
}

extension VoiceOSStore {
    public func recurrence(actionID: String) throws -> RecurrencePeriod? {
        try db.query("SELECT period FROM action_recurrence WHERE action_id=?", [actionID]).first?["period"].flatMap(RecurrencePeriod.init(rawValue:))
    }
    public func setRecurrence(actionID: String, period: RecurrencePeriod) throws {
        guard let row = try db.query("SELECT state FROM actions WHERE id=?", [actionID]).first else { throw VoiceOSError("行动不存在") }
        guard row["state"] == "open" else { throw VoiceOSError("只有未完成的行动可以设置重复") }
        if try db.query("SELECT action_id FROM action_recurrence WHERE action_id=?", [actionID]).first != nil {
            try db.execute("UPDATE action_recurrence SET period=? WHERE action_id=?", [period.rawValue, actionID])
        } else {
            try db.execute("INSERT INTO action_recurrence(action_id,series_id,period,created_at) VALUES(?,?,?,?)", [actionID, UUID().uuidString, period.rawValue, ReminderFields.timestamp(Date())])
        }
    }
    public func clearRecurrence(actionID: String) throws {
        try db.execute("DELETE FROM action_recurrence WHERE action_id=?", [actionID])
    }
    public func actionRecurrences() throws -> [String: RecurrencePeriod] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT action_id,period FROM action_recurrence").compactMap { row in
            guard let actionID = row["action_id"], let period = row["period"].flatMap(RecurrencePeriod.init(rawValue:)) else { return nil }
            return (actionID, period)
        })
    }
    @discardableResult
    public func completeActionWithRecurrence(id: String, now: Date = Date()) throws -> String? {
        guard let row = try db.query("SELECT * FROM actions WHERE id=?", [id]).first else { throw VoiceOSError("行动不存在") }
        let version = Int(row["version"]!)!
        let commandID = "recurrence-complete:" + id
        guard let series = try db.query("SELECT * FROM action_recurrence WHERE action_id=?", [id]).first else {
            if row["state"] == "completed" { return nil }
            try setActionState(actionID: id, expectedVersion: version, state: .completed, commandID: commandID)
            return nil
        }
        let alreadyCompleted = row["state"] == "completed"
        guard alreadyCompleted || row["validity"] == "current", alreadyCompleted || row["state"] == "open",
              let period = series["period"].flatMap(RecurrencePeriod.init(rawValue:)), let seriesID = series["series_id"] else {
            throw VoiceOSError("行动版本或依据已变化，请重新核对")
        }
        let metadata = try row["intent_json"].map { try JSONDecoder().decode(ActionIntentMetadata.self, from: Data($0.utf8)) }
        let stamp = ReminderFields.timestamp(now)
        let revisionHash = try Self.actionHash([id, String(version), LocalActionState.completed.rawValue, ""])
        var successorID: String?
        try db.transaction {
            if !alreadyCompleted {
                try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'completed','','user',?,?,?)", [UUID().uuidString, id, String(version + 1), String(version), commandID, revisionHash, stamp])
                try db.execute("UPDATE actions SET state='completed',version=? WHERE id=?", [String(version + 1), id])
            }
            try db.execute("DELETE FROM action_recurrence WHERE action_id=?", [id])
            if let metadata, let fields = metadata.reminderFields?.desired, fields.due != .none {
                guard let newDue = Self.nextRecurrenceDue(due: fields.due, period: period, now: now) else { throw VoiceOSError("下一次到期无法计算") }
                var nextFields = fields
                nextFields.due = newDue
                switch (fields.due, newDue) {
                case let (.instant(oldUTC, _), .instant(newUTC, _)):
                    guard let oldDate = ReminderFields.date(oldUTC), let newDate = ReminderFields.date(newUTC) else { throw VoiceOSError("提醒时刻无法核对") }
                    let delta = newDate.timeIntervalSince(oldDate)
                    nextFields.alerts = fields.alerts.compactMap(ReminderFields.date).map { ReminderFields.timestamp($0.addingTimeInterval(delta)) }
                default:
                    var calendar = Calendar(identifier: .gregorian)
                    if case let .dateOnly(_, zone) = newDue { calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current }
                    nextFields.alerts = []
                    nextFields = nextFields.withDefaultAlert(now: now, calendar: calendar)
                }
                var intent = metadata
                intent.reminderFields?.desired = nextFields
                let newID = UUID().uuidString
                let claimID = row["claim_id"]!, reviewVersion = row["claim_review_version"]!, title = row["title"]!, kind = row["kind"]!, actor = row["intent_actor"]!, note = row["note"]!
                let fingerprint = try Self.actionHash([claimID, reviewVersion, title, kind, actor, note])
                let nextCommand = "recurrence:" + id + ":" + Self.recurrenceToken(newDue)
                try db.execute("INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,command_id,input_fingerprint,created_at,intent_json,auto_send) VALUES(?,?,?,?,?,?,?,'open','current',?,?,?,?,?)", [newID, claimID, reviewVersion, title, kind, actor, note, nextCommand, fingerprint, stamp, String(decoding: try JSONEncoder().encode(intent), as: UTF8.self), row["auto_send"]!])
                try db.execute("INSERT INTO action_recurrence(action_id,series_id,period,created_at) VALUES(?,?,?,?)", [newID, seriesID, period.rawValue, stamp])
                successorID = newID
            }
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return successorID
    }
    @discardableResult
    public func reopenActionWithRecurrence(id: String, successorID: String? = nil) throws -> String? {
        guard let row = try db.query("SELECT * FROM actions WHERE id=?", [id]).first else { throw VoiceOSError("行动不存在") }
        guard row["validity"] == "current" else { throw VoiceOSError("行动版本或依据已变化，请重新核对") }
        guard row["state"] != "open" else { return nil }
        let version = Int(row["version"]!)!
        let fallback = try db.query("SELECT id FROM actions WHERE command_id LIKE ? ORDER BY created_at DESC LIMIT 1", ["recurrence:" + id + ":%"]).first?["id"]
        let resolved = successorID ?? fallback
        var keptSuccessorID: String?
        try db.transaction {
            if let resolved {
                let command = try db.query("SELECT command_id FROM actions WHERE id=?", [resolved]).first?["command_id"]
                if command?.hasPrefix("recurrence:" + id + ":") == true {
                    if try successorIsUntouched(resolved), let recurrence = try db.query("SELECT * FROM action_recurrence WHERE action_id=?", [resolved]).first {
                        try db.execute("DELETE FROM action_recurrence WHERE action_id=?", [resolved])
                        try db.execute("DELETE FROM actions WHERE id=?", [resolved])
                        try db.execute("INSERT OR REPLACE INTO action_recurrence(action_id,series_id,period,created_at) VALUES(?,?,?,?)", [id, recurrence["series_id"]!, recurrence["period"]!, recurrence["created_at"]!])
                    } else {
                        keptSuccessorID = resolved
                    }
                }
            }
            let commandID = "recurrence-reopen:" + id + ":" + String(version)
            let hash = try Self.actionHash([id, String(version), LocalActionState.open.rawValue, ""])
            try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,'open','','user',?,?,?)", [UUID().uuidString, id, String(version + 1), String(version), commandID, hash, ISO8601DateFormatter().string(from: Date())])
            try db.execute("UPDATE actions SET state='open',version=? WHERE id=?", [String(version + 1), id])
            try checkpoint(.actionStateUncommitted)
        }
        try checkpoint(.actionStateCommitted)
        return keptSuccessorID
    }
    private func successorIsUntouched(_ id: String) throws -> Bool {
        guard let row = try db.query("SELECT * FROM actions WHERE id=?", [id]).first, row["state"] == "open", row["version"] == "1", row["note"] == "" else { return false }
        for table in ["action_revisions","action_feedback","reminder_links","action_schedule_intents","reminder_compensation_plans","assistant_executions","assistant_assessments","action_clarifications","action_focus","action_subtasks","action_estimates"] {
            if !(try db.query("SELECT 1 AS present FROM \(table) WHERE action_id=? LIMIT 1", [id])).isEmpty { return false }
        }
        return true
    }
    static func nextRecurrenceDue(due: ReminderDueDate, period: RecurrencePeriod, now: Date) -> ReminderDueDate? {
        switch due {
        case .none:
            return nil
        case let .dateOnly(localDate, zone):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
            var date = localDate
            for _ in 0..<10000 {
                date = RecurrencePeriod.nextLocalDate(after: date, period: period, calendar: calendar)
                let parts = date.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3, let day = calendar.date(from: DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: parts[0], month: parts[1], day: parts[2])) else { return nil }
                if day > now { return .dateOnly(localDate: date, timeZone: zone) }
            }
            return nil
        case let .instant(utc, zone):
            guard let timeZone = TimeZone(identifier: zone), let anchor = ReminderFields.date(utc) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            var date = anchor
            for _ in 0..<10000 {
                guard let next = RecurrencePeriod.nextDue(after: date, period: period, calendar: calendar) else { return nil }
                date = next
                if date > now { return .instant(utc: ReminderFields.timestamp(date), timeZone: zone) }
            }
            return nil
        }
    }
    static func recurrenceToken(_ due: ReminderDueDate) -> String {
        switch due {
        case .none: return "none"
        case let .dateOnly(localDate, _): return localDate
        case let .instant(utc, _): return utc
        }
    }
}

public extension ReminderDueDate {
    var shortLabel: String {
        switch self {
        case .none: return ""
        case let .dateOnly(localDate, _): return String(localDate.dropFirst(5))
        case let .instant(utc, zone):
            guard let date = ReminderFields.date(utc) else { return "" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: zone) ?? .current
            formatter.dateFormat = "MM-dd"
            return formatter.string(from: date)
        }
    }
}
