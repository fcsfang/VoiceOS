import Foundation

public struct ReminderFields: Codable, Sendable, Equatable {
    public var due: ReminderDueDate
    public var alerts: [String]
    public var priority: Int
    public init(due: ReminderDueDate = .none, alerts: [String] = [], priority: Int = 0) {
        self.due = due; self.alerts = alerts; self.priority = priority
    }
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    public static func date(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp)
    }
    public static func relativeDates(expressedAt: String?, timeZone: String) -> [String: String] {
        let plain = ISO8601DateFormatter()
        guard let text = expressedAt, let instant = date(text) ?? plain.date(from: text),
              let zone = TimeZone(identifier: timeZone) else { return [:] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = calendar.startOfDay(for: instant)
        // The user's spoken day ends at 04:00; retain the actual recording timestamp separately.
        let anchor = calendar.component(.hour, from: instant) < 4 ? calendar.date(byAdding: .day, value: -1, to: day)! : day
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"
        return Dictionary(uniqueKeysWithValues: [("前天", -2), ("昨天", -1), ("今天", 0), ("今日", 0), ("今晚", 0), ("明天", 1), ("明早", 1), ("明晚", 1), ("后天", 2), ("大后天", 3)].map {
            ($0.0, formatter.string(from: calendar.date(byAdding: .day, value: $0.1, to: anchor)!))
        })
    }
    public func validate() throws {
        try due.validate()
        guard (0...9).contains(priority), alerts.allSatisfy({ Self.date($0).map { Self.timestamp($0) } == $0 }) else { throw VoiceOSError("提醒时间或优先级无效") }
    }
    public var summary: String {
        var parts: [String] = []
        if due != .none { parts.append(due.summary) }
        if !alerts.isEmpty {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "MM-dd HH:mm"
            parts.append("提醒 " + alerts.compactMap(Self.date).map(formatter.string).joined(separator: "、"))
        }
        if priority > 0 { parts.append(priority <= 4 ? "高优先级" : priority == 5 ? "中优先级" : "低优先级") }
        return parts.joined(separator: " · ")
    }
}
public struct ReminderFieldReceipt: Codable, Sendable {
    public var desired: ReminderFields?
    public var observed: ReminderFields?
    public var reviewNote: String
    public var responseIDs: [String]
    public var actor: String
    public var sourceVersions: [String: String]
    public var proposal: ReminderFieldProposal? = nil
    public init(desired: ReminderFields? = nil, observed: ReminderFields? = nil, reviewNote: String = "", responseIDs: [String] = [], actor: String = "user", sourceVersions: [String: String] = [:]) {
        self.desired = desired; self.observed = observed; self.reviewNote = reviewNote
        self.responseIDs = responseIDs; self.actor = actor; self.sourceVersions = sourceVersions
    }
}
public protocol RemindersFieldsPort: RemindersPort {
    func create(calendarID: String, title: String, marker: String, context: String, fields: ReminderFields) async throws
    func updateFields(calendarID: String, expected: ReminderSnapshot, desired: ReminderFields,
                      authorize: @Sendable () async throws -> Void) async throws
}

public struct ReminderFieldInput: Codable, Sendable {
    public struct Task: Codable, Sendable {
        public let id: String
        public let version: Int
        public let title: String
        public let quote: String
        public let sourceIDs: [String]
        public let isSuggestedStep: Bool
    }
    public struct Source: Codable, Sendable {
        public let id: String
        public let text: String
        public let version: String
        public let policyVersion: Int
        public let expressedAt: String?
        public let timeZone: String
        public let relativeDates: [String: String]
        public var transcriptionReview: TranscriptionReview? = nil
        public init(id: String, text: String, version: String, policyVersion: Int, expressedAt: String?, timeZone: String) {
            self.id = id; self.text = text; self.version = version; self.policyVersion = policyVersion
            self.expressedAt = expressedAt; self.timeZone = timeZone
            relativeDates = ReminderFields.relativeDates(expressedAt: expressedAt, timeZone: timeZone)
        }
    }
    public let tasks: [Task]
    public let sources: [Source]
    public let processingAt: String
}
public struct ReminderFieldProposal: Codable, Sendable {
    public let taskID: String
    public let dueDate: String
    public let dueTime: String
    public let dueSourceID: String
    public let dueQuote: String
    public let alertDate: String
    public let alertTime: String
    public let alertSourceID: String
    public let alertQuote: String
    public let priority: Int
    public let prioritySourceID: String
    public let priorityQuote: String
    public let reviewNote: String
}
public protocol ReminderFieldModelPort: Sendable {
    func extract(_ input: ReminderFieldInput) async throws -> ([ReminderFieldProposal], [String])
}

