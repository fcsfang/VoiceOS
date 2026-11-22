import SwiftUI
import VoiceOSCore

private enum WorkspaceProcessingFormatting {
    static let iso8601 = ISO8601DateFormatter()
}

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

/// One processing-page body evaluation. The sidebar dot and the processing
/// page read the same snapshot instead of each accessor rescanning the library.
struct WorkspaceAttentionSnapshot {
    let transcriptReviewPoints: [WorkspaceTranscriptReviewPoint]
    let unfinishedIntents: [ExpressionProcessingIntentRecord]
    let failedFollowups: [RecordingFollowupReceipt]
    let failedKnowledgeReviews: [KnowledgeReviewRecord]
    let failedAssistantExecutions: [AssistantExecutionRecord]
    let segmentedBatchFailures: [SegmentedProcessingBatch]
    let topicOrganizationNeedsAttention: Bool
    let monitorNeedsAttention: Bool
    let needsAttention: Bool
    let count: Int
    let transcriptIssueCount: Int
    let otherCount: Int
    let processingOutstanding: Bool
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
        UnfinishedProcessingIntents.filter(processingIntents, recordsByID: sourcePageIndex.recordsByID)
    }
    func workspaceTaskRequiresReview(_ action: ActionRecord) -> Bool {
        sourcePageIndex.requiresReview(action.id)
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
    var workspacePausedTasks: [ActionRecord] { sourcePageIndex.pausedTasks }
    var workspaceFailedFollowups: [RecordingFollowupReceipt] {
        var seen=Set<String>()
        return recordingFollowups.reversed().filter { seen.insert($0.sourceID).inserted }.filter { $0.state == "failed" }
    }
    var workspaceFailedKnowledgeReviews: [KnowledgeReviewRecord] {
        knowledgeReviews.filter { $0.validity == "current" && $0.state == "failed" && !ProcessingDismissals.isIgnored("knowledge:" + $0.id) }
    }
    var workspaceFailedAssistantExecutions: [AssistantExecutionRecord] {
        assistantExecutions.filter { $0.validity == "current" && $0.state == "failed" && !ProcessingDismissals.isIgnored("assistant:" + $0.id) }
    }
    /// The newest segmented batch per source. An older rejected record becomes
    /// history once a retry or a correction produced a newer batch.
    var workspaceSegmentedBatchFailures: [SegmentedProcessingBatch] {
        var latest: [String: SegmentedProcessingBatch] = [:]
        for batch in segmentedBatches {
            let sourceID = batch.scope.plan.source.sourceID
            if let current = latest[sourceID], (current.createdAt, current.id) > (batch.createdAt, batch.id) { continue }
            latest[sourceID] = batch
        }
        return latest.values.filter { [.rejected, .unknown].contains($0.state) }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }
    var workspaceAttentionSnapshot: WorkspaceAttentionSnapshot {
        let points = sourcePageIndex.transcriptReviewPoints
        let intents = workspaceUnfinishedIntents
        let followups = workspaceFailedFollowups
        let knowledge = workspaceFailedKnowledgeReviews
        let failedAssistant = workspaceFailedAssistantExecutions
        let segmentedFailures = workspaceSegmentedBatchFailures
        let needsAttention = !startupIssue.isEmpty
            || !workspacePausedTasks.isEmpty
            || sourcePageIndex.recordsNeedAttention
            || intents.contains { $0.needsAttention }
            || recordingRequests.contains { $0.state == "blocked" }
            || !failedAssistant.isEmpty
            || !segmentedFailures.isEmpty
            || records.contains { transcriptReviewIssue(for: $0) != nil }
            || reminderFieldIssue != nil
            || !assistantAssessmentIssues.isEmpty
        let topicAttention = topicOrganizationNeedsAttention
        let monitorAttention = monitorNeedsAttention
        let transcriptIssueCount = points.reduce(0) { $0 + $1.count }
        let count = transcriptIssueCount
            + followups.count + knowledge.count
            + (topicAttention ? 1 : 0) + (needsAttention ? 1 : 0) + (monitorAttention ? 1 : 0)
        let outstanding = needsAttention || topicAttention || !points.isEmpty
            || !followups.isEmpty || !knowledge.isEmpty || monitorAttention
            || recordingRequests.contains { $0.state == "waiting" }
            || intents.contains { $0.state == .queued || $0.state == .running }
        return .init(transcriptReviewPoints: points, unfinishedIntents: intents,
                     failedFollowups: followups, failedKnowledgeReviews: knowledge,
                     failedAssistantExecutions: failedAssistant,
                     segmentedBatchFailures: segmentedFailures,
                     topicOrganizationNeedsAttention: topicAttention,
                     monitorNeedsAttention: monitorAttention,
                     needsAttention: needsAttention, count: count,
                     transcriptIssueCount: transcriptIssueCount, otherCount: count - transcriptIssueCount,
                     processingOutstanding: outstanding)
    }
    var workspaceTranscriptReviewPoints: [WorkspaceTranscriptReviewPoint] {
        sourcePageIndex.transcriptReviewPoints
    }
    var workspaceAttentionCount: Int { workspaceAttentionSnapshot.count }
    var workspaceNeedsAttention: Bool { workspaceAttentionSnapshot.needsAttention }
    var workspaceProcessingOutstanding: Bool { workspaceAttentionSnapshot.processingOutstanding }
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
                    Text(title).vosFont(WorkspaceText.rowTitle).lineLimit(1)
                    if let id=model.workspaceProcessingSourceID,let source=model.sourcePageIndex.recordsByID[id] { Text(source.displayTitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(1) }
                }
            } else if model.workspaceProcessingHasScheduledRetry {
                WorkspaceBadge(text:"等待自动重试", tone:.warning)
            } else { Text(status.title).foregroundStyle(palette.secondaryText).lineLimit(1) }
            Spacer(minLength:8)
            if model.dictationActive {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(model.dictationElapsedText).monospacedDigit().foregroundStyle(palette.secondaryText)
                }
                Button("取消并丢弃…") { confirmingDiscard = true }
                    .buttonStyle(.workspaceDestructive)
                    .accessibilityIdentifier("processing.dictation.discard")
                Button("停止并整理") { model.stopDictation() }
                    .buttonStyle(.workspacePrimary)
                    .accessibilityIdentifier("processing.dictation.stop")
            }
            else if model.pausedActionBatch?.isRunning == true { Button("停止后续处理") { model.stopPausedActionBatch() }.buttonStyle(.workspaceSecondary).accessibilityIdentifier("processing.batch.stop") }
            else if model.fullRecordingBusy { Button("停止后续处理") { model.cancelFullRecording() }.buttonStyle(.workspaceSecondary).accessibilityIdentifier("processing.recording.stop") }
            Button("查看处理",action:open).buttonStyle(.workspaceSecondary).accessibilityIdentifier("workspace.processing")
        }.vosFont(WorkspaceText.meta).padding(.horizontal,20).padding(.vertical,12).background(palette.surface)
            .alert("取消并丢弃这段录音？", isPresented: $confirmingDiscard) {
                Button("继续录音", role: .cancel) {}
                Button("取消并丢弃", role: .destructive) { model.cancelAndDiscardDictation() }
            } message: { Text("这段录音不会保存，也不会进入转写与整理。") }
    }
}

