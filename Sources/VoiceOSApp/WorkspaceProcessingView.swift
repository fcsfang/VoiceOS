import SwiftUI
import VoiceOSCore

struct WorkspaceProcessingActivity {
    let sourceID: String
    let label: String
}

struct WorkspaceCompletionRecord: Identifiable {
    let id = UUID()
    let category: String
    let title: String
    let sourceID: String
    let date: Date
}

extension ControlCenter {
    func recordCompletion(category: String, title: String, sourceID: String) {
        recentCompletions.insert(.init(category: category, title: title, sourceID: sourceID, date: Date()), at: 0)
        if recentCompletions.count > 5 { recentCompletions.removeSubrange(5...) }
    }
}

/// Failed processing items the user chose not to chase. The
/// cognitive_feedback_ignores table is bound to relevance receipts, so these
/// view-level dismissals persist in UserDefaults under stable record IDs.
enum ProcessingDismissals {
    private static let key = "voiceos.processing.ignoredFailures.v1"
    static func isIgnored(_ id: String) -> Bool { UserDefaults.standard.stringArray(forKey: key)?.contains(id) == true }
    static func ignore(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        UserDefaults.standard.set(ids, forKey: key)
    }
}

/// One place that turns stored model failures into the three interface
/// categories. The raw message stays in the record and the log.
enum WorkspaceProcessingErrorText {
    static let format = "AI 返回格式异常，原文已保留，可重试"
    static let network = "网络中断，可重试"
    private static let formatMarkers = ["解码", "格式", "结构", "缺少", "JSON", "Decod",
                                        "couldn’t be read", "couldn't be read", "correct format",
                                        "keyNotFound", "typeMismatch", "valueNotFound", "dataCorrupted"]
    private static let networkMarkers = ["网络", "超时", "timed out", "timeout", "offline", "internet",
                                         "TLS", "secure connection", "URLError", "-1001", "-1005", "-1009"]
    static func display(_ raw: String) -> String {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return raw }
        if AssistantFailureMessage.isStructural(message) || formatMarkers.contains(where: { message.localizedCaseInsensitiveContains($0) }) {
            NSLog("VoiceOS processing format failure: %@", message)
            return format
        }
        if networkMarkers.contains(where: { message.localizedCaseInsensitiveContains($0) }) {
            NSLog("VoiceOS processing network failure: %@", message)
            return network
        }
        return raw
    }
}

struct WorkspaceTranscriptReviewPoint: Identifiable {
    let source: SourceRecord
    let count: Int
    var id: String { source.id }
}

extension SourceRecord {
    /// Unresolved transcription doubts left by a review of the current version.
    var unresolvedTranscriptionIssueCount: Int {
        guard let review = transcriptionReview, review.completed else { return 0 }
        return review.unresolved_issues?.count ?? 0
    }
}

