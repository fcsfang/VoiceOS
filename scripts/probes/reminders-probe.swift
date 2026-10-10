// An interactive single-fixture EventKit experiment, not a VoiceOS task adapter.
import SwiftUI
import EventKit

@MainActor
final class Probe: ObservableObject {
    @Published var calendars: [EKCalendar] = []
    @Published var selected = ""
    @Published var status = "尚未请求权限，也未读取清单。"
    @Published var busy = false
    private var store: EKEventStore?
    private let defaults = UserDefaults.standard
    private var marker: String {
        if let saved = defaults.string(forKey: "fixtureMarker") { return saved }
        let value = "voiceos-probe:" + UUID().uuidString
        defaults.set(value, forKey: "fixtureMarker")
        return value
    }
    var attempted: Bool { defaults.bool(forKey: "attempted") }

    func authorize() async {
        busy = true
        defer { busy = false }
        let candidate = EKEventStore()
        do {
            guard try await candidate.requestFullAccessToReminders() else {
                status = "权限未授予；没有读写。"; return
            }
            store = candidate
            calendars = candidate.calendars(for: .reminder).filter { $0.allowsContentModifications }
            selected = defaults.string(forKey: "fixtureCalendar") ?? ""
            status = "仅载入可写清单名称。请选择你创建的空白测试清单。"
        } catch { status = "权限请求失败：\(error.localizedDescription)" }
    }

    private func target() -> EKCalendar? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let store, !selected.isEmpty else { status = "需要权限和明确测试清单。"; return nil }
        if attempted && selected != defaults.string(forKey: "fixtureCalendar") {
            status = "已有尝试；只能回读原测试清单。"; return nil
        }
        guard let calendar = store.calendar(withIdentifier: selected), calendar.allowsContentModifications else {
            status = "测试清单不可写或已移除。"; return nil
        }
        return calendar
    }

    func create() async {
        guard !attempted, let calendar = target(), let store else { return }
        busy = true
        defer { busy = false }
        // Persist the attempt before side effect. A missing receipt never re-enables creation.
        defaults.set(calendar.calendarIdentifier, forKey: "fixtureCalendar")
        let identity = marker
        defaults.set(true, forKey: "attempted")
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = "VoiceOS 合成验证任务"
        reminder.notes = identity
        do {
            try store.save(reminder, commit: true)
            status = "写入已返回。请回读核对；没有设置时间、提醒或邀请。"
        } catch {
            status = "写入返回错误：\(error.localizedDescription)。尝试已保留，请回读核对，程序不会自动重建。"
        }
    }

    func readback() async {
        // Source refresh can leave fetched objects stale. Reset before reacquiring by ID.
        // This probe has no pending edits when querying; reset would discard such edits.
        store?.reset()
        guard attempted, let calendar = target(), let store else { return }
        busy = true
        defer { busy = false }
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForReminders(in: [calendar])
        let items: [EKReminder]? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0) }
        }
        guard let items else { status = "回读失败；结果未知，不自动重建。"; return }
        let identity = marker
        let matches = items.filter { $0.notes == identity }
        guard matches.count == 1, let item = matches.first else {
            status = "操作标记匹配 \(matches.count) 条；可能未同步、标记被修改或已删除。结果未知，不自动重建。"; return
        }
        status = "唯一标记匹配；标题：\(item.title ?? "")；完成：\(item.isCompleted)；本机 ID：\(item.calendarItemIdentifier)"
    }
}

@main
struct RemindersProbe: App {
    @StateObject private var probe = Probe()
    var body: some Scene {
        WindowGroup("VoiceOS 提醒事项验证") {
            VStack(alignment: .leading, spacing: 16) {
                Text("仅验证一个合成任务").font(.title2)
                Text("系统权限覆盖所有提醒事项。此程序只列出清单名称、读写你选择的测试清单；不自动启动操作，不上传数据，不自动删除或修改已有任务。")
                Button("请求系统权限并载入清单名称") { Task { await probe.authorize() } }
                Picker("空白测试清单", selection: $probe.selected) {
                    Text("请选择").tag("")
                    ForEach(probe.calendars, id: \.calendarIdentifier) { calendar in
                        Text(calendar.title).tag(calendar.calendarIdentifier)
                    }
                }.disabled(probe.attempted)
                HStack {
                    Button("在所选清单创建一次合成任务") { Task { await probe.create() } }
                        .disabled(probe.selected.isEmpty || probe.attempted)
                    Button("回读合成任务") { Task { await probe.readback() } }.disabled(!probe.attempted)
                }
                Text(probe.status).textSelection(.enabled)
                Text("创建后，可在 Apple 提醒事项手动完成、改标题，再回读。退出重开后仍只核对这一操作，不自动重试写入。测试结束可手动删除合成项。")
                    .font(.callout)
            }.padding(24).frame(width: 660).disabled(probe.busy)
        }
    }
}
