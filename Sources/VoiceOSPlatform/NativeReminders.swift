import Foundation
import EventKit
import VoiceOSCore

public struct ReminderCalendar: Identifiable, Sendable {
    public let id: String
    public let title: String
}
/// All EventKit objects stay on MainActor and are reacquired for each operation.
@MainActor
public final class NativeReminders: RemindersPort {
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
    private func calendar(_ id: String) throws -> EKCalendar {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw VoiceOSError("提醒事项权限不可用") }
        store.refreshSourcesIfNecessary()
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications else { throw VoiceOSError("明确选定的提醒事项清单不可用；不会另选清单") }
        return calendar
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
                    let results = items.filter { $0.calendar.calendarIdentifier == calendarID && ($0.notes == marker || (externalID != nil && $0.calendarItemIdentifier == externalID)) }.map {
                        ReminderSnapshot(id: $0.calendarItemIdentifier, title: $0.title ?? "", completed: $0.isCompleted, marker: $0.notes ?? "", dueDate: ReminderDueDate.reading($0.dueDateComponents))
                    }
                    complete(.success(results))
                }
            }
            return { [store] in store.cancelFetchRequest(token) }
        }
        try Task.checkCancellation()
        return snapshots
    }
    public func create(calendarID: String, title: String, marker: String) async throws {
        try Task.checkCancellation()
        guard !reading else { throw VoiceOSError("提醒事项读取正在进行") }
        let target = try calendar(calendarID)
        let item = EKReminder(eventStore: store)
        item.calendar = target; item.title = title; item.notes = marker
        // No guessed deadline, alarm, priority, or changes to other items.
        do { try store.save(item, commit: true) }
        catch { throw VoiceOSError("提醒事项写入结果未知") }
    }

    /// Development verification only: mark the one explicitly identified item
    /// complete, then let VoiceOS observe the change through its normal readback.
    public func markCompleted(calendarID: String, externalID: String) async throws {
        try Task.checkCancellation()
        let target = try calendar(calendarID)
        let predicate = store.predicateForReminders(in: [target])
        let gate = CallbackWait<[EKReminder]>()
        let items = try await gate.wait(timeout: readTimeout) { complete in
            let token = store.fetchReminders(matching: predicate) { reminders in
                Task { @MainActor in
                    guard gate.isWaiting else { return }
                    guard let reminders else { complete(.failure(VoiceOSError("提醒事项完成核对未返回结果"))); return }
                    complete(.success(reminders))
                }
            }
            return { [store] in store.cancelFetchRequest(token) }
        }
        guard let item = items.first(where: { $0.calendar.calendarIdentifier == calendarID && $0.calendarItemIdentifier == externalID }) else {
            throw VoiceOSError("未找到明确指定的 VoiceOS 任务；不会修改其他提醒事项")
        }
        item.isCompleted = true
        do { try store.save(item, commit: true) }
        catch { throw VoiceOSError("提醒事项完成写入结果未知") }
    }

    /// Development fixture only: reopen the one explicitly identified item.
    /// Formal material processing never calls this method; newly created items
    /// remain open until the user completes them in Apple Reminders.
    public func markIncomplete(calendarID: String, externalID: String) async throws {
        try Task.checkCancellation()
        let target = try calendar(calendarID)
        let predicate = store.predicateForReminders(in: [target])
        let gate = CallbackWait<[EKReminder]>()
        let items = try await gate.wait(timeout: readTimeout) { complete in
            let token = store.fetchReminders(matching: predicate) { reminders in
                Task { @MainActor in
                    guard gate.isWaiting else { return }
                    guard let reminders else { complete(.failure(VoiceOSError("提醒事项未完成核对未返回结果"))); return }
                    complete(.success(reminders))
                }
            }
            return { [store] in store.cancelFetchRequest(token) }
        }
        guard let item = items.first(where: { $0.calendar.calendarIdentifier == calendarID && $0.calendarItemIdentifier == externalID }) else {
            throw VoiceOSError("未找到明确指定的 VoiceOS 任务；不会修改其他提醒事项")
        }
        item.isCompleted = false
        do { try store.save(item, commit: true) }
        catch { throw VoiceOSError("提醒事项未完成写入结果未知") }
    }
}