extension ControlCenter {
    var workspaceProcessingStatus: WorkspaceProcessingStatus {
        .init(
            isInitializing: !initialized,
            hasStartupIssue: !startupIssue.isEmpty,
            isDictating: dictationActive,
            isOrganizingRecording: fullRecordingBusy,
            recordingStatus: fullRecordingStatus,
            isSealingDictation: dictationBusy,
            isReviewingTranscript: transcriptReviewSourceID != nil,
            activityLabel: processingActivity?.label,
            isUnderstanding: understandingSource != nil,
            isReplyingDiscussion: discussionSending,
            isExtractingDiscussion: discussionExtracting,
            knowledgeReview: knowledgeReviewBusy ? .running : .idle,
            assistantExecution: assistantExecutionPhase,
            followup: followupBusy ? .running : .idle,
            topicOrganization: organizingTopics ? .running : .idle
        )
    }
    /// The assistant worker also scans and discovers work. Only a current
    /// execution that the store marked running is a delivery in flight.
    private var assistantExecutionPhase: WorkspaceProcessingStatus.Phase {
        guard assistantBusy else { return .idle }
        return assistantExecutions.contains { $0.validity == "current" && $0.state == "running" } ? .running : .completed
    }
    var workspaceProcessingTitle: String? {
        let batchTitle: String?
        if let batch = pausedActionBatch, case .running(let progress) = batch.phase {
            batchTitle = progress.currentTitle.isEmpty ? progress.label : progress.label + " · " + progress.currentTitle
        } else {
            batchTitle = nil
        }
        return workspaceProcessingStatus.visibleTitle(preferringPausedBatch: batchTitle)
    }
    var workspaceProcessingHasScheduledRetry: Bool {
        workspaceFailedFollowups.contains { $0.retryAt != nil }
    }
    var workspaceProcessingBarVisible: Bool {
        workspaceProcessingTitle != nil || workspaceProcessingHasScheduledRetry
    }
    var workspaceProcessingSourceID: String? { pausedActionBatch?.currentSourceID ?? transcriptReviewSourceID ?? processingActivity?.sourceID ?? understandingSource ?? fullRecordingSourceID }
    var workspaceUnfinishedIntents: [ExpressionProcessingIntentRecord] {
        processingIntents.filter { intent in
            guard ![.completed,.cancelled,.frozen].contains(intent.state), let input = intent.snapshot.context.sources.first else { return false }
            return records.contains { $0.id == input.sourceID && $0.transcriptVersionID == input.transcriptVersionID && $0.policyVersion == intent.snapshot.policyVersion }
        }
    }
    func workspaceTaskRequiresReview(_ action: ActionRecord) -> Bool {
        WorkspaceActionPause.reason(for: action, sources: records, claims: claims,
                                    currentClaimsBySource: currentClaimsBySource, actions: actionRecords,
                                    ledgers: actionReviewLedgers) != nil
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
    func workspaceExternalCompletionLink(_ action: ActionRecord) -> ReminderLink? {
        guard action.validity == "frozen" else { return nil }
        return reminderLinks.first { $0.actionID == action.id && $0.state == "linked" && $0.remoteMarkerValid == true && $0.remoteCompleted == true }
    }
    func workspaceExternalCompletionNote(_ action: ActionRecord) -> String? {
        guard workspaceExternalCompletionLink(action) != nil else { return nil }
        return "提醒事项已标记完成 · " + workspaceActionStatus(action)
    }
    func workspaceExternalCompletion(_ action: ActionRecord) -> ExternalCompletionCandidate? {
        ExternalCompletionCandidate(action: action, link: workspaceExternalCompletionLink(action))
    }
    var workspacePausedTasks: [ActionRecord] { actionRecords.filter { $0.kind == "task" && workspaceTaskRequiresReview($0) } }
    var workspaceFailedFollowups: [RecordingFollowupReceipt] {
        var seen=Set<String>()
        return recordingFollowups.reversed().filter { seen.insert($0.sourceID).inserted }.filter { $0.state == "failed" }
    }
    var workspacePanoramaFailure: (status: String, reason: String?)? {
        guard let state = panorama.state, ["failed","unknown"].contains(state.status) else { return nil }
        return (state.status, state.error)
    }
    var workspaceFailedKnowledgeReviews: [KnowledgeReviewRecord] {
        knowledgeReviews.filter { $0.validity == "current" && $0.state == "failed" && !ProcessingDismissals.isIgnored("knowledge:" + $0.id) }
    }
    var workspaceFailedAssistantExecutions: [AssistantExecutionRecord] {
        assistantExecutions.filter { $0.validity == "current" && $0.state == "failed" && !ProcessingDismissals.isIgnored("assistant:" + $0.id) }
    }
    var workspaceNeedsAttention: Bool {
        !startupIssue.isEmpty || !workspacePausedTasks.isEmpty || records.contains { ["failed","blocked"].contains($0.jobState ?? "") || ["interrupted","quarantined"].contains($0.state) } ||
        records.contains { $0.needsEmptyTranscriptionReview } ||
        workspaceUnfinishedIntents.contains { [.blocked,.unknown,.rejected].contains($0.state) } ||
        recordingRequests.contains { $0.state == "blocked" } || !workspaceFailedAssistantExecutions.isEmpty ||
        workspacePanoramaFailure != nil ||
        records.contains { transcriptReviewIssue(for:$0) != nil } ||
        reminderFieldIssue != nil || !assistantAssessmentIssues.isEmpty
    }
    var workspaceTranscriptReviewPoints: [WorkspaceTranscriptReviewPoint] {
        records.compactMap { source -> WorkspaceTranscriptReviewPoint? in
            guard !source.isTrashed, !source.isArchived else { return nil }
            let count = source.unresolvedTranscriptionIssueCount
            guard count > 0 else { return nil }
            return WorkspaceTranscriptReviewPoint(source: source, count: count)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.source.displayTitle < $1.source.displayTitle }
    }
    var workspaceAttentionCount: Int {
        workspaceTranscriptReviewPoints.reduce(0) { $0 + $1.count } + workspaceFailedFollowups.count + workspaceFailedKnowledgeReviews.count + (topicOrganizationNeedsAttention ? 1 : 0) + (workspaceNeedsAttention ? 1 : 0)
    }
    var workspaceProcessingOutstanding: Bool {
        workspaceNeedsAttention || topicOrganizationNeedsAttention || !workspaceTranscriptReviewPoints.isEmpty ||
        !workspaceFailedFollowups.isEmpty || !workspaceFailedKnowledgeReviews.isEmpty ||
        recordingRequests.contains { $0.state == "waiting" } ||
        workspaceUnfinishedIntents.contains { $0.state == .queued || $0.state == .running }
    }
}

struct WorkspaceProcessingBar: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let open: () -> Void
    @State private var confirmingDiscard = false
    var body: some View {
        let status = model.workspaceProcessingStatus
        HStack(spacing:12) {
            if let title = model.workspaceProcessingTitle {
                ProgressView().controlSize(.small)
                VStack(alignment:.leading,spacing:3) {
                    Text(title).lineLimit(1)
                    if let id=model.workspaceProcessingSourceID,let source=model.records.first(where: { $0.id == id }) { Text(source.displayTitle).foregroundStyle(.secondary).lineLimit(1) }
                }
            } else if model.workspaceProcessingHasScheduledRetry {
                Label("等待自动重试",systemImage:"clock.arrow.circlepath").foregroundStyle(.secondary).lineLimit(1)
            } else { Text(status.title).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength:8)
            if model.dictationActive {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(model.dictationElapsedText).monospacedDigit().foregroundStyle(.secondary)
                }
                Button("取消并丢弃…") { confirmingDiscard = true }
                Button("停止并整理") { model.stopDictation() }
            }
            else if model.pausedActionBatch?.isRunning == true { Button("停止后续处理") { model.stopPausedActionBatch() } }
            else if model.fullRecordingBusy { Button("停止后续处理") { model.cancelFullRecording() } }
            Button("查看处理",action:open).accessibilityIdentifier("workspace.processing")
        }.vosFont(WorkspaceText.meta).padding(.horizontal,20).padding(.vertical,12).background(palette.surface)
            .alert("取消并丢弃这段录音？", isPresented: $confirmingDiscard) {
                Button("继续录音", role: .cancel) {}
                Button("取消并丢弃", role: .destructive) { model.cancelAndDiscardDictation() }
            } message: { Text("这段录音不会保存，也不会进入转写与整理。") }
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
                ReverifyControls(model:model)
                if !model.startupIssue.isEmpty {
                    WorkspaceSection(title:"资料库尚未打开",subtitle:"已有资料没有被重建或清空。处理原因后可以重新打开。",icon:"exclamationmark.triangle") {
                        reason(model.startupIssue).padding(.top,12)
                        Button("重试打开资料库") { Task { await model.start() } }
                    }
                }
                if let title = model.workspaceProcessingTitle {
                    WorkspaceSection(title:title,icon:"hourglass") {
                        if let id=model.workspaceProcessingSourceID,let source=model.records.first(where: { $0.id == id }) {
                            WorkspaceRow(title:source.displayTitle,subtitle:"当前正在处理这份完整材料",trailing:"查看原文") { openSource(id) }
                        }
                        Text(model.transcriptReviewSourceID != nil ? model.transcriptReviewStatus : model.status).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled).padding(.top,12)
                        if !model.fullRecordingDetail.isEmpty,model.fullRecordingDetail != model.fullRecordingStatus {
                            DisclosureGroup("查看处理详情") { Text(model.fullRecordingDetail).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled).padding(.top,8) }
                        }
                    }
                } else {
                    Label(WorkspaceProcessingStatus.idleTitle,systemImage:"checkmark.circle").foregroundStyle(.secondary)
                }
                if let failure = model.workspacePanoramaFailure {
                    WorkspaceSection(title:"全景生成未完成",subtitle:"已有材料与已核对区域保留；失败不会删除原文，可以明确重试。",icon:"circle.hexagongrid") {
                        Text(failure.status == "unknown" ? "上次生成在进程退出前未登记结果，没有自动重发。" : "上一次生成没有完成。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary).padding(.top,12)
                        if let error = failure.reason { reason(error) }
                        Button("重试生成全景") { model.retryPanorama() }
                            .disabled(!model.panorama.modelConfigured || model.panorama.isGenerating || model.panorama.state?.status == "running")
                            .accessibilityLabel("重试生成全景")
                    }
                }
                if !model.workspaceUnfinishedIntents.isEmpty {
                    WorkspaceSection(title:"文字理解与关联",icon:"text.bubble",count:model.workspaceUnfinishedIntents.count) {
                        ForEach(model.workspaceUnfinishedIntents) { intent in
                            VStack(alignment:.leading,spacing:10) {
                                WorkspaceRow(title:name(intent.sourceID),subtitle:intentLabel(intent),trailing:"核对材料") { openSource(intent.sourceID) }
                                if let error=intent.error { reason(error) }
                                if intent.state == .queued && !model.modelConfigured { Button("配置模型后继续",action:openSettings).accessibilityLabel("配置模型后继续：" + name(intent.sourceID)) }
                                if intent.state == .queued || intent.state == .running {
                                    Button("停止处理") { Task { await model.cancelProcessingIntent(intent) } }.accessibilityLabel("停止处理：" + name(intent.sourceID))
                                }
                            }
                        }
                    }
                }
                let quarantinedSources=model.records.filter { $0.state == "quarantined" }
                let quarantinedIDs=Set(quarantinedSources.map(\.id))
                if !quarantinedSources.isEmpty {
                    Text("需要核对的原件见上方『需要重新核对的原件』").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
                let failedSources=model.records.filter { !quarantinedIDs.contains($0.id) && !$0.isTrashed && !$0.needsEmptyTranscriptionReview && (["failed","blocked"].contains($0.jobState ?? "") || $0.state == "interrupted") }
                if !failedSources.isEmpty {
                    let retryableSources=failedSources.filter { $0.state == "saved" }
                    let sourceErrors=failedSources.compactMap { source in source.error.map { (source.displayTitle,$0) } }
                    WorkspaceSection(title:"录音与转写需要查看",subtitle:"录音被中断时已保存的片段仍保留；本地转写失败时原件仍保留。",icon:"waveform",count:failedSources.count) {
                        ForEach(failedSources) { source in
                            VStack(alignment:.leading,spacing:6) {
                                WorkspaceRow(title:source.displayTitle,subtitle:source.state == "interrupted" ? "录音被中断" : "本地转写未完成",trailing:"查看材料") { openSource(source.id) }
                                if source.dictationRecoveryPending {
                                    DictationRecoveryControls(model:model,source:source).padding(.leading,44).padding(.bottom,8)
                                }
                            }
                        }
                        reasons(sourceErrors)
                        if retryableSources.count > 1 {
                            Button("重试全部本地转写（\(retryableSources.count)）") { retryAllTranscriptions(retryableSources) }.disabled(model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil)
                        } else if let source=retryableSources.first {
                            Button("重试本地转写") { Task { await model.retry(source) } }.accessibilityLabel("重试本地转写：" + source.displayTitle).disabled(model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil)
                        }
                    }
                }
                let emptySources=model.records.filter { $0.needsEmptyTranscriptionReview }
                if !emptySources.isEmpty {
                    WorkspaceSection(title:"转写为空",subtitle:"录音与原件仍然保留，但这次没有转写出任何文字。可以重新转写，或移入回收站。",icon:"waveform.badge.mic",count:emptySources.count) {
                        ForEach(emptySources) { source in
                            VStack(alignment:.leading,spacing:6) {
                                WorkspaceRow(title:source.displayTitle,subtitle:emptyTranscriptSubtitle(source),trailing:"查看材料") { openSource(source.id) }
                                HStack(spacing:12) {
                                    Button("重新转写") { Task { await model.retry(source) } }.accessibilityLabel("重新转写：" + source.displayTitle).disabled(model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil)
                                    EmptyTranscriptTrashControl(model:model,source:source)
                                }.padding(.leading,44).padding(.bottom,8)
                            }
                        }
                    }
                }
                let waiting=model.recordingRequests.filter { $0.state == "waiting" || $0.state == "blocked" }
                if !waiting.isEmpty {
                    WorkspaceSection(title:"录音处理请求",icon:"tray",count:waiting.count) {
                        ForEach(waiting) { request in
                            VStack(alignment:.leading,spacing:6) {
                                WorkspaceRow(title:name(request.sourceID),subtitle:request.state == "blocked" ? "处理条件已变化，需要重新核对" : "等待完整转写与原文核对，随后继续理解",trailing:"查看材料") { openSource(request.sourceID) }
                                Button("停止处理") { Task { await model.cancelRecordingRequest(request) } }.accessibilityLabel("停止处理录音处理请求：" + name(request.sourceID)).padding(.bottom,8)
                            }
                        }
                        reasons(waiting.compactMap { request in request.error.map { (name(request.sourceID),$0) } })
                    }
                }
                WorkspaceExternalCompletionBatchSection(model:model)
                if !model.workspacePausedTasks.isEmpty {
                    WorkspaceSection(title:"这些待办需要核对",subtitle:"以下事项尚未登记完成，行动关系待核对或 AI 提取已暂停。逐条核对：同一件事会接回原记录，两件事会保留两条；核对后即可继续同步。",icon:"pause.circle",count:model.workspacePausedTasks.count) {
                        let ids=Set(model.workspacePausedTasks.flatMap { task in model.claims.first(where: { $0.id == task.claimID })?.references.map(\.sourceID) ?? [] })
                        ForEach(model.records.filter { ids.contains($0.id) }) { source in
                            WorkspaceRow(title:source.displayTitle,subtitle:"查看暂停原因、受影响的任务和处理按钮",trailing:"打开材料") { openSource(source.id) }
                            ForEach(model.workspacePausedTasks.filter { task in model.claims.first(where: { $0.id == task.claimID })?.references.contains { $0.sourceID == source.id } == true }) { task in
                                VStack(alignment:.leading,spacing:5) {
                                    Text(task.title)
                                    Text(model.workspaceExternalCompletionNote(task) ?? model.workspaceActionStatus(task)).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                    WorkspaceExternalCompletionButton(model:model,action:task)
                                    ForEach(model.actionReviewPairs(for:task)) { pair in
                                        ActionReviewResolutionControl(model:model,pair:pair)
                                    }
                                }.padding(.leading,26).padding(.bottom,12)
                            }
                        }
                        if model.pausedActionBatch == nil { PausedActionBatchControl(model:model) }
                    }
                }
                if model.pausedActionBatch != nil {
                    WorkspaceSection(title:"批量重新识别",icon:"arrow.triangle.2.circlepath") {
                        PausedActionBatchControl(model:model)
                    }
                }
                let reviewSources=model.records.filter { model.transcriptReviewIssue(for:$0) != nil }
                if !reviewSources.isEmpty {
                    let reviewErrors=reviewSources.compactMap { source in model.transcriptReviewIssue(for:source).map { (source.displayTitle,$0) } }
                    WorkspaceSection(title:"完整转写核对未完成",subtitle:"原音与原文保留，尚未进入云端理解。",icon:"waveform.badge.exclamationmark",count:reviewSources.count) {
                        ForEach(reviewSources) { source in
                            WorkspaceRow(title:source.displayTitle,subtitle:"",trailing:"查看材料") { openSource(source.id) }
                        }
                        reasons(reviewErrors)
                        if reviewSources.count > 1 {
                            Button("重试全部完整转写核对（\(reviewSources.count)）") { retryAllTranscriptReviews(reviewSources) }.disabled(!model.modelConfigured || model.transcriptReviewSourceID != nil || model.fullRecordingBusy)
                        } else if let source=reviewSources.first {
                            Button("重试完整转写核对") { Task { await model.reviewTranscription(sourceID:source.id) } }.accessibilityLabel("重试完整转写核对：" + source.displayTitle).disabled(!model.modelConfigured || model.transcriptReviewSourceID != nil || model.fullRecordingBusy)
                        }
                    }
                }
                let reviewPoints=model.workspaceTranscriptReviewPoints
                if !reviewPoints.isEmpty {
                    let issueTotal=reviewPoints.reduce(0) { $0 + $1.count }
                    WorkspaceSection(title:"转写疑点待核对",subtitle:"\(reviewPoints.count) 份材料的核对已经完成，仍有 \(issueTotal) 条疑点没有解决。打开材料可以逐条回听原音与查看原文。",icon:"exclamationmark.bubble",count:reviewPoints.count) {
                        ForEach(reviewPoints) { point in
                            WorkspaceRow(title:point.source.displayTitle,subtitle:"仍有 \(point.count) 条疑点未解决",trailing:"查看材料") { openSource(point.source.id) }
                        }
                    }
                }
                let failedFollowups=model.workspaceFailedFollowups
                if !failedFollowups.isEmpty {
                    let followupErrors=failedFollowups.compactMap { receipt in receipt.error.map { (name(receipt.sourceID),$0) } }
                    WorkspaceSection(title:"思想与目标跟进未完成",subtitle:"原文和已有任务已保存；失败后可以重试。",icon:"arrow.triangle.branch",count:failedFollowups.count) {
                        ForEach(failedFollowups) { receipt in
                            WorkspaceRow(title:name(receipt.sourceID),subtitle:receipt.retryAt == nil ? "未安排自动重试" : "已安排自动重试",trailing:"查看材料") { openSource(receipt.sourceID) }
                        }
                        reasons(followupErrors)
                        if failedFollowups.count > 1 {
                            Button("全部重试（\(failedFollowups.count)）") { model.retryAllFailedFollowups() }.accessibilityLabel("全部重试思想与下一步（\(failedFollowups.count)）").disabled(!model.modelConfigured || model.followupBusy)
                        } else if let receipt=failedFollowups.first {
                            Button("立即重试") { model.refreshFollowup(receipt.sourceID) }.accessibilityLabel("立即重试思想与下一步：" + name(receipt.sourceID)).disabled(!model.modelConfigured || model.followupBusy)
                        }
                    }
                }
                let failedKnowledgeReviews=model.workspaceFailedKnowledgeReviews
                if !failedKnowledgeReviews.isEmpty {
                    let knowledgeErrors=failedKnowledgeReviews.compactMap { review in review.error.map { (name(review.sourceID),$0) } }
                    WorkspaceSection(title:"知识核查未完成",subtitle:"当前理解与核查结论分别保留；不再跟进的可忽略这次。",icon:"lightbulb",count:failedKnowledgeReviews.count) {
                        ForEach(failedKnowledgeReviews) { review in
                            WorkspaceRow(title:name(review.sourceID),subtitle:"",trailing:"查看材料") { openSource(review.sourceID) }
                            Button("忽略这次") { model.ignoreProcessingFailure("knowledge:" + review.id) }
                                .accessibilityLabel("忽略这次知识核查：" + name(review.sourceID))
                                .padding(.bottom,8)
                        }
                        reasons(knowledgeErrors)
                        if failedKnowledgeReviews.count > 1 {
                            Button("全部重试（\(failedKnowledgeReviews.count)）") { Task { await model.retryAllFailedKnowledgeReviews() } }.accessibilityLabel("全部重试知识核查（\(failedKnowledgeReviews.count)）").disabled(!model.modelConfigured || model.knowledgeReviewBusy)
                        } else if let review=failedKnowledgeReviews.first {
                            Button("重试知识核查") { Task { await model.reviewKnowledge(sourceID:review.sourceID,retry:true) } }.accessibilityLabel("重试知识核查：" + name(review.sourceID)).disabled(!model.modelConfigured || model.knowledgeReviewBusy)
                        }
                    }
                }
                if model.topicOrganizationNeedsAttention {
                    let pending=model.topicOrganizationPendingTopicCount
                    WorkspaceSection(title:"主题整理未完成",subtitle:"已完成的主题会保留；补齐只处理还没整理完的部分。",icon:"square.stack.3d.up",count:pending) {
                        if let text=model.topicOrganizationAttentionText { reason(text) }
                        Button(pending > 0 ? "继续补齐正文（\(pending)）" : "立即重试") { model.queueTopicOrganization(retry:pending == 0, topUp:pending > 0) }
                            .accessibilityLabel(pending > 0 ? "继续补齐主题正文（\(pending)）" : "立即重试主题整理")
                    }
                }
                ForEach(model.workspaceFailedAssistantExecutions) { execution in
                    WorkspaceSection(title:"AI 代办未完成",icon:"sparkles") {
                        Text(execution.title).vosFont(WorkspaceText.rowTitle).padding(.vertical,12)
                        if let error=execution.error { reason(error) }
                        HStack(spacing:16) {
                            Button("查看委托与重试") { model.showTask(execution.actionID) }.accessibilityLabel("查看委托与重试：" + execution.title)
                            Button("忽略这次") { model.ignoreProcessingFailure("assistant:" + execution.id) }.accessibilityLabel("忽略这次 AI 代办：" + execution.title)
                        }
                    }
                }
                ForEach(model.assistantAssessmentIssues) { issue in
                    WorkspaceSection(title:"AI 委托识别未完成",icon:"sparkles") {
                        Text(issue.title).padding(.vertical,12);reason(issue.error)
                        Button("重新识别") { Task { await model.retryAssistantAssessment(issue) } }.accessibilityLabel("重新识别：" + issue.title).disabled(!model.modelConfigured || model.assistantBusy)
                    }
                }
                let reminderAnomalies = model.reminderSyncAnomalies
                if reminderAnomalies.total > 0 {
                    WorkspaceSection(title:"提醒事项需要核对",subtitle:"有 \(reminderAnomalies.total) 条关联的提醒事项未完成回读。可能已在提醒事项中被删除，任务保留为本地任务；重新回读只查询，不会重建。",icon:"exclamationmark.circle",count:reminderAnomalies.total) {
                        Text(reminderAnomalyCounts(reminderAnomalies)).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).padding(.vertical,8)
                        ForEach(reminderAnomalies.items) { item in
                            VStack(alignment:.leading,spacing:6) {
                                WorkspaceRow(title:item.actionTitle,subtitle:reminderAnomalySubtitle(item),trailing:"查看任务") { model.showTask(item.actionID) }
                                if let link=model.reminderLinks.first(where: { $0.id == item.id }) {
                                    Button("重新回读") { Task { await model.readReminder(link) } }
                                        .accessibilityLabel("重新回读：" + item.actionTitle)
                                        .disabled(model.remindersBusy || model.reminderFieldsPending || model.reminderAccess?.enabled != true)
                                        .padding(.leading,54).padding(.bottom,8)
                                }
                            }
                        }
                    }
                }
                if !inbox.folders.isEmpty || !inbox.pendingItems.isEmpty || !inbox.folderErrors.isEmpty {
                    WorkspaceSection(title:"录音自动入口",icon:"tray.and.arrow.down") {
                        Text(inbox.status).vosFont(WorkspaceText.meta).padding(.vertical,12)
                        Button("查看接收、重试与权限状态",action:openInbox)
                    }
                }
                if model.initialized { WorkspaceSection(title:"模型与提醒事项",icon:"checklist") {
                    Text(model.modelConfigured ? model.modelSummary : "尚未配置模型；完整原文仍可先在本机保存。").vosFont(WorkspaceText.meta).padding(.vertical,12)
                    Text(model.reminderAccess?.enabled == true ? reminderSyncStatusText : "尚未连接提醒事项；任务可以先在 VoiceOS 内保存。").vosFont(WorkspaceText.meta)
                    if let error=model.reminderFieldIssue {
                        reason(error)
                        Button("重试提醒同步") { Task { await model.refreshTaskReminders() } }.disabled(model.remindersBusy || model.reminderFieldsPending)
                    }
                    Button("检查连接与配置",action:openSettings).padding(.top,12)
                } }
                if !model.recentCompletions.isEmpty { WorkspaceSection(title:"最近完成",subtitle:"只保留本次运行最近 5 条；点开可查看对应材料。",icon:"clock.arrow.circlepath",count:model.recentCompletions.count) {
                    ForEach(model.recentCompletions) { item in
                        WorkspaceRow(title:item.title,subtitle:item.category + " · " + item.date.formatted(date:.abbreviated,time:.shortened),trailing:"查看材料") { openSource(item.sourceID) }
                    }
                } }
                if model.initialized, !model.workspaceProcessingOutstanding, !model.workspaceProcessingBarVisible,
                   inbox.pendingItems.isEmpty, inbox.folderErrors.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        Label("已全部处理",systemImage:"checkmark.circle").foregroundStyle(.secondary)
                            .accessibilityLabel("已全部处理，没有需要查看的处理结果")
                        Text(model.recentCompletions.isEmpty ? "本次运行还没有完成记录；长任务完成后会保留最近 5 条，错过通知也能在这里找回。" : "以上是最近完成的记录，可点开查看材料。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth:860,alignment:.leading).padding(30).frame(maxWidth:.infinity,alignment:.top)
        }
    }
    private func name(_ id:String) -> String { model.records.first(where: { $0.id == id })?.displayTitle ?? "已保存的材料" }
    private var reminderSyncStatusText: String {
        let summary = model.reminderSyncAnomalies
        guard summary.total > 0 else { return model.reminderSyncStatus }
        return model.reminderSyncStatus + " · 待核对 \(summary.total) 条（" + reminderAnomalyCounts(summary) + "）"
    }
    private func reminderAnomalyCounts(_ summary: ReminderSyncAnomalySummary) -> String {
        "找不到 \(summary.count("missing")) · 身份不一致 \(summary.count("conflict")) · 未确认 \(summary.count("unknown"))"
    }
    private func reminderAnomalySubtitle(_ item: ReminderSyncAnomaly) -> String {
        let state = item.state == "missing" ? "提醒事项中找不到" : item.state == "conflict" ? "匹配到多条或身份已变化" : "上次回读结果未确认"
        return "提醒事项「\(item.desiredTitle)」 · \(item.marker) · " + state
    }
    @ViewBuilder private func reasons(_ entries:[(String,String)]) -> some View {
        if !entries.isEmpty {
            DisclosureGroup("查看原因") {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(entries.indices,id:\.self) { index in
                        Text(entries[index].0 + "：" + WorkspaceProcessingErrorText.display(entries[index].1)).vosFont(WorkspaceText.body).textSelection(.enabled)
                    }
                }.padding(.top,8)
            }.accessibilityHint(entries.map { WorkspaceProcessingErrorText.display($0.1) }.joined(separator:"\n")).padding(.bottom,12)
        }
    }
    private func retryAllTranscriptions(_ sources:[SourceRecord]) {
        Task { for source in sources { await model.retry(source) } }
    }
    private func retryAllTranscriptReviews(_ sources:[SourceRecord]) {
        Task { for source in sources { await model.reviewTranscription(sourceID:source.id) } }
    }
    private func emptyTranscriptSubtitle(_ source:SourceRecord) -> String {
        let duration = source.duration.map { durationText($0) } ?? "时长未知"
        return "转写为空 · 时长 " + duration + " · " + source.recordingDateLabel
    }
    private func durationText(_ seconds:Double) -> String {
        let total = Int(seconds.rounded())
        return String(format:"%02d:%02d",total / 60,total % 60)
    }
    private func reason(_ text:String) -> some View {
        let display = WorkspaceProcessingErrorText.display(text)
        return DisclosureGroup("查看原因") { Text(display).vosFont(WorkspaceText.body).textSelection(.enabled) }.accessibilityHint(display).padding(.bottom,12)
    }
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

