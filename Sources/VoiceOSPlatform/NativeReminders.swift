import Foundation
import EventKit
import VoiceOSCore

public struct ReminderCalendar: Identifiable, Sendable {
    public let id: String
    public let title: String
}
/// All EventKit objects stay on MainActor and are reacquired for each operation.
@MainActor
public final class NativeReminders: RemindersSchedulingPort, RemindersFieldsPort, RecordingExpressionRemindersPort {
    private let store = EKEventStore()
    private var reading = false
    private let readTimeout: Duration = .seconds(8)
    public init() {}
    public func reconcileExpression(_ edit:RecordingExpressionReminderEdit,authorize:@Sendable () async throws -> Void) async throws -> ReminderSnapshot {
        let matches=try await find(calendarID:edit.calendarID,externalID:edit.externalID,marker:edit.marker)
        guard matches.count == 1,let current=matches.first,current.id == edit.externalID,current.marker == edit.marker else { throw VoiceOSError("补录关联提醒身份不唯一，未修改") }
        // Never undo a completion made in Reminders. Retain notes and the actual item as history.
        if current.completed { return current }
        let alreadyApplied=current.title == edit.desiredTitle && (!edit.withdraw || (current.fields?.alerts.isEmpty == true && current.fields?.due == ReminderDueDate.none))
        if !alreadyApplied {
            guard current.title == edit.expectedTitle,
                  !edit.withdraw || (edit.expectedFields != nil && current.fields == edit.expectedFields) else { throw VoiceOSError("提醒事项已有外部修改，补录没有覆盖它") }
            try await authorize();try Task.checkCancellation()
            let calendar=try calendar(edit.calendarID)
            guard calendar.title == "VoiceOS",let item=store.calendarItem(withIdentifier:edit.externalID) as? EKReminder,
                  item.calendar.calendarIdentifier == edit.calendarID,marker(item) == edit.marker,snapshot(item) == current else { throw VoiceOSError("保存前提醒已变化，补录没有覆盖它") }
            item.title=edit.desiredTitle
            if edit.withdraw { item.dueDateComponents=nil;item.startDateComponents=nil;item.alarms=[] }
            try store.save(item,commit:true)
        }
        let verified=try await find(calendarID:edit.calendarID,externalID:edit.externalID,marker:edit.marker)
        guard verified.count == 1,let result=verified.first else { throw VoiceOSError("补录提醒未完成回读") }
        return result
    }
    public var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    public func observeChanges(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in Task { @MainActor in handler() } }
    }

    public func authorize() async throws -> [ReminderCalendar] {
        guard try await store.requestFullAccessToReminders() else { throw VoiceOSError("提醒事项权限未授予；没有读取或写入任务") }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications).map { ReminderCalendar(id: $0.calendarIdentifier, title: $0.title) }
    }
    public func voiceOSCalendar() async throws -> ReminderCalendar {
        let calendars = try await authorize().filter { $0.title == "VoiceOS" }
        if calendars.count == 1 { return calendars[0] }
        guard calendars.isEmpty else { throw VoiceOSError("存在多个 VoiceOS 清单，请从列表选择") }
        guard let source = store.defaultCalendarForNewReminders()?.source else { throw VoiceOSError("没有可创建提醒事项清单的账户") }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = "VoiceOS"; calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return ReminderCalendar(id: calendar.calendarIdentifier, title: calendar.title)
    }
    private func calendar(_ id: String) throws -> EKCalendar {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw VoiceOSError("提醒事项权限不可用") }
        store.refreshSourcesIfNecessary()
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications else { throw VoiceOSError("明确选定的提醒事项清单不可用；不会另选清单") }
        return calendar
    }
    private func marker(_ item: EKReminder) -> String {
        let noteLink = item.notes?.components(separatedBy: "\n").last(where: { $0.hasPrefix("voiceos://task/") }).flatMap(URL.init(string:))
        if let url = item.url ?? noteLink, url.scheme == "voiceos", url.host == "task", UUID(uuidString: url.lastPathComponent) != nil {
            return "voiceos-action:" + url.lastPathComponent
        }
        return item.notes ?? ""
    }
    private func snapshot(_ item: EKReminder) -> ReminderSnapshot {
        let due = ReminderDueDate.reading(item.dueDateComponents)
        let alarms = item.alarms ?? []
        let dates = alarms.compactMap(\.absoluteDate).map(ReminderFields.timestamp).sorted()
        let fields = due.flatMap { due in dates.count == alarms.count ? ReminderFields(due: due, alerts: dates, priority: Int(item.priority)) : nil }
        return .init(id: item.calendarItemIdentifier, title: item.title ?? "", completed: item.isCompleted, marker: marker(item), dueDate: due, fields: fields)
    }
    public func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        try Task.checkCancellation()
        guard !reading else { throw VoiceOSError("提醒事项读取正在进行") }
        reading = true; defer { reading = false }
        // No pending writes; fetch a fresh store view without retaining stale EKObjects.
        store.reset()
        let target = try calendar(calendarID)
        let predicate = store.predicateForReminders(in: [target])
        let gate = CallbackWait<[ReminderSnapshot]>()
        let snapshots = try await gate.wait(timeout: readTimeout) { complete in
            let token = store.fetchReminders(matching: predicate) { items in
                Task { @MainActor in
                    // Do not touch stale EKObjects from a late or canceled callback.
                    guard gate.isWaiting else { return }
                    guard let items else { complete(.failure(VoiceOSError("提醒事项读取未返回结果"))); return }
                    guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { complete(.failure(VoiceOSError("回读期间权限已变化"))); return }
                    let results = items.filter { $0.calendar.calendarIdentifier == calendarID && (self.marker($0) == marker || (externalID != nil && $0.calendarItemIdentifier == externalID)) }.map {
                        self.snapshot($0)
                    }
                    complete(.success(results))
                }
            }
            return { [store] in store.cancelFetchRequest(token) }
        }
        try Task.checkCancellation()
        return snapshots
    }
    public func create(calendarID: String, title: String, marker: String, context: String) async throws {
        try await create(calendarID: calendarID, title: title, marker: marker, context: context, fields: ReminderFields())
    }
    public func create(calendarID: String, title: String, marker: String, context: String, fields: ReminderFields) async throws {
        try fields.validate()
        try Task.checkCancellation()
        guard !reading else { throw VoiceOSError("提醒事项读取正在进行") }
        let target = try calendar(calendarID)
        let item = EKReminder(eventStore: store)
        let link = "voiceos://task/" + marker.replacingOccurrences(of: "voiceos-action:", with: "")
        item.calendar = target; item.title = title
        item.url = URL(string: link)
        item.dueDateComponents = try fields.due.writableComponents()
        item.priority = fields.priority
        item.alarms = fields.alerts.compactMap(ReminderFields.date).map { EKAlarm(absoluteDate: $0) }
        do { try store.save(item, commit: true) }
        catch { throw VoiceOSError("提醒事项写入结果未知") }
    }

    public func updateDue(calendarID: String, expected: ReminderSnapshot, desired: ReminderDueDate,
                          authorize: @escaping @Sendable () async throws -> Void) async throws {
        let components = try desired.writableComponents()
        guard !expected.completed, expected.dueDate != nil else { throw VoiceOSError("不能改期已完成或期限未知的任务") }
        let matches = try await find(calendarID: calendarID, externalID: expected.id, marker: expected.marker)
        guard matches.count == 1, matches[0] == expected else { throw VoiceOSError("保存前提醒事项身份或字段已变化") }
        // This await may allow local cancellation, revocation, correction or a
        // newer cognition batch. Revalidate it before touching EventKit.
        try await authorize()
        try Task.checkCancellation()
        guard !reading else { throw VoiceOSError("提醒事项读取正在进行") }
        store.reset()
        _ = try calendar(calendarID)
        guard let item = store.calendarItem(withIdentifier: expected.id) as? EKReminder,
              item.calendar.calendarIdentifier == calendarID,
              snapshot(item) == expected else {
            throw VoiceOSError("最终保存前身份或字段已变化；没有修改")
        }
        // EventKit has no remote atomic compare-and-swap. The synchronous final
        // check narrows the race but cannot eliminate concurrent iCloud edits.
        // Preserve title, notes, completion, priority, alarms and other fields.
        item.dueDateComponents = components
        do { try store.save(item, commit: true) }
        catch { throw VoiceOSError("提醒事项改期结果未知；只能回读，不重发") }
    }

    public func updateFields(calendarID: String, expected: ReminderSnapshot, desired: ReminderFields,
                             authorize: @Sendable () async throws -> Void) async throws {
        try desired.validate()
        guard !expected.completed, expected.fields != nil else { throw VoiceOSError("提醒设置尚未完整读取，不能修改") }
        let matches = try await find(calendarID: calendarID, externalID: expected.id, marker: expected.marker)
        guard matches.count == 1, matches[0] == expected else { throw VoiceOSError("提醒事项已在别处修改，请刷新设置") }
        try await authorize(); try Task.checkCancellation()
        guard !reading else { throw VoiceOSError("提醒事项读取正在进行") }
        store.reset(); _ = try calendar(calendarID)
        guard let item = store.calendarItem(withIdentifier: expected.id) as? EKReminder,
              item.calendar.calendarIdentifier == calendarID, snapshot(item) == expected else { throw VoiceOSError("保存前提醒设置已变化，未覆盖修改") }
        item.dueDateComponents = try desired.due.writableComponents()
        item.priority = desired.priority
        item.alarms = desired.alerts.compactMap(ReminderFields.date).map { EKAlarm(absoluteDate: $0) }
        // One native save. Titles, user notes, completion and unsupported fields stay on the item.
        try store.save(item, commit: true)
    }

    public func updateContext(calendarID: String, externalID: String, marker: String, context: String) throws {
        guard !reading else { throw VoiceOSError("提醒事项读取正在进行") }
        _ = try calendar(calendarID)
        guard let item = store.calendarItem(withIdentifier: externalID) as? EKReminder,
              item.calendar.calendarIdentifier == calendarID, self.marker(item) == marker else { throw VoiceOSError("提醒事项身份已变化，请重新核对") }
        var existing = item.notes == marker ? "" : (item.notes ?? "")
        let url = URL(string: "voiceos://task/" + marker.replacingOccurrences(of: "voiceos-action:", with: ""))
        guard let link = url?.absoluteString else { throw VoiceOSError("提醒事项链接无效") }
        let compact = "详情：" + link
        // Only remove our exact generated text; any user's additions remain.
        if existing.hasPrefix(context) { existing.removeFirst(context.count) }
        existing = existing.replacingOccurrences(of: "\n\n在 VoiceOS 查看：\n" + link, with: "")
        if existing.hasPrefix(compact) { existing.removeFirst(compact.count) }
        existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes: String? = existing.isEmpty ? nil : existing
        if item.notes == notes, item.url == url { return }
        item.notes = notes; item.url = url
        try store.save(item, commit: true)
    }
    public func setCompletion(calendarID: String, externalID: String, marker: String, completed: Bool,
                              authorize: @MainActor () async throws -> Void) async throws {
        let matches = try await find(calendarID: calendarID, externalID: externalID, marker: marker)
        guard matches.count == 1, matches[0].id == externalID, matches[0].marker == marker else { throw VoiceOSError("提醒事项身份需重新核对") }
        try await authorize()
        try Task.checkCancellation()
        _ = try calendar(calendarID)
        guard let item = store.calendarItem(withIdentifier: externalID) as? EKReminder,
              item.calendar.calendarIdentifier == calendarID, self.marker(item) == marker else { throw VoiceOSError("保存前提醒事项身份已变化") }
        item.isCompleted = completed
        try store.save(item, commit: true)
    }
}
