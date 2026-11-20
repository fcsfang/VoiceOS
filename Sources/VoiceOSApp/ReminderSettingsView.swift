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
    @State private var confirmingAlertRemoval = false
    @State private var priority = 0
    @State private var hasLocation = false
    @State private var locationName = ""
    @State private var locationProximity = ReminderLocation.Proximity.enter
    @State private var error = ""
    private var zone: TimeZone {
        if case let .instant(_, zone) = snapshot.fields?.due { return TimeZone(identifier: zone) ?? .current }
        if case let .dateOnly(_, zone) = snapshot.fields?.due { return zone.flatMap(TimeZone.init(identifier:)) ?? .current }
        return .current
    }
    private var alertCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar
    }
    private var defaultAlertText: String? {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = zone
        guard let defaultAlert = ReminderFields.nextDefaultAlert(due: .dateOnly(localDate: formatter.string(from: due), timeZone: nil), now: Date(), calendar: alertCalendar) else { return nil }
        formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: defaultAlert)
    }
    private var hasNonDefaultAlert: Bool {
        guard let fields = snapshot.fields, !fields.alerts.isEmpty else { return false }
        guard case let .dateOnly(localDate, _) = fields.due,
              let defaultAlert = ReminderFields.nextDefaultAlert(due: .dateOnly(localDate: localDate, timeZone: nil), now: Date(), calendar: alertCalendar) else { return true }
        return fields.alerts != [ReminderFields.timestamp(defaultAlert)]
    }
    private var alertToggle: Binding<Bool> {
        Binding(get: { hasAlert }, set: { on in
            if on { hasAlert = true }
            else if hasNonDefaultAlert { confirmingAlertRemoval = true }
            else { hasAlert = false; alert = Date().addingTimeInterval(3600) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                WorkspaceSectionHeading("日期、提醒与优先级")
                Text(action.title).vosFont(WorkspaceText.rowTitle)
                Text("保存前会重新核对提醒事项当前设置。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                Toggle("安排日期", isOn: $hasDate)
                if hasDate {
                    DatePicker("日期", selection: $due, displayedComponents: [.date])
                }
                Toggle("具体时刻", isOn: $hasTime).disabled(!hasDate)
                if hasDate {
                    if hasTime { DatePicker("时刻", selection: $due, displayedComponents: [.hourAndMinute]) }
                    if !hasTime {
                        Text("仅日期任务固定 09:00 提醒（当前不可关闭）").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        if let text = defaultAlertText { Text("实际通知时间 " + text).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                    }
                }
                if hasTime {
                    Toggle("发送通知", isOn: alertToggle).disabled(!hasDate)
                    if hasDate, hasAlert {
                        DatePicker("提醒我", selection: $alert, displayedComponents: [.date, .hourAndMinute])
                        Text("通知时间独立于安排日期。其他已有通知会保留。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    }
                }
                Picker("优先级", selection: $priority) {
                    Text("无").tag(0); Text("高").tag(1); Text("中").tag(5); Text("低").tag(9)
                    if ![0, 1, 5, 9].contains(priority) { Text("当前优先级（\(priority)）").tag(priority) }
                }
            }
            WorkspaceListDivider()
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                WorkspaceSectionHeading("稍后提醒")
                HStack(spacing: 8) {
                    ForEach(SnoozePreset.allCases, id: \.self) { preset in
                        Button(preset.title) { apply(preset) }.buttonStyle(.workspaceSecondaryCompact)
                    }
                }
            }
            WorkspaceListDivider()
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                Toggle("地点提醒", isOn: $hasLocation)
                if hasLocation {
                    TextField("地点名称", text: $locationName).textFieldStyle(.roundedBorder)
                    Picker("提醒方式", selection: $locationProximity) {
                        Text("到达").tag(ReminderLocation.Proximity.enter); Text("离开").tag(ReminderLocation.Proximity.leave)
                    }.pickerStyle(.segmented)
                    Text("只按名称解析，不联网、不写坐标。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
            }
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
            HStack {
                Button("取消", action: dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction).disabled(model.reminderFieldEditing)
                Spacer()
                Button("保存到提醒事项") {
                    Task {
                        error = ""
                        do {
                            let fields = try chosenFields()
                            if await model.saveReminderSettings(action, expected: snapshot, fields: fields) { dismiss() }
                            else { error = model.status.isEmpty ? "提醒设置未保存" : model.status }
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.workspacePrimary).disabled(model.remindersBusy || model.reminderFieldEditing)
            }
        }.padding(24).frame(width: WorkspaceMetrics.modalSmall).environment(\.timeZone, zone)
            .workspaceModalSurface()
        .onAppear { load() }.interactiveDismissDisabled(model.reminderFieldEditing)
        .onChange(of: hasTime) { _, on in
            if !on { hasAlert = false; alert = Date().addingTimeInterval(3600) }
        }
        .alert("关闭发送通知？", isPresented: $confirmingAlertRemoval) {
            Button("关闭并清空通知", role: .destructive) { hasAlert = false; alert = Date().addingTimeInterval(3600) }
            Button("保留通知", role: .cancel) {}
        } message: { Text("这会移除这条任务现有的非默认通知。") }
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
        if hasTime, let first = fields.alerts.first.flatMap(ReminderFields.date) { alert = first; hasAlert = true }
        if let location = fields.location { hasLocation = true; locationName = location.title; locationProximity = location.proximity }
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
        if hasLocation { fields.location = ReminderLocation(title: locationName.trimmingCharacters(in: .whitespacesAndNewlines), proximity: locationProximity) }
        else { fields.location = nil }
        fields = fields.withDefaultAlert(now: Date(), calendar: alertCalendar)
        try fields.validate(); return fields
    }
    private func apply(_ preset: SnoozePreset) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        due = preset.dueDate(now: Date(), calendar: calendar)
        hasDate = true
        hasTime = true
    }
    private func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }
}
