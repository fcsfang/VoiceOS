import SwiftUI
import VoiceOSCore

struct CorrectionImpactView: View {
    @ObservedObject var model: ControlCenter
    var embedded = false
    @State private var policyFreezes: [PolicyFreezeImpact] = []
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更正后的处理情况").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            Text("更正后的内容用于后续理解。下面保留依赖更正前内容的任务；完成记录和反馈不会丢失，提醒事项也不会因一次更正被删除。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceMetrics.groupGap) {
                    ForEach(model.correctionImpacts) { impact in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(impact.action.title).vosFont(WorkspaceText.rowTitle)
                            ForEach(impact.understandingProgress) { progress in
                                Text(progress.summary).vosFont(WorkspaceText.body)
                                if let id = progress.sourceID {
                                    Button("查看更正后的原文与理解") { model.selected = id; dismiss() }
                                }
                            }
                            Text(impact.summary).vosFont(WorkspaceText.body)
                            DisclosureGroup("为什么保留这项历史任务") {
                                ForEach(impact.roots) { root in
                                    Text(root.summary).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                }
                            }
                            if let link = impact.link {
                                Text("上次外部标题：" + (link.remoteTitle ?? "尚未核对")).vosFont(WorkspaceText.meta)
                                Text("上次外部期限：" + (link.remoteDueDate?.summary ?? "未能核对")).vosFont(WorkspaceText.meta)
                                Text("保存的观测；回读只核对现状，不取消、不改写、不补偿。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
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
                                        Text((effect.before?.summary ?? "未知期限") + " → " + effect.desired.summary).vosFont(WorkspaceText.meta)
                                        Text(ReminderScheduleOperationState(rawValue: effect.state)?.summary ?? "改期效果待核对").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        WorkspaceListDivider()
                    }
                    if !policyFreezes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("许可变更后暂停的理解").vosFont(WorkspaceText.rowTitle)
                            Text("以下暂停来自云端使用许可调整，不是对文字错误的更正判定；完成记录与任务历史保持独立。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                            ForEach(policyFreezes) { freeze in
                                VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                                    Text(freeze.sourceName).vosFont(WorkspaceText.body)
                                    Text(freeze.summary).vosFont(WorkspaceText.body)
                                    Button("查看材料与暂停原因") { model.selected = freeze.sourceID; dismiss() }
                                }.padding(.vertical, 6)
                            }
                        }
                        WorkspaceListDivider()
                    }
                    if model.correctionImpacts.isEmpty && policyFreezes.isEmpty { Text("目前没有因明确更正或许可调整而暂停的任务。").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.correctionImpacts.contains(where: { !$0.scheduleEffects.isEmpty }) {
                Text("此前 AI 改过期限的，可查看恢复方案；恢复会保留任务的真实完成状态。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            }
            Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            if !embedded { HStack { Spacer(); Button("完成", action: dismiss).keyboardShortcut(.cancelAction).buttonStyle(.workspaceSecondary) } }
        }.padding(24).frame(width: embedded ? nil : WorkspaceMetrics.modalMedium, height: embedded ? nil : 620)
            .workspaceModalSurface()
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
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text("期限补偿方案：" + (plan.before.dueDate?.summary ?? "未知") + " → " + plan.desired.summary).vosFont(WorkspaceText.meta)
            if plan.validity == "frozen" { Text("迁移补偿仅作历史保留").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
            if let operation = model.compensationOperations.first(where: { $0.planID == plan.id }) {
                Text(operation.state.summary).vosFont(WorkspaceText.meta)
                Text(operation.reason).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                if operation.validity == "current", operation.attempted, [.unknown,.conflict].contains(operation.state) {
                    Button("只读核对补偿效果") { Task { await model.reconcileCompensation(operation) } }
                        .disabled(model.remindersBusy || model.reminderAccess?.enabled != true)
                }
            }
            if let grant = model.compensationGrants.first(where: { $0.planID == plan.id }) {
                Text(grant.revoked ? "补偿确认已撤回" : "本次具体补偿已确认").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
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
            Text("确认这一次期限补偿").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            Text(plan.before.title).vosFont(WorkspaceText.rowTitle)
            Text("清单：" + plan.calendarTitle)
            Text("上次回读期限：" + (plan.before.dueDate?.summary ?? "未核对"))
            Text("恢复为：" + plan.desired.summary).vosFont(WorkspaceText.rowTitle)
            Text("依据\(plan.rootIDs.count)条明确纠错和\(plan.operationIDs.count)次可追溯AI排期，拟恢复这段排期链之前的期限。受影响不等于任务必然错误，请确认这项效果符合你的意图。").vosFont(WorkspaceText.body)
            Text("只改期限，保留当前任务标题和完成状态。执行前重新核对；变化后停止旧方案。旧行动与认知保持暂停，不把补偿当成真实行动结果。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            if !errorText.isEmpty { WorkspaceNoticeText(message: errorText, severity: .danger) }
            HStack {
                Button("暂不补偿",action: dismiss).disabled(saving).keyboardShortcut(.cancelAction).buttonStyle(.workspaceSecondary)
                Spacer()
                Button(saving ? "正在处理…" : "确认并执行这一次期限补偿") {
                    saving = true
                    Task {
                        let approved = await model.confirmCompensation(plan,commandID: commandID)
                        saving = false
                        if approved { dismiss() } else { errorText = model.status }
                    }
                }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(saving || model.remindersBusy || !plan.eligibleForConfirmation)
            }
        }.padding(24).frame(width: 640)
            .workspaceModalSurface()
    }
}
