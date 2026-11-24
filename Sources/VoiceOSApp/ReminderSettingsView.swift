import SwiftUI
import VoiceOSCore

struct ReminderSettingsView: View {
    @Environment(\.workspacePalette) private var palette
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
    private var dateOnlyDue: ReminderDueDate {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = zone
        let day = formatter.string(from: due)
        if case let .dateOnly(originalDay, originalZone) = snapshot.fields?.due, originalDay == day {
            return .dateOnly(localDate: day, timeZone: originalZone)
        }
        return .dateOnly(localDate: day, timeZone: nil)
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
    private var timeNote: String? {
        guard hasDate, !hasTime else { return nil }
        let schedule = dateOnlyFields
        return schedule.alertSummary
    }
    private var dateOnlyFields: ReminderFields {
        let selected = dateOnlyDue
        if let existing = snapshot.fields, existing.due == selected, !existing.alerts.isEmpty { return existing }
        return ReminderFields(due: selected).withDefaultAlert(now: Date(), calendar: alertCalendar)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                    WorkspaceSectionHeading("日期、提醒与优先级")
                    Text(action.title).vosFont(WorkspaceText.rowTitle)
                    Text("保存前会重新核对提醒事项当前设置。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }.padding(.horizontal, 24)
                VStack(alignment: .leading, spacing: 0) {
                    WorkspaceSettingsRow(title: "安排日期", subtitle: !hasDate && snapshot.fields?.alerts.isEmpty == false ? "保存后会移除原有的定时通知。" : nil, showsDivider: false) {
                        Toggle("安排日期", isOn: $hasDate).toggleStyle(.switch).labelsHidden()
                    }
                    if hasDate {
                        WorkspaceSettingsRow(title: "日期") {
                            DatePicker("日期", selection: $due, displayedComponents: [.date]).labelsHidden().datePickerStyle(.field)
                        }
                        WorkspaceSettingsRow(title: "具体时刻", subtitle: timeNote) {
                            Toggle("具体时刻", isOn: $hasTime).toggleStyle(.switch).labelsHidden()
                        }
                    }
                    if hasDate, hasTime {
                        WorkspaceSettingsRow(title: "时刻") {
                            DatePicker("时刻", selection: $due, displayedComponents: [.hourAndMinute]).labelsHidden().datePickerStyle(.field)
                        }
                        WorkspaceSettingsRow(title: "发送通知") {
                            Toggle("发送通知", isOn: alertToggle).toggleStyle(.switch).labelsHidden()
                        }
                        if hasAlert {
                            WorkspaceSettingsRow(title: "提醒我", subtitle: "通知时间独立于安排日期。其他已有通知会保留。") {
                                DatePicker("提醒我", selection: $alert, displayedComponents: [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.field)
                            }
                        }
                    }
                    WorkspaceSettingsRow(title: "优先级") {
                        Picker("优先级", selection: $priority) {
                            Text("无").tag(0); Text("高").tag(1); Text("中").tag(5); Text("低").tag(9)
                            if ![0, 1, 5, 9].contains(priority) { Text("当前优先级（\(priority)）").tag(priority) }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                }
            }
            WorkspaceListDivider()
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                WorkspaceSectionHeading("快捷改期").padding(.horizontal, 24)
                HStack(spacing: 8) {
                    ForEach(SnoozePreset.allCases, id: \.self) { preset in
                        Button(preset.title) { apply(preset) }.buttonStyle(.workspaceSecondaryCompact)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(minHeight: 46)
            }
            WorkspaceListDivider()
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                WorkspaceSectionHeading("地点").padding(.horizontal, 24)
                VStack(alignment: .leading, spacing: 0) {
                    WorkspaceSettingsRow(title: "地点提醒", showsDivider: false) {
                        Toggle("地点提醒", isOn: $hasLocation).toggleStyle(.switch).labelsHidden()
                    }
                    if hasLocation {
                        WorkspaceSettingsRow(title: "地点名称") {
                            TextField("地点名称", text: $locationName).workspaceFieldSurface().frame(width: 260)
                        }
                        WorkspaceSettingsRow(title: "提醒方式", subtitle: "只按名称解析，不联网、不写坐标。") {
                            Picker("提醒方式", selection: $locationProximity) {
                                Text("到达").tag(ReminderLocation.Proximity.enter); Text("离开").tag(ReminderLocation.Proximity.leave)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                        }
                    }
                }
            }
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger).padding(.horizontal, 24) }
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
                }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(model.remindersBusy || model.reminderFieldEditing)
            }.padding(.horizontal, 24)
        }.padding(.vertical, 24).frame(width: WorkspaceMetrics.modalSmall).environment(\.timeZone, zone)
            .workspaceModalSurface()
        .onAppear { load() }.interactiveDismissDisabled(model.reminderFieldEditing)
        .onChange(of: hasTime) { _, on in
            if !on { hasAlert = false; alert = Date().addingTimeInterval(3600) }
        }
        .alert("关闭发送通知？", isPresented: $confirmingAlertRemoval) {
            Button("保留通知", role: .cancel) {}
            Button("关闭并清空通知", role: .destructive) { hasAlert = false; alert = Date().addingTimeInterval(3600) }
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
            else { fields.due = dateOnlyDue }
        } else { fields.due = .none }
        if hasDate, !hasTime {
            fields.alerts = dateOnlyFields.alerts
        } else if hasDate, hasAlert {
            let value = snapshot.fields?.alerts.first.flatMap(ReminderFields.date) == alert
                ? ReminderFields.timestamp(alert) : ReminderFields.timestamp(minute(alert))
            if value != snapshot.fields?.alerts.first, alert <= Date() { throw VoiceOSError("请选择未来的通知时间") }
            fields.alerts = ([value] + Array((snapshot.fields?.alerts ?? []).dropFirst())).sorted()
        } else { fields.alerts = [] }
        if hasLocation { fields.location = ReminderLocation(title: locationName.trimmingCharacters(in: .whitespacesAndNewlines), proximity: locationProximity) }
        else { fields.location = nil }
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
