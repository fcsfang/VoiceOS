import SwiftUI
import VoiceOSCore

struct DailyWorkbenchView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @ObservedObject var inbox: RecordingInbox
    let dismiss: () -> Void
    @State private var showingTasks = false
    @State private var showingGoals = false
    @State private var showingInbox = false
    @State private var showingOutcomes = false
    @State private var assistantSelection: AssistantSheetSelection?
    @State private var feedbackAction: ActionRecord?
    @State private var nextFeedback: ActionRecord?
    @State private var nextTask: ActionRecord?

    private var tasks: [ActionRecord] { model.actionRecords.filter { $0.kind == "task" && $0.state == "open" && $0.validity == "current" && !model.workspaceTaskRequiresReview($0) } }
    private func fields(_ action: ActionRecord) -> ReminderFields? {
        let receipt = action.intent?.reminderFields
        if model.reminderLinks.contains(where: { $0.actionID == action.id }) { return receipt?.observed }
        return receipt?.desired
    }
    private func day(_ action: ActionRecord) -> String? {
        switch fields(action)?.due {
        case let .dateOnly(text, _): return text
        case let .instant(text, zone):
            guard let date = ReminderFields.date(text) else { return nil }
            let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: zone); formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        default: return nil
        }
    }
    private var scheduled: [ActionRecord] {
        tasks.filter { day($0) != nil }.sorted {
            let left = day($0)!, right = day($1)!
            if left != right { return left < right }
            let lp = fields($0)?.priority ?? 0, rp = fields($1)?.priority ?? 0
            if lp != rp { return (lp == 0 ? 10 : lp) < (rp == 0 ? 10 : rp) }
            return $0.title < $1.title
        }
    }
    private var today: String { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: Date()) }
    private var plans: [(RecordingFollowupReceipt, GoalPlan)] {
        var seen = Set<String>(), result: [(RecordingFollowupReceipt, GoalPlan)] = []
        for receipt in model.recordingFollowups.reversed() {
            for plan in receipt.result?.goalPlans ?? [] where model.followupValidity[receipt.id]?.goalIsCurrent(plan.goalID) == true && seen.insert(plan.goalID).inserted { result.append((receipt, plan)) }
        }
        return result
    }
    private var goalsWithoutPlans: [ActionRecord] {
        let planned = Set(plans.map { $0.1.goalID })
        return model.actionRecords.filter {
            $0.validity == "current" && $0.state == "open" && $0.intent?.intentType == "goal" &&
            $0.intent?.uncertain == false && !planned.contains($0.id)
        }
    }
    private var latestFollowups: [RecordingFollowupReceipt] {
        var seen = Set<String>()
        return model.recordingFollowups.reversed().filter { seen.insert($0.sourceID).inserted }
    }
    private var unfinishedFollowups: [RecordingFollowupReceipt] { latestFollowups.filter { $0.state == "queued" || $0.state == "running" } }
    private var failedFollowups: [RecordingFollowupReceipt] { latestFollowups.filter { $0.state == "failed" } }
    private var understandingPending: Bool { model.processingIntents.contains { $0.state == .queued || $0.state == .running } || model.recordingRequests.contains { $0.state == "waiting" } }
    private func sourceName(_ id: String) -> String { model.records.first(where: { $0.id == id })?.displayTitle ?? "历史录音" }
    private func goalSource(_ goal: ActionRecord) -> SourceRecord? {
        let claim = model.currentClaimsBySource.values.flatMap { $0 }.first { $0.id == goal.claimID }
        let prior = model.recordingFollowups.reversed().lazy.compactMap { $0.input.goals.first { $0.id == goal.id } }.first
        let ids = Set(claim?.references.map(\.sourceID) ?? prior?.thought.evidence.map { $0.reference.sourceID } ?? [])
        return model.records.first { ids.contains($0.id) && $0.origin == "user" && $0.speaker == "user" && !$0.localOnly && $0.transcript != nil }
    }
    private var awaitingInput: Int { inbox.pendingItems.filter { $0.state == .needsAttention }.count + inbox.folderErrors.count }
    private func openTask(_ action: ActionRecord) { model.focusedTaskID = action.id; showingTasks = true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("现在该推进什么").font(.title2)
                    Text("已有安排、目标下一步与完成后的结果，集中放在这里。").foregroundStyle(.secondary)
                }
                Spacer(); Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if awaitingInput > 0 || !inbox.pendingItems.isEmpty || !inbox.folders.isEmpty {
                        HStack {
                            Label(awaitingInput > 0 ? "自动入口有 \(awaitingInput) 项需要查看" : "自动入口", systemImage: "tray.and.arrow.down")
                            Text(inbox.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(); Button("查看处理状态") { showingInbox = true }
                        }
                    }
                    backgroundProgress
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label("AI 助理", systemImage: "sparkles").font(.headline)
                            Spacer()
                            Button("查看代办与成果") { assistantSelection = AssistantSheetSelection(executionID: nil) }
                        }
                        if model.assistantExecutions.isEmpty {
                            Text("调研、比较与起草可以交给 AI。在任务中编辑交付要求，明确委托后，应用会继续处理。").font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(model.assistantExecutions.filter { $0.state != "cancelled" }.prefix(4))) { execution in
                                HStack(alignment: .top) {
                                    Image(systemName: execution.state == "completed" ? "doc.text" : execution.state == "failed" ? "exclamationmark.circle" : "hourglass")
                                        .foregroundStyle(palette.accent)
                                    Text(execution.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(assistantExecutionLabel(execution)).font(.caption).foregroundStyle(.secondary)
                                    Button(execution.state == "completed" ? "查看成果" : "查看状态") { assistantSelection = AssistantSheetSelection(executionID: execution.id) }
                                }
                            }
                        }
                        Text("AI 交付后，实际任务与个人判断仍由你确认。").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.assistantAssessmentIssues) { issue in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(issue.title).lineLimit(2)
                                    Text("尚未确认是否为 AI 委托 · " + issue.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("重试识别") { Task { await model.retryAssistantAssessment(issue) } }
                                    .disabled(model.assistantBusy || !model.modelConfigured)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已安排的待办").font(.headline)
                        if scheduled.isEmpty { Text("还没有明确日期的待办。未安排事项仍在任务清单中。").foregroundStyle(.secondary) }
                        ForEach(scheduled) { action in
                            HStack(alignment: .top) {
                                Text(day(action)!).font(.caption.monospacedDigit()).foregroundStyle(day(action)! < today ? .orange : .secondary)
                                if day(action)! < today { Text("已过安排日期").font(.caption).foregroundStyle(.orange) }
                                Text(action.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Button("查看待办") { openTask(action) }
                            }.padding(.vertical, 4)
                        }
                        Button("浏览全部待办（\(tasks.count)）") { showingTasks = true }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("目标下一步").font(.headline)
                            Spacer(); Button("查看阶段与依据") { showingGoals = true }
                        }
                        Text("这些是已有目标的建议；选择后才成为待办。").font(.caption).foregroundStyle(.secondary)
                        if plans.isEmpty && goalsWithoutPlans.isEmpty { Text("新的目标整理完成后，下一步会出现在这里。").foregroundStyle(.secondary) }
                        ForEach(Array(plans.enumerated()), id: \.offset) { _, pair in
                            let receipt = pair.0, plan = pair.1
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(receipt.input.goals.first(where: { $0.id == plan.goalID })?.title.replacingOccurrences(of: "【长期目标】", with: "") ?? plan.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text(plan.nextStep.title).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Button(plan.nextStep.existingTaskID.isEmpty ? "选为待办" : "查看待办") {
                                        Task { await model.activateStep(plan.nextStep, plan: plan, receipt: receipt) }
                                    }.disabled(model.savingAction)
                                }
                                if !plan.nextStep.condition.isEmpty {
                                    DisclosureGroup("执行条件") { Text(plan.nextStep.condition).textSelection(.enabled) }.font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6)
                        }
                        ForEach(goalsWithoutPlans) { goal in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(goal.title.replacingOccurrences(of: "【长期目标】", with: "")).lineLimit(2)
                                    Text(goalSource(goal) == nil ? "目标仍保留；当前来源尚不能用于生成建议。" : "进展已变化或尚未生成，等待更新下一步。").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if let source = goalSource(goal) {
                                    let pending = unfinishedFollowups.contains { $0.sourceID == source.id }
                                    Button(pending ? "更新已排队" : "更新下一步") { model.refreshFollowup(source.id) }
                                        .disabled(pending || !model.modelConfigured)
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("完成后的结果与收获").font(.headline)
                        Text("\(model.visibleOutcomeFollowups.count) 项可以补一句结果；普通事务也可以直接跳过。").foregroundStyle(.secondary)
                        HStack {
                            Button("记录结果或选择跳过") { showingOutcomes = true }
                            if model.outcomeFollowups.count > model.visibleOutcomeFollowups.count {
                                Button("重新显示已跳过事项") { model.showSkippedOutcomes() }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(24).frame(width: 920, height: 700)
        .sheet(isPresented: $showingTasks) { TaskManagerView(model: model) { showingTasks = false } }
        .sheet(item: $assistantSelection) { selection in AssistantExecutionView(model: model, initialExecutionID: selection.executionID) { assistantSelection = nil } }
        .sheet(isPresented: $showingGoals) { RecordingFollowupView(model: model, initialTab: "goals") { showingGoals = false } }
        .sheet(isPresented: $showingInbox) { RecordingInboxView(inbox: inbox, model: model) { showingInbox = false } }
        .sheet(isPresented: $showingOutcomes, onDismiss: {
            if let next = nextFeedback { nextFeedback = nil; feedbackAction = next }
            if let next = nextTask { nextTask = nil; openTask(next) }
        }) {
            OutcomeFollowupView(actions: model.visibleOutcomeFollowups,
                                onRecord: { nextFeedback = $0; showingOutcomes = false },
                                onOpen: { nextTask = $0; showingOutcomes = false },
                                onSkip: model.skipOutcome,
                                onDone: { showingOutcomes = false })
        }
        .sheet(item: $feedbackAction) { action in ActionFeedbackView(action: action, model: model) { feedbackAction = nil } }
    }

    @ViewBuilder private var backgroundProgress: some View {
        if model.fullRecordingBusy || model.understandingSource != nil || understandingPending || model.followupBusy || !unfinishedFollowups.isEmpty || !failedFollowups.isEmpty || model.reminderAccess?.enabled == true {
            VStack(alignment: .leading, spacing: 7) {
                Text("自动处理").font(.headline)
                if model.fullRecordingBusy {
                    HStack { ProgressView().controlSize(.small); Text(model.fullRecordingStatus.isEmpty ? "正在完整转写与整理录音" : model.fullRecordingStatus).lineLimit(2) }
                } else if let sourceID = model.understandingSource {
                    HStack { ProgressView().controlSize(.small); Text("正在理解：" + sourceName(sourceID)).lineLimit(1) }
                } else if understandingPending {
                    Label("文字理解已排队，应用会继续处理", systemImage: "hourglass")
                }
                if model.followupBusy {
                    HStack { ProgressView().controlSize(.small); Text(model.followupStatus).lineLimit(2) }
                } else if !unfinishedFollowups.isEmpty {
                    Label("\(unfinishedFollowups.count) 份思想与目标跟进等待继续", systemImage: "hourglass")
                }
                if model.reminderAccess?.enabled == true {
                    Label(model.reminderSyncStatus, systemImage: model.remindersBusy ? "arrow.triangle.2.circlepath" : "checklist").lineLimit(2)
                }
                ForEach(failedFollowups) { receipt in
                    HStack(alignment: .top) {
                        DisclosureGroup {
                            Text(receipt.error ?? "自动跟进尚未完成，录音与任务已保存。").textSelection(.enabled)
                        } label: {
                            Text(sourceName(receipt.sourceID) + (receipt.retryAt != nil ? " · 将自动重试" : " · 跟进待重试")).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("立即重试") { model.refreshFollowup(receipt.sourceID) }.disabled(!model.modelConfigured)
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
