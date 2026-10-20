import Foundation
import SwiftUI
import VoiceOSCore

struct ActionScheduleEditor: View {
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
        VStack(alignment: .leading, spacing: 16) {
            Text("设置本地期限选择").font(.title2)
            Text(action.title).font(.headline)
            Picker("期限类型", selection: $mode) {
                Text("仅日期").tag("date"); Text("日期与时间").tag("time"); Text("移除期限").tag("none")
            }.pickerStyle(.segmented).disabled(saving)
            if mode != "none" {
                DatePicker("期限", selection: $date, displayedComponents: mode == "time" ? [.date,.hourAndMinute] : [.date])
                    .environment(\.timeZone, timeZone).disabled(saving)
                Text("解释时区：" + timeZone.identifier).font(.caption).foregroundStyle(.secondary)
            }
            Text("这是你在控制中心作出的期限选择，先仅本地保存。外部期限有差异时，需查看具体改期并确认；不会因为保存而自动修改提醒事项。").font(.callout).foregroundStyle(.secondary)
            if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
            HStack {
                Button("取消", action: dismiss).disabled(saving)
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
                }.keyboardShortcut(.defaultAction).disabled(saving || model.savingAction)
            }
        }.padding(24).frame(width: 620)
    }
}

struct ReminderScheduleConfirmationView: View {
    let effect: ReminderScheduleEffect
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var commandID = UUID().uuidString
    @State private var saving = false
    @State private var errorText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认本次具体改期").font(.title2)
            Text(effect.before.title).font(.headline)
            Text("清单：" + effect.calendarTitle)
            Text("上次回读期限：" + (effect.before.dueDate?.summary ?? "未能核对"))
            Text("拟改为：" + effect.desired.summary).font(.headline)
            Text(effect.authority == .userCommitment ? "你的明确期限选择" : "AI 弹性安排，仍非你的明确承诺").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("本次排期依据") {
                Text(effect.rawExpression).textSelection(.enabled)
                Text("表达时刻：" + effect.anchorSummary).font(.caption).foregroundStyle(.secondary)
            }
            Text("只允许这一项期限变更。执行前会重新核对；任务、清单或期限发生变化时停止写入。标题、完成状态和其他字段保留。").font(.callout)
            Text("确认不代表任务已完成或观点已验证。可以撤回后续写入许可；已派发的变更不能因此自动撤销。").font(.caption).foregroundStyle(.secondary)
            if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
            HStack {
                Button("暂不修改", action: dismiss).disabled(saving)
                Spacer()
                Button(saving ? "正在处理…" : "确认并执行这一次改期") {
                    saving = true; errorText = ""
                    Task {
                        let approved = await model.confirmScheduleEffect(effect, commandID: commandID)
                        saving = false
                        if approved { dismiss() } else { errorText = model.status }
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || model.remindersBusy)
            }
        }.padding(24).frame(width: 620)
    }
}
