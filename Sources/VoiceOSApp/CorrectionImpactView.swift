import SwiftUI
import VoiceOSCore

struct CorrectionImpactView: View {
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("纠错影响与外部核对").font(.title2)
            Text("明确纠错先阻止旧依据继续执行。下面依据已保存的修订和操作历史列出受影响行动；不代表所有行动都错误，也不代表外部任务已撤销。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.correctionImpacts) { impact in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(impact.action.title).font(.headline)
                            Text(impact.summary).font(.callout)
                            ForEach(impact.roots) { root in
                                Text(root.summary).font(.caption).foregroundStyle(.secondary)
                                if let id = root.sourceID {
                                    Button("查看纠错来源") { model.selected = id; dismiss() }
                                }
                            }
                            if let link = impact.link {
                                Text("上次外部标题：" + (link.remoteTitle ?? "尚未核对")).font(.caption)
                                Text("上次外部期限：" + (link.remoteDueDate?.summary ?? "未能核对")).font(.caption)
                                Text("这是保存的观测；回读只核对现状，不执行取消、改写或补偿。").font(.caption).foregroundStyle(.secondary)
                                Button("回读外部现状") { Task { await model.readReminder(link) } }
                                    .disabled(model.remindersBusy || model.reminderAccess?.enabled != true || model.reminderCalendarID != link.calendarID)
                            }
                            if !impact.scheduleEffects.isEmpty {
                                DisclosureGroup("受影响行动的改期历史") {
                                    ForEach(impact.scheduleEffects) { effect in
                                        Text((effect.before?.summary ?? "未知期限") + " → " + effect.desired.summary).font(.caption)
                                        Text(ReminderScheduleOperationState(rawValue: effect.state)?.summary ?? "改期效果待核对").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                    if model.correctionImpacts.isEmpty { Text("当前没有可定位到明确纠错的受影响行动。").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("此处仅核对影响与外部现状。外部取消和具体补偿尚不受此入口支持，不能把暂停执行当作已经撤销。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成", action: dismiss).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 720, height: 620)
    }
}
