import Foundation
import SwiftUI
import VoiceOSCore

struct ActionScheduleEditor: View {
    @Environment(\.workspacePalette) private var palette
    let action: ActionRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var scheduleVersion: Int
    @State private var timeZoneIdentifier: String
    private var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier)! }
    @State private var mode: String
    @State private var date: Date
    @State private var anchorTime: Date?
    @State private var commandID = UUID().uuidString
    @State private var saving = false
    @State private var errorText = ""

    init(action: ActionRecord, model: ControlCenter, dismiss: @escaping () -> Void) {
        self.action = action; self.model = model; self.dismiss = dismiss
        let current = model.scheduleIntents.first { $0.actionID == action.id }
        _scheduleVersion = State(initialValue: current?.version ?? 0)
        var zone = TimeZone.current, initialDate = Date(), initialMode = "date"
        if let due = current?.due {
            switch due {
            case .none: initialMode = "none"
            case let .dateOnly(text, identifier):
                zone = identifier.flatMap(TimeZone.init(identifier:)) ?? zone
                let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"
                initialDate = formatter.date(from: text) ?? initialDate
            case let .instant(utc, identifier):
                zone = TimeZone(identifier: identifier) ?? zone
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
                initialDate = formatter.date(from: utc) ?? initialDate; initialMode = "time"
            }
        }
        _timeZoneIdentifier = State(initialValue: zone.identifier)
        _date = State(initialValue: initialDate); _mode = State(initialValue: initialMode)
    }
    private func selectedDue() throws -> ReminderDueDate {
        if mode == "none" { return .none }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year,.month,.day,.hour,.minute], from: date)
        if mode == "date" {
            return .dateOnly(localDate: String(format: "%04d-%02d-%02d",components.year!,components.month!,components.day!), timeZone: timeZone.identifier)
        }
        components.second = 0
        guard let instant = calendar.date(from: components) else { throw VoiceOSError("选定时刻无法解析") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return .instant(utc: formatter.string(from: instant), timeZone: timeZone.identifier)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                WorkspaceSectionHeading("设置本地期限选择")
                Text(action.title).vosFont(WorkspaceText.rowTitle)
            }
            WorkspaceListDivider()
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                Picker("期限类型", selection: $mode) {
                    Text("仅日期").tag("date"); Text("日期与时间").tag("time"); Text("移除期限").tag("none")
                }.pickerStyle(.segmented).disabled(saving)
                if mode != "none" {
                    DatePicker("期限", selection: $date, displayedComponents: mode == "time" ? [.date,.hourAndMinute] : [.date])
                        .environment(\.timeZone, timeZone).disabled(saving)
                    Text("解释时区：" + timeZone.identifier).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
            }
            WorkspaceListDivider()
            Text("仅保存在本地；外部改期差异需另行确认。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            if !errorText.isEmpty { WorkspaceNoticeText(message: errorText, severity: .danger) }
            HStack {
                Button("取消", action: dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? "正在保存…" : "保存本地期限") {
                    do {
                        let due = try selectedDue(); _ = try due.writableComponents()
                        if anchorTime == nil { anchorTime = Date() }
                        saving = true; errorText = ""
                        Task {
                            let saved = await model.saveUserSchedule(action, due: due, scheduleVersion: scheduleVersion,
                                                                     anchorTime: anchorTime!, timeZone: timeZone.identifier, commandID: commandID)
                            saving = false
                            if saved { dismiss() } else { errorText = model.status }
                        }
                    } catch { errorText = error.localizedDescription }
                }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(saving || model.savingAction)
            }
        }.padding(24).frame(width: WorkspaceMetrics.modalSmall)
            .workspaceModalSurface()
    }
}

struct ReminderScheduleConfirmationView: View {
    @Environment(\.workspacePalette) private var palette
    let effect: ReminderScheduleEffect
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var commandID = UUID().uuidString
    @State private var saving = false
    @State private var errorText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                WorkspaceSectionHeading("确认本次具体改期")
                Text(effect.before.title).vosFont(WorkspaceText.rowTitle)
                Text("清单：" + effect.calendarTitle)
            }
            WorkspaceListDivider()
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                HStack(spacing: 8) {
                    WorkspaceBadge(text: "上次回读期限：" + (effect.before.dueDate?.summary ?? "未能核对"),
                                   tone: effect.before.dueDate == nil ? .warning : .neutral)
                    WorkspaceBadge(text: "拟改为：" + effect.desired.summary)
                }
                Text(effect.authority == .userCommitment ? "你的明确期限选择" : "AI 弹性安排，仍非你的明确承诺").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                DisclosureGroup("本次排期依据") {
                    Text(effect.rawExpression).textSelection(.enabled)
                    Text("表达时刻：" + effect.anchorSummary).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
            }
            WorkspaceListDivider()
            VStack(alignment: .leading, spacing: WorkspaceMetrics.controlPadding) {
                Text("只允许这一项变更，执行前重新核对。").vosFont(WorkspaceText.body)
                Text("确认不代表任务已完成；撤回后续写入许可不会撤销已派发的变更。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            }
            if !errorText.isEmpty { WorkspaceNoticeText(message: errorText, severity: .danger) }
            HStack {
                Button("暂不修改", action: dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? "正在处理…" : "确认并执行这一次改期") {
                    saving = true; errorText = ""
                    Task {
                        let approved = await model.confirmScheduleEffect(effect, commandID: commandID)
                        saving = false
                        if approved { dismiss() } else { errorText = model.status }
                    }
                }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(saving || model.remindersBusy)
            }
        }.padding(24).frame(width: WorkspaceMetrics.modalSmall)
            .workspaceModalSurface()
    }
}
