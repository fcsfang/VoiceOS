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
                                if !impact.scheduleEffects.isEmpty {
                                    Button("查看期限补偿方案") { Task { await model.prepareCompensation(impact) } }
                                        .disabled(model.remindersBusy || model.reminderAccess?.enabled != true || model.reminderCalendarID != link.calendarID)
                                }
                            }
                            ForEach(model.compensationPlans.filter { $0.actionID == impact.action.id }) { plan in
                                CompensationHistoryRow(plan: plan,model: model)
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
            Text("可查看并确认恢复AI排期之前的期限。任务取消仍需另行处理；期限补偿不代表任务或旧认知已恢复有效。").font(.caption).foregroundStyle(.secondary)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成", action: dismiss).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 720, height: 620)
            .sheet(item: $model.pendingCompensation) { plan in
                CompensationConfirmationView(plan: plan,model: model) { model.pendingCompensation = nil }
            }
    }
}

private struct CompensationHistoryRow: View {
    let plan: ReminderCompensationPlan
    @ObservedObject var model: ControlCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("期限补偿方案：" + (plan.before.dueDate?.summary ?? "未知") + " → " + plan.desired.summary).font(.caption)
            if plan.validity == "frozen" { Text("迁移补偿仅作历史保留").font(.caption).foregroundStyle(.secondary) }
            if let operation = model.compensationOperations.first(where: { $0.planID == plan.id }) {
                Text(operation.state.summary).font(.caption)
                Text(operation.reason).font(.caption).foregroundStyle(.secondary)
                if operation.validity == "current", operation.attempted, [.unknown,.conflict].contains(operation.state) {
                    Button("只读核对补偿效果") { Task { await model.reconcileCompensation(operation) } }
                        .disabled(model.remindersBusy || model.reminderAccess?.enabled != true)
                }
            }
            if let grant = model.compensationGrants.first(where: { $0.planID == plan.id }) {
                Text(grant.revoked ? "补偿确认已撤回" : "本次具体补偿已确认").font(.caption).foregroundStyle(.secondary)
                if grant.eligibleForExecution {
                    Button("执行已确认期限补偿") { Task { await model.executeCompensation(plan,grant: grant) } }.disabled(model.remindersBusy)
                }
                if grant.validity == "current", !grant.revoked {
                    Button("撤回补偿确认") { Task { await model.revokeCompensation(grant) } }
                }
            } else if plan.eligibleForConfirmation {
                Button("查看并确认这一期限补偿") { model.pendingCompensation = plan }.disabled(model.remindersBusy)
            }
        }
    }
}

private struct CompensationConfirmationView: View {
    let plan: ReminderCompensationPlan
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var commandID = UUID().uuidString
    @State private var saving = false
    @State private var errorText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认这一次期限补偿").font(.title2)
            Text(plan.before.title).font(.headline)
            Text("清单：" + plan.calendarTitle)
            Text("上次回读期限：" + (plan.before.dueDate?.summary ?? "未核对"))
            Text("恢复为：" + plan.desired.summary).font(.headline)
            Text("依据\(plan.rootIDs.count)条明确纠错和\(plan.operationIDs.count)次可追溯AI排期，拟恢复这段排期链之前的期限。受影响不等于任务必然错误，请确认这项效果符合你的意图。").font(.callout)
            Text("只改期限，保留当前任务标题和完成状态。执行前重新核对；变化后停止旧方案。旧行动与认知保持暂停，不把补偿当成真实行动结果。").font(.callout).foregroundStyle(.secondary)
            if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
            HStack {
                Button("暂不补偿",action: dismiss).disabled(saving)
                Spacer()
                Button(saving ? "正在处理…" : "确认并执行这一次期限补偿") {
                    saving = true
                    Task {
                        let approved = await model.confirmCompensation(plan,commandID: commandID)
                        saving = false
                        if approved { dismiss() } else { errorText = model.status }
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || model.remindersBusy || !plan.eligibleForConfirmation)
            }
        }.padding(24).frame(width: 640)
    }
}
