import SwiftUI
import VoiceOSCore

struct CorrectionImpactView: View {
    @ObservedObject var model: ControlCenter
    var embedded = false
    @State private var policyFreezes: [PolicyFreezeImpact] = []
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更正后的处理情况").font(.title2)
            Text("更正后的内容会用于后续理解。下面保留的是依赖更正前内容的任务：原有完成记录和反馈不会丢失；已写入系统提醒事项的任务也不会凭一次更正就被删除。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.correctionImpacts) { impact in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(impact.action.title).font(.headline)
                            ForEach(impact.understandingProgress) { progress in
                                Text(progress.summary).font(.callout)
                                if let id = progress.sourceID {
                                    Button("查看更正后的原文与理解") { model.selected = id; dismiss() }
                                }
                            }
                            Text(impact.summary).font(.callout)
                            DisclosureGroup("为什么保留这项历史任务") {
                                ForEach(impact.roots) { root in
                                    Text(root.summary).font(.caption).foregroundStyle(.secondary)
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
                    if !policyFreezes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("许可变更后暂停的理解").font(.headline)
                            Text("以下暂停来自云端使用许可调整，不是对文字错误的更正判定；完成记录与任务历史保持独立。").font(.caption).foregroundStyle(.secondary)
                            ForEach(policyFreezes) { freeze in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(freeze.sourceName).font(.subheadline)
                                    Text(freeze.summary).font(.callout)
                                    Button("查看材料与暂停原因") { model.selected = freeze.sourceID; dismiss() }
                                }.padding(.vertical, 6)
                            }
                        }
                        Divider()
                    }
                    if model.correctionImpacts.isEmpty && policyFreezes.isEmpty { Text("目前没有因明确更正或许可调整而暂停的任务。").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.correctionImpacts.contains(where: { !$0.scheduleEffects.isEmpty }) {
                Text("如果此前 AI 改过期限，可查看恢复期限的具体方案。恢复期限会保留任务的真实完成状态。").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if !embedded { HStack { Spacer(); Button("完成", action: dismiss).keyboardShortcut(.defaultAction) } }
        }.padding(24).frame(width: embedded ? nil : WorkspaceMetrics.modalMedium, height: embedded ? nil : 620)
            .sheet(item: $model.pendingCompensation) { plan in
                CompensationConfirmationView(plan: plan,model: model) { model.pendingCompensation = nil }
            }
            .task(id: model.records.map { $0.id + String($0.policyVersion) }.joined()) {
                guard let store = model.store else { policyFreezes = []; return }
                policyFreezes = (try? await store.policyFreezeImpacts()) ?? []
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
            if !errorText.isEmpty { WorkspaceNoticeText(message: errorText, severity: .danger) }
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
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || model.remindersBusy || !plan.eligibleForConfirmation)
            }
        }.padding(24).frame(width: 640)
    }
}
