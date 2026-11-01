import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VoiceOSCore

struct WorkspaceDeliveryView: View {
    @ObservedObject var model: ControlCenter
    let execution: AssistantExecutionRecord
    let openTask: (String) -> Void
    let openTopic: (String) -> Void
    let discuss: () -> Void
    @State private var topicID = ""
    @State private var error = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                WorkspaceHeading(eyebrow: "AI 助理 · " + assistantExecutionLabel(execution), title: execution.title)
                if execution.validity != "current" {
                    Label("依据已变化，这份交付作为历史保留。", systemImage: "pause.circle").foregroundStyle(.orange)
                }
                if let report = execution.report, !report.isEmpty {
                    WorkspaceSection(title:"交付正文",subtitle:"AI 产出 · " + (ConversationReflectionFocus.date(execution.createdAt)?.formatted(date:.abbreviated,time:.shortened) ?? execution.createdAt),icon:"doc.text",actionTitle:"保存报告…",action:{ export(report) }) {
                        AssistantReportView(report: report).padding(.top,14)
                    }
                    if !execution.references.isEmpty {
                        WorkspaceSection(title:"参考与来源",icon:"link",count:execution.references.count) {
                            DisclosureGroup("参考来源（\(execution.references.count)）") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(execution.references.enumerated()), id: \.offset) { _, ref in
                                        if let url = URL(string: ref.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                            Link(ref.title.isEmpty ? ref.url : ref.title, destination: url)
                                            Text(ref.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }
                                }.padding(.top, 12)
                            }.padding(.vertical,14)
                        }
                    }
                    if execution.validity == "current" {
                        Button("带着成果继续讨论", systemImage: "bubble.left.and.bubble.right", action: discuss)
                            .buttonStyle(.borderedProminent)
                    }
                } else if ["queued", "running"].contains(execution.state) {
                    HStack(spacing: 14) {
                        ProgressView().controlSize(.small)
                        Text(execution.state == "queued" ? "委托已保存，正在等待执行。" : "AI 正在完成交付，结果会保存在这里。")
                    }.padding(.vertical, 30)
                    Text("可以继续阅读其他材料，VoiceOS 保持运行就会继续处理。").foregroundStyle(.secondary)
                }
                if let message = execution.error, !message.isEmpty { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                WorkspaceSection(title:"继续使用这份成果",icon:"arrow.right.circle") {
                    HStack {
                        Button("原任务与使用结果") { openTask(execution.actionID) }
                        Spacer()
                        if ["queued", "running"].contains(execution.state) { Button("取消代办") { Task { await model.cancelAssistant(execution) } } }
                        if execution.validity == "current", ["failed", "cancelled"].contains(execution.state) { Button("重新执行") { Task { await model.retryAssistant(execution) } } }
                    }.padding(.vertical,14)
                    if let id = execution.questionID, let topic = model.workspaceTopics.first(where: { $0.id == id }) {
                        WorkspaceRow(title: topic.title, subtitle: "成果已回流到这个主题", icon: "circle.hexagongrid") { openTopic(id) }
                    }
                    if execution.state == "completed", execution.validity == "current" {
                        DisclosureGroup("调整成果所属主题") {
                            HStack {
                                Picker("主题", selection: $topicID) {
                                    Text("选择主题").tag("")
                                    ForEach(model.workspaceTopics) { Text($0.title).tag($0.id) }
                                }
                                Button("接回主题") { Task { if !(await model.attachAssistantResult(execution, questionID: topicID)) { error = model.assistantStatus } } }.disabled(topicID.isEmpty)
                            }.padding(.top, 12)
                        }.padding(.vertical,14)
                    }
                    DisclosureGroup("交付要求与记录") {
                        Text(execution.instruction).textSelection(.enabled).padding(.top, 8)
                        Text("AI 产出 · " + execution.createdAt).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,14)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.orange) }
            }.frame(maxWidth: 820, alignment: .leading).padding(30).frame(maxWidth: .infinity, alignment: .top)
        }.task(id: execution.id) { topicID = execution.questionID ?? "" }
    }
    private func export(_ report: String) {
        let panel = NSSavePanel()
        panel.title = "保存完整 AI 报告"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = execution.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let citations = execution.references.map { "- [\($0.title.isEmpty ? $0.url : $0.title)](\($0.url))" }.joined(separator: "\n")
                try (report + (citations.isEmpty ? "" : "\n\n## 参考来源\n\n" + citations) + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct TaskFeedbackDraft {
    var text = ""
    var kind = ActionFeedbackKind.outcome
    var commandID = UUID().uuidString
    var expanded = false
}

struct WorkspaceTaskView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let action: ActionRecord
    @Binding var draft: TaskFeedbackDraft
    let openSource: (String) -> Void
    let openDelivery: (String) -> Void
    let discuss: () -> Void
    @State private var feedbackHistory: [ActionFeedbackRecord] = []
    @State private var delegating = false
    @State private var instruction = ""
    @State private var error = ""
    @State private var saving = false
    @State private var confirming = false
    @State private var settings: ReminderSnapshot?
    @State private var showingSettings = false
    @State private var scheduleAction: ActionRecord?
    @State private var replacementTitle = ""
    @State private var pauseReasons: [String] = []
    private var correctedClaim: CandidateClaim? {
        model.claims.first { $0.id == action.claimID && $0.validity == "current" && $0.reviewState != "rejected" && $0.reviewVersion > action.claimReviewVersion }
    }
    private var sources: [SourceRecord] {
        let ids = Set(model.claims.first { $0.id == action.claimID }?.references.map(\.sourceID) ?? [])
        return model.records.filter { ids.contains($0.id) }
    }
    private var executions: [AssistantExecutionRecord] { model.assistantExecutions.filter { $0.actionID == action.id } }
    private var current: Bool { action.validity == "current" && action.state != "dismissed" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                WorkspaceHeading(eyebrow: current ? (action.state == "completed" ? "行动 · 已完成" : action.kind == "task" ? "行动 · 待跟进" : "问题与目标") : model.workspaceActionStatus(action), title: action.title)
                if action.validity != "current" {
                    VStack(alignment:.leading,spacing:12) {
                        Label(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),systemImage:action.state == "completed" ? "checkmark.circle" : "pause.circle").font(.headline)
                        Text(action.state == "completed" ? "这项任务已有完成记录。AI 提取暂停不会撤销完成状态，也不需要你再完成一次。" : model.workspaceTaskRequiresReview(action) ? "AI 之前从材料中提取了这项待办，尚未登记完成；暂停也不代表识别有误。打开下方材料，查看具体原因及处理按钮。" : "这次提取仅作为历史保留。打开下方材料可查看最新识别的任务；本条记录的完成状态仍单独保留。").font(.callout).foregroundStyle(.secondary)
                        ForEach(pauseReasons,id:\.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                        ForEach(sources) { source in Button("打开材料：" + source.workspaceTitle) { openSource(source.id) } }
                        if model.workspaceTaskRequiresReview(action), let claim = correctedClaim {
                            Text("你更正后的观点").font(.subheadline.bold())
                            Text(claim.statement).textSelection(.enabled)
                            Text("若仍需做这件事，在下方写下准确的待办并保存；之前的任务及完成记录会保留。").font(.callout).foregroundStyle(.secondary)
                            TextField("要做的事情",text:$replacementTitle)
                            Button("保存为新的待办") { saveReplacement(claim) }.disabled(saving || replacementTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(palette.selection,in:RoundedRectangle(cornerRadius:12))
                }
                if let fields = action.intent?.reminderFields?.observed ?? action.intent?.reminderFields?.desired, !fields.summary.isEmpty { Label(fields.summary, systemImage: "calendar").font(.callout) }
                if current, action.kind == "task" {
                    VStack(alignment:.leading,spacing:8) {
                        if let link=model.reminderLinks.first(where: { $0.actionID == action.id }) {
                            Label(link.state == "linked" ? "已同步提醒事项并回读" : "提醒同步需要核对，保留原有尝试",systemImage:link.state == "linked" ? "checkmark.circle" : "exclamationmark.circle").font(.callout)
                        } else {
                            Text(model.reminderAccess?.enabled != true ? "待办已保存在 VoiceOS，连接提醒事项后可同步。" : model.reminderFieldsPending ? "正在核对日期与优先级，完成后同步所选清单。" : "待办已保存，等待同步到所选清单。").font(.callout).foregroundStyle(.secondary)
                        }
                        if model.reminderAccess?.enabled == true {
                            Text(model.reminderSyncStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("核对提醒同步") { Task { await model.refreshTaskReminders() } }.disabled(model.remindersBusy || model.reminderFieldsPending)
                        }
                    }
                }
                HStack {
                    if current, action.kind == "task" {
                        Button(action.state == "completed" ? "重新跟进" : "标记已完成") { changeState() }
                            .buttonStyle(.borderedProminent).disabled(model.savingAction || model.remindersBusy)
                    } else if current, action.intentActor == "user" { Button("核对为待办") { confirming = true } }
                    if current {
                        Button("继续思考", systemImage: "bubble.left.and.bubble.right", action: discuss)
                        if action.state == "open", action.intentActor == "user" {
                            Button("交给 AI", systemImage: "sparkles") { instruction = action.title + "\n\n请给出清晰的结论和可用的交付物；调研时附可核查的来源。"; delegating.toggle() }
                        }
                    }
                }
                if !action.note.isEmpty {
                    WorkspaceSection(title:"任务说明",icon:"text.alignleft") {
                        WorkspaceExpandableText(text:action.note,label:"完整说明",size:16).padding(.top,10)
                    }
                }
                if delegating {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("让 AI 推进这件事").font(.headline)
                        TextEditor(text: $instruction).frame(minHeight: 130).padding(8).background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
                        Text("发送后使用完整任务原文执行调研、比较或起草，结果自动保存。").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("收起") { delegating = false }
                            Spacer()
                            Button("开始代办") { delegate() }.buttonStyle(.borderedProminent).disabled(saving || !model.modelConfigured || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(18).background(palette.selection, in: RoundedRectangle(cornerRadius: 10))
                }
                if !executions.isEmpty {
                    WorkspaceSection(title:"AI 的工作与交付",icon:"sparkles",count:executions.count) {
                        ForEach(executions) { execution in
                            WorkspaceRow(title: execution.title, subtitle: assistantExecutionLabel(execution), icon: "sparkles", trailing: execution.state == "completed" ? "阅读结果" : "查看进度") { openDelivery(execution.id) }
                            if execution.id != executions.last?.id { Divider() }
                        }
                    }
                }
                if !feedbackHistory.isEmpty {
                    WorkspaceSection(title:"实际进展与收获",icon:"checkmark.circle",count:feedbackHistory.count) {
                        ForEach(feedbackHistory) { record in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(record.label + (record.actionVersion == action.version && record.sourceState != "frozen" ? "" : " · 历史记录")).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
                                WorkspaceExpandableText(text:record.text,label:"完整记录",size:16)
                                Button("查看结果原话") { openSource(record.recordingSourceID ?? record.sourceID) }.font(.system(size:13))
                            }.padding(.vertical,18)
                            if record.id != feedbackHistory.last?.id { Divider() }
                        }
                    }
                }
                WorkspaceSection(title:"记录与依据",icon:"quote.bubble") {
                    if current {
                        DisclosureGroup(action.state == "completed" ? "记录这次的结果或收获" : "记录实际进展", isExpanded: $draft.expanded) {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("记录类型", selection: $draft.kind) { Text("实际结果 / 进展").tag(ActionFeedbackKind.outcome); Text("我的反思").tag(ActionFeedbackKind.reflection) }.pickerStyle(.menu).disabled(model.savingFeedback)
                                TextEditor(text: $draft.text).frame(minHeight: 100).padding(8).background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
                                    .accessibilityLabel("实际进展与收获草稿").disabled(model.savingFeedback)
                                Text("本窗口内切页保留草稿；正式保存后才接回任务，关闭窗口前请保存。").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("口述进展或结果") { showingFeedback = true }
                                    Spacer()
                                    Button("保存并接回原任务") { saveFeedback() }.buttonStyle(.borderedProminent).disabled(model.savingFeedback || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }.padding(.top, 12)
                        }.padding(.vertical,16)
                        Divider()
                    }
                    DisclosureGroup("原话依据与安排") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(sources) { source in WorkspaceRow(title: source.workspaceTitle, subtitle: "查看完整原话与出处", icon: "quote.bubble") { openSource(source.id) } }
                            if current {
                                Button("回听任务原话") { Task { _ = await model.playActionOriginal(action) } }
                                if let player = model.player { NativePlayerView(player: player).frame(height: 65) }
                                if action.kind == "task", action.state == "open" {
                                    Button("日期、提醒与优先级") { Task { if let snapshot = await model.loadReminderSettings(action) { settings = snapshot; showingSettings = true } else { error = model.status } } }.disabled(model.remindersBusy)
                                }
                            }
                            scheduleSection
                        }.padding(.top, 10)
                    }.padding(.vertical,16)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }.frame(maxWidth: 820, alignment: .leading).padding(30).frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: action.id + String(action.version) + action.validity + sources.map { $0.id + String($0.policyVersion) + $0.state }.joined()) {
            guard action.validity != "current", let store = model.store else { pauseReasons = []; return }
            var reasons: [String] = []
            for source in sources {
                guard let pause = try? await store.understandingPause(sourceID: source.id) else { continue }
                if !reasons.contains(pause.summary) { reasons.append(pause.summary) }
            }
            pauseReasons = reasons
        }
        .task(id: action.id + String(action.version) + String(model.recentOutcomes.count)) { await loadFeedback() }
        .sheet(isPresented: $confirming) { ConfirmTaskView(action: action, model: model) { confirming = false } }
        .sheet(isPresented: $showingSettings) { if let settings { ReminderSettingsView(action: action, snapshot: settings, model: model) { showingSettings = false } } }
        .sheet(item: $scheduleAction) { action in ActionScheduleEditor(action: action, model: model) { scheduleAction = nil } }
        .sheet(isPresented: $showingFeedback, onDismiss: { Task { await loadFeedback() } }) { ActionFeedbackView(action: action, model: model) { showingFeedback = false } }
        .onDisappear { model.stopPlayback() }
        .onAppear { replacementTitle = action.title }
    }
    @State private var showingFeedback = false
    @ViewBuilder private var scheduleSection: some View {
        if action.kind == "task" {
            Button("设置本地期限选择") { scheduleAction = action }
                .disabled(model.savingAction || model.remindersBusy || action.validity != "current" || action.state != "open")
            if let schedule = model.scheduleIntents.first(where: { $0.actionID == action.id }) {
                Text((schedule.authority == .userCommitment ? "用户明确期限：" : "AI 弹性安排：") + schedule.due.summary).font(.caption)
                Text(schedule.baseOperationID != nil ? "外部期限基线：已应答并回读的 AI 弹性安排" : (schedule.baseAuthority == .externalManual ? "外部期限基线：人工或未确认归属，改动需具体确认" : (schedule.baseAuthority == .userCommitment ? "外部期限基线：明确承诺" : "外部期限基线：初始无期限或尚未绑定"))).font(.caption).foregroundStyle(.secondary)
                if let operation = model.scheduleOperations.first(where: { $0.intentID == schedule.id }) {
                    Text("排期操作：" + operation.state.summary).font(.caption)
                    Text(operation.reason).font(.caption).foregroundStyle(.secondary)
                    if operation.validity == "frozen" {
                        Text("迁移历史已冻结，不恢复外部操作。").font(.caption).foregroundStyle(.secondary)
                    } else if operation.attempted, operation.state == .unknown || operation.state == .conflict {
                        Button("只读核对改期结果") { Task { await model.reconcileSchedule(operation) } }
                            .disabled(model.remindersBusy || model.reminderAccess?.enabled != true)
                    }
                } else {
                    Text(schedule.eligibleForPlanning ? "本地排期意图，尚未执行外部改期。" : "排期保留为历史，当前暂停执行。").font(.caption).foregroundStyle(.secondary)
                    if let preview = model.schedulePreviews[schedule.id] {
                        Text("基于上次回读：" + preview.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.schedulePreviews[schedule.id]?.disposition == .writeFlexible,
                       let target = model.reminderLinks.first(where: { $0.actionID == action.id }), target.state == "linked" {
                        Button("执行普通弹性安排") { Task { await model.executeSchedule(schedule, link: target) } }
                            .disabled(model.remindersBusy || model.reminderAccess?.enabled != true || model.reminderCalendarID != target.calendarID)
                    }
                }
                if let grant = model.scheduleGrants.first(where: { $0.intentID == schedule.id }) {
                    Text(grant.revoked ? "本次改期确认已撤回" : (grant.validity == "frozen" ? "迁移确认仅作历史保留" : "已确认本次具体改期")).font(.caption).foregroundStyle(.secondary)
                    if grant.eligibleForExecution, let target = model.reminderLinks.first(where: { $0.actionID == action.id }) {
                        Button("执行已确认改期") { Task { await model.executeSchedule(schedule, link: target, grantID: grant.id) } }.disabled(model.remindersBusy)
                    }
                    if !grant.revoked, grant.validity == "current" {
                        Button("撤回本次改期确认") { Task { await model.revokeScheduleGrant(grant) } }
                    }
                } else if model.schedulePreviews[schedule.id]?.disposition == .requiresConfirmation,
                          let target = model.reminderLinks.first(where: { $0.actionID == action.id }),
                          !model.scheduleOperations.contains(where: { $0.intentID == schedule.id }) {
                    Button("查看具体改期并确认") { Task { await model.prepareScheduleEffect(schedule, link: target) } }.disabled(model.remindersBusy)
                }
                DisclosureGroup("排期依据") {
                    Text(schedule.rawExpression).font(.caption)
                    Text("表达时刻：" + schedule.anchorSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func saveReplacement(_ claim: CandidateClaim) {
        guard let store=model.store else { return }
        saving=true
        Task {
            defer { saving=false }
            do {
                let id = try await store.createAction(claimID:claim.id,expectedClaimReviewVersion:claim.reviewVersion,title:replacementTitle,kind:.task,note:"根据更正后的观点重新确认。",commandID:"workspace-reconfirm:" + action.id + ":" + String(claim.reviewVersion))
                await model.refresh();model.showTask(id)
                error=""
            } catch { self.error=error.localizedDescription }
        }
    }
    private func loadFeedback() async { feedbackHistory = (try? await model.store?.actionFeedback(actionID: action.id)) ?? [] }
    private func changeState() {
        let state:LocalActionState=action.state == "completed" ? .open : .completed
        Task {
            await model.changeAction(action,state:state)
            error=model.actionRecords.first { $0.id == action.id }?.state == state.rawValue ? "" : model.status
        }
    }
    private func saveFeedback() {
        let input = draft
        Task {
            if await model.saveFeedback(action, kind: input.kind, text: input.text, commandID: input.commandID) {
                if draft.commandID == input.commandID && draft.text == input.text && draft.kind == input.kind { draft = TaskFeedbackDraft() }
                error = ""; await loadFeedback()
            } else { error = model.status }
        }
    }
    private func delegate() {
        saving = true
        Task {
            let sourceIDs = Set(sources.map(\.id))
            let topicID = model.workspaceTopics.first { !(Set(model.workspaceTopicSources[$0.id] ?? []).intersection(sourceIDs)).isEmpty }?.id
            if await model.enqueueAssistant(action, instruction: instruction, questionID: topicID, allowCloud: true) { delegating = false; error = "" }
            else { error = model.assistantStatus }
            saving = false
        }
    }
}
