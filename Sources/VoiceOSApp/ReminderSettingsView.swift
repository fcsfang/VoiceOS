import SwiftUI
import VoiceOSCore

struct ReminderSettingsView: View {
    let action: ActionRecord
    let snapshot: ReminderSnapshot
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var hasDate = false
    @State private var hasTime = false
    @State private var due = Date()
    @State private var hasAlert = false
    @State private var alert = Date()
    @State private var priority = 0
    @State private var error = ""
    private var zone: TimeZone {
        if case let .instant(_, zone) = snapshot.fields?.due { return TimeZone(identifier: zone) ?? .current }
        if case let .dateOnly(_, zone) = snapshot.fields?.due { return zone.flatMap(TimeZone.init(identifier:)) ?? .current }
        return .current
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("日期、提醒与优先级").font(.title2)
            Text(action.title).font(.headline)
            Text("读取的是 Apple 提醒事项当前设置。保存时会再次核对，其他设备刚改过的内容不会被旧设置覆盖。").font(.caption).foregroundStyle(.secondary)
            Toggle("安排日期", isOn: $hasDate)
            if hasDate {
                DatePicker("日期", selection: $due, displayedComponents: [.date])
                Toggle("具体时刻", isOn: $hasTime)
                if hasTime { DatePicker("时刻", selection: $due, displayedComponents: [.hourAndMinute]) }
            }
            Toggle("发送通知", isOn: $hasAlert)
            if hasAlert {
                DatePicker("提醒我", selection: $alert, displayedComponents: [.date, .hourAndMinute])
                Text("通知时间独立于安排日期。其他已有通知会保留。").font(.caption).foregroundStyle(.secondary)
            }
            Picker("优先级", selection: $priority) {
                Text("无").tag(0); Text("高").tag(1); Text("中").tag(5); Text("低").tag(9)
                if ![0, 1, 5, 9].contains(priority) { Text("当前优先级（\(priority)）").tag(priority) }
            }
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
            HStack {
                Button("取消", action: dismiss).disabled(model.reminderFieldEditing)
                Spacer()
                Button("保存到提醒事项") {
                    Task {
                        do {
                            let fields = try chosenFields()
                            if await model.saveReminderSettings(action, expected: snapshot, fields: fields) { dismiss() }
                            else { error = model.status }
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(model.remindersBusy || model.reminderFieldEditing)
            }
        }.padding(24).frame(width: 590).environment(\.timeZone, zone)
        .onAppear { load() }.interactiveDismissDisabled(model.reminderFieldEditing)
    }
    private func load() {
        guard let fields = snapshot.fields else { return }
        due = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        alert = Date().addingTimeInterval(3600)
        priority = fields.priority
        switch fields.due {
        case .none: break
        case let .dateOnly(text, _):
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = zone
            if let date = formatter.date(from: text) { due = date; hasDate = true }
        case let .instant(utc, _):
            if let date = ReminderFields.date(utc) { due = date; hasDate = true; hasTime = true }
        }
        if let first = fields.alerts.first.flatMap(ReminderFields.date) { alert = first; hasAlert = true }
    }
    private func chosenFields() throws -> ReminderFields {
        var fields = snapshot.fields ?? ReminderFields(); fields.priority = priority
        if hasDate {
            if hasTime { fields.due = .instant(utc: ReminderFields.timestamp(minute(due)), timeZone: zone.identifier) }
            else {
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = zone
                fields.due = .dateOnly(localDate: formatter.string(from: due), timeZone: nil)
            }
        } else { fields.due = .none }
        if hasAlert {
            let value = ReminderFields.timestamp(minute(alert))
            if value != snapshot.fields?.alerts.first, alert <= Date() { throw VoiceOSError("请选择未来的通知时间") }
            fields.alerts = ([value] + Array((snapshot.fields?.alerts ?? []).dropFirst())).sorted()
        } else { fields.alerts = [] }
        try fields.validate(); return fields
    }
    private func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }
}
