import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VoiceOSCore
import VoiceOSPlatform

struct WorkspaceDeliveryView: View {
    @Environment(\.workspacePalette) private var palette
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
                    Label("依据已变化，这份交付作为历史保留。", systemImage: "pause.circle").foregroundStyle(palette.warning)
                }
                if let report = execution.report, !report.isEmpty {
                    WorkspaceSection(title:"交付正文",subtitle:ConversationReflectionFocus.date(execution.createdAt)?.formatted(date:.abbreviated,time:.shortened) ?? "时间未知",icon:"doc.text",actionTitle:"保存报告…",action:{ export(report) }) {
                        AssistantReportView(report: report).padding(.top,14)
                    }
                    if !execution.references.isEmpty {
                        WorkspaceSection(title:"参考与来源",icon:"link",count:execution.references.count) {
                            DisclosureGroup("参考来源") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(execution.references.enumerated()), id: \.offset) { _, ref in
                                        if let url = URL(string: ref.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                            Link(ref.title.isEmpty ? ref.url : ref.title, destination: url)
                                            Text(ref.url).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled)
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
                if let message = execution.error, !message.isEmpty { WorkspaceNoticeText(message:message,severity:.danger) }
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
                        Text(ConversationReflectionFocus.date(execution.createdAt)?.formatted(date:.abbreviated,time:.shortened) ?? "时间未知").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    }.padding(.vertical,14)
                }
                if !error.isEmpty { WorkspaceNoticeText(message:error,severity:.danger) }
            }.frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading).padding(WorkspaceMetrics.pagePadding).frame(maxWidth: .infinity, alignment: .top)
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