extension VoiceOSStore {
    public func prepareReminderFields(actionIDs: Set<String>? = nil) throws -> ReminderFieldInput {
        let linked = Set(try reminderLinks().map(\.actionID))
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id, $0) })
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        var entries: [ReminderFieldInput.Task] = [], sourceIDs = Set<String>()
        for action in try actions() where action.kind == "task" && (actionIDs.map { $0.contains(action.id) } ?? !linked.contains(action.id)) && action.intent?.reminderFields?.desired == nil {
            guard let claim = claims[action.claimID], try reminderSourceAllowed(action), try reminderCognitionIsLatest(action) else { continue }
            let refs = Array(Set(claim.references.map(\.sourceID))).sorted()
            entries.append(.init(id: action.id, version: action.version, title: action.title, quote: action.note,
                                 sourceIDs: refs, isSuggestedStep: action.intent?.goalID != nil))
            sourceIDs.formUnion(refs)
        }
        let sources = try sourceIDs.sorted().compactMap { id -> ReminderFieldInput.Source? in
            guard let source = catalog[id], let text = source.transcript, let version = source.transcriptVersionID,
                  let row = try db.query("SELECT timezone FROM sources WHERE id=?", [id]).first else { return nil }
            let zone = row["timezone"] ?? ""
            var anchor: String? = nil
            if source.kind == "user_text" || source.name.hasPrefix("我的口述") { anchor = source.createdAt }
            else {
                // Imported time is not recording time. Only the known filename formats provide an anchor.
                for (pattern, format) in [("^\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}", "yyyy-MM-dd_HH-mm-ss"), ("^\\d{8} \\d{6}", "yyyyMMdd HHmmss")] {
                    if let range = source.name.range(of: pattern, options: .regularExpression), let timeZone = TimeZone(identifier: zone) {
                        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format
                        formatter.timeZone = timeZone; formatter.isLenient = false
                        if let date = formatter.date(from: String(source.name[range])) { anchor = ReminderFields.timestamp(date) }
                        break
                    }
                }
            }
            var input = ReminderFieldInput.Source(id: id, text: text, version: version, policyVersion: source.policyVersion, expressedAt: anchor, timeZone: zone)
            input.transcriptionReview = source.transcriptionReview
            return input
        }
        return .init(tasks: entries, sources: sources, processingAt: ReminderFields.timestamp(Date()))
    }
    public func extractReminderFields(using model: any ReminderFieldModelPort, actionIDs: Set<String>? = nil) async throws {
        let input = try prepareReminderFields(actionIDs: actionIDs)
        guard !input.tasks.isEmpty else { return }
        let (proposals, ids) = try await model.extract(input)
        guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }), proposals.count == input.tasks.count,
              Set(proposals.map(\.taskID)) == Set(input.tasks.map(\.id)) else { throw VoiceOSError("提醒字段核对未覆盖全部任务") }
        let encoder = JSONEncoder()
        var saved: [(String, ActionIntentMetadata)] = []
        for proposal in proposals {
            let entry = input.tasks.first { $0.id == proposal.taskID }!
            guard let action = try actions().first(where: { $0.id == entry.id }), action.version == entry.version,
                  action.title == entry.title, try reminderSourceAllowed(action), try reminderCognitionIsLatest(action) else { throw VoiceOSError("提醒字段处理期间任务已变化") }
            // An explicit user edit while inference was in flight takes precedence.
            if action.intent?.reminderFields?.desired != nil { continue }
            for id in entry.sourceIDs {
                guard let expected = input.sources.first(where: { $0.id == id }), let actual = try sources().first(where: { $0.id == id }),
                      actual.transcriptVersionID == expected.version, actual.policyVersion == expected.policyVersion, !actual.localOnly else { throw VoiceOSError("提醒字段处理期间原话或授权已变化") }
            }
            let fields: ReminderFields
            var reviewNote = proposal.reviewNote
            do { fields = try Self.resolveReminderFields(proposal, task: entry, input: input) }
            catch { fields = .init(); reviewNote = [reviewNote, error.localizedDescription].filter { !$0.isEmpty }.joined(separator: "；") }
            var metadata = action.intent ?? .init(intentType: "task", followupState: "pending", uncertain: false)
            metadata.reminderFields = .init(desired: fields, reviewNote: reviewNote, responseIDs: ids, actor: "spoken",
                                           sourceVersions: Dictionary(uniqueKeysWithValues: input.sources.filter { entry.sourceIDs.contains($0.id) }.map { ($0.id, $0.version) }))
            metadata.reminderFields?.proposal = proposal
            saved.append((action.id, metadata))
        }
        try db.transaction {
            for (id, metadata) in saved { try db.execute("UPDATE actions SET intent_json=? WHERE id=?", [String(decoding: try encoder.encode(metadata), as: UTF8.self), id]) }
        }
    }
    public static func resolveReminderFields(_ proposal: ReminderFieldProposal, task: ReminderFieldInput.Task, input: ReminderFieldInput) throws -> ReminderFields {
        func evidence(_ quote: String, _ sourceID: String) throws -> ReminderFieldInput.Source {
            guard !quote.isEmpty, task.sourceIDs.contains(sourceID), let source = input.sources.first(where: { $0.id == sourceID }),
                  source.text.contains(quote), TimeZone(identifier: source.timeZone) != nil else { throw VoiceOSError("提醒字段缺少该任务的连续原话") }
            return source
        }
        func time(_ date: String, _ time: String, zone: String) throws -> ReminderDueDate {
            // EventKit stores date-only reminders as calendar dates without a timezone.
            if time.isEmpty { let value = ReminderDueDate.dateOnly(localDate: date, timeZone: nil); try value.validate(); return value }
            guard time.range(of: "^\\d{2}:\\d{2}$", options: .regularExpression) != nil else { throw VoiceOSError("提醒时刻无效") }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: zone)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
            let text = date + " " + time
            guard let instant = formatter.date(from: text), formatter.string(from: instant) == text else { throw VoiceOSError("提醒日期无效") }
            let value = ReminderDueDate.instant(utc: ReminderFields.timestamp(instant), timeZone: zone)
            _ = try value.writableComponents(); return value
        }
        func checkRelativeDate(_ date: String, quote: String, source: ReminderFieldInput.Source) throws {
            // Explicit calendar dates take precedence. Otherwise simple relative days are checked locally as well as by the model.
            if quote.range(of: "\\d{1,4}\\s*(年|月|[./-])\\s*\\d{1,2}", options: .regularExpression) != nil { return }
            let regex = try NSRegularExpression(pattern: "大后天|后天|明天|明早|明晚|今晚|今天|今日|昨天|前天")
            let tokens = regex.matches(in: quote, range: NSRange(quote.startIndex..., in: quote)).compactMap { Range($0.range, in: quote).map { String(quote[$0]) } }
            guard tokens.isEmpty || tokens.contains(where: { source.relativeDates[$0] == date }) else {
                throw VoiceOSError("相对日期与凌晨4点换日规则不一致，请核对原话")
            }
        }
        var result = ReminderFields()
        if !proposal.dueDate.isEmpty {
            let source = try evidence(proposal.dueQuote, proposal.dueSourceID)
            try checkRelativeDate(proposal.dueDate, quote: proposal.dueQuote, source: source)
            result.due = try time(proposal.dueDate, proposal.dueTime, zone: source.timeZone)
        } else if !proposal.dueTime.isEmpty { throw VoiceOSError("时间缺少日期") }
        if !proposal.alertDate.isEmpty {
            let source = try evidence(proposal.alertQuote, proposal.alertSourceID)
            try checkRelativeDate(proposal.alertDate, quote: proposal.alertQuote, source: source)
            guard !proposal.alertTime.isEmpty, case let .instant(utc, _) = try time(proposal.alertDate, proposal.alertTime, zone: source.timeZone),
                  let date = ReminderFields.date(utc), let now = ReminderFields.date(input.processingAt), date > now else { throw VoiceOSError("通知时刻已过去或不明确，请核对后设置") }
            result.alerts = [utc]
        } else if !proposal.alertTime.isEmpty { throw VoiceOSError("提醒时间缺少日期") }
        guard [0, 1, 5, 9].contains(proposal.priority) else { throw VoiceOSError("优先级无效") }
        if proposal.priority != 0 { _ = try evidence(proposal.priorityQuote, proposal.prioritySourceID) }
        result.priority = proposal.priority
        if task.isSuggestedStep, result != ReminderFields() { throw VoiceOSError("目标的时间不能直接当作新建议步骤的承诺") }
        try result.validate(); return result
    }
    public func saveReminderFields(actionID: String, expectedVersion: Int, fields: ReminderFields) throws {
        try fields.validate()
        guard let action = try actions().first(where: { $0.id == actionID }), action.version == expectedVersion, action.kind == "task" else { throw VoiceOSError("任务已变化") }
        var metadata = action.intent ?? .init(intentType: "task", followupState: "pending", uncertain: false)
        metadata.reminderFields = .init(desired: fields, observed: metadata.reminderFields?.observed)
        try db.execute("UPDATE actions SET intent_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self), actionID])
    }
    func observeReminderFields(actionID: String, fields: ReminderFields) throws {
        guard let action = try actions(includeHistory: true).first(where: { $0.id == actionID }) else { return }
        var metadata = action.intent ?? .init(intentType: "task", followupState: "pending", uncertain: false)
        var receipt = metadata.reminderFields ?? .init(); receipt.observed = fields; metadata.reminderFields = receipt
        try db.execute("UPDATE actions SET intent_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self), actionID])
    }
    public func updateReminderFields(actionID: String, expectedVersion: Int, expected: ReminderSnapshot, desired: ReminderFields,
                                     expectedAccessVersion: Int, using port: any RemindersFieldsPort) async throws {
        guard let access = try reminderAccess(), let link = try reminderLinks().first(where: { $0.actionID == actionID }),
              link.calendarID == access.calendarID, link.state == "linked", link.externalID == expected.id,
              expected.marker == "voiceos-action:" + link.id, expected.fields != nil,
              !activeReminderLinks.contains(link.id) else { throw VoiceOSError("请先核对提醒事项设置") }
        try checkReminderAccess(calendarID: access.calendarID, expectedVersion: expectedAccessVersion)
        try saveReminderFields(actionID: actionID, expectedVersion: expectedVersion, fields: desired)
        activeReminderLinks.insert(link.id); defer { activeReminderLinks.remove(link.id) }
        do {
            try await port.updateFields(calendarID: access.calendarID, expected: expected, desired: desired) { [self] in
                try await self.checkReminderFieldWrite(actionID: actionID, expectedVersion: expectedVersion, calendarID: access.calendarID, accessVersion: expectedAccessVersion)
            }
            let matches = try await port.find(calendarID: access.calendarID, externalID: expected.id, marker: expected.marker)
            try checkReminderAccess(calendarID: access.calendarID, expectedVersion: expectedAccessVersion)
            try applyReminder(matches, linkID: link.id)
            guard matches.count == 1, matches[0].fields == desired else { throw VoiceOSError("设置未能核对；请刷新后查看，不自动重写") }
        } catch {
            // Keep requested and last observed fields separately; a later read never replays this edit.
            throw VoiceOSError("提醒设置未全部确认：" + error.localizedDescription)
        }
    }
    private func checkReminderFieldWrite(actionID: String, expectedVersion: Int, calendarID: String, accessVersion: Int) throws {
        try checkReminderAccess(calendarID: calendarID, expectedVersion: accessVersion)
        guard let action = try actions().first(where: { $0.id == actionID }), action.version == expectedVersion,
              try reminderSourceAllowed(action) else { throw VoiceOSError("设置期间任务或授权已变化") }
    }
}