struct EmptyTranscriptTrashControl: View {
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    @State private var confirming = false
    var body: some View {
        Button("移入回收站") { confirming = true }.disabled(source.state != "saved")
            .alert("把「\(source.displayTitle)」移入回收站？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button("移入回收站", role: .destructive) { Task { await model.manageMaterial(source, disposition: .trashed) } }
            } message: {
                Text("原件与录音历史保留，可从回收站恢复；已连接的 Apple 提醒事项不会被修改。")
            }
    }
}

struct WorkspaceExternalCompletionButton: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let action: ActionRecord
    @State private var confirming = false
    @State private var error = ""
    var body: some View {
        let candidate = model.workspaceExternalCompletion(action)
        if candidate != nil || !error.isEmpty {
            VStack(alignment:.leading,spacing:6) {
                if candidate != nil {
                    Button("确认外部已完成") { confirming = true }.disabled(model.savingAction)
                }
                if !error.isEmpty { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger).textSelection(.enabled) }
            }
            .alert("把「\(action.title)」登记为已完成？", isPresented: $confirming) {
                Button("确认外部已完成") { confirm() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("任务将标记为已完成并进入结果队列。原始声明与理解继续冻结保留，不会恢复旧输出。Apple 提醒事项本身不会被修改。")
            }
        }
    }
    private func confirm() {
        guard let candidate = model.workspaceExternalCompletion(action) else {
            error = "提醒事项关联或最新回读已变化，请查看最新状态"
            return
        }
        Task { error = await model.confirmExternalCompletion(candidate) ? "" : model.status }
    }
}

