import Foundation
import EventKit
import VoiceOSCore

public struct ReminderCalendar: Identifiable, Sendable {
    public let id: String
    public let title: String
}
/// All EventKit objects stay on MainActor and are reacquired for each operation.
@MainActor
public final class NativeReminders: RemindersSchedulingPort {
    private let store = EKEventStore()
    private var reading = false
    private let readTimeout: Duration = .seconds(8)
    public init() {}
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
                        ReminderSnapshot(id: $0.calendarItemIdentifier, title: $0.title ?? "", completed: $0.isCompleted, marker: self.marker($0), dueDate: ReminderDueDate.reading($0.dueDateComponents))
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
        try Task.checkCancellation()
        guard !reading else { throw VoiceOSError("提醒事项读取正在进行") }
        let target = try calendar(calendarID)
        let item = EKReminder(eventStore: store)
        let link = "voiceos://task/" + marker.replacingOccurrences(of: "voiceos-action:", with: "")
        item.calendar = target; item.title = title; item.notes = context + "\n\n在 VoiceOS 查看：\n" + link
        item.url = URL(string: link)
        // No guessed deadline, alarm, priority, or changes to other items.
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
              ReminderSnapshot(id: item.calendarItemIdentifier, title: item.title ?? "", completed: item.isCompleted,
                               marker: marker(item), dueDate: ReminderDueDate.reading(item.dueDateComponents)) == expected else {
            throw VoiceOSError("最终保存前身份或字段已变化；没有修改")
        }
        // EventKit has no remote atomic compare-and-swap. The synchronous final
        // check narrows the race but cannot eliminate concurrent iCloud edits.
        // Preserve title, notes, completion, priority, alarms and other fields.
        item.dueDateComponents = components
        do { try store.save(item, commit: true) }
        catch { throw VoiceOSError("提醒事项改期结果未知；只能回读，不重发") }
    }

    public func updateContext(calendarID: String, externalID: String, marker: String, context: String) throws {
        guard !reading else { throw VoiceOSError("提醒事项读取正在进行") }
        _ = try calendar(calendarID)
        guard let item = store.calendarItem(withIdentifier: externalID) as? EKReminder,
              item.calendar.calendarIdentifier == calendarID, self.marker(item) == marker else { throw VoiceOSError("提醒事项身份已变化，请重新核对") }
        let existing = item.notes == marker ? "" : (item.notes ?? "")
        var notes = existing.hasPrefix("来源：") ? existing : context + (existing.isEmpty ? "" : "\n\n我的补充：\n" + existing)
        let url = URL(string: "voiceos://task/" + marker.replacingOccurrences(of: "voiceos-action:", with: ""))
        if let link = url?.absoluteString, !notes.contains(link) { notes += "\n\n在 VoiceOS 查看：\n" + link }
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