struct WorkspaceProcessingView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @ObservedObject var inbox: RecordingInbox
    let openSource: (String) -> Void
    let openSettings: () -> Void
    let openInbox: () -> Void
    let openMonitor: () -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:WorkspaceMetrics.sectionGap) {
                let attention = model.workspaceAttentionSnapshot
                let quarantinedSources=model.records.filter { $0.state == "quarantined" }
                let quarantinedIDs=Set(quarantinedSources.map(\.id))
                let failedSources=model.records.filter { !quarantinedIDs.contains($0.id) && !$0.isTrashed && !$0.needsEmptyTranscriptionReview && (["failed","blocked"].contains($0.jobState ?? "") || $0.state == "interrupted") }
                let emptySources=model.records.filter { $0.needsEmptyTranscriptionReview }
                let waiting=model.recordingRequests.filter { $0.state == "waiting" || $0.state == "blocked" }
                let segmentedFailures=attention.segmentedBatchFailures
                let pausedTasks=model.workspacePausedTasks
                let reviewSources=model.records.filter { model.transcriptReviewIssue(for:$0) != nil }
                let reviewPoints=attention.transcriptReviewPoints
                let failedFollowups=attention.failedFollowups
                let failedKnowledgeReviews=attention.failedKnowledgeReviews
                let reminderAnomalies=model.reminderSyncAnomalies
                let pendingReminderSyncs=model.pendingReminderSyncList
                let showIntents = !attention.unfinishedIntents.isEmpty
                let showFailedSources = !failedSources.isEmpty
                let showEmptySources = !emptySources.isEmpty
                let showWaiting = !waiting.isEmpty
                let showSegmentedFailures = !segmentedFailures.isEmpty
                let showReviewSources = !reviewSources.isEmpty
                let showReviewPoints = !reviewPoints.isEmpty
                let showPausedBatch=model.pausedActionBatch != nil
                let showPausedTasks = !pausedTasks.isEmpty
                let showFailedFollowups = !failedFollowups.isEmpty
                let showFailedKnowledgeReviews = !failedKnowledgeReviews.isEmpty
                let showFailedAssistant = !attention.failedAssistantExecutions.isEmpty
                let showAssessmentIssues = !model.assistantAssessmentIssues.isEmpty
                let showMonitor=attention.monitorNeedsAttention
                let showReminderAnomalies=reminderAnomalies.total > 0 || reminderAnomalies.failureTotal > 0
                let showPendingReminderSyncs = !pendingReminderSyncs.isEmpty
                let showStartupIssue = !model.startupIssue.isEmpty
                let showTopicOrganization=attention.topicOrganizationNeedsAttention
                let showInbox = !inbox.folders.isEmpty || !inbox.pendingItems.isEmpty || !inbox.folderErrors.isEmpty
                let showModelStatus=model.initialized
                WorkspacePageHeading(eyebrow:"后台处理",title:"进度与需要查看的事项",subtitle:"保持应用运行即可继续处理；原文、处理结果与历史分别保留。")
                ReverifyControls(model:model)
                if let title = model.workspaceProcessingTitle {
                    WorkspaceCard {
                        VStack(alignment:.leading,spacing:12) {
                            WorkspaceSectionHeading(title)
                            WorkspaceListDivider()
                            if let id=model.workspaceProcessingSourceID,let source=model.sourcePageIndex.recordsByID[id] {
                                WorkspaceRow(title:source.displayTitle,subtitle:"当前正在处理这份完整材料",trailing:"查看原文") { openSource(id) }.processingRowInset()
                            }
                            Text(model.transcriptReviewSourceID != nil ? model.transcriptReviewStatus : model.status).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                            if !model.fullRecordingDetail.isEmpty,model.fullRecordingDetail != model.fullRecordingStatus {
                                DisclosureGroup("查看处理详情") { Text(model.fullRecordingDetail).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled).padding(.top,8) }
                            }
                        }
                    }
                } else {
                    WorkspaceBadge(text:WorkspaceProcessingStatus.idleTitle, tone:.neutral)
                }
                if !quarantinedSources.isEmpty {
                    Text("需要核对的原件见上方『需要重新核对的原件』").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
                if showIntents || showFailedSources || showEmptySources || showWaiting || showSegmentedFailures || showReviewSources || showReviewPoints || showPausedBatch {
                    WorkspaceSettingsCard(title:"转写与理解", subtitle:"失败、待核对与可重试的处理项") {
                        if showIntents {
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"文字理解与关联") { WorkspaceBadge(text:"\(attention.unfinishedIntents.count)", tone:.warning) }
                                WorkspaceListDivider()
                                ForEach(attention.unfinishedIntents) { intent in
                                    VStack(alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                                        WorkspaceRow(title:name(intent.sourceID),subtitle:intentLabel(intent),trailing:"核对材料") { openSource(intent.sourceID) }.processingRowInset()
                                        if let error=intent.error { reason(error) }
                                        if intent.state == .queued && !model.modelConfigured { Button("配置模型后继续",action:openSettings).buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("配置模型后继续：" + name(intent.sourceID)).accessibilityIdentifier("processing.intent." + intent.id + ".configure") }
                                        if intent.state == .queued || intent.state == .running {
                                            Button("停止处理") { Task { await model.cancelProcessingIntent(intent) } }.buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("停止处理：" + name(intent.sourceID)).accessibilityIdentifier("processing.intent." + intent.id + ".stop")
                                        }
                                        if intent.canReprocess {
                                            Button("重新理解") { Task { await model.reprocessProcessingIntent(intent) } }
                                                .buttonStyle(.workspaceSecondaryCompact)
                                                .disabled(!model.modelConfigured)
                                                .accessibilityLabel("重新理解：" + name(intent.sourceID))
                                                .accessibilityIdentifier("processing.intent." + intent.id + ".retry")
                                        }
                                        if intent.canIgnore {
                                            Button("忽略这次") { Task { await model.ignoreProcessingIntent(intent) } }
                                                .buttonStyle(.workspaceQuietCompact)
                                                .accessibilityLabel("忽略这次理解失败：" + name(intent.sourceID))
                                                .accessibilityIdentifier("processing.intent." + intent.id + ".ignore")
                                        }
                                    }
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showFailedSources {
                            if showIntents { WorkspaceListDivider().padding(.horizontal,20) }
                            let retryableSources=failedSources.filter { $0.state == "saved" }
                            let sourceErrors=failedSources.compactMap { source in source.error.map { (source.displayTitle,$0) } }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"录音与转写需要查看") { WorkspaceBadge(text:"\(failedSources.count)", tone:.warning) }
                                Text("中断录音的已保存片段和转写失败的原件都会保留。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                ForEach(failedSources) { source in
                                    VStack(alignment:.leading,spacing:6) {
                                        WorkspaceRow(title:source.displayTitle,subtitle:source.state == "interrupted" ? "录音被中断" : "本地转写未完成",trailing:"查看材料") { openSource(source.id) }.processingRowInset()
                                        if source.dictationRecoveryPending {
                                            DictationRecoveryControls(model:model,source:source).padding(.leading,44).padding(.bottom,8)
                                        }
                                    }
                                }
                                reasons(sourceErrors)
                                if retryableSources.count > 1 {
                                    Button("重试全部本地转写（\(retryableSources.count)）") { retryAllTranscriptions(retryableSources) }.buttonStyle(.workspaceSecondary).disabled(model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil).accessibilityIdentifier("processing.transcription.retryAll")
                                } else if let source=retryableSources.first {
                                    Button("重试本地转写") { Task { await model.retry(source) } }.buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("重试本地转写：" + source.displayTitle).disabled(model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil).accessibilityIdentifier("processing.transcription." + source.id + ".retry")
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showEmptySources {
                            if showIntents || showFailedSources { WorkspaceListDivider().padding(.horizontal,20) }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"转写为空") { WorkspaceBadge(text:"\(emptySources.count)", tone:.warning) }
                                Text("录音与原件仍然保留，但这次没有转写出任何文字。可以重新转写，或移入回收站。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                ForEach(emptySources) { source in
                                    VStack(alignment:.leading,spacing:6) {
                                        WorkspaceRow(title:source.displayTitle,subtitle:emptyTranscriptSubtitle(source),trailing:"查看材料") { openSource(source.id) }.processingRowInset()
                                        HStack(spacing:12) {
                                            Button("重新转写") { Task { await model.retry(source) } }.buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("重新转写：" + source.displayTitle).disabled(model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil).accessibilityIdentifier("processing.transcription." + source.id + ".retry")
                                            EmptyTranscriptTrashControl(model:model,source:source)
                                        }.padding(.leading,44).padding(.bottom,8)
                                    }
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showWaiting {
                            if showIntents || showFailedSources || showEmptySources { WorkspaceListDivider().padding(.horizontal,20) }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"录音处理请求") { WorkspaceBadge(text:"\(waiting.count)", tone:.warning) }
                                WorkspaceListDivider()
                                ForEach(waiting) { request in
                                    VStack(alignment:.leading,spacing:6) {
                                        WorkspaceRow(title:name(request.sourceID),subtitle:request.state == "blocked" ? "处理条件已变化，需要重新核对" : "等待完整转写与原文核对，随后继续理解",trailing:"查看材料") { openSource(request.sourceID) }.processingRowInset()
                                        HStack(spacing:16) {
                                            if request.state == "blocked" {
                                                Button("重新核对并继续") { Task { await model.retryRecordingRequest(request) } }
                                                    .buttonStyle(.workspaceSecondaryCompact)
                                                    .disabled(!model.modelConfigured)
                                                    .accessibilityLabel("重新核对并继续录音处理：" + name(request.sourceID))
                                                    .accessibilityIdentifier("processing.request." + request.id + ".recheck")
                                            }
                                            Button("停止处理") { Task { await model.cancelRecordingRequest(request) } }.buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("停止处理录音处理请求：" + name(request.sourceID)).accessibilityIdentifier("processing.request." + request.id + ".stop")
                                        }.padding(.bottom,8)
                                    }
                                }
                                reasons(waiting.compactMap { request in request.error.map { (name(request.sourceID),$0) } })
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showSegmentedFailures {
                            if showIntents || showFailedSources || showEmptySources || showWaiting { WorkspaceListDivider().padding(.horizontal,20) }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"长录音分段理解未完成") { WorkspaceBadge(text:"\(segmentedFailures.count)", tone:.warning) }
                                Text("模型输出未通过本地校验，原文与旧记录保留；整批重试会新建处理，不覆盖这次记录。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                ForEach(segmentedFailures) { batch in
                                    VStack(alignment:.leading,spacing:6) {
                                        WorkspaceRow(title:name(batch.scope.plan.source.sourceID),subtitle:batch.state.allowsExplicitRetry ? "输出未通过校验，可整批重试" : "结果未知，未自动重发",trailing:"查看材料") { openSource(batch.scope.plan.source.sourceID) }.processingRowInset()
                                        if let error=batch.error { reason(error) }
                                        if batch.state.allowsExplicitRetry {
                                            Button("整批重试") { model.retrySegmentedBatch(batch) }
                                                .buttonStyle(.workspaceSecondaryCompact)
                                                .disabled(model.understandingSource != nil || !model.modelConfigured || model.fullRecordingBusy)
                                                .accessibilityLabel("整批重试长录音分段理解：" + name(batch.scope.plan.source.sourceID))
                                                .accessibilityIdentifier("processing.segmented." + batch.id + ".retry")
                                                .padding(.leading,44).padding(.bottom,8)
                                        }
                                    }
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showReviewSources {
                            if showIntents || showFailedSources || showEmptySources || showWaiting || showSegmentedFailures { WorkspaceListDivider().padding(.horizontal,20) }
                            let reviewErrors=reviewSources.compactMap { source in model.transcriptReviewIssue(for:source).map { (source.displayTitle,$0) } }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"完整转写核对未完成") { WorkspaceBadge(text:"\(reviewSources.count)", tone:.warning) }
                                Text("原音与原文保留，尚未进入云端理解。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                ForEach(reviewSources) { source in
                                    WorkspaceRow(title:source.displayTitle,subtitle:"",trailing:"查看材料") { openSource(source.id) }.processingRowInset()
                                }
                                reasons(reviewErrors)
                                if reviewSources.count > 1 {
                                    Button("重试全部完整转写核对（\(reviewSources.count)）") { retryAllTranscriptReviews(reviewSources) }.buttonStyle(.workspaceSecondary).disabled(!model.modelConfigured || model.transcriptReviewSourceID != nil || model.fullRecordingBusy).accessibilityIdentifier("processing.transcriptReview.retryAll")
                                } else if let source=reviewSources.first {
                                    Button("重试完整转写核对") { Task { await model.reviewTranscription(sourceID:source.id) } }.buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("重试完整转写核对：" + source.displayTitle).disabled(!model.modelConfigured || model.transcriptReviewSourceID != nil || model.fullRecordingBusy).accessibilityIdentifier("processing.transcriptReview." + source.id + ".retry")
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showReviewPoints {
                            if showIntents || showFailedSources || showEmptySources || showWaiting || showSegmentedFailures || showReviewSources { WorkspaceListDivider().padding(.horizontal,20) }
                            let issueTotal=reviewPoints.reduce(0) { $0 + $1.count }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"转写疑点待核对") { WorkspaceBadge(text:"\(issueTotal)", tone:.warning) }
                                Text("核对完成，仍有未解决疑点。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3).help("打开材料可以逐条回听原音与查看原文")
                                WorkspaceListDivider()
                                ForEach(reviewPoints) { point in
                                    WorkspaceRow(title:point.source.displayTitle,subtitle:"仍有 \(point.count) 条疑点未解决",trailing:"查看材料") { openSource(point.source.id) }.processingRowInset()
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showPausedBatch {
                            if showIntents || showFailedSources || showEmptySources || showWaiting || showSegmentedFailures || showReviewSources || showReviewPoints { WorkspaceListDivider().padding(.horizontal,20) }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading("批量重新识别")
                                WorkspaceListDivider()
                                PausedActionBatchControl(model:model)
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                    }
                }
                WorkspaceExternalCompletionBatchSection(model:model)
                if showPausedTasks || showFailedFollowups || showFailedKnowledgeReviews || showFailedAssistant || showAssessmentIssues {
                    WorkspaceSettingsCard(title:"行动与知识", subtitle:"待办、思想、知识与 AI 委托的未完成项") {
                        if showPausedTasks {
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"这些待办需要核对") { WorkspaceBadge(text:"\(pausedTasks.count)", tone:.warning) }
                                Text("这些待办尚未登记完成或关系待核对；核对后即可继续同步。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                let ids=Set(pausedTasks.flatMap { task in model.sourcePageIndex.claim(for: task.claimID)?.references.map(\.sourceID) ?? [] })
                                ForEach(model.records.filter { ids.contains($0.id) }) { source in
                                    WorkspaceRow(title:source.displayTitle,subtitle:"待核对",trailing:"打开材料") { openSource(source.id) }.processingRowInset()
                                    ForEach(pausedTasks.filter { task in model.sourcePageIndex.claim(for: task.claimID)?.references.contains { $0.sourceID == source.id } == true }) { task in
                                        VStack(alignment:.leading,spacing:5) {
                                            Text(task.title)
                                            Text(model.workspaceExternalCompletionNote(task) ?? model.workspaceActionStatus(task)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                            WorkspaceExternalCompletionButton(model:model,action:task)
                                            ForEach(model.actionReviewPairs(for:task)) { pair in
                                                ActionReviewResolutionControl(model:model,pair:pair)
                                            }
                                        }.padding(.leading,44).padding(.bottom,12)
                                    }
                                }
                                if model.pausedActionBatch == nil { PausedActionBatchControl(model:model) }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showFailedFollowups {
                            if showPausedTasks { WorkspaceListDivider().padding(.horizontal,20) }
                            let followupErrors=failedFollowups.compactMap { receipt in receipt.error.map { (name(receipt.sourceID),$0) } }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"思想与目标跟进未完成") { WorkspaceBadge(text:"\(failedFollowups.count)", tone:.warning) }
                                Text("原文和已有任务已保存；失败后可以重试。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                ForEach(failedFollowups) { receipt in
                                    WorkspaceRow(title:name(receipt.sourceID),subtitle:receipt.retryAt == nil ? "未安排自动重试" : "已安排自动重试",trailing:"查看材料") { openSource(receipt.sourceID) }.processingRowInset()
                                }
                                reasons(followupErrors)
                                if failedFollowups.count > 1 {
                                    Button("全部重试（\(failedFollowups.count)）") { model.retryAllFailedFollowups() }.buttonStyle(.workspaceSecondary).accessibilityLabel("全部重试思想与下一步（\(failedFollowups.count)）").disabled(!model.modelConfigured || model.followupBusy).accessibilityIdentifier("processing.followup.retryAll")
                                } else if let receipt=failedFollowups.first {
                                    Button("立即重试") { model.refreshFollowup(receipt.sourceID) }.buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("立即重试思想与下一步：" + name(receipt.sourceID)).disabled(!model.modelConfigured || model.followupBusy).accessibilityIdentifier("processing.followup." + receipt.sourceID + ".retry")
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showFailedKnowledgeReviews {
                            if showPausedTasks || showFailedFollowups { WorkspaceListDivider().padding(.horizontal,20) }
                            let knowledgeErrors=failedKnowledgeReviews.compactMap { review in review.error.map { (name(review.sourceID),$0) } }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"知识核查未完成") { WorkspaceBadge(text:"\(failedKnowledgeReviews.count)", tone:.warning) }
                                Text("当前理解与核查结论分别保留；不再跟进的可忽略这次。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                ForEach(failedKnowledgeReviews) { review in
                                    WorkspaceRow(title:name(review.sourceID),subtitle:"",trailing:"查看材料") { openSource(review.sourceID) }.processingRowInset()
                                    Button("忽略这次") { model.ignoreProcessingFailure("knowledge:" + review.id) }
                                        .buttonStyle(.workspaceQuietCompact)
                                        .accessibilityLabel("忽略这次知识核查：" + name(review.sourceID))
                                        .accessibilityIdentifier("processing.knowledge." + review.id + ".ignore")
                                        .padding(.bottom,8)
                                }
                                reasons(knowledgeErrors)
                                if failedKnowledgeReviews.count > 1 {
                                    Button("全部重试（\(failedKnowledgeReviews.count)）") { Task { await model.retryAllFailedKnowledgeReviews() } }.buttonStyle(.workspaceSecondary).accessibilityLabel("全部重试知识核查（\(failedKnowledgeReviews.count)）").disabled(!model.modelConfigured || model.knowledgeReviewBusy).accessibilityIdentifier("processing.knowledge.retryAll")
                                } else if let review=failedKnowledgeReviews.first {
                                    Button("重试知识核查") { Task { await model.reviewKnowledge(sourceID:review.sourceID,retry:true) } }.buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("重试知识核查：" + name(review.sourceID)).disabled(!model.modelConfigured || model.knowledgeReviewBusy).accessibilityIdentifier("processing.knowledge." + review.id + ".retry")
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showFailedAssistant {
                            if showPausedTasks || showFailedFollowups || showFailedKnowledgeReviews { WorkspaceListDivider().padding(.horizontal,20) }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading("AI 代办未完成")
                                WorkspaceListDivider()
                                ForEach(attention.failedAssistantExecutions) { execution in
                                    VStack(alignment:.leading,spacing:12) {
                                        Text(execution.title).vosFont(WorkspaceText.rowTitle)
                                        if let error=execution.error { reason(error) }
                                        HStack(spacing:16) {
                                            Button("查看委托与重试") { model.showTask(execution.actionID) }.buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("查看委托与重试：" + execution.title).accessibilityIdentifier("processing.assistant." + execution.id + ".open")
                                            Button("忽略这次") { model.ignoreProcessingFailure("assistant:" + execution.id) }.buttonStyle(.workspaceQuietCompact).accessibilityLabel("忽略这次 AI 代办：" + execution.title).accessibilityIdentifier("processing.assistant." + execution.id + ".ignore")
                                        }
                                    }
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showAssessmentIssues {
                            if showPausedTasks || showFailedFollowups || showFailedKnowledgeReviews || showFailedAssistant { WorkspaceListDivider().padding(.horizontal,20) }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading("AI 委托识别未完成")
                                WorkspaceListDivider()
                                ForEach(model.assistantAssessmentIssues) { issue in
                                    VStack(alignment:.leading,spacing:12) {
                                        Text(issue.title);reason(issue.error)
                                        Button("重新识别") { Task { await model.retryAssistantAssessment(issue) } }.buttonStyle(.workspaceSecondaryCompact).accessibilityLabel("重新识别：" + issue.title).disabled(!model.modelConfigured || model.assistantBusy).accessibilityIdentifier("processing.assistantAssessment." + issue.id + ".retry")
                                    }
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                    }
                }
                if showMonitor || showReminderAnomalies || showPendingReminderSyncs {
                    WorkspaceSettingsCard(title:"提醒与监测", subtitle:"提醒同步与消息监测的待核对项") {
                        if showMonitor {
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"消息监测") { WorkspaceBadge(text:"1", tone:.warning) }
                                Text("每日检查未完成或推送失败；已采集原文保留，不会重复发送。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                if let text = model.monitorAttentionText {
                                    WorkspaceNoticeText(message: text, severity: .warning)
                                }
                                HStack(spacing:16) {
                                    Button("去查看") { openMonitor() }.buttonStyle(.workspaceSecondary).accessibilityLabel("打开消息监测")
                                        .accessibilityIdentifier("processing.monitor.open")
                                    if model.monitorReports.first?.deliveryState == "failed" {
                                        Button("重试推送") { Task { await model.pushLatestMonitorReport() } }
                                            .buttonStyle(.workspaceSecondaryCompact)
                                            .disabled(model.monitorChecking)
                                            .accessibilityLabel("重试推送今日监测报告")
                                            .accessibilityIdentifier("processing.monitor.pushRetry")
                                    } else {
                                        Button("重新检查") { Task { await model.runMonitorCheck() } }
                                            .buttonStyle(.workspaceSecondaryCompact)
                                            .disabled(model.monitorChecking)
                                            .accessibilityLabel("重新检查消息监测")
                                            .accessibilityIdentifier("processing.monitor.recheck")
                                    }
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showReminderAnomalies {
                            if showMonitor { WorkspaceListDivider().padding(.horizontal,20) }
                            let reminderSubtitle = reminderAnomalies.total > 0
                                ? "有 \(reminderAnomalies.total) 条关联的提醒事项未完成回读" + (reminderAnomalies.failureTotal > 0 ? "，另有 \(reminderAnomalies.failureTotal) 条回读失败" : "") + "。可能已在提醒事项中被删除，任务保留为本地任务；重新回读只查询，不会重建。"
                                : "有 \(reminderAnomalies.failureTotal) 条回读失败。任务保留为本地任务；重新回读只查询，不会重建。"
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"提醒事项需要核对") { WorkspaceBadge(text:"\(reminderAnomalies.total + reminderAnomalies.failureTotal)", tone:.warning) }
                                Text(reminderSubtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                if reminderAnomalies.total > 0 {
                                    HStack(spacing:6) {
                                        WorkspaceBadge(text:"找不到 \(reminderAnomalies.count("missing"))", tone:.warning)
                                        WorkspaceBadge(text:"身份不一致 \(reminderAnomalies.count("conflict"))", tone:.warning)
                                        WorkspaceBadge(text:"未确认 \(reminderAnomalies.count("unknown"))", tone:.warning)
                                    }
                                    ForEach(reminderAnomalies.items) { item in
                                        VStack(alignment:.leading,spacing:6) {
                                            WorkspaceRow(title:item.actionTitle,subtitle:reminderAnomalySubtitle(item),trailing:"查看任务") { model.showTask(item.actionID) }.processingRowInset()
                                            if let link=model.reminderLinks.first(where: { $0.id == item.id }) {
                                                Button("重新回读") { Task { await model.readReminder(link) } }
                                                    .buttonStyle(.workspaceSecondaryCompact)
                                                    .accessibilityLabel("重新回读：" + item.actionTitle)
                                                    .accessibilityIdentifier("processing.reminder." + item.id + ".reread")
                                                    .disabled(model.remindersBusy || model.reminderFieldsPending || model.reminderAccess?.enabled != true)
                                                    .padding(.leading,44).padding(.bottom,8)
                                            }
                                        }
                                    }
                                }
                                ForEach(reminderAnomalies.failures) { failure in
                                    VStack(alignment:.leading,spacing:6) {
                                        WorkspaceRow(title:failure.actionTitle,subtitle:reminderSyncFailureSubtitle(failure),trailing:"查看任务") { model.showTask(failure.actionID) }.processingRowInset()
                                        Text("原因：" + WorkspaceProcessingErrorText.display(failure.reason)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled).padding(.leading,44).padding(.bottom,8)
                                    }
                                }
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showPendingReminderSyncs {
                            if showMonitor || showReminderAnomalies { WorkspaceListDivider().padding(.horizontal,20) }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"本地变更待同步提醒事项") { WorkspaceBadge(text:"\(pendingReminderSyncs.count)", tone:.accent) }
                                Text("这些变更只保存在 VoiceOS；恢复连接并授权后会自动写入 Apple 提醒事项并回读。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                ForEach(pendingReminderSyncs) { entry in
                                    VStack(alignment:.leading,spacing:6) {
                                        WorkspaceRow(title:entry.title,subtitle:entry.desiredState == LocalActionState.completed.rawValue ? "已在 VoiceOS 完成" : "已在 VoiceOS 撤销完成",trailing:"查看任务") { model.showTask(entry.actionID) }.processingRowInset()
                                        if let failure = entry.lastFailureReason {
                                            Text("上次同步未完成：" + WorkspaceProcessingErrorText.display(failure)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled).padding(.leading,44).padding(.bottom,8)
                                        }
                                    }
                                }
                                Button("现在核对") { Task { await model.retryPendingReminderSyncs() } }
                                    .buttonStyle(.workspaceSecondary)
                                    .disabled(model.remindersBusy || model.pendingReminderSyncs.isEmpty)
                                    .accessibilityLabel("现在核对 \(pendingReminderSyncs.count) 项待同步提醒")
                                    .accessibilityIdentifier("processing.reminderSync.check")
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                    }
                }
                if showStartupIssue || showTopicOrganization || showInbox || showModelStatus {
                    WorkspaceSettingsCard(title:"系统与后台", subtitle:"资料库、主题与运行配置") {
                        if showStartupIssue {
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading("资料库尚未打开")
                                Text("已有资料没有被重建或清空。处理原因后可以重新打开。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                reason(model.startupIssue)
                                Button("重试打开资料库") { Task { await model.start() } }
                                    .buttonStyle(.workspaceSecondary)
                                    .accessibilityIdentifier("processing.library.retry")
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showTopicOrganization {
                            if showStartupIssue { WorkspaceListDivider().padding(.horizontal,20) }
                            let pending=model.topicOrganizationPendingTopicCount
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading(title:"主题整理未完成") { WorkspaceBadge(text:"\(pending)", tone:.warning) }
                                Text("已完成的主题会保留；补齐只处理还没整理完的部分。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                                WorkspaceListDivider()
                                if let text=model.topicOrganizationAttentionText { reason(text) }
                                Button(pending > 0 ? "继续补齐正文（\(pending)）" : "立即重试") { model.queueTopicOrganization(retry:pending == 0, topUp:pending > 0) }
                                    .buttonStyle(.workspaceSecondary)
                                    .accessibilityLabel(pending > 0 ? "继续补齐主题正文（\(pending)）" : "立即重试主题整理")
                                    .accessibilityIdentifier("processing.topic.retry")
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showInbox {
                            if showStartupIssue || showTopicOrganization { WorkspaceListDivider().padding(.horizontal,20) }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading("录音自动入口")
                                WorkspaceListDivider()
                                Text(inbox.status).vosFont(WorkspaceText.meta)
                                Button("查看接收、重试与权限状态",action:openInbox)
                                    .buttonStyle(.workspaceSecondary)
                                    .accessibilityIdentifier("processing.inbox.open")
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                        if showModelStatus {
                            if showStartupIssue || showTopicOrganization || showInbox { WorkspaceListDivider().padding(.horizontal,20) }
                            VStack(alignment:.leading,spacing:12) {
                                WorkspaceSectionHeading("模型与提醒事项")
                                WorkspaceListDivider()
                                Text(model.modelConfigured ? model.modelSummary : "尚未配置模型；完整原文仍可先在本机保存。").vosFont(WorkspaceText.meta)
                                Text(model.reminderAccess?.enabled == true ? reminderSyncStatusText : "尚未连接提醒事项；任务可以先在 VoiceOS 内保存。").vosFont(WorkspaceText.meta)
                                if let error=model.reminderFieldIssue {
                                    reason(error)
                                    Button("重试提醒同步") { Task { await model.refreshTaskReminders() } }.buttonStyle(.workspaceSecondaryCompact).disabled(model.remindersBusy || model.reminderFieldsPending).accessibilityIdentifier("processing.reminderSync.retry")
                                }
                                Button("检查连接与配置",action:openSettings).buttonStyle(.workspaceSecondary).accessibilityIdentifier("processing.settings.open")
                            }.padding(.horizontal,20).padding(.top,14)
                        }
                    }
                }
                if !model.recentCompletions.isEmpty { WorkspaceCard {
                    VStack(alignment:.leading,spacing:12) {
                        WorkspaceSectionHeading(title:"最近完成") { WorkspaceBadge(text:"\(model.recentCompletions.count)", tone:.neutral) }
                        WorkspaceListDivider()
                        ForEach(model.recentCompletions) { item in
                            WorkspaceRow(title:item.title,subtitle:item.category + " · " + item.date.formatted(date:.abbreviated,time:.shortened),trailing:"查看材料") { openSource(item.sourceID) }.processingRowInset()
                        }
                    }
                } }
                if model.initialized, !attention.processingOutstanding, !model.workspaceProcessingBarVisible,
                   inbox.pendingItems.isEmpty, inbox.folderErrors.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        WorkspaceBadge(text:"已全部处理", tone:.success)
                            .accessibilityLabel("已全部处理，没有需要查看的处理结果")
                        Text(model.recentCompletions.isEmpty ? "本次运行还没有完成记录；最近 5 条会保留在这里。" : "以上是本次运行最近完成的记录。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    }
                }
            }.frame(maxWidth:760,alignment:.leading).padding(WorkspaceMetrics.pagePadding).frame(maxWidth:.infinity,alignment:.top)
        }
        .onChange(of: model.recentCompletions.first?.id) { previous, current in
            guard let current, current != previous, let item = model.recentCompletions.first else { return }
            AccessibilityNotification.Announcement("已完成：" + item.title).post()
        }
    }
    private func name(_ id:String) -> String { model.sourcePageIndex.recordsByID[id]?.displayTitle ?? "已保存的材料" }
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
    private func reminderSyncFailureSubtitle(_ failure: ReminderSyncFailure) -> String {
        let stage = failure.stage == .expression ? "提醒补录" : "新任务发送"
        let at = WorkspaceProcessingFormatting.iso8601.date(from: failure.failedAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? failure.failedAt
        return stage + "失败 · " + at
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
        Button("移入回收站") { confirming = true }.buttonStyle(.workspaceDestructive).disabled(source.state != "saved")
            .accessibilityIdentifier("processing.transcription." + source.id + ".trash")
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
                    Button("确认外部已完成") { confirming = true }.buttonStyle(.workspaceSecondaryCompact).disabled(model.savingAction)
                        .accessibilityIdentifier("processing.external." + action.id + ".confirm")
                }
                if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
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
            model.sourcePageIndex.claim(for: item.action.claimID)?.references.first?.sourceID ?? ""
        }
        return grouped.map { sourceID, items in
            let title = sourceID.isEmpty ? "已保存的材料" : (model.sourcePageIndex.recordsByID[sourceID]?.displayTitle ?? "已保存的材料")
            return WorkspaceExternalCompletionGroup(sourceID: sourceID, title: title, items: items.sorted { $0.action.title < $1.action.title })
        }.sorted { $0.title < $1.title }
    }
    var body: some View {
        let groups = self.groups
        if !groups.isEmpty {
            let total = groups.reduce(0) { $0 + $1.items.count }
            WorkspaceCard {
                VStack(alignment:.leading,spacing:12) {
                    WorkspaceSectionHeading(title:"提醒事项已完成待登记") { WorkspaceBadge(text:"\(total)", tone:.accent) }
                    Text("共 \(total) 条，来自 \(groups.count) 份材料。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineSpacing(3)
                    WorkspaceListDivider()
                    ForEach(groups) { group in
                        VStack(alignment:.leading,spacing:0) {
                            HStack(spacing:12) {
                                Image(systemName:"doc.text").vosFont(WorkspaceText.rowTitle.size).foregroundStyle(palette.accent)
                                    .frame(width:30,height:30).background(palette.selection.opacity(0.6),in:RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
                                    .accessibilityHidden(true)
                                Text(group.title).vosFont(WorkspaceText.rowTitle)
                                WorkspaceBadge(text:"\(group.items.count) 条", tone:.neutral)
                                Spacer(minLength:8)
                                Button("全部确认（\(group.items.count)）") { pending = group; confirming = true }
                                    .buttonStyle(.workspaceSecondaryCompact)
                                    .disabled(busy || model.savingAction)
                                    .accessibilityLabel("全部确认「\(group.title)」的 \(group.items.count) 条提醒事项已完成")
                                    .accessibilityIdentifier("processing.external." + group.sourceID + ".confirmAll")
                            }.padding(.vertical,10).padding(.horizontal,10)
                            ForEach(group.items) { item in
                                WorkspaceRow(title:item.action.title,subtitle:model.workspaceExternalCompletionNote(item.action) ?? model.workspaceActionStatus(item.action),icon:"circle",trailing:"查看任务") { model.showTask(item.action.id) }
                                    .padding(.leading,44)
                            }
                        }.padding(.bottom,8)
                    }
                    if !result.isEmpty {
                        Text(result).vosFont(WorkspaceText.meta).foregroundStyle(failed ? palette.danger : palette.secondaryText).textSelection(.enabled)
                    }
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
                guard let action = model.sourcePageIndex.allAction(for: item.action.id),
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

private extension View {
    /// `WorkspaceRow` already insets its text by 10; pull rows back so their text sits on the card's 20pt column.
    func processingRowInset() -> some View { padding(.horizontal, -10) }
}