struct WorkspaceExternalCompletionItem: Identifiable {
    let action: ActionRecord
    var id: String { action.id }
}

struct WorkspaceExternalCompletionGroup: Identifiable {
    let sourceID: String
    let title: String
    let items: [WorkspaceExternalCompletionItem]
    var id: String { sourceID }
}

struct WorkspaceExternalCompletionBatchSection: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @State private var pending: WorkspaceExternalCompletionGroup?
    @State private var confirming = false
    @State private var busy = false
    @State private var result = ""
    @State private var failed = false
    private var groups: [WorkspaceExternalCompletionGroup] {
        let items = model.actionRecords.compactMap { action -> WorkspaceExternalCompletionItem? in
            model.workspaceExternalCompletion(action) == nil ? nil : WorkspaceExternalCompletionItem(action: action)
        }
        let grouped = Dictionary(grouping: items) { item in
            model.claims.first { $0.id == item.action.claimID }?.references.first?.sourceID ?? ""
        }
        return grouped.map { sourceID, items in
            let title = sourceID.isEmpty ? "已保存的材料" : (model.records.first { $0.id == sourceID }?.displayTitle ?? "已保存的材料")
            return WorkspaceExternalCompletionGroup(sourceID: sourceID, title: title, items: items.sorted { $0.action.title < $1.action.title })
        }.sorted { $0.title < $1.title }
    }
    var body: some View {
        let groups = self.groups
        if !groups.isEmpty {
            let total = groups.reduce(0) { $0 + $1.items.count }
            WorkspaceSection(title:"提醒事项已完成待登记",subtitle:"共 \(total) 条，来自 \(groups.count) 份材料；确认后进入结果队列，Apple 提醒事项本身不会被修改。",icon:"checklist",count:total) {
                ForEach(groups) { group in
                    VStack(alignment:.leading,spacing:0) {
                        HStack(spacing:12) {
                            Image(systemName:"doc.text").vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                                .frame(width:30,height:30).background(palette.selection.opacity(0.6),in:RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
                                .accessibilityHidden(true)
                            Text(group.title).vosFont(WorkspaceText.rowTitle)
                            Text("\(group.items.count) 条").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            Spacer(minLength:8)
                            Button("全部确认（\(group.items.count)）") { pending = group; confirming = true }
                                .disabled(busy || model.savingAction)
                                .accessibilityLabel("全部确认「\(group.title)」的 \(group.items.count) 条提醒事项已完成")
                        }.padding(.vertical,10).padding(.horizontal,10)
                        ForEach(group.items) { item in
                            WorkspaceRow(title:item.action.title,subtitle:model.workspaceExternalCompletionNote(item.action) ?? model.workspaceActionStatus(item.action),icon:"circle",trailing:"查看任务") { model.showTask(item.action.id) }
                                .padding(.leading,40)
                        }
                    }.padding(.bottom,8)
                }
                if !result.isEmpty {
                    Text(result).vosFont(WorkspaceText.meta).foregroundStyle(failed ? palette.danger : palette.secondaryText).textSelection(.enabled).padding(.top,12)
                }
            }
            .alert(confirmTitle, isPresented:$confirming) {
                Button("全部确认") { if let group = pending { confirm(group) }; pending = nil }
                Button("取消", role:.cancel) { pending = nil }
            } message: {
                Text("这些任务将标记为已完成并进入结果队列。原始声明与理解继续冻结保留，Apple 提醒事项本身不会被修改。")
            }
        }
    }
    private var confirmTitle: String {
        guard let pending = pending else { return "" }
        return "把「\(pending.title)」的 \(pending.items.count) 条提醒事项登记为已完成？"
    }
    private func confirm(_ group: WorkspaceExternalCompletionGroup) {
        guard !busy else { return }
        busy = true
        result = ""
        failed = false
        Task {
            defer { busy = false }
            var done = 0
            for item in group.items {
                guard let action = model.actionRecords.first(where: { $0.id == item.action.id }),
                      let candidate = model.workspaceExternalCompletion(action) else {
                    result = "已确认 \(done) 条；「\(item.action.title)」的提醒回读已变化，请查看最新状态"
                    failed = true
                    return
                }
                if await model.confirmExternalCompletion(candidate) {
                    done += 1
                } else {
                    result = "已确认 \(done) 条；「\(item.action.title)」未登记：" + model.status
                    failed = true
                    return
                }
            }
            result = "已确认 \(done) 条"
        }
    }
}
