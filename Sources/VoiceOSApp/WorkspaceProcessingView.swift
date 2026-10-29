import SwiftUI
import VoiceOSCore

struct WorkspaceProcessingActivity {
    let sourceID: String
    let label: String
}

extension ControlCenter {
    var workspaceProcessingTitle: String? {
        if !initialized { return startupIssue.isEmpty ? "正在恢复资料库与草稿" : nil }
        if dictationActive { return "正在录音，停止后保存并整理" }
        if fullRecordingBusy { return fullRecordingStatus.isEmpty ? "正在完整整理录音" : fullRecordingStatus }
        if dictationBusy { return "正在封存录音与转写" }
        if transcriptReviewSourceID != nil { return "AI 正在校正完整转写" }
        if let activity = processingActivity { return activity.label }
        if understandingSource != nil { return "正在理解当前材料" }
        if discussionSending { return "正在回复讨论" }
        if discussionExtracting { return "正在整理讨论成果" }
        if knowledgeReviewBusy { return "正在核查知识理解" }
        if assistantBusy { return "AI 正在执行代办" }
        if followupBusy { return "正在接续思想与目标" }
        if organizingTopics { return "正在连接主题与更新简报" }
        if remindersBusy { return "正在同步提醒事项" }
        if reminderFieldsPending { return "正在核对提醒日期与优先级" }
        return nil
    }
    var workspaceProcessingSourceID: String? { transcriptReviewSourceID ?? processingActivity?.sourceID ?? understandingSource ?? fullRecordingSourceID }
    var workspaceUnfinishedIntents: [ExpressionProcessingIntentRecord] {
        processingIntents.filter { intent in
            guard ![.completed,.cancelled,.frozen].contains(intent.state), let input = intent.snapshot.context.sources.first else { return false }
            return records.contains { $0.id == input.sourceID && $0.transcriptVersionID == input.transcriptVersionID && $0.policyVersion == intent.snapshot.policyVersion }
        }
    }
    func workspaceTaskRequiresReview(_ action: ActionRecord) -> Bool {
        if recordingActionRequiresReview(action) { return action.state == "open" }
        guard action.validity != "current", action.state == "open" else { return false }
        if actionRecords.contains(where: { $0.claimID == action.claimID && $0.validity == "current" && $0.claimReviewVersion > action.claimReviewVersion }) { return false }
        let refs = claims.first(where: { $0.id == action.claimID })?.references ?? []
        // The latest completed extraction is shown at its source. Keep earlier records
        // in history instead of making the same recording ask for repair forever.
        let replaced = !refs.isEmpty && refs.allSatisfy { ref in
            let latest = currentClaimsBySource[ref.sourceID] ?? []
            return !latest.isEmpty && !latest.contains { $0.id == action.claimID }
        }
        return !replaced
    }
    func workspaceActionStatus(_ action: ActionRecord) -> String {
        if action.intent?.followupState == "withdrawn" { return "已在后续录音中撤回 · 不再跟进" }
        if action.kind != "task" {
            if action.validity == "current" { return "问题与目标 · 不计为已承诺待办" }
            return workspaceTaskRequiresReview(action) ? "AI 提取已暂停 · 不代表已完成或识别有误" : "之前提取的问题与目标 · 历史记录"
        }
        let completion = action.state == "completed" ? "已登记完成" : action.state == "dismissed" ? "已停止跟进" : "尚未登记完成"
        if action.validity == "current" { return completion + (recordingActionRequiresReview(action) ? " · 行动关系待核对，暂不同步" : "") }
        return completion + (workspaceTaskRequiresReview(action) ? " · AI 提取已暂停" : " · 历史记录")
    }
    var workspacePausedTasks: [ActionRecord] { actionRecords.filter { $0.kind == "task" && workspaceTaskRequiresReview($0) } }
    var workspaceFailedFollowups: [RecordingFollowupReceipt] {
        var seen=Set<String>()
        return recordingFollowups.reversed().filter { seen.insert($0.sourceID).inserted }.filter { $0.state == "failed" }
    }
    var workspaceNeedsAttention: Bool {
        !startupIssue.isEmpty || !workspacePausedTasks.isEmpty || records.contains { ["failed","blocked"].contains($0.jobState ?? "") || ["interrupted","quarantined"].contains($0.state) } ||
        workspaceUnfinishedIntents.contains { [.blocked,.unknown,.rejected].contains($0.state) } ||
        recordingRequests.contains { $0.state == "blocked" } || assistantExecutions.contains { $0.validity == "current" && $0.state == "failed" } ||
        !workspaceFailedFollowups.isEmpty || records.contains { transcriptReviewIssue(for:$0) != nil } ||
        reminderFieldIssue != nil || !assistantAssessmentIssues.isEmpty || knowledgeReviews.contains { $0.validity == "current" && $0.state == "failed" }
    }
}