private struct ActionOriginalQuotes: View {
    @ObservedObject var model: ControlCenter
    let action: ActionRecord
    let openSource: (String) -> Void
    private var references: [ClaimReference] {
        model.claims.first { $0.id == action.claimID }?.references ?? []
    }
    var body: some View {
        ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
            if let source = model.records.first(where: { $0.id == reference.sourceID }),
               source.transcriptVersionID == reference.transcriptVersionID,
               let span = source.spans.first(where: { $0.id == reference.spanID }),
               let transcript = source.transcript {
                VStack(alignment: .leading, spacing: 8) {
                    QuoteHoverPreview(sourceTitle: source.displayTitle, snippet: quote(span, text: transcript), open: { openSource(source.id) }) {
                        Text(source.displayTitle).vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(.secondary)
                    }
                    QuoteHoverPreview(sourceTitle: source.displayTitle, snippet: quote(span, text: transcript), open: { openSource(source.id) }) {
                        Text(quote(span, text: transcript)).vosFont(WorkspaceText.body).lineSpacing(4).textSelection(.enabled)
                    }
                    HStack(spacing: 14) {
                        Button("打开材料") { openSource(source.id) }
                            .accessibilityLabel("打开材料：" + source.displayTitle)
                        if let start = span.startMS, let end = span.endMS {
                            Button("回听这段原话", systemImage: "play.circle") { Task { _ = await model.playSpan(source, milliseconds: start, endMilliseconds: end) } }
                                .accessibilityLabel("回听这段原话：" + source.displayTitle)
                        }
                    }.vosFont(WorkspaceText.meta)
                }
            } else if let source = model.records.first(where: { $0.id == reference.sourceID }) {
                VStack(alignment: .leading, spacing: 6) {
                    QuoteHoverPreview(sourceTitle: source.displayTitle, snippet: "原话版本已变化，打开材料查看当前原文。", open: { openSource(source.id) }) {
                        Text(source.displayTitle).vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(.secondary)
                    }
                    Text("原话版本已变化，打开材料查看当前原文。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    Button("打开材料") { openSource(source.id) }.vosFont(WorkspaceText.meta)
                        .accessibilityLabel("打开材料：" + source.displayTitle)
                }
            } else {
                Text("来源已不可用。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            }
        }
    }
    private func quote(_ span: TranscriptSpan, text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard span.textStart >= 0, span.textEnd <= scalars.count, span.textStart < span.textEnd else { return "原文范围已变化" }
        return String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd]))
    }
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
    @State private var feedbackError: String?
    @State private var feedbackActionID = ""
    @State private var delegating = false
    @State private var instruction = ""
    @State private var error = ""
    @State private var saving = false
    @State private var confirming = false
    @State private var askingForResult = false
    @State private var confirmingDismiss = false
    @State private var confirmingReopen = false
    @State private var undoReopen = false
    @State private var settings: ReminderSnapshot?
    @State private var showingSettings = false
    @State private var scheduleAction: ActionRecord?
    @State private var replacementTitle = ""
    @State private var pauseReasons: [String] = []
    @State private var showingNextActionForm = false
    @State private var nextActionNotice = ""
    @State private var confirmingCompleteOutcome = false
    @State private var undoMessage: String?
    @State private var undoToken = UUID()
    @State private var subtasks: [ActionSubtask] = []
    @State private var subtaskTitle = ""
    @State private var actionEstimate: Int?
    @State private var planBusy = false
    @State private var recurrence: RecurrencePeriod?
    @State private var recurrenceBusy = false
    @State private var locationLabel: String?
    private var correctedClaim: CandidateClaim? {
        model.claims.first { $0.id == action.claimID && $0.validity == "current" && $0.reviewState != "rejected" && $0.reviewVersion > action.claimReviewVersion }
    }
    private var sources: [SourceRecord] {
        let ids = Set(model.claims.first { $0.id == action.claimID }?.references.map(\.sourceID) ?? [])
        return model.records.filter { ids.contains($0.id) }
    }
    private var executions: [AssistantExecutionRecord] { model.assistantExecutions.filter { $0.actionID == action.id } }
    private var current: Bool { action.validity == "current" && action.state != "dismissed" }
    private var eyebrow: String {
        if current {
            if action.state == "completed" { return "行动 · 已完成" }
            return action.kind == "task" ? "行动 · 待跟进" : "问题与目标"
        }
        if action.kind != "task", action.validity == "current" { return "问题与目标 · 已放下" }
        return model.workspaceActionStatus(action)
    }
    private var showsClarification: Bool {
        guard action.isExtracted, action.kind == "task", action.state == "open", action.validity == "current",
              action.parentID == nil,
              model.actionClarifications[action.id] == nil,
              let created = ConversationReflectionFocus.date(action.createdAt),
              created >= Date().addingTimeInterval(-14 * 24 * 60 * 60) else { return false }
        return true
    }
    private var reviewPairs: [ActionReviewPair] { model.actionReviewPairs(for: action) }
    private var nextActions: [ActionRecord] { model.actionRecords.filter { $0.parentID == action.id } }
    private var openNextActions: [ActionRecord] { nextActions.filter { $0.state == "open" } }
    private var subtaskSummary: String {
        guard !subtasks.isEmpty else { return "把任务拆成可勾选的小步。" }
        return "已完成 " + String(subtasks.filter(\.done).count) + "/" + String(subtasks.count)
    }
    private var hasDue: Bool {
        guard let due = action.intent?.reminderFields?.desired?.due else { return false }
        return due != .none
    }
    private var recurrenceEditable: Bool { action.state == "open" && hasDue }
    private var currentDue: ReminderDueDate? {
        if let due = model.reminderLinks.first(where: { $0.actionID == action.id && $0.state == "linked" })?.remoteDueDate, due != .none { return due }
        if let due = action.intent?.reminderFields?.desired?.due, due != .none { return due }
        return nil
    }
    private var recurrenceSelection: Binding<RecurrencePeriod?> {
        Binding(get: { self.recurrence }, set: { value in
            let previous = self.recurrence
            guard value != previous else { return }
            self.recurrence = value
            self.recurrenceBusy = true
            Task {
                defer { self.recurrenceBusy = false }
                do {
                    try await self.model.saveActionRecurrence(self.action.id, period: value)
                    self.error = ""
                } catch {
                    self.recurrence = previous
                    self.error = "保存重复失败：" + error.localizedDescription
                }
            }
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                WorkspaceHeading(eyebrow: eyebrow, title: StatementTagParser.split(action.title).text)
                if let recurrence {
                    HStack(spacing: 12) {
                        Label("重复 · " + recurrence.display, systemImage: "repeat").vosFont(WorkspaceText.meta)
                        if let due = currentDue { Text("当前到期 " + due.summary).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                    }
                }
                if current || actionEstimate != nil {
                    HStack(spacing: 14) {
                        Text("预计时长").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        ForEach([15, 30, 60], id: \.self) { minutes in
                            Button { setEstimate(minutes) } label: {
                                Label(String(minutes) + " 分钟", systemImage: actionEstimate == minutes ? "checkmark.circle.fill" : "circle").vosFont(WorkspaceText.meta)
                                    .frame(minHeight: WorkspaceMetrics.rowActionMinHeight)
                            }.buttonStyle(.borderless).disabled(!current || planBusy)
                        }
                        if actionEstimate != nil {
                            Button("清除") { clearEstimate() }.buttonStyle(.borderless).vosFont(WorkspaceText.meta)
                                .frame(minHeight: WorkspaceMetrics.rowActionMinHeight).disabled(!current || planBusy)
                        }
                    }
                }
                if showsClarification {
                    VStack(alignment:.leading,spacing:12) {
                        Text("这条行动来自你的原话。要把它当作承诺吗？").vosFont(WorkspaceText.body)
                        HStack(spacing:10) {
                            Button("这是我的承诺") { clarify(.commit) }.buttonStyle(.borderedProminent)
                            Button("放到问题与目标") { clarify(.opportunity) }
                            Button("不是") { clarify(.not) }
                        }.disabled(model.savingAction)
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(palette.selection,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.panelRadius))
                }
                if !reviewPairs.isEmpty {
                    VStack(alignment:.leading,spacing:12) {
                        ForEach(reviewPairs) { pair in ActionReviewResolutionControl(model:model,pair:pair) }
                    }
                    .padding(20).frame(maxWidth:.infinity,alignment:.leading)
                    .background(palette.selection,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.panelRadius))
                }
                if action.validity != "current" {
                    VStack(alignment:.leading,spacing:12) {
                        HStack(alignment:.center,spacing:12) {
                            Label(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),systemImage:action.state == "completed" ? "checkmark.circle" : "pause.circle").vosFont(WorkspaceText.meta.size, weight: .semibold)
                            WorkspaceExternalCompletionButton(model:model,action:action)
                        }
                        Text(action.state == "completed" ? "这项任务已有完成记录。AI 提取暂停不会撤销完成状态，也不需要你再完成一次。" : model.workspaceTaskRequiresReview(action) ? "AI 之前从材料中提取了这项待办，尚未登记完成；暂停也不代表识别有误。打开下方材料，查看具体原因及处理按钮。" : "这次提取仅作为历史保留。打开下方材料可查看最新识别的任务；本条记录的完成状态仍单独保留。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                        ForEach(pauseReasons,id:\.self) { Text($0).vosFont(WorkspaceText.body).foregroundStyle(.secondary) }
                        ForEach(sources) { source in Button("打开材料：" + source.displayTitle) { openSource(source.id) } }
                        if model.workspaceTaskRequiresReview(action), let claim = correctedClaim {
                            Text("你更正后的观点").vosFont(WorkspaceText.rowTitle).accessibilityAddTraits(.isHeader)
                            Text(claim.statement).textSelection(.enabled)
                            Text("若仍需做这件事，在下方写下准确的待办并保存；之前的任务及完成记录会保留。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                            TextField("要做的事情",text:$replacementTitle)
                            Button("保存为新的待办") { saveReplacement(claim) }.disabled(saving || replacementTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(palette.selection,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.panelRadius))
                }
                if let fields = action.intent?.reminderFields?.observed ?? action.intent?.reminderFields?.desired, !fields.summary.isEmpty { Label(fields.summary, systemImage: "calendar").vosFont(WorkspaceText.meta) }
                if let due = model.reminderLinks.first(where: { $0.actionID == action.id && $0.state == "linked" })?.remoteDueDate, due != .none {
                    let overdue = dueIsPast(due)
                    Label((overdue ? "已逾期 " : "到期 ") + due.summary, systemImage: "calendar").vosFont(WorkspaceText.meta)
                        .foregroundStyle(overdue ? palette.warning : palette.text)
                }
                if let locationLabel { Label("地点提醒 · " + locationLabel, systemImage: "mappin.and.ellipse").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                if current, action.kind == "task" {
                    VStack(alignment:.leading,spacing:8) {
                        Button("日期与提醒", systemImage: "calendar") { openReminderSettings() }
                            .disabled(model.savingAction || model.remindersBusy)
                        if let link=model.reminderLinks.first(where: { $0.actionID == action.id }) {
                            Label(link.state == "linked" ? "已同步提醒事项并回读" : "提醒同步需要核对，保留原有尝试",systemImage:link.state == "linked" ? "checkmark.circle" : "exclamationmark.circle").vosFont(WorkspaceText.meta)
                        } else {
                            Text(model.reminderAccess?.enabled != true ? "待办已保存在 VoiceOS，连接提醒事项后可同步。" : model.reminderFieldsPending ? "正在核对日期与优先级，完成后同步所选清单。" : "待办已保存，等待同步到所选清单。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        }
                        if model.reminderAccess?.enabled == true {
                            Text(model.reminderSyncStatus).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("核对提醒同步") { Task { await model.refreshTaskReminders() } }.disabled(model.remindersBusy || model.reminderFieldsPending)
                        }
                    }
                }
                HStack {
                    if current, action.kind == "task" {
                        Button(action.state == "completed" ? "重新跟进" : "标记已完成") { changeState() }
                            .buttonStyle(.borderedProminent).disabled(model.savingAction || model.remindersBusy)
                        if model.remindersBusy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在同步提醒事项，稍后可操作").vosFont(WorkspaceText.meta).foregroundStyle(palette.disabledText)
                            }.accessibilityElement(children: .combine)
                        }
                        if action.state == "open" {
                            Button("改天") { openReminderSettings() }.disabled(model.savingAction || model.remindersBusy)
                            Button("不再跟进", role: .destructive) { confirmingDismiss = true }.disabled(model.savingAction)
                        }
                    } else if action.canPromoteToTask {
                        Button("添加下一步") { showingNextActionForm = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.savingAction)
                            .accessibilityLabel("添加下一步：" + action.title)
                        Button("标记达成") { confirmingCompleteOutcome = true }
                            .disabled(model.savingAction)
                            .accessibilityLabel("标记达成：" + action.title)
                        Button("不再跟进", role: .destructive) { confirmingDismiss = true }
                            .disabled(model.savingAction)
                            .accessibilityLabel("不再跟进：" + action.title)
                    } else if action.validity == "current", action.state == "dismissed" {
                        Button("重新跟进") { confirmingReopen = true }.buttonStyle(.borderedProminent).disabled(model.savingAction)
                            .alert("重新跟进这条行动？", isPresented: $confirmingReopen) {
                                Button("重新跟进") { reopen() }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("会恢复为待办，历史记录保留。")
                            }
                    } else if current, action.intentActor == "user" { Button("核对为待办") { confirming = true } }
                    if current {
                        Button("继续思考", systemImage: "bubble.left.and.bubble.right", action: discuss)
                        if action.state == "open", action.intentActor == "user" {
                            if action.kind == "task" {
                                Button("交给 AI", systemImage: "sparkles") { instruction = action.title + "\n\n请给出清晰的结论和可用的交付物；调研时附可核查的来源。"; delegating.toggle() }
                            } else {
                                Button("让 VoiceOS 分析", systemImage: "text.magnifyingglass") { analyze() }
                                    .disabled(model.assistantBusy || !model.modelConfigured)
                            }
                        }
                    }
                }.alert(action.kind == "task" ? "不再跟进这项任务？" : "不再跟进这个目标？", isPresented: $confirmingDismiss) {
                    Button("不再跟进", role: .destructive) { stopFollowing() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(action.kind == "task" ? "会移入历史记录，之后仍可找回。Apple 提醒事项中的提醒需单独处理。" : "会移到历史记录，之后仍可找回；已经添加的下一步仍会保留。")
                }
                if action.kind != "task" { nextActionSection }
                if action.kind == "task" || recurrence != nil {
                    WorkspaceSection(title:"重复",subtitle:recurrence.map { "完成后按「" + $0.display + "」生成下一次行动。" } ?? "这次完成后不再生成新的行动。",icon:"repeat") {
                        HStack(spacing: 14) {
                            Picker("重复", selection: recurrenceSelection) {
                                Text("不重复").tag(RecurrencePeriod?.none)
                                ForEach(RecurrencePeriod.allCases, id: \.self) { period in Text(period.display).tag(Optional(period)) }
                            }.pickerStyle(.menu).labelsHidden().fixedSize().disabled(recurrenceBusy || !recurrenceEditable)
                            if !hasDue { Text("先设置日期").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                            else if action.state != "open" { Text("仅未完成的任务可调整重复。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
                            if recurrenceBusy { ProgressView().controlSize(.small) }
                        }.padding(.vertical, 12)
                    }
                }
                if current || !subtasks.isEmpty {
                    WorkspaceSection(title:"子任务",subtitle:subtaskSummary,icon:"checklist",count:subtasks.isEmpty ? nil : subtasks.count) {
                        ForEach(subtasks, id: \.id) { subtask in
                            HStack(spacing: 12) {
                                Button { toggleSubtask(subtask) } label: {
                                    Image(systemName: subtask.done ? "checkmark.circle.fill" : "circle")
                                        .vosFont(WorkspaceText.sectionTitle.size).foregroundStyle(subtask.done ? palette.accent : palette.secondaryText)
                                        .frame(width: WorkspaceMetrics.rowActionMinHeight, height: WorkspaceMetrics.rowActionMinHeight)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!current || planBusy)
                                    .accessibilityLabel(subtask.done ? "标为未完成" : "标为已完成")
                                Text(subtask.title).vosFont(WorkspaceText.body).lineSpacing(3).textSelection(.enabled)
                                    .strikethrough(subtask.done).foregroundStyle(subtask.done ? palette.secondaryText : palette.text)
                                Spacer(minLength: 8)
                                if current {
                                    Button { deleteSubtask(subtask) } label: {
                                        Image(systemName:"trash").vosFont(WorkspaceText.meta.size)
                                            .frame(width: WorkspaceMetrics.rowActionMinHeight, height: WorkspaceMetrics.rowActionMinHeight)
                                            .contentShape(Rectangle())
                                    }
                                        .buttonStyle(.borderless).foregroundStyle(palette.secondaryText)
                                        .accessibilityLabel("删除子任务").disabled(planBusy)
                                }
                            }.padding(.vertical, 10).padding(.horizontal, 4)
                            if subtask.id != subtasks.last?.id { Divider() }
                        }
                        if current {
                            HStack(spacing: 10) {
                                TextField("添加子任务", text: $subtaskTitle).textFieldStyle(.roundedBorder)
                                    .onSubmit { addSubtask() }
                                Button("添加") { addSubtask() }.buttonStyle(.borderedProminent)
                                    .disabled(planBusy || subtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }.padding(.top, 12)
                        }
                    }
                }
                if !action.note.isEmpty {
                    WorkspaceSection(title:"任务说明",icon:"text.alignleft") {
                        WorkspaceExpandableText(text:action.note,label:"完整说明",size:WorkspaceText.body.size).padding(.top,10)
                    }
                }
                if delegating {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("让 AI 推进这件事").vosFont(WorkspaceText.rowTitle).accessibilityAddTraits(.isHeader)
                        TextEditor(text: $instruction).frame(minHeight: 130).workspaceEditorSurface()
                        Text("发送后使用完整任务原文执行调研、比较或起草，结果自动保存。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        if !model.modelConfigured {
                            HStack(spacing:8) {
                                Text("开始代办需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                                Button("配置文本模型…") { model.chooseTextModel() }.vosFont(WorkspaceText.meta)
                            }
                        }
                        HStack {
                            Button("收起") { delegating = false }
                            Spacer()
                            Button("开始代办") { delegate() }.buttonStyle(.borderedProminent).disabled(saving || !model.modelConfigured || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(18).background(palette.selection, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                }
                if !executions.isEmpty {
                    WorkspaceSection(title:"AI 的工作与交付",icon:"sparkles",count:executions.count) {
                        ForEach(executions) { execution in
                            WorkspaceRow(title: execution.title, subtitle: assistantExecutionLabel(execution), icon: "sparkles", trailing: execution.state == "completed" ? "阅读结果" : "查看进度") { openDelivery(execution.id) }
                            if execution.id != executions.last?.id { Divider() }
                        }
                    }
                }
                if let feedbackError {
                    HStack(spacing:10) {
                        WorkspaceNoticeText(message:feedbackError,severity:.danger)
                        Button("重试") { Task { await loadFeedback() } }.vosFont(WorkspaceText.meta).buttonStyle(.borderless).accessibilityLabel("重试读取反馈历史")
                    }
                }
                if !feedbackHistory.isEmpty {
                    WorkspaceSection(title:"实际进展与收获",icon:"checkmark.circle",count:feedbackHistory.count) {
                        ForEach(feedbackHistory) { record in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(record.label + (record.actionVersion == action.version && record.sourceState != "frozen" ? "" : " · 历史记录")).vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(.secondary)
                                WorkspaceExpandableText(text:record.text,label:"完整记录",size:WorkspaceText.body.size)
                                Button("查看结果原话") { openSource(record.recordingSourceID ?? record.sourceID) }.vosFont(WorkspaceText.meta)
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
                                TextEditor(text: $draft.text).frame(minHeight: 100).workspaceEditorSurface()
                                    .accessibilityLabel("实际进展与收获草稿").disabled(model.savingFeedback)
                                Text("本窗口内切页保留草稿；正式保存后才接回任务，关闭窗口前请保存。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
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
                            ActionOriginalQuotes(model: model, action: action, openSource: openSource)
                            if current {
                                Button("回听任务原话") { Task { _ = await model.playActionOriginal(action) } }
                                if let player = model.player { NativePlayerView(player: player).frame(height: 65) }
                            }
                        }.padding(.top, 10)
                    }.padding(.vertical,16)
                    if action.kind == "task" {
                        Divider()
                        DisclosureGroup("处理记录与高级") {
                            VStack(alignment: .leading, spacing: 14) { scheduleSection }.padding(.top, 10)
                        }.padding(.vertical,16)
                    }
                }
                if !error.isEmpty { WorkspaceNoticeText(message:error,severity:.danger) }
            }.frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading).padding(WorkspaceMetrics.pagePadding).frame(maxWidth: .infinity, alignment: .top)
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
        .task(id: action.id + String(action.version)) { await loadPlan() }
        .task(id: action.id + String(action.version)) {
            recurrence = await model.actionRecurrence(action.id)
            locationLabel = await model.actionLocationLabel(action.id)
        }
        .sheet(isPresented: $confirming) { ConfirmTaskView(action: action, model: model) { confirming = false } }
        .sheet(isPresented: $showingSettings) { if let settings { ReminderSettingsView(action: action, snapshot: settings, model: model) { showingSettings = false } } }
        .sheet(item: $scheduleAction) { action in ActionScheduleEditor(action: action, model: model) { scheduleAction = nil } }
        .sheet(isPresented: $showingFeedback, onDismiss: { Task { await loadFeedback() } }) { ActionFeedbackView(action: action, model: model) { showingFeedback = false } }
        .sheet(isPresented: $showingNextActionForm) {
            NextActionFormSheet(model: model, outcome: action, onAdded: { _ in nextActionNotice = "已添加下一步" })
        }
        .alert("标记这个目标已达成？", isPresented: $confirmingCompleteOutcome) {
            Button("标记达成") { completeOutcome() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("目标会移到已完成，已经添加的下一步不受影响。")
        }
        .alert("已完成。要记一句结果吗？", isPresented: $askingForResult) {
            Button("记录结果") { showingFeedback = true }
            Button("完成", role: .cancel) {}
        } message: { Text("结果会接回这条任务，不会自动生成记录。") }
        .onDisappear { model.stopPlayback() }
        .onAppear { replacementTitle = action.title }
        .overlay(alignment: .bottom) {
            if let undoMessage {
                HStack(spacing: 12) {
                    Text(undoMessage).vosFont(WorkspaceText.meta.size, weight: .medium)
                    Button("撤销") { undo() }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(palette.selection, in: Capsule())
                .overlay { Capsule().strokeBorder(palette.border) }
                .padding(.bottom, 24)
            }
        }
        .task(id: undoToken) {
            guard undoMessage != nil else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            undoMessage = nil
        }
    }
    @State private var showingFeedback = false
    @ViewBuilder private var scheduleSection: some View {
        if action.kind == "task" {
            Button("改到某天") { scheduleAction = action }
                .disabled(model.savingAction || model.remindersBusy || action.validity != "current" || action.state != "open")
            if let schedule = model.scheduleIntents.first(where: { $0.actionID == action.id }) {
                Text((schedule.authority == .userCommitment ? "你确认的日期：" : "AI 建议的日期：") + schedule.due.summary).vosFont(WorkspaceText.meta)
                Text(schedule.baseOperationID != nil ? "同步基准：上次写入后已回读" : (schedule.baseAuthority == .externalManual ? "同步基准：手动修改或来源不明，改动前会再次确认" : (schedule.baseAuthority == .userCommitment ? "同步基准：已确认的承诺日期" : "同步基准：还没有写入提醒事项"))).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                if let operation = model.scheduleOperations.first(where: { $0.intentID == schedule.id }) {
                    Text("上次改期：" + operation.state.summary).vosFont(WorkspaceText.meta)
                    Text(operation.reason).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    if operation.validity == "frozen" {
                        Text("历史记录已冻结，不再写入。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    } else if operation.attempted, operation.state == .unknown || operation.state == .conflict {
                        Button("只读核对") { Task { await model.reconcileSchedule(operation) } }
                            .disabled(model.remindersBusy || model.reminderAccess?.enabled != true)
                    }
                } else {
                    Text(schedule.eligibleForPlanning ? "本地已选日期，还没有写入提醒事项。" : "已暂停写入，记录保留。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    if let preview = model.schedulePreviews[schedule.id] {
                        Text("上次核对：" + preview.reason).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    }
                    if model.schedulePreviews[schedule.id]?.disposition == .writeFlexible,
                       let target = model.reminderLinks.first(where: { $0.actionID == action.id }), target.state == "linked" {
                        Button("写入 Apple 提醒事项") { Task { await model.executeSchedule(schedule, link: target) } }
                            .disabled(model.remindersBusy || model.reminderAccess?.enabled != true || model.reminderCalendarID != target.calendarID)
                    }
                }
                if let grant = model.scheduleGrants.first(where: { $0.intentID == schedule.id }) {
                    Text(grant.revoked ? "本次改期确认已撤回" : (grant.validity == "frozen" ? "这次确认仅作历史保留" : "已确认这次改期")).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    if grant.eligibleForExecution, let target = model.reminderLinks.first(where: { $0.actionID == action.id }) {
                        Button("按确认的日期写入") { Task { await model.executeSchedule(schedule, link: target, grantID: grant.id) } }.disabled(model.remindersBusy)
                    }
                    if !grant.revoked, grant.validity == "current" {
                        Button("撤回这次改期确认") { Task { await model.revokeScheduleGrant(grant) } }
                    }
                } else if model.schedulePreviews[schedule.id]?.disposition == .requiresConfirmation,
                          let target = model.reminderLinks.first(where: { $0.actionID == action.id }),
                          !model.scheduleOperations.contains(where: { $0.intentID == schedule.id }) {
                    Button("核对这次改期并确认") { Task { await model.prepareScheduleEffect(schedule, link: target) } }.disabled(model.remindersBusy)
                }
                DisclosureGroup("原话里的日期") {
                    Text(schedule.rawExpression).vosFont(WorkspaceText.meta)
                    Text("记录于：" + schedule.anchorSummary).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder private var nextActionSection: some View {
        WorkspaceSection(title: "下一步",
                         subtitle: openNextActions.isEmpty ? "这个目标还没有下一步。" : "还有 \(openNextActions.count) 个下一步未完成。",
                         icon: "arrow.turn.down.right", count: nextActions.isEmpty ? nil : nextActions.count) {
            ForEach(nextActions) { child in
                HStack(spacing: 12) {
                    Button { toggleNextAction(child) } label: {
                        Image(systemName: child.state == "completed" ? "checkmark.circle.fill" : "circle")
                            .vosFont(WorkspaceText.sectionTitle.size)
                            .foregroundStyle(child.state == "completed" ? palette.accent : palette.secondaryText)
                            .frame(width: WorkspaceMetrics.rowActionMinHeight, height: WorkspaceMetrics.rowActionMinHeight)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.savingAction || child.state == "dismissed")
                        .accessibilityLabel(child.state == "completed" ? "重新打开下一步：" + child.title : "完成下一步：" + child.title)
                    Text(child.title).vosFont(WorkspaceText.body).lineSpacing(3).textSelection(.enabled)
                        .strikethrough(child.state == "completed").foregroundStyle(child.state == "completed" ? palette.secondaryText : palette.text)
                    Spacer(minLength: 8)
                    Button("摘除") { detachNextAction(child) }
                        .buttonStyle(.borderless).vosFont(WorkspaceText.meta)
                        .frame(minHeight: WorkspaceMetrics.rowActionMinHeight)
                        .disabled(model.savingAction)
                        .accessibilityLabel("摘除下一步：" + child.title)
                }.padding(.vertical, 10).padding(.horizontal, 4)
                if child.id != nextActions.last?.id { Divider() }
            }
            if !nextActionNotice.isEmpty {
                Label(nextActionNotice, systemImage: "checkmark.circle").vosFont(WorkspaceText.meta)
                    .foregroundStyle(palette.success).padding(.top, 8)
            }
        }
    }
    private func completeOutcome() {
        Task {
            if await model.completeOutcome(action) { error = ""; nextActionNotice = "" }
            else { error = model.status }
        }
    }
    private func toggleNextAction(_ child: ActionRecord) {
        let target: LocalActionState = child.state == "completed" ? .open : .completed
        Task {
            await model.changeAction(child, state: target)
            if model.actionRecords.first(where: { $0.id == child.id })?.state != target.rawValue { error = model.status }
        }
    }
    private func detachNextAction(_ child: ActionRecord) {
        Task {
            if await model.detachNextAction(child) { error = "" } else { error = model.status }
        }
    }
    private func clarify(_ decision: ActionClarificationDecision) {
        Task { if await model.clarifyAction(action, decision: decision) { error = "" } else { error = model.status } }
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
    private func loadFeedback() async {
        if feedbackActionID != action.id { feedbackActionID = action.id; feedbackHistory = [] }
        guard let store = model.store else { feedbackError = "资料库尚未打开，无法读取反馈历史"; return }
        do { feedbackHistory = try await store.actionFeedback(actionID: action.id); feedbackError = nil }
        catch { feedbackError = "读取反馈历史失败：" + error.localizedDescription }
    }
    private func loadPlan() async {
        guard let store = model.store else { error = "资料库尚未打开，无法读取子任务"; return }
        do {
            subtasks = try await store.subtasks(actionID: action.id)
            let estimates = try await store.actionEstimates()
            actionEstimate = estimates[action.id]
        } catch { self.error = "读取子任务失败：" + error.localizedDescription }
    }
    private func addSubtask() {
        let title = subtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        planBusy = true
        Task {
            defer { planBusy = false }
            guard let store = model.store else { error = "资料库尚未打开"; return }
            do {
                _ = try await store.addSubtask(actionID: action.id, title: title)
                subtasks = try await store.subtasks(actionID: action.id)
                subtaskTitle = ""
                error = ""
            } catch { self.error = "添加子任务失败：" + error.localizedDescription }
        }
    }
    private func toggleSubtask(_ subtask: ActionSubtask) {
        planBusy = true
        Task {
            defer { planBusy = false }
            guard let store = model.store else { error = "资料库尚未打开"; return }
            do {
                _ = try await store.setSubtaskDone(id: subtask.id, done: !subtask.done)
                subtasks = try await store.subtasks(actionID: action.id)
                error = ""
            } catch { self.error = "更新子任务失败：" + error.localizedDescription }
        }
    }
    private func deleteSubtask(_ subtask: ActionSubtask) {
        planBusy = true
        Task {
            defer { planBusy = false }
            guard let store = model.store else { error = "资料库尚未打开"; return }
            do {
                _ = try await store.deleteSubtask(id: subtask.id)
                subtasks = try await store.subtasks(actionID: action.id)
                error = ""
            } catch { self.error = "删除子任务失败：" + error.localizedDescription }
        }
    }
    private func setEstimate(_ minutes: Int) {
        planBusy = true
        Task {
            defer { planBusy = false }
            guard let store = model.store else { error = "资料库尚未打开"; return }
            do {
                _ = try await store.setActionEstimate(actionID: action.id, minutes: minutes)
                actionEstimate = minutes
                error = ""
            } catch { self.error = "保存预计时长失败：" + error.localizedDescription }
        }
    }
    private func clearEstimate() {
        planBusy = true
        Task {
            defer { planBusy = false }
            guard let store = model.store else { error = "资料库尚未打开"; return }
            do {
                _ = try await store.clearActionEstimate(actionID: action.id)
                actionEstimate = nil
                error = ""
            } catch { self.error = "清除预计时长失败：" + error.localizedDescription }
        }
    }
    private func changeState() {
        let state:LocalActionState=action.state == "completed" ? .open : .completed
        Task {
            let receipt = await model.changeAction(action,state:state)
            guard model.actionRecords.first(where: { $0.id == action.id })?.state == state.rawValue else { error=model.status; return }
            error=""
            if state == .completed {
                showUndo("已完成" + (await model.recurrenceDueLabel(receipt?.successorID)))
                await loadFeedback()
                if feedbackHistory.isEmpty { askingForResult = true }
            } else {
                undoMessage = nil
            }
        }
    }
    private func openReminderSettings() {
        Task { if let snapshot = await model.loadReminderSettings(action) { settings = snapshot; showingSettings = true } else { error = model.status } }
    }
    private func stopFollowing() {
        Task {
            await model.changeAction(action, state: .dismissed)
            if model.actionRecords.first(where: { $0.id == action.id })?.state == LocalActionState.dismissed.rawValue { error = "";showUndo("已不再跟进") }
            else { error = model.status }
        }
    }
    private func reopen() {
        Task {
            await model.changeAction(action, state: .open)
            if model.actionRecords.first(where: { $0.id == action.id })?.state == LocalActionState.open.rawValue { error = "";showUndo("已重新跟进");undoReopen = true }
            else { error = model.status }
        }
    }
    private func showUndo(_ message:String) {
        undoReopen = false
        undoMessage = message
        undoToken = UUID()
    }
    private func undo() {
        let id = action.id
        if undoReopen {
            undoReopen = false
            undoMessage = nil
            Task {
                await model.changeAction(action, state: .dismissed)
                if model.actionRecords.first(where: { $0.id == id })?.state != LocalActionState.dismissed.rawValue { error = model.status }
            }
            return
        }
        Task {
            if await model.undoActionState(actionID: id) { undoMessage = nil }
            else { error = model.status }
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
    private func analyze() {
        Task {
            if await model.analyzeThought(action) { error = "" }
            else { error = model.assistantStatus }
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
    private func dueIsPast(_ due: ReminderDueDate) -> Bool {
        switch due {
        case .none: return false
        case let .instant(utc, _):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: utc) { return date < Date() }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: utc) else { return false }
            return date < Date()
        case let .dateOnly(localDate, zone):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return localDate < formatter.string(from: Date())
        }
    }
}

extension ControlCenter {
    func actionRecurrence(_ actionID: String) async -> RecurrencePeriod? {
        guard let store else { return nil }
        return ((try? await store.actionRecurrences()) ?? [:])[actionID]
    }
    func saveActionRecurrence(_ actionID: String, period: RecurrencePeriod?) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        if let period { try await store.setRecurrence(actionID: actionID, period: period) }
        else { try await store.clearRecurrence(actionID: actionID) }
    }
    func actionLocationLabel(_ actionID: String) async -> String? {
        guard let link = reminderLinks.first(where: { $0.actionID == actionID && $0.state == "linked" }), let externalID = link.externalID else { return nil }
        return await NativeReminders.structuredLocationLabel(externalID: externalID)
    }
}

/// Adds a next action under an outcome. One form session keeps one command id,
/// so a retry after a failed attach reuses the created task instead of creating
/// a second one. `submitNextAction` and `retryNextActionAttach` below carry the
/// command; the attach retry never creates a task.
struct NextActionFormSheet: View {
    @ObservedObject var model: ControlCenter
    let outcome: ActionRecord
    var onAdded: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var sessionID = UUID().uuidString
    @State private var createdActionID: String?
    @State private var error = ""
    @State private var busy = false

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sessionCommandID: String {
        "next-action:" + outcome.id + ":" + trimmedTitle + ":" + sessionID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加下一步").vosFont(WorkspaceText.rowTitle).accessibilityAddTraits(.isHeader)
            Text("下一步会挂在这个目标下，目标本身保留。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            TextField("下一步要做的事", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
                .disabled(busy || createdActionID != nil)
                .accessibilityLabel("下一步标题")
            if createdActionID != nil {
                WorkspaceNoticeText(message: "下一步已创建，但未能挂到目标。重试只挂接，不会新建待办。", severity: .warning)
            }
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
            HStack {
                Button("取消") { dismiss() }.disabled(busy)
                Spacer()
                if createdActionID != nil {
                    Button("重试挂接") { retryAttach() }.buttonStyle(.borderedProminent).disabled(busy)
                        .accessibilityLabel("重试挂接下一步")
                } else {
                    Button("添加") { submit() }.buttonStyle(.borderedProminent)
                        .disabled(busy || trimmedTitle.isEmpty)
                        .accessibilityLabel("确认添加下一步")
                }
            }
        }.padding(24).frame(width: 420)
    }

    private func submit() {
        guard !trimmedTitle.isEmpty, !busy, createdActionID == nil else { return }
        busy = true
        error = ""
        let commandID = sessionCommandID
        Task {
            defer { busy = false }
            guard let id = await model.submitNextAction(outcome: outcome, title: trimmedTitle, commandID: commandID) else {
                error = model.status
                return
            }
            if model.actionRecords.first(where: { $0.id == id })?.parentID == outcome.id {
                onAdded(trimmedTitle)
                dismiss()
            } else {
                createdActionID = id
            }
        }
    }

    private func retryAttach() {
        guard let id = createdActionID, !busy else { return }
        busy = true
        error = ""
        Task {
            defer { busy = false }
            if await model.retryNextActionAttach(outcomeID: outcome.id, actionID: id, commandID: sessionCommandID) {
                onAdded(trimmedTitle)
                dismiss()
            } else {
                error = model.status
            }
        }
    }
}

extension ControlCenter {
    /// Form-session command for adding a next action: create once, attach once.
    /// The caller keeps `commandID` stable, so resubmitting after an attach
    /// failure returns the task already created instead of making a second one.
    func submitNextAction(outcome: ActionRecord, title: String, commandID: String) async -> String? {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return nil }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { status = "下一步不能为空"; return nil }
        savingAction = true; defer { savingAction = false }
        do {
            let id = try await store.createAction(claimID: outcome.claimID, expectedClaimReviewVersion: outcome.claimReviewVersion,
                                                  title: clean, kind: .task, commandID: commandID)
            await refresh()
            if actionRecords.first(where: { $0.id == id })?.parentID == outcome.id {
                status = "已添加下一步"
                return id
            }
            do {
                _ = try await store.attachNextAction(outcomeID: outcome.id, actionID: id, commandID: commandID)
            } catch {
                await refresh()
                status = "下一步已创建，但未能挂到目标：" + error.localizedDescription
                return id
            }
            await refresh()
            guard actionRecords.first(where: { $0.id == id })?.parentID == outcome.id else {
                status = "下一步已创建，但未能挂到目标，请重试挂接。"
                return id
            }
            status = "已添加下一步"
            return id
        } catch {
            status = error.localizedDescription
            await refresh()
            return nil
        }
    }
    /// Retries the attach half of a form-session command. Same `commandID` as the
    /// create, so the store returns the existing receipt instead of a second task.
    func retryNextActionAttach(outcomeID: String, actionID: String, commandID: String) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.attachNextAction(outcomeID: outcomeID, actionID: actionID, commandID: commandID)
            await refresh()
            guard actionRecords.first(where: { $0.id == actionID })?.parentID == outcomeID else {
                status = "下一步仍未能挂到目标，请稍后重试"
                return false
            }
            status = "已添加下一步"
            return true
        } catch {
            status = error.localizedDescription
            await refresh()
            return false
        }
    }
}