struct WorkspaceProcessingBar: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @ObservedObject var inbox: RecordingInbox
    let open: () -> Void
    var body: some View {
        HStack(spacing:12) {
            if let title = model.workspaceProcessingTitle {
                ProgressView().controlSize(.small)
                VStack(alignment:.leading,spacing:3) {
                    Text(title).lineLimit(1)
                    if let id=model.workspaceProcessingSourceID,let source=model.records.first(where: { $0.id == id }) { Text(source.workspaceTitle).foregroundStyle(.secondary).lineLimit(1) }
                }
            } else if model.workspaceNeedsAttention || inbox.pendingItems.contains(where: { $0.state == .needsAttention }) || !inbox.folderErrors.isEmpty {
                Label("有事项需要查看，原文与历史保留",systemImage:"exclamationmark.circle").foregroundStyle(.orange)
            } else { Text(model.status).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength:8)
            if model.dictationActive { Button("停止并整理") { model.stopDictation() } }
            else if model.fullRecordingBusy { Button("停止后续处理") { model.cancelFullRecording() } }
            Button("查看处理",action:open).accessibilityIdentifier("workspace.processing")
        }.font(.caption).padding(.horizontal,20).padding(.vertical,12).background(palette.surface)
    }
}

struct WorkspaceProcessingView: View {
    @ObservedObject var model: ControlCenter
    @ObservedObject var inbox: RecordingInbox
    let openSource: (String) -> Void
    let openSettings: () -> Void
    let openInbox: () -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:24) {
                WorkspaceHeading(eyebrow:"后台处理",title:"进度与需要查看的事项",subtitle:"保持应用运行即可继续处理；可以先阅读其他内容。原文、处理结果与历史分别保留。")
                if !model.startupIssue.isEmpty {
                    WorkspaceSection(title:"资料库尚未打开",subtitle:"已有资料没有被重建或清空。处理原因后可以重新打开。",icon:"exclamationmark.triangle") {
                        reason(model.startupIssue).padding(.top,12)
                        Button("重试打开资料库") { Task { await model.start() } }
                    }
                }
                if let title = model.workspaceProcessingTitle {
                    WorkspaceSection(title:title,icon:"hourglass") {
                        if let id=model.workspaceProcessingSourceID,let source=model.records.first(where: { $0.id == id }) {
                            WorkspaceRow(title:source.workspaceTitle,subtitle:"当前正在处理这份完整材料",trailing:"查看原文") { openSource(id) }
                        }
                        Text(model.transcriptReviewSourceID != nil ? model.transcriptReviewStatus : model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top,12)
                        if !model.fullRecordingDetail.isEmpty,model.fullRecordingDetail != model.fullRecordingStatus {
                            DisclosureGroup("查看处理详情") { Text(model.fullRecordingDetail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top,8) }
                        }
                    }
                } else {
                    Label("当前没有正在执行的处理",systemImage:"checkmark.circle").foregroundStyle(.secondary)
                }
                if !model.workspaceUnfinishedIntents.isEmpty {
                    WorkspaceSection(title:"文字理解与关联",icon:"text.bubble",count:model.workspaceUnfinishedIntents.count) {
                        ForEach(model.workspaceUnfinishedIntents) { intent in
                            VStack(alignment:.leading,spacing:10) {
                                WorkspaceRow(title:name(intent.sourceID),subtitle:intentLabel(intent),trailing:"核对材料") { openSource(intent.sourceID) }
                                if let error=intent.error { reason(error) }
                                if intent.state == .queued && !model.modelConfigured { Button("配置模型后继续",action:openSettings) }
                            }
                        }
                    }
                }
                let failedSources=model.records.filter { ["failed","blocked"].contains($0.jobState ?? "") || ["interrupted","quarantined"].contains($0.state) }
                if !failedSources.isEmpty {
                    WorkspaceSection(title:"录音与转写需要查看",icon:"waveform",count:failedSources.count) {
                        ForEach(failedSources) { source in
                            WorkspaceRow(title:source.workspaceTitle,subtitle:source.state == "interrupted" ? "录音被中断，已保存的片段仍保留" : source.state == "quarantined" ? "原件完整性待核对，已暂停后续处理" : "本地转写未完成，原件仍保留",trailing:"查看材料") { openSource(source.id) }
                            if let error=source.error { reason(error) }
                            if source.state == "saved" { Button("重试本地转写") { Task { await model.retry(source) } }.disabled(model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil) }
                        }
                    }
                }
                let waiting=model.recordingRequests.filter { $0.state == "waiting" || $0.state == "blocked" }
                if !waiting.isEmpty {
                    WorkspaceSection(title:"录音处理请求",icon:"tray",count:waiting.count) {
                        ForEach(waiting) { request in
                            WorkspaceRow(title:name(request.sourceID),subtitle:request.state == "blocked" ? "处理条件已变化，需要重新核对" : "等待完整转写与原文核对，随后继续理解",trailing:"查看材料") { openSource(request.sourceID) }
                            if let error=request.error { reason(error) }
                        }
                    }
                }
                if !model.workspacePausedTasks.isEmpty {
                    WorkspaceSection(title:"这些待办需要核对",subtitle:"以下事项尚未登记完成，行动关系待核对或 AI 提取已暂停。打开任务查看依据与原因；确认原话有误后再更正文字或重新识别。",icon:"pause.circle",count:model.workspacePausedTasks.count) {
                        let ids=Set(model.workspacePausedTasks.flatMap { task in model.claims.first(where: { $0.id == task.claimID })?.references.map(\.sourceID) ?? [] })
                        ForEach(model.records.filter { ids.contains($0.id) }) { source in
                            WorkspaceRow(title:source.workspaceTitle,subtitle:"查看暂停原因、受影响的任务和处理按钮",trailing:"打开材料") { openSource(source.id) }
                            ForEach(model.workspacePausedTasks.filter { task in model.claims.first(where: { $0.id == task.claimID })?.references.contains { $0.sourceID == source.id } == true }) { task in
                                VStack(alignment:.leading,spacing:5) { Text(task.title);Text(model.workspaceActionStatus(task)).font(.caption).foregroundStyle(.secondary) }.padding(.leading,26).padding(.bottom,12)
                            }
                        }
                    }
                }
                ForEach(model.records.filter { model.transcriptReviewIssue(for:$0) != nil }) { source in
                    WorkspaceSection(title:"完整转写核对未完成",icon:"waveform.badge.exclamationmark") {
                        WorkspaceRow(title:source.workspaceTitle,subtitle:"原音与原文保留，尚未进入云端理解",trailing:"查看材料") { openSource(source.id) }
                        if let error=model.transcriptReviewIssue(for:source) { reason(error) }
                        Button("重试完整转写核对") { Task { await model.reviewTranscription(sourceID:source.id) } }.disabled(!model.modelConfigured || model.transcriptReviewSourceID != nil || model.fullRecordingBusy)
                    }
                }
                let failedFollowups=model.workspaceFailedFollowups
                if !failedFollowups.isEmpty {
                    WorkspaceSection(title:"思想与目标跟进未完成",icon:"arrow.triangle.branch",count:failedFollowups.count) {
                        ForEach(failedFollowups) { receipt in
                            WorkspaceRow(title:name(receipt.sourceID),subtitle:receipt.retryAt == nil ? "原文和已有任务已保存，可重试跟进" : "已有结果保留，已安排自动重试",trailing:"查看材料") { openSource(receipt.sourceID) }
                            if let error=receipt.error { reason(error) }
                            Button("立即重试") { model.refreshFollowup(receipt.sourceID) }.disabled(!model.modelConfigured || model.followupBusy)
                        }
                    }
                }
                ForEach(model.knowledgeReviews.filter { $0.validity == "current" && $0.state == "failed" }) { review in
                    WorkspaceSection(title:"知识核查未完成",icon:"lightbulb") {
                        WorkspaceRow(title:name(review.sourceID),subtitle:"当前理解与核查结论分别保留",trailing:"查看材料") { openSource(review.sourceID) }
                        if let error=review.error { reason(error) }
                        Button("重试知识核查") { Task { await model.reviewKnowledge(sourceID:review.sourceID,retry:true) } }.disabled(!model.modelConfigured || model.knowledgeReviewBusy)
                    }
                }
                ForEach(model.assistantExecutions.filter { $0.validity == "current" && $0.state == "failed" }) { execution in
                    WorkspaceSection(title:"AI 代办未完成",icon:"sparkles") {
                        Text(execution.title).font(.headline).padding(.vertical,12)
                        if let error=execution.error { reason(error) }
                        Button("查看委托与重试") { model.showTask(execution.actionID) }
                    }
                }
                ForEach(model.assistantAssessmentIssues) { issue in
                    WorkspaceSection(title:"AI 委托识别未完成",icon:"sparkles") {
                        Text(issue.title).padding(.vertical,12);reason(issue.error)
                        Button("重新识别") { Task { await model.retryAssistantAssessment(issue) } }.disabled(!model.modelConfigured || model.assistantBusy)
                    }
                }
                if !inbox.folders.isEmpty || !inbox.pendingItems.isEmpty || !inbox.folderErrors.isEmpty {
                    WorkspaceSection(title:"录音自动入口",icon:"tray.and.arrow.down") {
                        Text(inbox.status).font(.callout).padding(.vertical,12)
                        Button("查看接收、重试与权限状态",action:openInbox)
                    }
                }
                if model.initialized { WorkspaceSection(title:"模型与提醒事项",icon:"checklist") {
                    Text(model.modelConfigured ? model.modelSummary : "尚未配置模型；完整原文仍可先在本机保存。").font(.callout).padding(.vertical,12)
                    Text(model.reminderAccess?.enabled == true ? model.reminderSyncStatus : "尚未连接提醒事项；任务可以先在 VoiceOS 内保存。").font(.callout)
                    if let error=model.reminderFieldIssue {
                        reason(error)
                        Button("重试提醒同步") { Task { await model.refreshTaskReminders() } }.disabled(model.remindersBusy || model.reminderFieldsPending)
                    }
                    Button("检查连接与配置",action:openSettings).padding(.top,12)
                } }
            }.frame(maxWidth:860,alignment:.leading).padding(30).frame(maxWidth:.infinity,alignment:.top)
        }
    }
    private func name(_ id:String) -> String { model.records.first(where: { $0.id == id })?.workspaceTitle ?? "已保存的材料" }
    private func reason(_ text:String) -> some View { DisclosureGroup("查看原因") { Text(text).font(.callout).textSelection(.enabled) }.padding(.bottom,12) }
    private func intentLabel(_ intent:ExpressionProcessingIntentRecord) -> String {
        switch intent.state {
        case .queued: return model.modelConfigured ? "已保存，等待理解与关联" : "已保存，等待配置模型"
        case .running: return intent.phase == .association ? "理解已保存，正在核对历史关联" : "正在理解完整原文"
        case .unknown: return "请求结果未知，已停止自动重发，请先核对原文与处理历史"
        case .blocked: return "处理条件已变化，原文保留，等待核对"
        case .rejected: return "本次结果未通过核对，原文仍保留"
        case .frozen: return "依据已变化，旧结果保留为历史"
        case .cancelled: return "已停止后续处理，已有内容保留"
        case .completed: return "理解与关联已完成"
        }
    }
}
