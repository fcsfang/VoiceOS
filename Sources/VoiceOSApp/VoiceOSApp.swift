import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import VoiceOSCore
import VoiceOSPlatform

@MainActor
final class ControlCenter: ObservableObject {
    @Published var textCaptureDraft = TextCaptureDraft() {
        didSet { if !textCaptureDraft.hasSameContents(as: oldValue) { scheduleDraftSave() } }
    }
    @Published var textCaptureDraftIssue = ""
    private var textCaptureDraftFile: URL?
    private var draftSaveWorker: Task<Void, Never>?
    private var draftNeedsSave = false
    private func restoreTextCaptureDraft(at root: URL) {
        let file = root.appendingPathComponent("草稿/文字录入.json")
        do { textCaptureDraft = try TextCaptureDraft.load(from: file) }
        catch {
            let backup = file.deletingLastPathComponent().appendingPathComponent("文字录入-读取失败-" + UUID().uuidString + ".json")
            do {
                try FileManager.default.copyItem(at: file, to: backup)
                textCaptureDraftIssue = "旧草稿读取失败，原文件已另存保留；可以继续记录。"
            } catch {
                textCaptureDraftIssue = "旧草稿无法读取或另存，暂未覆盖；这次请使用仅本地保存。"
                return
            }
        }
        textCaptureDraftFile = file
        draftNeedsSave = false
    }
    private func scheduleDraftSave() {
        guard textCaptureDraftFile != nil else { return }
        draftNeedsSave = true
        draftSaveWorker?.cancel()
        draftSaveWorker = Task {
            do { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation(); flushTextCaptureDraft() }
            catch {}
        }
    }
    func flushTextCaptureDraft() {
        draftSaveWorker?.cancel(); draftSaveWorker = nil
        guard draftNeedsSave, let file = textCaptureDraftFile else { return }
        do { try textCaptureDraft.save(to: file); draftNeedsSave = false; textCaptureDraftIssue = "" }
        catch { textCaptureDraftIssue = "草稿暂未自动保存：" + error.localizedDescription + "；请先使用仅本地保存。" }
    }
    @Published var records: [SourceRecord] = []
    @Published var recordingTitleStatus = ""
    @Published var generatingRecordingTitles = false
    private var recordingTitleModel: ResponsesRecordingTitlePort?
    private var recordingTitleWorker: Task<Void, Never>?
    private var recordingTitlesPending = false
    func queueRecordingTitles() {
        guard initialized, recordingTitleModel != nil else { return }
        if recordingTitleWorker != nil { recordingTitlesPending = true; return }
        recordingTitleWorker = Task {
            defer { recordingTitleWorker = nil; generatingRecordingTitles = false }
            repeat {
                recordingTitlesPending = false
                guard let store, let port = recordingTitleModel,
                      (try? await store.sources())?.contains(where: { $0.needsContentTitle }) == true else { return }
                generatingRecordingTitles = true; recordingTitleStatus = "正在根据完整转写生成内容标题…"
                do {
                    let count = try await store.generateRecordingTitles(using: port)
                    recordingTitleStatus = "已更新 \(count) 份录音的内容标题"
                    await refresh()
                } catch { recordingTitleStatus = error.localizedDescription; return }
            } while recordingTitlesPending && !Task.isCancelled
        }
    }
    func renameRecording(_ record: SourceRecord, title: String?) async -> Bool {
        do {
            try await store?.renameRecording(sourceID: record.id, title: title)
            await refresh(); queueRecordingTitles(); return true
        } catch { recordingTitleStatus = error.localizedDescription; return false }
    }
    func manageMaterial(_ record: SourceRecord, disposition: MaterialDisposition) async {
        guard let store else { return }
        do {
            let catalog=Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0) })
            let ids=record.recordingExpression(in:catalog)?.sourceIDs ?? [record.id]
            try await store.setMaterialDisposition(sourceIDs:ids,disposition:disposition)
            await refresh()
            switch disposition {
            case .archived: status="材料已归档，可在材料页的“已归档”中恢复；历史依据仍保留。"
            case .trashed: status="材料已移入回收站；原件与历史保留，系统提醒事项未修改。"
            case .active: status="材料已恢复；从回收站恢复的内容仅本机保存，旧理解不自动启用。"
            }
        } catch { status=error.localizedDescription; await refresh() }
    }
    @Published var discussionList:[ConversationRecord] = []
    @Published var sourceDiscussions:[ConversationRecord] = []
    @Published var discussionSession:ConversationRecord?
    @Published var discussionTurns:[ConversationUserTurn] = []
    @Published var discussionReplies:[DiscussionAttemptRecord] = []
    @Published var discussionDerivations:[DiscussionClaimDerivation] = []
    @Published var claimOrigins:[DiscussionClaimDerivation] = []
    @Published var outcomeOrigins:[ConversationOutcomeOrigin] = []
    @Published var discussionOutcomes:[ConversationOutcomeRecord] = []
    @Published var discussionHistory:[ContextTranscript] = []
    @Published var discussionRecordingID:String?
    @Published var discussionSaving=false
    @Published var discussionSending=false
    @Published var discussionExtracting=false
    private var outcomeWorker:Task<Void,Never>?
    private var outcomeModel:ResponsesOutcomePort?
    @Published var discussionStatus="选择一份历史，明确进入讨论。"
    private var discussionModel:ResponsesDiscussionPort?
    @Published var selected: String?
    @Published var retrievalResult: RetrievalResult?
    @Published var retrievalStatus = ""
    @Published var searchingHistory = false
    private let retrieval = NativeRetrieval()
    private let semanticRetrieval: CoreMLRetrieval? = Bundle.main.resourceURL.map { $0.appendingPathComponent("BGE",isDirectory:true) }.flatMap { FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path) ? CoreMLRetrieval(root:$0) : nil }
    var semanticAvailable: Bool { semanticRetrieval != nil }
    private var retrievalWorker: Task<Void,Never>?
    private var retrievalGeneration = UUID()
    let relevance = RelevanceQueryCoordinator()
    @Published var quietFeedback: [CognitiveFeedbackItem] = []
    @Published var associationFeedback: [ExpressionAssociationFeedback] = []
    @Published var selectedAssociationFeedback: [ExpressionAssociationFeedback] = []
    @Published var selectedAssociationAttempts: [ExpressionAssociationAttempt] = []
    @Published var associationStatuses: [String: String] = [:]
    @Published var quietAssociationSourceID: String?
    private var associationModel: ResponsesExpressionAssociationPort?
    @Published var quietMode: CognitiveFeedbackMode = .normal
    @Published var quietStatus = ""
    private var quietVersion = 0
    func refreshQuietFeedback() async {
        guard let store else { return }
        do {
            let preference = try await store.cognitiveFeedbackPreference()
            quietMode = preference.mode; quietVersion = preference.version
            quietFeedback = quietAssociationSourceID == nil ? try await store.cognitiveFeedback() : []
            associationFeedback = try await store.expressionAssociationFeedback(currentSourceID: quietAssociationSourceID)
            await refreshAssociationSelection()
            quietStatus = "关联属于AI提案；问题状态来自单独登记的历史，不因关联判断而改变，无需回应。"
        } catch { quietFeedback = []; associationFeedback = []; quietStatus = error.localizedDescription }
    }
    func refreshAssociationSelection() async {
        guard let store, let id = selected else { selectedAssociationFeedback = []; selectedAssociationAttempts = []; return }
        do {
            let items = try await store.expressionAssociationFeedback(currentSourceID: id)
            let attempts = try await store.expressionAssociationAttempts().filter { $0.currentSourceID == id }
            if selected == id {
                selectedAssociationFeedback = items; selectedAssociationAttempts = attempts
                if let source = records.first(where: { $0.id == id }) {
                    let current = attempts.first {
                        $0.snapshot.current.sources.first?.transcriptVersionID == source.transcriptVersionID && $0.snapshot.policyVersion == source.policyVersion
                    }
                    if current?.validity == "frozen" {
                        associationStatuses[id] = "旧关联依据已变化，已暂停使用；保留历史，不自动重发。"
                    } else if current == nil, !attempts.isEmpty {
                        associationStatuses[id] = nil
                    }
                }
            }
        } catch { if selected == id { selectedAssociationFeedback = []; selectedAssociationAttempts = [] } }
    }
    private func associateUnderstoodExpression(_ id: String, segmentedBatchID: String? = nil) async {
        guard let store else { return }
        do {
            guard let source = try await store.sources().first(where: { $0.id == id }), source.origin == "user", source.speaker == "user" else { return }
            associationStatuses[id] = "正在本机寻找授权历史；关联判断最多发送一次文字请求。"
            let local: any LocalRetrievalPort
            if let semanticRetrieval { local = semanticRetrieval } else { local = retrieval }
            let result: ExpressionAssociationProcessing
            if let batchID=segmentedBatchID { result=try await store.processCommittedSegmentedAssociation(batchID:batchID,retrieval:local,semantic:semanticRetrieval != nil,model:associationModel) }
            else { result=try await store.processExpressionAssociation(sourceID:id,retrieval:local,semantic:semanticRetrieval != nil,model:associationModel) }
            switch result.state {
            case .paused: associationStatuses[id] = "静默关联已暂停；没有发送。"
            case .localOnly: associationStatuses[id] = "表达仅本机处理；没有发送关联判断。"
            case .modelUnavailable: associationStatuses[id] = "关联文本模型不可用；没有发送。"
            case .budgetExceeded: associationStatuses[id] = "完整原话与历史超过关联预算；没有裁剪或发送。"
            case .noCandidates: associationStatuses[id] = "本机召回没有找到可用候选；未调用关联模型，不代表历史一定没有相关内容。"
            case .inFlight: associationStatuses[id] = "关联已有在途预留；不会重复发送。"
            case .unknown: associationStatuses[id] = "关联结果未知；已保留尝试和已知用量，不自动重发。"
            case .frozen: associationStatuses[id] = "旧关联依据已变化，已暂停使用；保留历史，不自动重发。"
            case .completed: associationStatuses[id] = result.attempt?.proposals.isEmpty == true ? "关联判断已完成，没有直接相关提案。" : "历史关联已保存；关系属于AI提案，未改变观点或行动。"
            }
        } catch { associationStatuses[id] = "关联未完成：" + error.localizedDescription }
        await refreshQuietFeedback()
    }
    func changeQuietMode(_ mode: CognitiveFeedbackMode) async {
        guard let store else { return }
        do { try await store.setCognitiveFeedbackMode(mode,expectedVersion:quietVersion); await refreshQuietFeedback() }
        catch { await refreshQuietFeedback(); quietStatus = error.localizedDescription }
    }
    func ignoreQuietFeedback(_ item: CognitiveFeedbackItem) async {
        guard let store else { return }
        do { try await store.ignoreCognitiveFeedback(attemptID:item.attemptID,candidateID:item.hit.id); await refreshQuietFeedback() }
        catch { await refreshQuietFeedback(); quietStatus = error.localizedDescription }
    }
    func ignoreAssociation(_ item: ExpressionAssociationFeedback) async {
        guard let store else { return }
        do { try await store.ignoreExpressionAssociation(attemptID: item.attemptID, candidateID: item.proposal.candidateID, relation: item.proposal.relation); await refreshQuietFeedback() }
        catch { await refreshQuietFeedback(); quietStatus = error.localizedDescription }
    }
    func openAssociation(_ item: ExpressionAssociationFeedback, historical: Bool) async -> Bool {
        guard let store else { return false }
        do {
            guard try await store.expressionAssociationFeedback(currentSourceID: item.currentSourceID).contains(where: { $0.id == item.id }) else { throw VoiceOSError("关联已失效或已忽略，请刷新") }
            selected = historical ? item.historical.document.sourceID : item.currentSourceID
            await refresh(); return true
        } catch { await refreshQuietFeedback(); quietStatus = error.localizedDescription; return false }
    }
    func openQuietFeedback(_ item: CognitiveFeedbackItem) async -> Bool {
        guard let store else { return false }
        do {
            let hit = try await store.cognitiveFeedbackHit(attemptID:item.attemptID,candidateID:item.hit.id)
            selected = hit.document.sourceID; await refresh(); return true
        } catch { await refreshQuietFeedback(); quietStatus = error.localizedDescription; return false }
    }
    private var relevanceModel: ResponsesRelevancePort?
    func prepareRelevance(query: String, candidates: [RetrievalHit]) async {
        guard let store else { return }
        await relevance.prepare(query:query,candidates:candidates,store:store)
    }
    func judgeRelevance() {
        guard let store, let port = relevanceModel else { return }
        relevance.run(store:store,port:port)
    }
    func cancelHistorySearch() {
        relevance.cancel()
        retrievalWorker?.cancel(); retrievalWorker = nil; retrievalGeneration = UUID()
        searchingHistory = false; retrievalResult = nil; retrievalStatus = ""
    }
    func searchHistory(query: String, semantic: Bool) {
        guard let store else { return }
        cancelHistorySearch(); let generation = retrievalGeneration
        let port: any LocalRetrievalPort
        if semantic {
            guard let semanticRetrieval else { retrievalStatus = "本地语义资源未安装，请使用关键词查找"; return }
            port = semanticRetrieval
        } else { port = retrieval }
        searchingHistory = true; retrievalStatus = "正在本机查找历史文字…"
        retrievalWorker = Task {
            do {
                let result = try await store.retrieve(query,semantic:semantic,limit:semantic ? 8 : 20,using:port)
                guard generation == retrievalGeneration else { return }
                retrievalResult = result
                retrievalStatus = semantic ? "本机扫描 \(result.scannedSources) 份资料 · 显示 \(result.hits.count) 份按排序候选，尚未判断相关性" : "此次扫描 \(result.scannedSources) 份资料 · 找到 \(result.matchingSources) 份，显示 \(result.hits.count) 份"
            } catch {
                guard generation == retrievalGeneration else { return }
                retrievalStatus = error.localizedDescription
            }
            searchingHistory = false; retrievalWorker = nil
        }
    }
    func openRetrievalHit(_ hit: RetrievalHit) async -> Bool {
        guard let store else { return false }
        do { try await store.validateRetrievalHit(hit); selected = hit.document.sourceID; await refresh(); return true }
        catch { cancelHistorySearch(); retrievalStatus = error.localizedDescription; return false }
    }
    @Published var query = ""
    var filtered: [SourceRecord] {
        query.isEmpty ? records : records.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) || ($0.transcript?.localizedCaseInsensitiveContains(query) ?? false) }
    }
    @Published var status = "正在检查资料库…"
    @Published var importing = false
    @Published var fullRecordingInput: FullRecordingInput?
    @Published var fullRecordingBusy = false
    @Published var fullRecordingStatus = ""
    @Published var fullRecordingDetail = ""
    @Published var fullRecordingCount: Int?
    @Published var fullRecordingOutput: URL?
    private var fullRecordingWorker: Task<Void, Never>?
    private var fullRecordingLog: URL?
    private(set) var fullRecordingSourceID: String?
    let recordingInbox: RecordingInbox
    private var textConfigurationFile: URL?
    @Published var changingPolicy = false
    @Published var understandingSource: String?
    @Published var modelConfigured = false
    @Published var modelSummary = "尚未配置文本模型"
    @Published var speechSummary = "Qwen 本地转写 · 尚未配置"
    private var speechPort: (any SpeechPort)?
    private let speechPreferenceKey="voiceos.localSpeechSelection.v1"
    private func installSpeechSelection(_ selection: LocalSpeechSelection, persist: Bool) throws {
        let port=try selection.port()
        let encoded=try JSONEncoder().encode(selection)
        if persist { UserDefaults.standard.set(encoded,forKey:speechPreferenceKey) }
        speechPort=port
        speechSummary="Qwen 本地转写 · 完整音轨"
    }
    private func restoreSpeechSelection() {
        guard let data=UserDefaults.standard.data(forKey:speechPreferenceKey) else {
            status="原件可保存；请配置已选定的本地 Qwen 转写模型"
            return
        }
        do {
            guard data.count<=32_768 else { throw VoiceOSError("转写选择配置过大") }
            let selection=try JSONDecoder().decode(LocalSpeechSelection.self,from:data)
            try installSpeechSelection(selection,persist:false)
        } catch {
            speechPort=nil;speechSummary="已保存的本地转写配置不可用"
            status="保留原件和待转写任务；请修复本地转写配置，不会自动切换模型"
        }
    }
    func chooseLocalSpeech() {
        guard worker == nil,!dictationActive else { status="请等待当前处理结束后切换转写器";return }
        let panel=NSOpenPanel();panel.title="选择本地 Qwen 转写配置";panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do {
            try installSpeechSelection(.init(configuration:Data(contentsOf:url)),persist:true)
            status="Qwen 转写选择已保存，重启后继续使用；已有逐字稿保持原版本"
            scheduleProcessing()
        } catch { status="无法启用本地 Qwen，请核对配置与模型；保留当前转写器" }
    }
    @Published var attempts: [String: [ModelAttemptRecord]] = [:]
    @Published var processingIntents: [ExpressionProcessingIntentRecord] = []
    @Published var processingActivity: WorkspaceProcessingActivity?
    @Published var recordingRequests: [RecordingProcessingRequest] = []
    @Published var segmentationPlan: TranscriptSegmentationPlan?
    @Published var segmentationStatus = ""
    @Published var segmentedBatches: [SegmentedProcessingBatch] = []
    @Published var segmentedCognitiveCounts: [String:Int] = [:]
    @Published var segmentedAssociationStates: [String:String] = [:]
    private var segmentExtractionModel: ResponsesSegmentExtractionPort?
    private var segmentAggregationModel: ResponsesSegmentAggregationPort?
    private var textModel: ResponsesModelPort?
    private var followupModel: ResponsesRecordingFollowupPort?
    private var assistantModel: ResponsesAssistantPort?
    private var knowledgeReviewModel: ResponsesKnowledgeReviewPort?
    private var knowledgeReviewWorker: Task<Void, Never>?
    @Published var knowledgeReviews: [KnowledgeReviewRecord] = []
    @Published var knowledgeReviewBusy = false
    @Published var knowledgeReviewStatus = ""
    @Published var transcriptReviewSourceID: String?
    @Published var transcriptReviewStatus = ""
    func transcriptReviewIssue(for source: SourceRecord) -> String? {
        guard let version = source.transcriptVersionID else { return nil }
        return transcriptReviewFailures[source.id + ":" + version + ":" + String(source.policyVersion)]
    }
    private var transcriptReviewWorker: Task<Void, Error>?
    private var transcriptReviewFailures: [String: String] = [:]
    private var assistantWorker: Task<Void, Never>?
    @Published var assistantExecutions: [AssistantExecutionRecord] = []
    @Published var assistantAssessmentIssues: [AssistantAssessmentIssue] = []
    @Published var assistantBusy = false
    @Published var assistantStatus = ""
    private var reminderFieldModel: ResponsesReminderFieldPort?
    private var reminderFieldWorker: Task<Void, Never>?
    private var reminderFieldFailure: String?
    var reminderFieldsPending: Bool { reminderFieldWorker != nil }
    var reminderFieldIssue: String? { reminderFieldFailure }
    private var reminderFieldsReady = false
    @Published var reminderFieldEditing = false
    @Published var recordingFollowups: [RecordingFollowupReceipt] = []
    @Published var followupValidity: [String: RecordingFollowupValidity] = [:]
    @Published var taskPresentation = 0
    @Published var outcomeFollowups: [ActionRecord] = []
    @Published var recentOutcomes: [ActionFeedbackRecord] = []
    @Published var discussionReflection: ConversationReflectionFocus?
    @Published var skippedOutcomeKeys = Set<String>()
    private var outcomePreferenceKey = "voiceos.outcomeFollowup.skipped"
    private var lastRecordingOutcome: RecordingInboxOutcome = .needsAttention("尚未开始处理")
    var visibleOutcomeFollowups: [ActionRecord] { outcomeFollowups.filter { !skippedOutcomeKeys.contains($0.id + ":" + String($0.version)) } }
    func skipOutcome(_ action: ActionRecord) {
        skippedOutcomeKeys.insert(action.id + ":" + String(action.version))
        UserDefaults.standard.set(Array(skippedOutcomeKeys), forKey: outcomePreferenceKey)
    }
    func showSkippedOutcomes() {
        skippedOutcomeKeys = []; UserDefaults.standard.removeObject(forKey: outcomePreferenceKey)
    }
    @Published var followupBusy = false
    @Published var followupStatus = ""
    private var followupWorker: Task<Void, Never>?
    private var understandingWorker: Task<Void, Never>?
    @Published var initialized = false
    @Published var startupIssue = ""
    @Published var player: AVPlayer?
    private var playbackBoundary: Any?
    @Published var history: [TranscriptVersion] = []
    @Published var claims: [CandidateClaim] = []
    /// Source-facing claims use only the newest completed producer for that
    /// source.  `claims` remains the full audit view for history and review.
    @Published var currentClaimsBySource: [String: [CandidateClaim]] = [:]
    @Published var questionRecords: [QuestionRecord] = []
    @Published var questionRevisions: [String: [QuestionRevision]] = [:]
    @Published var savingQuestion = false
    @Published var claimHistory: [ClaimReviewVersion] = []
    @Published var reviewingClaim = false
    @Published var actionRecords: [ActionRecord] = []
    @Published var focusedTaskID: String?
    @Published var correctionImpacts: [CorrectionActionImpact] = []
    @Published var compensationPlans: [ReminderCompensationPlan] = []
    @Published var compensationGrants: [ReminderCompensationGrant] = []
    @Published var compensationOperations: [ReminderCompensationOperation] = []
    @Published var pendingCompensation: ReminderCompensationPlan?
    @Published var scheduleIntents: [ActionScheduleIntent] = []
    @Published var scheduleOperations: [ReminderScheduleOperation] = []
    @Published var scheduleGrants: [ReminderScheduleGrant] = []
    @Published var pendingScheduleEffect: ReminderScheduleEffect?
    @Published var schedulePreviews: [String: ReminderScheduleDecision] = [:]
    @Published var savingAction = false
    @Published var actionVersions: [ActionRevision] = []
    @Published var feedbackRecords: [ActionFeedbackRecord] = []
    @Published var activeActionTitle = ""
    @Published var savingFeedback = false
    @Published var reminderLinks: [ReminderLink] = []
    @Published var reminderCalendars: [ReminderCalendar] = []
    @Published var reminderCalendarID = ""
    @Published var proposedReminderCalendarID = ""
    @Published var reminderAccess: ReminderAccess?
    @Published var reminderSyncStatus = "尚未启用自动回读"
    private var reminderObservers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var reminderTimer: Timer?
    private var followupTimer: Timer?
    private lazy var reminderRefresh = ReminderRefreshCoordinator { [weak self] in await self?.automaticReminderRefresh() }

    @Published var remindersBusy = false
    @Published var choosingReminderCalendar = false
    private let reminders = NativeReminders()
    var reminderCalendarTitle: String { reminderCalendars.first { $0.id == reminderCalendarID }?.title ?? (reminderAccess?.enabled == true ? reminderAccess!.title : "未选择清单") }
    func recordingActionRequiresReview(_ action:ActionRecord) -> Bool {
        let sourceIDs=Set(claims.first(where: { $0.id == action.claimID })?.references.map(\.sourceID) ?? [])
        return records.contains { source in
            guard let expression=source.presentation?.expression else { return false }
            return (sourceIDs.contains(source.id) || expression.previousActionIDs.contains(action.id)) && expression.requiresActionReview(actionID:action.id)
        }
    }
    func reminderSourceAllowed(_ action: ActionRecord) -> Bool {
        guard let claim = claims.first(where: { $0.id == action.claimID }) else { return false }
        return !recordingActionRequiresReview(action) && !claim.references.isEmpty && claim.references.allSatisfy { ref in records.contains { $0.id == ref.sourceID && !$0.localOnly } }
    }
    private let rootOverride: URL?
    var libraryTitle: String { rootOverride == nil ? "VoiceOS" : "独立资料库 · " + rootOverride!.lastPathComponent }
    init(root: URL? = nil) {
        rootOverride=root
        recordingInbox=RecordingInbox(libraryRoot:root ?? ProcessInfo.processInfo.environment["VOICEOS_DATA_DIR"].map { URL(fileURLWithPath:$0) })
    }
    var store: VoiceOSStore?
    @Published var workspaceTopics: [ReflectionQuestion] = []
    @Published var workspaceTopicSources: [String: [String]] = [:]
    @Published var workspaceBriefing: WorkspaceBriefing?
    @Published var organizingTopics = false
    @Published var topicOrganizationStatus = ""
    private var topicModel: ResponsesTopicOrganizationPort?
    var recordingExpressionModel: ResponsesRecordingExpressionPort?
    private var topicWorker: Task<Void, Never>?
    private var topicAttemptDigest: String?
    private var topicPending = false
    private var topicForcePending = false
    func queueTopicOrganization(retry: Bool = false) {
        guard initialized, topicModel != nil else { return }
        topicForcePending = topicForcePending || retry
        if topicWorker != nil { topicPending = true; return }
        if retry { topicAttemptDigest = nil }
        topicWorker = Task {
            defer { topicWorker = nil; organizingTopics = false }
            repeat {
                topicPending = false
                let force = topicForcePending
                topicForcePending = false
                do {
                    guard let store, let port = topicModel, let input = try await store.prepareTopicOrganization() else { return }
                    if !force {
                        guard input.digest != topicAttemptDigest, try await store.workspaceBriefing()?.digest != input.digest else { return }
                    }
                    topicAttemptDigest = input.digest
                    organizingTopics = true; topicOrganizationStatus = "AI 正在连接跨时间的材料与任务…"
                    _ = try await store.organizeTopics(using: port, force: force)
                    topicOrganizationStatus = "主题与首页简报已更新"
                    await refresh()
                } catch { topicOrganizationStatus = "主题整理未完成：" + error.localizedDescription }
            } while topicPending && !Task.isCancelled
        }
    }

    @Published var dictationBusy = false
    @Published var dictationActive = false
    private var dictationSource: String?
    private var dictationInterrupted = false
    private var dictationFullOrganization = false
    private let dictation = NativeDictation()
    private var dictationObservers: [NSObjectProtocol] = []
    func startDictation(processAfterTranscription: Bool = false) async {
        guard let store, !dictationBusy, !dictationActive, !fullRecordingBusy, !importing, worker == nil, understandingWorker == nil else { status = "请等待当前录音或文字处理结束"; return }
        if processAfterTranscription {
            guard speechPort is LocalQwenSpeechPort, modelConfigured, textConfigurationFile != nil,
                  Bundle.main.url(forResource: "organize_podcast", withExtension: "py") != nil else { status = "请先配置 Qwen 和文本模型，再录制并完整整理"; return }
        }
        dictationBusy = true; defer { dictationBusy = false }
        let duration: TimeInterval?
        if let raw = ProcessInfo.processInfo.environment["VOICEOS_TEST_CAPTURE_SECONDS"] {
            guard let seconds = Double(raw), seconds.isFinite, seconds > 0, seconds <= 60 else { status = "限时采集参数无效，未开启麦克风"; return }
            duration = seconds
        } else { duration = nil }
        guard await dictation.requestPermission() else { status = "麦克风未获授权，未开始录制；仍可导入文件"; return }
        do {
            let intent = try await store.beginDictation()
            dictationFullOrganization = processAfterTranscription
            dictationSource = intent.sourceID; dictationInterrupted = false
            try dictation.start(at:intent.stagingURL,maximumDuration:duration) { [weak self] success in Task { await self?.finishDictation(success:success) } }
            dictationActive = true; selected = intent.sourceID
            status = duration.map { "正在进行\($0)秒限时采集 · 到时自动停止 · 仅本地" } ?? "正在录制我的口述 · 仅本地；停止后才核对并封存原件"
            if processAfterTranscription { status = "正在录制 · 停止后完整转写并整理所有意图；仅文字用于云端" }
            await refresh()
        } catch {
            if let id = dictationSource { try? await store.interruptDictation(sourceID:id) }
            dictationSource = nil; dictationActive = false; dictationFullOrganization = false; status = error.localizedDescription; await refresh()
        }
    }
    func stopDictation(interrupted:Bool = false) {
        guard dictationActive, !dictationBusy else { return }
        dictationInterrupted = interrupted; dictationBusy = true
        status = interrupted ? "录制因系统中断结束，保留片段待核对" : "正在停止录制并核对原件…"
        dictation.stop()
    }
    private func finishDictation(success:Bool) async {
        guard let store, let id = dictationSource else { return }
        let organize = dictationFullOrganization
        dictationFullOrganization = false
        dictationSource = nil; dictationActive = false
        defer { dictationBusy = false }
        if success && !dictationInterrupted {
            do { try await store.sealDictation(sourceID:id); status = "口述原件已保存 · 本地转写随后处理" }
            catch { try? await store.interruptDictation(sourceID:id); status = "录制封存未完成，请重开或核对片段；未报告保存成功" }
        } else {
            try? await store.interruptDictation(sourceID:id); status = "录制未正常结束，片段保留待核对；未报告保存成功"
        }
        await refresh()
        if discussionRecordingID == id {
            discussionStatus=records.first(where: { $0.id == id })?.state == "saved" ? "本轮口述原件已保存；等待本地转写与核对，尚未关联和发送。" : "本轮录制尚未正常保存，片段保留待核对；尚未关联和发送。"
        }
        if organize, records.first(where: { $0.id == id })?.state == "saved" {
            dictationBusy = false
            organizeSavedRecording(sourceID: id, transcribeFirst: true)
        } else { scheduleProcessing(); resumeRecordingFollowups() }
    }
    func recoverDictation(_ record:SourceRecord) async {
        guard let store, !dictationBusy, !dictationActive else { return }
        dictationBusy = true; defer { dictationBusy = false }
        do { try await store.sealDictation(sourceID:record.id); status = "可解码片段已保存；它是中断片段，不代表完整表达"; await refresh(); scheduleProcessing() }
        catch { status = "片段尚不能完整解码，保留待核对"; await refresh() }
    }
    func startFeedbackDictation() async -> String? {
        guard speechPort is LocalQwenSpeechPort, worker == nil, !fullRecordingBusy, !dictationActive, !dictationBusy else {
            status = "请先配置 Qwen，并等待当前录音或转写结束"; return nil
        }
        await startDictation()
        return dictationActive ? dictationSource : nil
    }
    private var worker: Task<Void, Never>?
    private var resumedSavedRecordingExpressions = false
    func start() async {
        guard store == nil else { return }
        startupIssue = ""
        do {
            let root: URL
            if let override = rootOverride { root = override }
            else if let path = ProcessInfo.processInfo.environment["VOICEOS_DATA_DIR"] { root = URL(fileURLWithPath: path, isDirectory: true) }
            else { root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("VoiceOS", isDirectory: true) }
            outcomePreferenceKey = "voiceos.outcomeFollowup.skipped:" + root.standardizedFileURL.path
            skippedOutcomeKeys = Set(UserDefaults.standard.stringArray(forKey: outcomePreferenceKey) ?? [])
            let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
            self.store = store
            try await store.recover()
            restoreTextCaptureDraft(at: root)
            initialized = true; status = "准备就绪 · 媒体只在本机处理"
            restoreSpeechSelection()
            if let path = ProcessInfo.processInfo.environment["VOICEOS_MODEL_CONFIG_FILE"] {
                configureTextModel(URL(fileURLWithPath: path))
            } else if let path = UserDefaults.standard.string(forKey: "voiceos.textModelConfigPath.v1") ?? Bundle.main.object(forInfoDictionaryKey: "VoiceOSModelConfigurationPath") as? String {
                configureTextModel(URL(fileURLWithPath: path))
            }
            await refresh()
            scheduleProcessing()
            installReminderRefresh()
            dictationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.flushTextCaptureDraft(); self?.stopDictation(interrupted:true) } })
            dictationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.stopDictation(interrupted:true) } })
            dictationObservers.append(NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.flushTextCaptureDraft(); self?.stopDictation(interrupted:true) } })
            requestReminderRefresh()
            resumeRecordingFollowups()
            queueRecordingTitles()
                recordingInbox.start(canProcess: { [weak self] in
                    guard let self else { return false }
                    return self.initialized && self.modelConfigured && self.speechPort is LocalQwenSpeechPort && !self.fullRecordingBusy && self.worker == nil && self.understandingWorker == nil && !self.dictationActive && !self.dictationBusy && !self.importing
                }, resumeSaved: { [weak self] in
                    await self?.resumeSavedRecordingExpressions()
                }, receive: { [weak self] batch, finished in
                    guard let self else { finished(Dictionary(uniqueKeysWithValues:batch.map { ($0.digest,.needsAttention("应用已关闭")) })); return }
                    self.organizeAutomaticRecordings(batch,finished:finished)
                })
        } catch {
            store = nil; initialized = false
            startupIssue = error.localizedDescription
            status = "资料库尚未打开：" + error.localizedDescription
        }
    }
    private var refreshWorker: Task<Void, Never>?
    private var refreshPending = false
    func refresh() async {
        refreshPending = true
        if let refreshWorker { await refreshWorker.value; return }
        let work = Task {
            defer { refreshWorker = nil }
            repeat {
                refreshPending = false
                await reloadWorkspace()
            } while refreshPending && !Task.isCancelled
        }
        refreshWorker = work
        await work.value
    }
    private func reloadWorkspace() async {
        guard let store else { return }
        do {
            let snapshot = try await store.workspaceSnapshot()
            // Publish together, without awaits between related data sets.
            records = snapshot.sources
            claims = snapshot.claims
            currentClaimsBySource = snapshot.currentClaimsBySource
            questionRecords = snapshot.questions
            questionRevisions = snapshot.questionHistories
            claimOrigins = snapshot.claimOrigins
            outcomeOrigins = snapshot.outcomeOrigins
            actionRecords = snapshot.actions
            assistantExecutions = snapshot.assistantExecutions
            assistantAssessmentIssues = snapshot.assistantAssessmentIssues
            knowledgeReviews = snapshot.knowledgeReviews
            recentOutcomes = snapshot.recentOutcomes
            outcomeFollowups = snapshot.outcomeFollowups
            correctionImpacts = snapshot.correctionImpacts
            compensationPlans = snapshot.compensationPlans
            compensationGrants = snapshot.compensationGrants
            compensationOperations = snapshot.compensationOperations
            scheduleIntents = snapshot.scheduleIntents
            scheduleOperations = snapshot.scheduleOperations
            scheduleGrants = snapshot.scheduleGrants
            schedulePreviews = snapshot.schedulePreviews
            reminderLinks = snapshot.reminderLinks
            reminderAccess = snapshot.reminderAccess
            reminderCalendarID = reminderAccess?.enabled == true ? reminderAccess!.calendarID : ""
            if reminderAccess?.enabled == false { reminderSyncStatus = "提醒事项连接已暂停 · 外部任务和历史保留" }
            workspaceTopics = snapshot.topics
            workspaceTopicSources = snapshot.topicSources
            workspaceBriefing = snapshot.briefing
            recordingFollowups = snapshot.recordingFollowups
            followupValidity = snapshot.followupValidity
            attempts = snapshot.attempts
            processingIntents = snapshot.processingIntents
            recordingRequests = snapshot.recordingRequests
            segmentedBatches = snapshot.segmentedBatches
            segmentedCognitiveCounts = snapshot.segmentedCognitiveCounts
            segmentedAssociationStates = snapshot.segmentedAssociationStates
            if let plan = segmentationPlan, !records.contains(where: { $0.id == plan.source.sourceID && $0.transcriptVersionID == plan.source.transcriptVersionID && $0.policyVersion == plan.policyVersion && ["saved","reference_only"].contains($0.state) }) {
                segmentationPlan = nil; segmentationStatus = "原话或授权已变化，请重新查看分段"
            }
            if let result = retrievalResult {
                let generation = retrievalGeneration
                do { try await store.validateRetrievalResult(result) }
                catch {
                    if generation == retrievalGeneration {
                        cancelHistorySearch(); retrievalStatus = "历史资料已变化，请重新查找"
                    }
                }
            }

            await relevance.validate(store:store)
            await refreshQuietFeedback()
            await refreshDiscussion()
            await refreshSourceDiscussions()
        }
        catch { status = error.localizedDescription }
        resumeAssistantExecutions()
        queueTopicOrganization()
    }
    func chooseTextModel() {
        let panel = NSOpenPanel()
        panel.title = "选择本地文本模型配置"; panel.prompt = "使用配置"
        panel.showsHiddenFiles = true; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url { self.configureTextModel(url) }
        }
    }
    private func configureTextModel(_ file: URL) {
        do {
            // Long segmented cognition uses the explicitly validated SSE
            // transport and 600-second window. Its versioned identity prevents
            // queued non-streaming attempts from being silently replayed.
            let suite=try LocalTextModel.loadSuite(from:file,segmentRequestTimeout:600,segmentStreaming:true),port=suite.cognition
            discussionModel=suite.discussion;outcomeModel=suite.outcome
            recordingTitleModel=suite.recordingTitles
            topicModel=suite.topics; topicAttemptDigest=nil
            recordingExpressionModel=suite.recordingExpressions
            assistantModel=suite.assistant
            followupModel=suite.followup;associationModel=suite.association;reminderFieldModel=suite.reminderFields
            knowledgeReviewModel=suite.knowledgeReview
            relevance.cancel();relevanceModel=suite.relevance
            segmentExtractionModel=suite.segmentExtraction;segmentAggregationModel=suite.segmentAggregation
            textModel = port; modelConfigured = true
            UserDefaults.standard.set(file.path, forKey: "voiceos.textModelConfigPath.v1")
            textConfigurationFile = file
            modelSummary = "gpt-6.1-sol · " + port.configuration.provider.replacingOccurrences(of: "responses:", with: "")
            status = "文本模型已就绪 · 只处理你选择并授权的文字"
            // A queued intent may have been restored before the user selected a
            // configuration. Wake the durable worker exactly once after the
            // new model identity is installed; scheduleProcessing() itself
            // remains the single-owner gate for concurrent work.
            scheduleProcessing()
            queueRecordingTitles()
            resumeRecordingFollowups()
            resumeAssistantExecutions()
            resumeKnowledgeReviews()
            queueTopicOrganization()
        } catch { status = error.localizedDescription }
    }
    func chooseFullRecording() {
        guard !fullRecordingBusy else { return }
        let panel = NSOpenPanel(); panel.title = "完整整理我的录音或 OBS 视频"; panel.prompt = "选择完整素材"
        panel.allowedContentTypes = [.audio, .movie, UTType(filenameExtension: "mkv") ?? .data]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let media = try await FullRecordingOrganizer.inspect(url)
                    self.fullRecordingCount = nil; self.fullRecordingStatus = ""
                    self.fullRecordingOutput = nil
                    self.fullRecordingInput = FullRecordingInput(url: url, media: media)
                } catch { self.status = error.localizedDescription }
            }
        }
    }
    func cancelFullRecording() { fullRecordingWorker?.cancel() }
    func openFullRecordingOutput() {
        if let fullRecordingOutput { NSWorkspace.shared.open(fullRecordingOutput.appendingPathComponent("完整任务清单.md")) }
    }
    func isCompletelyOrganized(_ record: SourceRecord) -> Bool {
        guard !record.needsTranscriptionReview else { return false }
        if attempts[record.id]?.contains(where: { $0.provider == "organized_import" && $0.state == "completed" && $0.contextState == "current" }) == true { return true }
        let claimIDs = Set((currentClaimsBySource[record.id] ?? []).filter { $0.validity == "current" }.map(\.id))
        return actionRecords.contains { claimIDs.contains($0.claimID) && $0.validity == "current" && $0.intent != nil }
    }
    /// One physical recording, two separate sources. Both complete transcripts
    /// are reviewed before binding, while only the personal source enters intent extraction.
    private func prepareRecordingContext(input:URL,media:RecordingMediaInfo,personalSourceID:String,personalTrack:Int,staging:URL,speech:LocalQwenSpeechPort) async throws {
        guard let store,media.usesPersonalRecordingLayout,personalTrack == media.personalTrack,let track=media.contextTrack else { return }
        let command="recording-context:"+personalSourceID+":\(track)"
        let externalID:String
        let log=staging.appendingPathComponent("节目轨处理日志.txt")
        if let existing=try await store.importedSourceID(commandID:command) { externalID=existing }
        else {
            setFullRecordingStatus("正在保存同次录制的完整节目音轨…")
            let audio=staging.appendingPathComponent(input.deletingPathExtension().lastPathComponent+"_节目音轨\(track).wav")
            if FileManager.default.fileExists(atPath:audio.path) { try FileManager.default.removeItem(at:audio) }
            let before=try FileManager.default.attributesOfItem(atPath:input.path)
            try await FullRecordingOrganizer.extract(input,track:track,to:audio,log:log)
            let after=try FileManager.default.attributesOfItem(atPath:input.path)
            guard before[.size] as? NSNumber == after[.size] as? NSNumber,before[.modificationDate] as? Date == after[.modificationDate] as? Date else { throw VoiceOSError("素材仍在更新，节目轨等待保存完成后重试") }
            externalID=try await store.importFile(audio,commandID:command)
            try FileManager.default.removeItem(at:audio)
        }
        let policy=try await store.sourcePolicy(sourceID:externalID)
        if policy.localOnly,policy.version == 1 { _ = try await store.setSourceLocalOnly(sourceID:externalID,expectedVersion:policy.version,localOnly:false) }
        guard try await !store.sourcePolicy(sourceID:externalID).localOnly else { throw VoiceOSError("节目文字已设为仅本机，双轨理解等待恢复许可") }
        var externalSpeech=speech;externalSpeech.progressLog=log;fullRecordingLog=log
        setFullRecordingStatus("正在本机完整转写节目音轨，保留外部来源…")
        try await store.processTranscriptions(using:externalSpeech,sourceIDs:[externalID])
        guard let external=try await store.sources().first(where: { $0.id == externalID }),external.jobState == "completed" else { throw VoiceOSError("节目完整转写尚未完成，保留本人转写等待续作") }
        fullRecordingLog=nil
        // A genuinely silent system track is valid input, not a broken personal
        // recording. Keep its original without inventing programme context.
        if (external.transcript ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            setFullRecordingStatus("节目音轨没有识别到讲话，继续整理本人口述…")
            return
        }
        setFullRecordingStatus("正在核对双方完整转写，随后关联节目与个人思考…")
        try await ensureTranscriptReviewed(sourceID:externalID)
        try await ensureTranscriptReviewed(sourceID:personalSourceID)
        try await store.attachRecordingContext(personalSourceID:personalSourceID,externalSourceID:externalID,sessionID:personalSourceID,offsetMS:media.contextOffsetMS(personalTrack:personalTrack))
    }
    func organizeAutomaticRecordings(_ batch:[RecordingInboxInput],finished:@escaping ([String:RecordingInboxOutcome])->Void) {
        guard let store,var speech=speechPort as? LocalQwenSpeechPort,let grouping=recordingExpressionModel,
              let configuration=textConfigurationFile,let script=Bundle.main.url(forResource:"organize_podcast",withExtension:"py"),!fullRecordingBusy else {
            finished(Dictionary(uniqueKeysWithValues:batch.map { ($0.digest,.retryableFailure("请等待模型就绪与当前整理完成")) }));return
        }
        fullRecordingBusy=true;fullRecordingCount=nil
        fullRecordingWorker=Task {
            let refreshTask=watchFullRecording()
            var outcomes:[String:RecordingInboxOutcome]=[:]
            defer { refreshTask.cancel();fullRecordingBusy=false;fullRecordingWorker=nil;fullRecordingLog=nil;fullRecordingSourceID=nil;finished(outcomes);scheduleProcessing();resumeRecordingFollowups();resumeKnowledgeReviews() }
            do {
                let root=await store.root
                // Seal and transcribe every stable clip before interpreting any of them.
                for entry in batch {
                    do {
                        try Task.checkCancellation()
                        let media=try await FullRecordingOrganizer.inspect(entry.url)
                        guard entry.voiceMemos || media.tracks.count == 1 || media.usesPersonalRecordingLayout else { throw VoiceOSError("素材不符合固定音轨格式，请选择本人音轨") }
                        let track=entry.voiceMemos ? 0 : media.personalTrack
                        let command="automatic-recording:"+entry.digest+":\(track)"
                        let staging=root.appendingPathComponent("整理/自动接收/"+entry.digest)
                        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
                        let log=staging.appendingPathComponent("处理日志.txt");fullRecordingLog=log;speech.progressLog=log
                        let id:String
                        if let saved=try await store.importedSourceID(commandID:command) { id=saved }
                        else {
                            let audio=staging.appendingPathComponent(entry.url.deletingPathExtension().lastPathComponent+".wav")
                            if FileManager.default.fileExists(atPath:audio.path) { try FileManager.default.removeItem(at:audio) }
                            let before=try FileManager.default.attributesOfItem(atPath:entry.url.path)
                            try await FullRecordingOrganizer.extract(entry.url,track:track,to:audio,log:log)
                            let after=try FileManager.default.attributesOfItem(atPath:entry.url.path)
                            guard before[.size] as? NSNumber == after[.size] as? NSNumber,before[.modificationDate] as? Date == after[.modificationDate] as? Date else { throw VoiceOSError("素材仍在更新，稍后自动重试") }
                            id=try await store.importPersonalAudio(audio,commandID:command)
                            try FileManager.default.removeItem(at:audio)
                        }
                        fullRecordingSourceID=id
                        let policy=try await store.sourcePolicy(sourceID:id)
                        // Automatic intake retains its existing text-processing grant; never regrant an explicit revocation on retry.
                        if policy.localOnly,policy.version == 1 { _ = try await store.setSourceLocalOnly(sourceID:id,expectedVersion:policy.version,localOnly:false) }
                        guard try await !store.sourcePolicy(sourceID:id).localOnly else { throw VoiceOSError("这份录音已改为仅本地，自动合并停止") }
                        setFullRecordingStatus("正在完整转写新录音，随后自动判断连续表达…")
                        try await store.processTranscriptions(using:speech,sourceIDs:[id])
                        guard let record=try await store.sources().first(where: { $0.id == id }),record.jobState == "completed",let version=record.transcriptVersionID else { throw VoiceOSError("完整录音转写尚未完成") }
                        let date=media.recordedAt ?? record.expressedDate?.ISO8601Format()
                        try await store.registerAutomaticRecording(sourceID:id,inbox:entry.inbox,recordedAt:date)
                        if record.needsTranscriptionReview {
                            let folder=staging.appendingPathComponent(version).appendingPathComponent(id)
                            _ = try await store.writeOrganizingInput(sourceID:id,to:folder)
                            setFullRecordingStatus("正在校正完整转写，保留每段原音与时间…")
                            try await FullRecordingOrganizer.organize(folder:folder,script:script,python:speech.pythonExecutable,configuration:configuration,log:log,reviewTranscriptOnly:true)
                            _ = try await store.applyTranscriptQualityResult(sourceID:id,expectedVersionID:version,from:folder)
                        }
                        try await prepareRecordingContext(input:entry.url,media:media,personalSourceID:id,personalTrack:track,staging:staging,speech:speech)
                    } catch {
                        outcomes[entry.digest]=automaticRecordingFailure(error)
                    }
                }
                await refresh()
                // Do not publish interpretations of half a delivery batch when another clip has not finished.
                guard outcomes.isEmpty else { throw VoiceOSError("本批录音尚未全部完成转写，连续表达等待自动重试") }
                fullRecordingLog=nil
                setFullRecordingStatus("AI 正在阅读全部分段并独立核对连续性…")
                try await preparePendingCorrectedRecordingContexts()
                _ = try await store.connectRecordingExpressions(using:grouping)
                try await understandPendingRecordingExpressions(store:store,speech:speech,grouping:grouping,configuration:configuration,script:script)
                for entry in batch { outcomes[entry.digest] = .completed }
                requestReminderRefresh();queueRecordingTitles();queueTopicOrganization()
                setFullRecordingStatus("连续表达已自动合并理解，原始分段与原话均保留")
            } catch {
                let failure=automaticRecordingFailure(error)
                for entry in batch where outcomes[entry.digest] == nil { outcomes[entry.digest]=failure }
                setFullRecordingStatus(error.localizedDescription)
            }
            await refresh()
        }
    }
    /// Once per launch, recover imported recordings that predate continuity
    /// metadata, and resume saved groups interrupted before whole-expression analysis.
    private func resumeSavedRecordingExpressions() async {
        guard !resumedSavedRecordingExpressions,worker == nil,understandingWorker == nil,!dictationActive,!dictationBusy,let store,
              let speech=speechPort as? LocalQwenSpeechPort,let grouping=recordingExpressionModel,
              let configuration=textConfigurationFile,let script=Bundle.main.url(forResource:"organize_podcast",withExtension:"py"),
              !fullRecordingBusy else { return }
        resumedSavedRecordingExpressions=true
        do {
            try await store.enrollPreviouslyImportedAutomaticRecordings()
            let corrected=try await store.sources().contains { $0.presentation?.correctedSourceIDs != nil }
            // A corrected programme deliberately invalidates the old pair. Repair
            // its saved versions before asking for fresh semantic grouping.
            let newInput=corrected ? nil : try await store.prepareRecordingExpressions()
            let pending=try await store.recordingExpressions().contains { $0.state != "completed" }
            try await acknowledgeCompletedRecordingExpressions(store:store)
            guard newInput != nil || pending || corrected else { return }
        } catch { setFullRecordingStatus(error.localizedDescription);return }
        fullRecordingBusy=true;fullRecordingCount=nil
        fullRecordingWorker=Task {
            let refreshTask=watchFullRecording()
            defer { refreshTask.cancel();fullRecordingBusy=false;fullRecordingWorker=nil;fullRecordingLog=nil;fullRecordingSourceID=nil;scheduleProcessing();resumeRecordingFollowups();resumeKnowledgeReviews() }
            do {
                setFullRecordingStatus("正在为已接收录音补充连续表达判断，复用完整转写…")
                try await preparePendingCorrectedRecordingContexts()
                _ = try await store.connectRecordingExpressions(using:grouping)
                try await understandPendingRecordingExpressions(store:store,speech:speech,grouping:grouping,configuration:configuration,script:script)
                try await acknowledgeCompletedRecordingExpressions(store:store)
                requestReminderRefresh();queueRecordingTitles();queueTopicOrganization()
                setFullRecordingStatus("已接收录音的连续表达已整理，原始分段保留")
            } catch { setFullRecordingStatus("连续表达尚未整理完成，重开应用后继续："+error.localizedDescription) }
            await refresh()
        }
    }
    private func acknowledgeCompletedRecordingExpressions(store:VoiceOSStore) async throws {
        let completed=Set(try await store.recordingExpressions().filter { $0.state == "completed" }.flatMap(\.sourceIDs))
        // Recovery may finish outside the inbox callback, including before a
        // restart. Clear stale failures only when the current group is complete.
        for item in recordingInbox.pendingItems where item.state != .processing {
            for track in [0,1] {
                if let id=try await store.importedSourceID(commandID:"automatic-recording:"+item.id+":\(track)"),completed.contains(id) {
                    recordingInbox.acknowledgeCompleted(item.id);break
                }
            }
        }
    }
    private func preparePendingCorrectedRecordingContexts() async throws {
        guard let store else { return }
        let records=try await store.sources()
        let ids=Set(records.flatMap { $0.presentation?.correctedSourceIDs ?? [] })
        guard !ids.isEmpty else { return }
        setFullRecordingStatus(records.contains(where: { ids.contains($0.id) && $0.presentation?.recordingUnderstandingIsCorrection == true }) ? "已保存原文更正，正在更新完整理解与关联…" : "正在按当前原文与许可，更新完整理解与关联…")
        for id in ids.sorted() {
            try await ensureTranscriptReviewed(sourceID:id)
            if let pair=records.first(where: { $0.id == id })?.presentation?.recordingContext { try await ensureTranscriptReviewed(sourceID:pair.externalSourceID) }
        }
        try await store.refreshCorrectedRecordingContexts(sourceIDs:Array(ids))
    }
    private func understandPendingRecordingExpressions(store:VoiceOSStore,speech:LocalQwenSpeechPort,grouping:ResponsesRecordingExpressionPort,configuration:URL,script:URL) async throws {
        let root=await store.root
        let groups=try await store.recordingExpressions().filter { $0.state != "completed" }
        for expression in groups {
            if try await store.completeUnchangedSingleRecording(expression) { continue }
            try Task.checkCancellation()
            fullRecordingSourceID=expression.sourceIDs.first
            let digest=expression.digest
            let base=root.appendingPathComponent("整理/连续表达/"+expression.id+"/"+digest)
            var folders:[URL]=[]
            for (index,id) in expression.sourceIDs.enumerated() {
                let folder=base.appendingPathComponent(String(format:"%03d-",index+1)+id)
                _ = try await store.writeOrganizingInput(sourceID:id,to:folder)
                folders.append(folder)
            }
            _ = try await store.writeExistingTaskInput(to:base.appendingPathComponent("已有任务.json"),excludingSourceIDs:expression.sourceIDs)
            try JSONEncoder().encode(expression).write(to:base.appendingPathComponent("连续表达.json"),options:.atomic)
            let log=base.appendingPathComponent("处理日志.txt");fullRecordingLog=log
            setFullRecordingStatus("正在整体理解“"+expression.title+"”的 \(folders.count) 段录音…")
            try await FullRecordingOrganizer.organize(folders:folders,script:script,python:speech.pythonExecutable,configuration:configuration,log:log)
            _ = try await store.ingestOrganizedPodcast(at:base,allowReminderWrites:false,requireAPIReview:true)
            try await store.finishRecordingExpression(expression,using:grouping)
            fullRecordingOutput=base
            for id in expression.sourceIDs {
                _ = try await store.enqueueRecordingFollowup(sourceID:id)
                if !(try await store.latestCandidateClaims(for:id)).isEmpty { _ = try await store.enqueueKnowledgeReview(sourceID:id) }
            }
            await refresh()
        }
    }
    private func automaticRecordingFailure(_ error:Error) -> RecordingInboxOutcome {
        let message=error.localizedDescription
        if error is CancellationError { return .retryableFailure("处理被中断，将从已保存的转写与分组继续") }
        let temporary=["HTTP 429","HTTP 502","HTTP 503","HTTP 504","网络","timed out","connection","response.completed","本批录音","素材仍在更新"].contains { message.localizedCaseInsensitiveContains($0) }
        return temporary ? .retryableFailure(message) : .needsAttention(message)
    }
    func organizeRecording(_ input: FullRecordingInput, track: Int, importCommand: String? = nil, finished: ((Bool) -> Void)? = nil) {
        guard let store, var speech = speechPort as? LocalQwenSpeechPort, !fullRecordingBusy, worker == nil,
              understandingWorker == nil, !dictationActive, let configuration = textConfigurationFile,
              let script = Bundle.main.url(forResource: "organize_podcast", withExtension: "py") else {
            fullRecordingStatus = "请先配置 Qwen 和文本模型，并等待当前处理结束"
            lastRecordingOutcome = .needsAttention(fullRecordingStatus); finished?(false); return
        }
        fullRecordingBusy = true; fullRecordingCount = nil
        lastRecordingOutcome = .needsAttention("整理未完成，请查看处理记录")
        fullRecordingWorker = Task {
            let refreshTask = watchFullRecording()
            var success = false
            defer { refreshTask.cancel(); fullRecordingBusy = false; fullRecordingWorker = nil; fullRecordingLog = nil; fullRecordingSourceID = nil; finished?(success); scheduleProcessing(); resumeRecordingFollowups(); resumeKnowledgeReviews() }
            do {
                let root = await store.root
                let staging = root.appendingPathComponent("整理/导入-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let log = staging.appendingPathComponent("处理日志.txt"); fullRecordingLog = log
                let attrs = try FileManager.default.attributesOfItem(atPath: input.url.path)
                let identity = input.url.path + ":\(track):" + String(describing: attrs[.size]) + ":" + String(describing: attrs[.modificationDate])
                let command = importCommand ?? "full-recording:" + identity
                let id: String
                if let existing = try await store.importedSourceID(commandID: command) { id = existing }
                else {
                    setFullRecordingStatus("正在提取完整本人音轨…")
                    let audio = staging.appendingPathComponent(input.url.deletingPathExtension().lastPathComponent + "_音轨\(track).wav")
                    try await FullRecordingOrganizer.extract(input.url, track: track, to: audio, log: log)
                    try Task.checkCancellation()
                    let after = try FileManager.default.attributesOfItem(atPath: input.url.path)
                    guard attrs[.size] as? NSNumber == after[.size] as? NSNumber, attrs[.modificationDate] as? Date == after[.modificationDate] as? Date else { throw VoiceOSError("素材仍在更新，等待文件保存完成后重试") }
                    id = try await store.importPersonalAudio(audio, commandID: command)
                    // importPersonalAudio has sealed its asset; the ffmpeg staging copy is disposable.
                    try FileManager.default.removeItem(at: audio)
                }
                selected = id
                fullRecordingSourceID = id
                await refresh()
                let needsProgramContext=input.media.contextTrack != nil && track == input.media.personalTrack
                let hasProgramContext=(try? await store.recordingContext(sourceID:id)) != nil
                if let record = records.first(where: { $0.id == id }), isCompletelyOrganized(record), !needsProgramContext || hasProgramContext {
                    success = true; setFullRecordingStatus("这份素材已完整整理，未重复调用模型"); return
                }
                let policy = try await store.sourcePolicy(sourceID: id)
                if policy.localOnly { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: false) }
                try JSONSerialization.data(withJSONObject: ["original_media_path": input.url.path, "audio_track": track, "audio_track_numbering": "zero_based", "audio_role": "user", "full_duration_seconds": input.media.duration], options: [.prettyPrinted, .sortedKeys]).write(to: staging.appendingPathComponent("原始素材.json"), options: .atomic)
                if records.first(where: { $0.id == id })?.transcriptionBackend?.hasPrefix("Qwen3-ASR") != true {
                    try await store.retryTranscription(sourceID: id)
                    speech.progressLog = log
                    setFullRecordingStatus("Qwen 正在本地转写完整音轨…")
                    try await store.processTranscriptions(using: speech, sourceIDs: [id])
                    if let failed = try await store.sources().first(where: { $0.id == id && $0.jobState == "failed" }) {
                        throw VoiceOSError(failed.error ?? "本地转写未完成；已保存的分段进度保留")
                    }
                }
                try Task.checkCancellation()
                try await prepareRecordingContext(input:input.url,media:input.media,personalSourceID:id,personalTrack:track,staging:staging,speech:speech)
                try await completeFullOrganization(sourceID: id, speech: speech, configuration: configuration, script: script)
                success = true
            } catch is CancellationError {
                setFullRecordingStatus("已停止；原件、逐字稿和已完成整理结果保留")
                lastRecordingOutcome = .needsAttention("你已停止处理，点击重试后继续")
            } catch {
                setFullRecordingStatus(error.localizedDescription)
                let text = error.localizedDescription
                let temporary = ["HTTP 429", "HTTP 502", "HTTP 503", "HTTP 504", "网络", "timed out", "connection", "Incomplete text response", "response.completed", "temporarily unavailable", "server_error", "overloaded", "素材仍在更新"].contains { text.localizedCaseInsensitiveContains($0) }
                lastRecordingOutcome = temporary ? .retryableFailure(text) : .needsAttention(text)
            }
            await refresh()
        }
    }
    func organizeFullTranscript(_ record: SourceRecord) {
        if record.presentation?.expression != nil || record.presentation?.recordingContext != nil {
            guard !fullRecordingBusy,worker == nil,understandingWorker == nil else { status="当前录音仍在处理，完成后可重新整理";return }
            Task {
                do { try await queueWholeRecordingUnderstanding(sourceID:record.id) }
                catch { status="原文已保留，整体整理尚未排入："+error.localizedDescription }
            }
        } else { organizeSavedRecording(sourceID: record.id, transcribeFirst: false) }
    }
    private func queueWholeRecordingUnderstanding(sourceID:String) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        _ = try await store.queueRecordingUnderstanding(sourceID:sourceID,previousActionIDs:actionRecords.map(\.id))
        resumedSavedRecordingExpressions=false
        await refresh()
        status="已排入完整表达重新整理，保留原任务身份、完成与实际反馈。"
        await resumeSavedRecordingExpressions()
    }
    private func organizeSavedRecording(sourceID: String, transcribeFirst: Bool) {
        guard let store, var speech = speechPort as? LocalQwenSpeechPort, let configuration = textConfigurationFile,
              let script = Bundle.main.url(forResource: "organize_podcast", withExtension: "py"),
              !fullRecordingBusy, worker == nil, understandingWorker == nil else { status = "请先配置模型并等待当前处理结束"; return }
        fullRecordingBusy = true; fullRecordingCount = nil; fullRecordingOutput = nil
        fullRecordingSourceID = sourceID
        fullRecordingWorker = Task {
            let refreshTask = watchFullRecording()
            defer { refreshTask.cancel(); fullRecordingBusy = false; fullRecordingWorker = nil; fullRecordingLog = nil; fullRecordingSourceID = nil; scheduleProcessing(); resumeRecordingFollowups(); resumeKnowledgeReviews() }
            do {
                let policy = try await store.sourcePolicy(sourceID: sourceID)
                if policy.localOnly { _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: policy.version, localOnly: false) }
                if transcribeFirst {
                    let root = await store.root
                    let folder = root.appendingPathComponent("整理/" + sourceID)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let log = folder.appendingPathComponent("Qwen转写日志.txt")
                    speech.progressLog = log; fullRecordingLog = log
                    setFullRecordingStatus("Qwen 正在本地转写整段口述…")
                    try await store.processTranscriptions(using: speech, sourceIDs: [sourceID])
                    try Task.checkCancellation()
                }
                try await completeFullOrganization(sourceID: sourceID, speech: speech, configuration: configuration, script: script)
            } catch is CancellationError { setFullRecordingStatus("已停止；录音、逐字稿和已完成的整理结果保留") }
            catch { setFullRecordingStatus(error.localizedDescription) }
            await refresh()
        }
    }
    private func completeFullOrganization(sourceID: String, speech: LocalQwenSpeechPort, configuration: URL, script: URL) async throws {
        guard let store, let record = try await store.sources().first(where: { $0.id == sourceID }), let version = record.transcriptVersionID else { throw VoiceOSError("完整转写尚未保存") }
        let policy = try await store.sourcePolicy(sourceID: sourceID)
        guard !policy.localOnly else { throw VoiceOSError("这份文字已限制为仅本机，完整整理已停止") }
        await refresh() // Transcription has completed; publish the durable stage once.
        let root = await store.root
        let sourceFolder = root.appendingPathComponent("整理/" + sourceID)
        var base = sourceFolder.appendingPathComponent(version)
        // Correction changes the database version. Reuse the same completed
        // processing directory after a restart instead of extracting tasks again.
        for candidate in (try? FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil)) ?? [] {
            let manifestURL = candidate.appendingPathComponent(record.name).appendingPathComponent("source.json")
            if let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               manifest["voiceos_source_id"] as? String == sourceID, manifest["voiceos_transcript_version_id"] as? String == version {
                base = candidate; break
            }
        }
        let folder = base.appendingPathComponent(record.name)
        _ = try await store.writeOrganizingInput(sourceID: sourceID, to: folder)
        _ = try await store.writeExistingTaskInput(to: base.appendingPathComponent("已有任务.json"), excludingSourceIDs: [sourceID])
        let log = base.appendingPathComponent("处理日志.txt"); fullRecordingLog = log
        setFullRecordingStatus("AI 正在直接校正完整逐字稿…")
        try await FullRecordingOrganizer.organize(folder: folder, script: script, python: speech.pythonExecutable, configuration: configuration, log: log, reviewTranscriptOnly: true)
        try Task.checkCancellation()
        _ = try await store.applyTranscriptQualityResult(sourceID: sourceID, expectedVersionID: version, from: folder)
        await refresh()
        setFullRecordingStatus("全文校正已保存，正在整理观点、任务与已有任务的接续…")
        try await FullRecordingOrganizer.organize(folder: folder, script: script, python: speech.pythonExecutable, configuration: configuration, log: log)
        try Task.checkCancellation()
        let count = try await store.ingestOrganizedPodcast(at: base, allowReminderWrites: reminderAccess?.enabled == true && reminderAccess?.title == "VoiceOS", requireAPIReview: true)
        fullRecordingCount = count
        fullRecordingOutput = base
        await refresh()
        _ = try await store.enqueueRecordingFollowup(sourceID: sourceID)
        if !(currentClaimsBySource[sourceID] ?? []).isEmpty {
            do { _ = try await store.enqueueKnowledgeReview(sourceID: sourceID) }
            catch { knowledgeReviewStatus = "录音已整理，知识核查尚未排入：" + error.localizedDescription }
        }
        await refresh()
        requestReminderRefresh()
        queueRecordingTitles()
        setFullRecordingStatus("已保存 \(count) 条观点与意图 · 提醒事项和思想跟进将在后台继续，可接收下一段录音")
    }
    private func setFullRecordingStatus(_ message: String, detail: String = "") {
        if fullRecordingDetail != detail { fullRecordingDetail=detail }
        if fullRecordingStatus != message { fullRecordingStatus = message }
        if status != message { status = message }
    }
    private func recordingProgressMessage(_ detail:String) -> String {
        if detail.contains("extract window") { return "正在按原话整理完整内容…" }
        if detail.contains("independent omission check") { return "正在通读全文，检查遗漏的观点与意图…" }
        if detail.contains("清单合并模型结果") { return "正在合并同一意图，保留条件与否定…" }
        if detail.contains("意图核对模型结果") { return "正在核对理解、任务归属和原话依据…" }
        if detail.contains("context-links") || detail.contains("双轨关联") { return "正在关联节目原话与个人回应…" }
        if detail.hasPrefix("{") && detail.contains("unlocated_citations") { return "全文整理已保存，正在接续关联与实际结果…" }
        if detail.contains("模型正在推理") || detail.contains("模型正在返回正文") { return "AI 正在理解完整内容，已完成阶段会保留…" }
        return detail
    }
    private func watchFullRecording() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                if let log = fullRecordingLog {
                    let last = await Task.detached(priority: .utility) { () -> String? in
                        do {
                            let file = try FileHandle(forReadingFrom: log); defer { try? file.close() }
                            let end = try file.seekToEnd()
                            try file.seek(toOffset: end > 8192 ? end - 8192 : 0)
                            guard let data = try file.readToEnd() else { return nil }
                            return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
                        } catch { return nil }
                    }.value
                    guard !Task.isCancelled else { return }
                    if let last { setFullRecordingStatus(recordingProgressMessage(last),detail:last) }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func chooseOrganizedResult() {
        guard !fullRecordingBusy, !importing else { return }
        let panel = NSOpenPanel(); panel.title = "导入已完成的全文整理"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let store = self.store else { return }
            Task {
                self.importing = true; defer { self.importing = false }
                do {
                    let count = try await store.ingestOrganizedPodcast(at: url, allowReminderWrites: self.reminderAccess?.enabled == true && self.reminderAccess?.title == "VoiceOS", requireAPIReview: true)
                    await self.refresh(); self.requestReminderRefresh()
                    self.status = "已导入完整整理 \(count) 个事项；相同清单不会重复创建"
                } catch { self.status = error.localizedDescription }
            }
        }
    }
    func processFollowup(sourceID: String, retry: Bool = false) async {
        if followupBusy {
            do { _ = try await store?.enqueueRecordingFollowup(sourceID: sourceID, retry: retry) }
            catch { followupStatus = error.localizedDescription }
            return
        }
        guard let store, let port = followupModel else { return }
        followupBusy = true; followupStatus = "正在关联旧思想、调整目标下一步并延续英语反馈…"
        defer { followupBusy = false; scheduleProcessing(); resumeRecordingFollowups() }
        do {
            let receipt = try await store.processRecordingFollowup(sourceID: sourceID, using: port, retry: retry)
            followupStatus = receipt.state == "completed" ? "思想关联、目标建议与练习反馈已保存" : "这份跟进尚未完成，可重新生成"
        } catch { followupStatus = "录音与任务已保留，自动跟进未完成：" + error.localizedDescription }
        await refresh()
    }
    private func queueActionFollowups(_ actionIDs: Set<String>) async {
        do { _ = try await store?.enqueueActionFollowups(actionIDs: actionIDs) }
        catch { followupStatus = "任务已保存，目标跟进尚未排入：" + error.localizedDescription }
        await refresh()
        resumeRecordingFollowups()
    }
    private func resumeRecordingFollowups() {
        guard initialized, followupModel != nil, followupWorker == nil, !fullRecordingBusy, !dictationActive else { return }
        followupWorker = Task {
            defer { followupWorker = nil }
            var attempted = Set<String>()
            while !Task.isCancelled, !fullRecordingBusy, !dictationActive, let store {
                guard let next = (try? await store.pendingRecordingFollowups())?.first(where: { !attempted.contains($0.id) }) else { return }
                attempted.insert(next.id)
                await processFollowup(sourceID: next.sourceID)
            }
        }
    }
    func refreshFollowup(_ sourceID: String) {
        Task {
            do { _ = try await store?.enqueueRecordingFollowup(sourceID: sourceID, retry: true); await refresh(); resumeRecordingFollowups() }
            catch { followupStatus = error.localizedDescription }
        }
    }
    func showTask(_ id: String) {
        focusedTaskID = id; taskPresentation += 1
    }
    func activateStep(_ step: GoalStep, plan: GoalPlan, receipt: RecordingFollowupReceipt) async {
        if !step.existingTaskID.isEmpty {
            guard let task = actionRecords.first(where: { $0.id == step.existingTaskID }),
                  task.validity == "current", task.state == "open", task.title == step.title else {
                followupStatus = "这个步骤已完成或变化，请更新目标建议"; return
            }
            // Viewing an existing task does not select a new step or regenerate plans.
            showTask(task.id); return
        }
        guard let store, !savingAction else { return }
        savingAction = true; defer { savingAction = false }
        do {
            let id = try await store.activateGoalStep(receiptID: receipt.id, goalID: plan.goalID, step: step)
            await refresh()
            if let task = actionRecords.first(where: { $0.id == id }), reminderAccess?.enabled == true, !reminderLinks.contains(where: { $0.actionID == id }) { await sendReminder(task) }
            showTask(id)
            followupStatus = "已选择这一步；后续进展会用于调整目标建议"
            await queueActionFollowups([id])
        } catch { followupStatus = error.localizedDescription }
    }
    func playFollowupQuote(sourceID: String, quote: String) async {
        guard let record = records.first(where: { $0.id == sourceID }), let text = record.transcript, let range = text.range(of: quote) else { return }
        let start = text[..<range.lowerBound].unicodeScalars.count
        let end = start + quote.unicodeScalars.count
        let spans = record.spans.filter { $0.textEnd > start && $0.textStart < end }
        if let begin = spans.first?.startMS, let finish = spans.last?.endMS { _ = await playSpan(record, milliseconds: begin, endMilliseconds: finish) }
        else if !spans.isEmpty, ["audio","video"].contains(record.kind) {
            if await playSpan(record,milliseconds:0) { status="更正稿未精确定位，正在回听完整录音" }
        }
    }
    func understand(_ record: SourceRecord) {
        guard let store, let port = textModel, understandingWorker == nil, !discussionExtracting, !record.localOnly,
              !(record.transcript ?? "").isEmpty else { return }
        understandingSource = record.id
        status = "正在理解所选文字 · 原始音视频仍在本机"
        // Application-owned: changing selection or closing the window does not resend/cancel.
        understandingWorker = Task {
            do {
                try await ensureTranscriptReviewed(sourceID: record.id)
                if record.origin == "user", record.speaker == "user", ["user_text", "audio"].contains(record.kind) {
                    guard let association = associationModel else { throw VoiceOSError("关联模型尚未配置；个人表达尚未排队") }
                    let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: record.id, cognition: port.configuration, association: association.configuration)
                    let intent = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "understand:" + record.id + ":" + snapshot.contentDigest, cognition: port.configuration, association: association.configuration)
                    status = intent.state == .queued ? "个人表达已排队 · 原始录音仍在本机" : "已有处理回执：\(intent.state.rawValue)；未重复排队"
                    scheduleProcessing()
                } else {
                    let result = try await store.continueSourceUnderstanding(sourceID: record.id, using: port)
                    await applyUnderstandingContinuation(result, sourceID: record.id)
                }
            } catch { status = error.localizedDescription }
            await refresh(); requestReminderRefresh(); resumeKnowledgeReviews()
            understandingSource = nil; understandingWorker = nil
        }
    }
    func understandSegmented(_ record: SourceRecord) {
        guard let store,let extraction=segmentExtractionModel,let aggregation=segmentAggregationModel,
              understandingWorker == nil,!discussionExtracting,!record.localOnly,
              record.origin == "user",record.speaker == "user",["audio","user_text"].contains(record.kind),
              (record.transcript ?? "").unicodeScalars.count>4000 else { return }
        understandingSource=record.id;status="正在分段理解文字 · 原始音视频仍在本机"
        understandingWorker=Task {
            do {
                try await ensureTranscriptReviewed(sourceID: record.id)
                guard let current = try await store.sources().first(where: { $0.id == record.id }) else { throw VoiceOSError("资料已变化") }
                // Model reconfiguration alone cannot regenerate this expression.
                let batches=try await store.segmentedProcessingBatches()
                let prior=batches.first { $0.scope.plan.source.sourceID == record.id && $0.scope.plan.source.transcriptVersionID == current.transcriptVersionID && $0.scope.plan.policyVersion == current.policyVersion }
                let batch: SegmentedProcessingBatch
                if let prior { batch=prior }
                else {
                    let scope=try await store.prepareSegmentedExpressionProcessingScope(sourceID:record.id,extraction:extraction.configuration,aggregation:aggregation.configuration)
                    batch=try await store.enqueueSegmentedProcessingBatch(scope,commandID:"segmented-understand:"+record.id+":"+scope.contentDigest,extraction:extraction.configuration,aggregation:aggregation.configuration)
                }
                segmentedBatches=try await store.segmentedProcessingBatches()
                let result=try await store.processSegmentedCognition(batchID:batch.id,extraction:extraction,aggregation:aggregation)
                if let ids=result.claimIDs {
                    status="长表达认知已保存 · \(ids.count) 条候选；正在核对历史关联"
                    await associateUnderstoodExpression(record.id,segmentedBatchID:batch.id)
                    status="长表达认知已保存 · \(ids.count) 条候选；"+(associationStatuses[record.id] ?? "关联未完成")
                }
                else { status="分段处理记录：\(result.state.rawValue) · 未重复发送未知或已结束的请求" }
            } catch { status=error.localizedDescription }
            await refresh();requestReminderRefresh();resumeKnowledgeReviews()
            understandingSource=nil;understandingWorker=nil
        }
    }
    func cancelSegmented(_ id: String) {
        guard let store else { return }
        Task {
            do { _ = try await store.cancelSegmentedProcessingBatch(id:id);status="已停止分段处理 · 原文与处理历史保留" }
            catch { status=error.localizedDescription }
            await refresh()
        }
    }
    private func applyUnderstandingContinuation(_ result: SourceUnderstandingContinuation, sourceID: String) async {
        if result.state == "completed" || result.state == "discussion_completed" {
            status = result.reused ? "沿用已有理解 · 核对关联处理，不重复生成候选或任务" : "理解完成 · \(result.claimIDs.count) 条候选待核对"
            await refresh(); requestReminderRefresh()
            await associateUnderstoodExpression(sourceID)
            await processFollowup(sourceID: sourceID)
        } else {
            let label: String
            switch result.state {
            case "unknown", "discussion_unknown": label = "结果未知"
            case "reserved", "discussion_reserved": label = "正在处理"
            case "rejected", "discussion_rejected": label = "结果未接纳"
            default: label = "依据已失效"
            }
            status = "已有理解记录 · \(label)；未重发，也未启动后续关联"
        }
    }
    func saveExpression(_ text: String, commandID: String) async -> Bool {
        guard let store else { return false }
        do {
            selected = try await store.recordUserExpression(text, commandID: commandID)
            await refresh(); status = "表达原文已保存 · 仅本地，尚未发送模型或提醒事项"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    var canUnderstandCapturedText: Bool { modelConfigured && understandingWorker == nil && !discussionExtracting }
    func saveCapturedText(_ text: String, title: String, ownership: TextCaptureOwnership, allowCloud: Bool, commandID: String) async -> String? {
        guard let store else { return nil }
        guard !allowCloud || canUnderstandCapturedText else {
            status = "其他内容正在整理或模型尚未就绪，草稿已保留；可先仅本地保存。"; return nil
        }
        do {
            let id = try await store.recordCapturedText(text, title: title, ownership: ownership, commandID: commandID)
            let policy = try await store.sourcePolicy(sourceID: id)
            if policy.localOnly != !allowCloud {
                _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: !allowCloud)
            }
            await refresh()
            guard allowCloud else { status = "完整原文已保存 · 仅本机"; return id }
            guard canUnderstandCapturedText, let record = records.first(where: { $0.id == id }) else {
                status = "完整原文已保存；其他内容正在整理，草稿保留，可稍后重试理解。"; return nil
            }
            if ownership == .personal, text.unicodeScalars.count > 4000 { understandSegmented(record) }
            else { understand(record) }
            return id
        } catch { status = error.localizedDescription; await refresh(); return nil }
    }
    func saveAndProcessExpression(_ text: String, commandID: String) async -> Bool {
        guard let store, let cognition = textModel, let association = associationModel else {
            status = "文本模型或关联模型尚未配置；原文仍可先本地保存"; return false
        }
        var savedSourceID: String?
        do {
            let source = try await store.recordUserExpression(text, commandID: commandID)
            savedSourceID = source; selected = source
            guard let current = try await store.sources().first(where: { $0.id == source }) else { throw VoiceOSError("表达保存后找不到来源") }
            if current.localOnly { _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: current.policyVersion, localOnly: false) }
            let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: cognition.configuration, association: association.configuration)
            let intent = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "process:" + commandID, cognition: cognition.configuration, association: association.configuration)
            status = intent.state == .queued ? "原文已保存并排队处理 · 本次文字已允许云端" : "原文已保存 · 原处理回执：\(intent.state.rawValue)；未重复排队"
            await refresh(); scheduleProcessing(); return true
        } catch {
            status = (savedSourceID == nil ? "原文未保存：" : "原文已保存，处理未排队：") + error.localizedDescription
            await refresh(); return false
        }
    }
    func export(includeMedia: Bool) {
        let panel = NSSavePanel()
        panel.title = includeMedia ? "导出资料与原件" : "导出结构化资料"
        panel.nameFieldStringValue = "VoiceOS-导出-" + ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.prompt = "导出"
        panel.begin { response in
            guard response == .OK, let url = panel.url, let store = self.store else { return }
            Task {
                do { try await store.exportPackage(to: url, includeMedia: includeMedia); self.status = "已导出资料" + (includeMedia ? "和完整原件" : "；原件未包含，可另选打包") }
                catch { self.status = error.localizedDescription }
            }
        }
    }
    func chooseFiles(personalAudio: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = personalAudio ? "导入仅含我声音的录音 · 不上传原始音频" : "导入音频或视频"; panel.prompt = personalAudio ? "确认为我的录音" : "导入"
        panel.allowedContentTypes = personalAudio ? [.audio] : [.audio, .movie]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { await self.importFiles(urls, personalAudio: personalAudio) }
        }
    }
    private func importFiles(_ urls: [URL], personalAudio: Bool = false) async {
        guard let store, !importing else { return }
        importing = true
        defer { importing = false }
        var failures = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            status = "正在保存：\(url.lastPathComponent)"
            do { selected = personalAudio ? try await store.importPersonalAudio(url) : try await store.importFile(url) }
            catch { failures += 1; status = error.localizedDescription }
            if access { url.stopAccessingSecurityScopedResource() }
            await refresh()
        }
        if failures == 0 { status = "已可靠保存 \(urls.count) 个原件 · 正在本地转写" }
        scheduleProcessing()
        if failures == 0 { status = "导入完成 · 可查看原件和转写状态" }
    }
    private func scheduleProcessing() {
        guard worker == nil, !fullRecordingBusy, !dictationActive else { return }
        // Owned by the application model, not the SwiftUI view task/window lifetime.
        worker = Task {
            await process()
            worker = nil
            if let store {
                let queuedTranscription = (try? await store.sources())?.contains(where: { $0.jobState == "queued" }) == true
                let pendingTranscription = speechPort != nil && queuedTranscription
                // A queued expression intent is intentionally left durable while
                // no text model is configured. It must not cause a tight retry
                // loop; configureTextModel() wakes it after a real identity is
                // available.
                let pendingIntent: Bool
                if textModel != nil {
                    pendingIntent = (try? await store.processingIntents())?.contains(where: { $0.state == .queued }) == true
                } else {
                    pendingIntent = false
                }
                if pendingTranscription || pendingIntent { scheduleProcessing() }
            }
        }
    }
    private func process() async {
        guard let store else { return }
        defer { processingActivity = nil }
        if let selectedSpeech = speechPort {
            for source in (try? await store.sources()) ?? [] where source.jobState == "queued" {
                processingActivity = .init(sourceID: source.id, label: "正在本地转写")
                do { try await store.processTranscriptions(using: selectedSpeech, sourceIDs: [source.id]) }
                catch { status = error.localizedDescription }
                await refresh()
            }
            processingActivity = nil
        }
        if textModel != nil {
            // Only durable record-and-process requests need this automatic review.
            // Explicit source understanding and full recording organization review
            // their own source; opening the app must not reprocess the old library.
            let requested = Set(((try? await store.recordingProcessingRequests()) ?? []).filter { $0.state == "waiting" }.map(\.sourceID))
            for source in (try? await store.sources()) ?? [] where requested.contains(source.id) && !source.localOnly && source.needsTranscriptionReview {
                do { try await ensureTranscriptReviewed(sourceID: source.id) }
                catch { transcriptReviewStatus = error.localizedDescription }
            }
        }
        if let cognition = textModel, let association = associationModel {
            do { try await store.reconcileRecordingProcessingRequests(cognition: cognition.configuration, association: association.configuration,segmentExtraction:segmentExtractionModel?.configuration,segmentAggregation:segmentAggregationModel?.configuration) }
            catch { status = error.localizedDescription }
            do { try await store.enqueueActionFeedbackUnderstanding(cognition: cognition.configuration, association: association.configuration) }
            catch { status = "结果原话已保留，知识整理尚未排入：" + error.localizedDescription }
        }
        await processExpressionQueue(store)
        if let extraction=segmentExtractionModel,let aggregation=segmentAggregationModel {
            do {
                let requests=try await store.recordingProcessingRequests().filter { $0.state == "enqueued" && $0.segmentedBatchID != nil && $0.segmentedAssociationState == nil }
                for request in requests {
                    guard let batchID=request.segmentedBatchID,try await store.segmentedProcessingBatch(id:batchID).state == .queued else { continue }
                    processingActivity = .init(sourceID: request.sourceID, label: "正在分段理解与核对关联")
                    await refresh() // Publish the durable batch before the first model await.
                    try await store.processRecordingSegmentPlan(requestID:request.id,extraction:extraction,aggregation:aggregation,retrieval:semanticRetrieval ?? retrieval,semantic:semanticRetrieval != nil,association:associationModel)
                    requestReminderRefresh()
                }
            } catch { status=error.localizedDescription }
        }
        await refresh()
        queueRecordingTitles()
        resumeRecordingFollowups()
        resumeKnowledgeReviews()
    }
    private func processExpressionQueue(_ store: VoiceOSStore) async {
        guard let cognition = textModel else { return }
        defer { processingActivity = nil }
        let association = associationModel
        let local: any LocalRetrievalPort = semanticRetrieval ?? retrieval
        while let intent = try? await store.processingIntents().first(where: { $0.state == .queued }) {
            processingActivity = .init(sourceID: intent.sourceID, label: "正在理解与关联")
            do {
                let result = try await store.runExpressionProcessingIntent(id: intent.id, retrieval: local, cognitionPort: cognition, associationPort: association, semantic: semanticRetrieval != nil)
                if result.state == .completed {
                    if result.associationAttemptID == nil {
                        status = "理解已完成 · 本机未召回可用关联候选，本次未发送关联判断"
                    } else {
                        let receipt = try await store.expressionAssociationAttempts().first { $0.id == result.associationAttemptID }
                        status = receipt?.proposals.isEmpty == true
                            ? "理解与关联判断已完成 · 没有直接相关提案"
                            : "理解与关联判断已完成 · 关系提案已保存，未改变观点或行动"
                    }
                } else if result.state == .frozen, result.phase == .association {
                    status = "当前文字的理解已保留 · 旧关联已冻结，未重发；请核对纠错后的依据"
                } else { status = "表达处理状态：\(result.state.rawValue)" }
                requestReminderRefresh()
            } catch { status = error.localizedDescription; await refresh(); break }
            await refresh()
        }
    }
    func previewSegmentation(_ record: SourceRecord) async -> Bool {
        guard let store else { return false }
        do {
            segmentationPlan = try await store.prepareTranscriptSegmentation(sourceID:record.id)
            segmentationStatus = ""; return true
        } catch { segmentationStatus = error.localizedDescription; return false }
    }
    func playSegmentationReference(_ plan: TranscriptSegmentationPlan, reference: TranscriptSegmentReference) async {
        guard let store else { return }
        do {
            try await store.validateTranscriptSegmentation(plan)
            guard let record = try await store.sources().first(where: { $0.id == plan.source.sourceID }), record.state == "saved", let start = reference.containingSpanStartMS else { throw VoiceOSError("原片段时间未确认") }
            await playSpan(record,milliseconds:start)
        } catch { segmentationStatus = error.localizedDescription }
    }
    func cancelRecordingRequest(_ request: RecordingProcessingRequest) async {
        guard let store else { return }
        do { let cancelled = try await store.cancelRecordingProcessingRequest(id: request.id); status = cancelled ? "已取消文字处理 · 录音和本地转写保留" : "处理已结束或冻结，保留原回执"; await refresh() }
        catch { status = error.localizedDescription }
    }
    func cancelProcessingIntent(_ intent: ExpressionProcessingIntentRecord) async {
        guard let store, [.queued, .running].contains(intent.state) else { return }
        do {
            _ = try await store.cancelExpressionProcessingIntent(id: intent.id, reason: "用户从处理记录取消")
            status = "已取消表达处理 · 已发出的模型请求保留历史，不自动重发"
            await refresh()
        } catch { status = error.localizedDescription; await refresh() }
    }
    func stopPlayback() {
        guard let player else { return }
        player.pause()
        if let playbackBoundary { player.removeTimeObserver(playbackBoundary); self.playbackBoundary = nil }
        self.player = nil
    }
    @discardableResult
    func playSpan(_ record: SourceRecord, milliseconds: Int, endMilliseconds: Int? = nil) async -> Bool {
        do {
            guard let url = try await store?.playableURL(sourceID: record.id) else { return false }
            stopPlayback()
            let playback = AVPlayer(url: url)
            player = playback
            await playback.seek(to: CMTime(value: Int64(milliseconds), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
            if let end = endMilliseconds, end > milliseconds {
                playbackBoundary = playback.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(value: Int64(end), timescale: 1000))], queue: .main) { [weak playback] in playback?.pause() }
            }
            playback.play()
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func playActionOriginal(_ action: ActionRecord) async -> Bool {
        guard let claim = claims.first(where: { $0.id == action.claimID }), let first = claim.references.first,
              let record = records.first(where: { $0.id == first.sourceID }), record.transcriptVersionID == first.transcriptVersionID else { status = "原话版本已变化，请先核对出处"; return false }
        let spans = claim.references.filter { $0.sourceID == record.id && $0.transcriptVersionID == record.transcriptVersionID }
            .compactMap { ref in record.spans.first(where: { $0.id == ref.spanID }) }.sorted { ($0.startMS ?? 0) < ($1.startMS ?? 0) }
        guard let start = spans.first?.startMS, var end = spans.first?.endMS else {
            guard !spans.isEmpty,["audio","video"].contains(record.kind) else { status="这份文字没有对应录音";return false }
            let played=await playSpan(record,milliseconds:0)
            if played { status="更正稿未精确定位，正在回听完整录音" }
            return played
        }
        for span in spans.dropFirst() {
            guard let next = span.startMS, next <= end + 1000, let finish = span.endMS else { break }
            end = max(end, finish)
        }
        return await playSpan(record, milliseconds: start, endMilliseconds: end)
    }
    func historyFor(_ record: SourceRecord) async {
        do { history = try await store?.transcriptHistory(sourceID: record.id) ?? [] }
        catch { status = error.localizedDescription }
    }
    func correct(_ record: SourceRecord, text: String) async -> Bool {
        guard let store, let version = record.transcriptVersionID else { return false }
        let previousActions=actionRecords.filter { $0.validity == "current" }.map(\.id)
        do {
            _ = try await store.correctTranscript(sourceID: record.id, expectedVersionID: version, text: text)
        } catch { status=error.localizedDescription;return false }
        await refresh()
        guard let current=records.first(where: { $0.id == record.id }) else { return true }
        if current.localOnly { status="更正已保存为本机原文，历史保留。";return true }
        do {
            if ["audio","video"].contains(current.kind),current.transcriptionBackend?.hasPrefix("Qwen3-ASR") == true,
               current.origin == "user" || records.contains(where: { $0.presentation?.recordingContext?.externalSourceID == current.id }) {
                _ = try await store.queueCorrectedRecordingUnderstanding(sourceID:current.id,previousActionIDs:previousActions)
                resumedSavedRecordingExpressions=false
                status="更正已保存，完整表达已排队更新；真实完成与原话历史保留。"
                await refresh()
                await resumeSavedRecordingExpressions()
            } else if current.origin == "user",current.speaker == "user",(current.transcript?.unicodeScalars.count ?? 0) <= 4000,
                      let cognition=textModel?.configuration,let association=associationModel?.configuration {
                _ = try await store.enqueueCorrectedSourceUnderstanding(sourceID:current.id,cognition:cognition,association:association)
                status="更正已保存，正在自动更新理解。";scheduleProcessing()
            } else if !current.localOnly,modelConfigured {
                if current.origin == "user",(current.transcript?.unicodeScalars.count ?? 0) > 4000 { understandSegmented(current) }
                else { understand(current) }
            } else { status="更正已保存，配置文字模型后可继续整理。" }
        } catch { status="更正已保存，后续整理尚未继续："+error.localizedDescription }
        await refresh();queueRecordingTitles()
        return true
    }
    func changeTextPolicy(_ record: SourceRecord) async {
        guard let store, !changingPolicy else { return }
        if !record.localOnly {
            if fullRecordingSourceID == record.id { cancelFullRecording() }
            if dictationSource == record.id { dictationFullOrganization = false }
            if transcriptReviewSourceID == record.id { transcriptReviewWorker?.cancel() }
        }
        changingPolicy = true
        defer { changingPolicy = false }
        do {
            _ = try await store.setSourceLocalOnly(sourceID: record.id, expectedVersion: record.policyVersion, localOnly: !record.localOnly)
            await refresh(); queueRecordingTitles()
            if record.localOnly {
                let paired=records.contains { $0.presentation?.recordingContext?.externalSourceID == record.id }
                if paired || (record.origin == "user" && (record.presentation?.expression != nil || record.presentation?.recordingContext != nil)) {
                    do { try await queueWholeRecordingUnderstanding(sourceID:record.id) }
                    catch { status="文字许可已恢复，整体整理尚未继续："+error.localizedDescription;return }
                }
                scheduleProcessing();resumeKnowledgeReviews()
            }
            status = "文本处理权限已更新 · 原始音频仍仅本机"
        } catch { status = error.localizedDescription }
    }
    func changeQuestion(_ question: QuestionRecord, to: QuestionStatus, reason: String, answerSourceID: String?, answerQuote: String?, commandID: String) async -> Bool {
        guard let store, !savingQuestion else { return false }
        savingQuestion = true; defer { savingQuestion = false }
        do {
            var evidence: OutcomeSourceEvidence?
            if to == .resolved {
                guard let answerSourceID, let answerQuote, !answerQuote.isEmpty,
                      let source = records.first(where: { $0.id == answerSourceID }), let version = source.transcriptVersionID, let text = source.transcript,
                      let span = source.spans.first(where: { String(String.UnicodeScalarView(Array(text.unicodeScalars)[$0.textStart..<$0.textEnd])).contains(answerQuote) }) else { throw VoiceOSError("请选择个人答案出处并填写其中连续的原话") }
                evidence = .init(reference: .init(sourceID: answerSourceID, transcriptVersionID: version, spanID: span.id), quote: answerQuote)
            }
            let input = try await store.prepareStoredQuestionTransition(questionID: question.id, expectedVersion: question.version, to: to, reason: reason, resolution: evidence)
            _ = try await store.transitionQuestion(questionID: question.id, input: input, commandID: commandID)
            await refresh(); status = "问题状态已保存 · 原认知归属和未验证状态保留"; return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func review(_ claim: CandidateClaim, action: ClaimReviewAction, statement: String? = nil, ownership: CandidateOwnership? = nil, note: String = "") async -> Bool {
        guard let store, !reviewingClaim else { return false }
        reviewingClaim = true; defer { reviewingClaim = false }
        do {
            _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: claim.reviewVersion, action: action, statement: statement, ownership: ownership, note: note)
            await refresh()
            status = action == .correct ? "认知更正已保存 · 重新待核对，原始结果与历史保留" : (action == .endorse ? "已记录明确认可 · 来源与未验证状态保留" : "已记录拒绝 · 保留历史，停止当前使用")
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func createAction(_ claim: CandidateClaim, title: String, kind: ActionKind, note: String, commandID: String) async -> Bool {
        guard let store, !savingAction else { return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: claim.reviewVersion, title: title, kind: kind, note: note, commandID: commandID)
            await refresh(); status = "意图已保存到 VoiceOS · 尚未写入提醒事项"; return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func confirmTask(_ action: ActionRecord, title: String, commandID: String) async -> Bool {
        guard let store, !savingAction else { return false }
        savingAction = true; defer { savingAction = false }
        do {
            focusedTaskID = try await store.confirmOpportunityAsTask(actionID: action.id, expectedVersion: action.version, title: title, commandID: commandID)
            await refresh(); await automaticReminderRefresh()
            status = "已按你的核对保存为明确待办 · " + reminderSyncStatus
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func connectReminders() async {
        guard !remindersBusy else { return }
        remindersBusy = true; defer { remindersBusy = false }
        reminderSyncStatus = "正在核对系统提醒事项权限"
        do {
            reminderCalendars = try await reminders.authorize()
            proposedReminderCalendarID = reminderCalendarID
            choosingReminderCalendar = true
            status = "请选择明确授权的清单 · 本次尚未更改连接"
            reminderSyncStatus = "系统权限可用 · 清单授权范围保持原设置"
        } catch {
            status = error.localizedDescription
            reminderSyncStatus = "系统权限核对未完成 · 保留既有连接"
        }
    }
    func saveReminderConnection() async {
        guard let store, let calendar = reminderCalendars.first(where: { $0.id == proposedReminderCalendarID }) else { return }
        do {
            reminderAccess = try await store.setReminderAccess(calendarID: calendar.id, title: calendar.title, enabled: true, expectedVersion: reminderAccess?.version ?? 0)
            choosingReminderCalendar = false
            status = "提醒事项持续授权已保存"
            reminderSyncStatus = "正在核对所选清单的任务"
            await refresh(); requestReminderRefresh()
        } catch { status = error.localizedDescription }
    }
    func connectVoiceOSCalendar() async {
        guard !remindersBusy else { return }
        remindersBusy = true
        do {
            let calendar = try await reminders.voiceOSCalendar()
            if !reminderCalendars.contains(where: { $0.id == calendar.id }) { reminderCalendars.append(calendar) }
            proposedReminderCalendarID = calendar.id
            remindersBusy = false
            await saveReminderConnection()
        } catch { remindersBusy = false; status = error.localizedDescription }
    }
    func disconnectReminders() async {
        guard let store, let access = reminderAccess else { return }
        do {
            _ = try await store.setReminderAccess(calendarID: access.calendarID, title: access.title, enabled: false, expectedVersion: access.version)
            reminderRefresh.stop()
            await refresh(); reminderSyncStatus = "提醒事项连接已暂停 · 外部任务和历史保留"
        } catch { status = error.localizedDescription }
    }
    private func installReminderRefresh() {
        guard reminderObservers.isEmpty else { return }
        reminderObservers.append(reminders.observeChanges { [weak self] in self?.requestReminderRefresh() })
        reminderObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.requestReminderRefresh(); self?.resumeRecordingFollowups(); self?.resumeKnowledgeReviews() } })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.requestReminderRefresh(); self?.resumeRecordingFollowups(); self?.resumeKnowledgeReviews() } }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.requestReminderRefresh() } }
        followupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.resumeRecordingFollowups(); self?.resumeAssistantExecutions(); self?.resumeKnowledgeReviews() } }
    }
    private func requestReminderRefresh() {
        guard reminderAccess?.enabled == true else { return }
        reminderRefresh.request()
    }
    func refreshTaskReminders() async { await automaticReminderRefresh() }
    func loadReminderSettings(_ action: ActionRecord) async -> ReminderSnapshot? {
        guard let link = reminderLinks.first(where: { $0.actionID == action.id }), link.state == "linked",
              reminderAccess?.enabled == true, reminderAccess?.calendarID == link.calendarID, !remindersBusy else {
            status = "请先同步此任务到已连接的提醒事项清单"; return nil
        }
        reminderFieldEditing = true; defer { reminderFieldEditing = false }
        do {
            let matches = try await reminders.find(calendarID: link.calendarID, externalID: link.externalID, marker: "voiceos-action:" + link.id)
            guard matches.count == 1, let snapshot = matches.first, snapshot.id == link.externalID, snapshot.marker == "voiceos-action:" + link.id,
                  !snapshot.completed, snapshot.fields != nil else { throw VoiceOSError("此提醒已完成、身份变化或含尚不能读取的设置；请在提醒事项中查看") }
            return snapshot
        } catch { status = error.localizedDescription; return nil }
    }
    func saveReminderSettings(_ action: ActionRecord, expected: ReminderSnapshot, fields: ReminderFields) async -> Bool {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy else { return false }
        remindersBusy = true; reminderFieldEditing = true
        defer { remindersBusy = false; reminderFieldEditing = false; requestReminderRefresh() }
        do {
            try await store.updateReminderFields(actionID: action.id, expectedVersion: action.version, expected: expected, desired: fields,
                                                 expectedAccessVersion: access.version, using: reminders)
            await refresh(); status = "日期、通知和优先级已保存并回读核对"; return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    private func automaticReminderRefresh() async {
        guard let store, let access = reminderAccess, access.enabled else { return }
        if remindersBusy || reminderFieldEditing { return }
        guard reminders.isAuthorized else { reminderSyncStatus = "系统权限不可用 · 自动回读暂停"; return }
        let before = Dictionary(uniqueKeysWithValues: actionRecords.filter { $0.kind == "task" }.map { ($0.id, String($0.version) + ":" + $0.state) })
        remindersBusy = true
        defer {
            remindersBusy = false
            if reminderFieldsReady {
                reminderFieldsReady = false
                requestReminderRefresh()
            }
        }
        do {
            // Field inference must not hold up completion readback or recording intake.
            try await store.syncRecordingExpressionReminders(using:reminders)
            if reminderFieldWorker == nil, let reminderFieldModel,
               !(try await store.prepareReminderFields()).tasks.isEmpty {
                reminderFieldFailure = nil
                reminderFieldWorker = Task {
                    defer { reminderFieldWorker = nil }
                    do {
                        try await store.extractReminderFields(using: reminderFieldModel)
                        reminderFieldFailure = nil
                        if remindersBusy { reminderFieldsReady = true }
                        else { requestReminderRefresh() }
                    } catch {
                        reminderFieldFailure = error.localizedDescription
                        reminderSyncStatus = "任务已保存，提醒字段待重试：" + error.localizedDescription
                    }
                }
            }
            try await store.refreshAuthorizedReminders(expectedAccessVersion: access.version, using: reminders, requireReviewedFields: true)
            if reminderAccess?.version == access.version {
                if let failure = reminderFieldFailure { reminderSyncStatus = "已回读既有任务，提醒字段待重试：" + failure }
                else if reminderFieldWorker != nil { reminderSyncStatus = "已回读既有任务 · 新任务日期和优先级正在后台核对" }
                else { reminderSyncStatus = "已自动核对「\(access.title)」的关联任务" }
            }
            try Task.checkCancellation()
        } catch {
            if reminderAccess?.version == access.version { reminderSyncStatus = "自动同步未全部完成 · 已保存各任务状态，不自动重建" }
        }
        await refresh()
        let changed = Set(actionRecords.filter { $0.kind == "task" && before[$0.id] != String($0.version) + ":" + $0.state }.map(\.id))
        if !changed.isEmpty { await queueActionFollowups(changed) }
    }
    func sendReminder(_ action: ActionRecord) async {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy, !reminderCalendarID.isEmpty else { return }
        remindersBusy = true; defer { remindersBusy = false; requestReminderRefresh() }
        do {
            if let reminderFieldModel { try await store.extractReminderFields(using: reminderFieldModel) }
            try await store.sendTaskToReminders(actionID: action.id, expectedVersion: action.version, calendarID: reminderCalendarID, using: reminders, expectedAccessVersion: access.version)
            status = "提醒事项尝试已记录 · 以回读状态为准"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func readReminder(_ link: ReminderLink) async {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy, reminderCalendarID == link.calendarID else { return }
        remindersBusy = true; defer { remindersBusy = false; requestReminderRefresh() }
        do {
            try await store.readReminder(linkID: link.id, calendarID: reminderCalendarID, using: reminders, expectedAccessVersion: access.version)
            status = "已回读关联任务 · 外部改名保留，完成反馈独立记录"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func actionHistory(_ action: ActionRecord) async {
        do {
            actionVersions = try await store?.actionHistory(actionID: action.id) ?? []
            feedbackRecords = try await store?.actionFeedback(actionID: action.id) ?? []
            activeActionTitle = action.title
        }
        catch { status = error.localizedDescription }
    }
    func focusReminder(_ url: URL) async -> Bool {
        guard url.scheme == "voiceos", url.host == "task", UUID(uuidString: url.lastPathComponent) != nil else { return false }
        await refresh()
        guard let link = reminderLinks.first(where: { $0.id == url.lastPathComponent }),
              let action = actionRecords.first(where: { $0.id == link.actionID }) else { status = "这条提醒的来源不在当前资料库中"; return false }
        focusedTaskID = action.id
        selected = claims.first(where: { $0.id == action.claimID })?.references.first?.sourceID
        return true
    }
    func enrichReminderContexts() async {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy else { return }
        remindersBusy = true; defer { remindersBusy = false; requestReminderRefresh() }
        var count = 0
        do {
            for link in reminderLinks where link.calendarID == access.calendarID && link.state == "linked" {
                guard let id = link.externalID, let action = actionRecords.first(where: { $0.id == link.actionID }),
                      action.validity == "current", reminderSourceAllowed(action) else { continue }
                let context = try await store.reminderContext(actionID: action.id)
                guard (try await store.reminderAccess())?.version == access.version else { throw VoiceOSError("提醒事项连接已变化，停止补充出处") }
                try reminders.updateContext(calendarID: access.calendarID, externalID: id, marker: "voiceos-action:" + link.id, context: context)
                count += 1
            }
            status = "已精简 \(count) 条提醒事项；完整原话、时间与说明保留在 VoiceOS"
        } catch { status = "已精简 \(count) 条提醒；" + error.localizedDescription }
        await refresh()
    }
    func acceptReminderStatus(_ link: ReminderLink, action: ActionRecord) async {
        guard let store, let access = reminderAccess, access.enabled,
              !remindersBusy, !savingAction, access.calendarID == link.calendarID,
              let observationID = link.lastObservationID else { return }
        remindersBusy = true; savingAction = true
        defer { remindersBusy = false; savingAction = false; requestReminderRefresh() }
        do {
            _ = try await store.acceptReminderStatus(linkID: link.id, expectedActionVersion: action.version,
                                                     expectedObservationID: observationID, expectedAccessVersion: access.version,
                                                     using: reminders)
            status = "已采用重新核对的提醒事项状态 · 外部任务未修改，观点仍需独立验证"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func executeSchedule(_ intent: ActionScheduleIntent, link: ReminderLink, grantID: String? = nil) async {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy,
              access.calendarID == link.calendarID, let observationID = link.lastObservationID else { return }
        remindersBusy = true; defer { remindersBusy = false }
        do {
            _ = try await store.executeReminderSchedule(intentID: intent.id, expectedObservationID: observationID,
                                                        expectedAccessVersion: access.version, grantID: grantID, using: reminders)
            status = "排期尝试已登记，请查看保存与回读状态"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func prepareScheduleEffect(_ intent: ActionScheduleIntent, link: ReminderLink) async {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy,
              access.calendarID == link.calendarID, let observation = link.lastObservationID else { return }
        do {
            pendingScheduleEffect = try await store.prepareReminderScheduleEffect(intentID: intent.id, expectedObservationID: observation, expectedAccessVersion: access.version)
        } catch { status = error.localizedDescription }
    }
    func confirmScheduleEffect(_ effect: ReminderScheduleEffect, commandID: String) async -> Bool {
        guard let store, !remindersBusy else { return false }
        remindersBusy = true; defer { remindersBusy = false }
        var approved = false
        do {
            let grant = try await store.confirmReminderSchedule(intentID: effect.intentID, expectedObservationID: effect.observationID,
                                                                 expectedAccessVersion: effect.accessVersion, displayedEffectDigest: effect.digest,
                                                                 actor: .user, commandID: commandID)
            approved = true
            _ = try await store.executeReminderSchedule(intentID: effect.intentID, expectedObservationID: effect.observationID,
                                                        expectedAccessVersion: effect.accessVersion, grantID: grant, using: reminders,
                                                        commandID: "schedule-effect:" + commandID)
            status = "本次改期已确认并登记尝试，请查看保存与回读状态"
        } catch { status = error.localizedDescription }
        await refresh()
        return approved
    }
    func revokeScheduleGrant(_ grant: ReminderScheduleGrant) async {
        do {
            _ = try await store?.revokeReminderScheduleGrant(grantID: grant.id, reason: "用户在控制中心撤回本次改期确认", actor: .user)
            status = "本次确认已撤回；已派发的效果保留核对记录，不自动撤销"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func prepareCompensation(_ impact: CorrectionActionImpact) async {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy else { return }
        do {
            let id = try await store.recordReminderCompensationPlan(actionID: impact.action.id,expectedImpactDigest: impact.digest,expectedAccessVersion: access.version)
            await refresh()
            pendingCompensation = compensationPlans.first { $0.id == id }
        } catch { status = error.localizedDescription }
    }
    func confirmCompensation(_ plan: ReminderCompensationPlan, commandID: String) async -> Bool {
        guard let store, !remindersBusy else { return false }
        remindersBusy = true; defer { remindersBusy = false }
        var approved = false
        do {
            let grant = try await store.confirmReminderCompensation(planID: plan.id,displayedEffectDigest: plan.digest,actor: .user,commandID: commandID)
            approved = true
            _ = try await store.executeReminderCompensation(planID: plan.id,grantID: grant,using: reminders,commandID: "compensation-effect:"+commandID)
            status = "期限补偿尝试已登记，请查看保存与回读状态；旧行动仍暂停"
        } catch { status = error.localizedDescription }
        await refresh(); return approved
    }
    func executeCompensation(_ plan: ReminderCompensationPlan, grant: ReminderCompensationGrant) async {
        guard let store, !remindersBusy else { return }
        remindersBusy = true; defer { remindersBusy = false }
        do {
            _ = try await store.executeReminderCompensation(planID: plan.id,grantID: grant.id,using: reminders)
            status = "补偿尝试已保留，请查看实际效果"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func revokeCompensation(_ grant: ReminderCompensationGrant) async {
        do {
            _ = try await store?.revokeReminderCompensation(grantID: grant.id,reason: "用户在控制中心撤回期限补偿确认",actor: .user)
            status = "补偿许可已撤回；已派发效果仅回读核对，不自动反向改期"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func reconcileCompensation(_ operation: ReminderCompensationOperation) async {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy else { return }
        remindersBusy = true; defer { remindersBusy = false }
        do {
            try await store.reconcileReminderCompensation(operationID: operation.id,expectedAccessVersion: access.version,using: reminders)
            status = "补偿效果已只读核对，没有重发"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func saveUserSchedule(_ action: ActionRecord, due: ReminderDueDate, scheduleVersion: Int,
                          anchorTime: Date, timeZone: String, commandID: String) async -> Bool {
        guard let store, !savingAction else { return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try due.writableComponents()
            let link = reminderLinks.first { $0.actionID == action.id && $0.state == "linked" && $0.remoteMarkerValid == true && $0.remoteCompleted == false && $0.remoteDueDate != nil }
            let access = reminderAccess.flatMap { $0.enabled && $0.calendarID == link?.calendarID ? $0 : nil }
            _ = try await store.recordActionSchedule(actionID: action.id, expectedActionVersion: action.version, expectedScheduleVersion: scheduleVersion,
                                                     proposal: .init(due: due, authority: .userCommitment,
                                                                     rawExpression: "用户在控制中心设置期限选择：" + due.summary, anchorEventTime: anchorTime),
                                                     actor: .user, anchorTimeZone: timeZone, baseObservationID: access == nil ? nil : link?.lastObservationID,
                                                     expectedAccessVersion: access?.version, commandID: commandID)
            status = "期限选择已本地保存；外部差异须查看具体效果后确认"
            await refresh(); return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func reconcileSchedule(_ operation: ReminderScheduleOperation) async {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy else { return }
        remindersBusy = true; defer { remindersBusy = false }
        do {
            try await store.reconcileReminderSchedule(operationID: operation.id, expectedAccessVersion: access.version, using: reminders)
            status = "已只读核对排期结果，没有重新派发"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func saveFeedback(_ action: ActionRecord, kind: ActionFeedbackKind, text: String, recordingSourceID: String? = nil, commandID: String, allowCloud: Bool = true) async -> Bool {
        guard let store, !savingFeedback else { return false }
        savingFeedback = true; defer { savingFeedback = false }
        do {
            selected = try await store.recordActionFeedback(actionID: action.id, expectedVersion: action.version, kind: kind, text: text, recordingSourceID: recordingSourceID, commandID: commandID)
            if allowCloud, let id = selected {
                let policy = try await store.sourcePolicy(sourceID: id)
                if policy.localOnly { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: false) }
            }
            if allowCloud {
                if let cognition = textModel, let association = associationModel {
                    do { try await store.enqueueActionFeedbackUnderstanding(cognition: cognition.configuration, association: association.configuration) }
                    catch { followupStatus = "结果已保存，知识整理尚未排入：" + error.localizedDescription }
                }
            }
            await refresh(); scheduleProcessing()
            status = allowCloud ? "结果原话已关联原行动，知识与思想跟进将在后台整理" : "结果原话已关联原行动 · 仅本地保存"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func changeAction(_ action: ActionRecord, state: LocalActionState) async {
        guard let store, !savingAction else { return }
        savingAction = true; defer { savingAction = false }
        do {
            if state != .dismissed, let link = reminderLinks.first(where: { $0.actionID == action.id }), let id = link.externalID {
                guard let access = reminderAccess, access.enabled, access.calendarID == link.calendarID, !remindersBusy else { throw VoiceOSError("请先恢复提醒事项连接，或在 Apple 提醒事项中更改完成状态") }
                remindersBusy = true; defer { remindersBusy = false; requestReminderRefresh() }
                try await reminders.setCompletion(calendarID: link.calendarID, externalID: id, marker: "voiceos-action:" + link.id, completed: state == .completed) {
                    guard let currentAccess = try await store.reminderAccess(), currentAccess.enabled, currentAccess.version == access.version,
                          let current = try await store.actions(includeHistory: true).first(where: { $0.id == action.id }), current.validity == "current", current.version == action.version else { throw VoiceOSError("任务或连接已变化，请重新核对") }
                }
                try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: reminders, expectedAccessVersion: access.version)
                status = "完成状态已同步并回读；可以补充实际结果或收获"
            } else {
                _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: state)
                status = "行动状态已保存"
            }
        } catch { status = error.localizedDescription }
        await refresh(); await queueActionFollowups([action.id])
    }
    func reviewHistory(_ claim: CandidateClaim) async {
        do { claimHistory = try await store?.claimReviewHistory(claimID: claim.id) ?? [] }
        catch { status = error.localizedDescription }
    }
    func play(_ record: SourceRecord) async {
        do { if let url = try await store?.playableURL(sourceID: record.id) { NSWorkspace.shared.open(url) } }
        catch { status = error.localizedDescription; await refresh() }
    }
    func retry(_ record: SourceRecord) async {
        do { try await store?.retryTranscription(sourceID: record.id); await refresh(); scheduleProcessing() }
        catch { status = error.localizedDescription }
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main
struct VoiceOSApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model = ControlCenter()
    @FocusedValue(\.voiceOSController) private var focusedModel
    var body: some Scene {
        Window("VoiceOS", id: "control-center") { WorkspaceView(model: model) }
        WindowGroup("独立资料库", id: "restored-library", for: String.self) { path in
            if let path = path.wrappedValue { RestoredLibraryView(path: path) }
        }
        .commands { CommandGroup(after: .newItem) { Button("导入音频或视频…") { focusedModel?.chooseFullRecording() }.keyboardShortcut("i").disabled(focusedModel?.initialized != true || focusedModel?.importing == true) } }
    }
}

struct ActionCreationView: View {
    let claim: CandidateClaim
    @ObservedObject var model: ControlCenter
    let close: () -> Void
    @State private var title = ""
    @State private var kind: ActionKind = .opportunity
    @State private var note = ""
    @State private var commandID = UUID().uuidString
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("记录行动意图").font(.title2)
            Text("认可观点不等于承诺任务。选择明确任务，或先放入机会池；尚未写入提醒事项。").foregroundStyle(.secondary)
            Text("依据：" + claim.statement).lineLimit(4)
            Picker("意图", selection: $kind) {
                Text("探索意图 · 机会池").tag(ActionKind.opportunity)
                Text("明确任务").tag(ActionKind.task)
            }.pickerStyle(.segmented)
            TextField("要做什么", text: $title)
            TextField("补充说明（可选）", text: $note)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消", action: close).disabled(model.savingAction)
                Spacer()
                Button("保存意图") { Task { if await model.createAction(claim, title: title, kind: kind, note: note, commandID: commandID) { close() } } }
                    .disabled(model.savingAction || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600)
    }
}

struct ActionFeedbackView: View {
    let action: ActionRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var allowFollowup = true
    @State private var kind = "outcome"
    @State private var text = ""
    @State private var saving = false
    @State private var errorText = ""
    @State private var commandID = UUID().uuidString
    @State private var recordingID: String?
    @State private var appliedRecording = false
    private var recording: SourceRecord? { model.records.first { $0.id == recordingID } }
    private var waitingForVoice: Bool { recordingID != nil && !appliedRecording && (model.dictationActive || model.dictationBusy || ["queued", "running"].contains(recording?.jobState ?? "")) }
    private func applyTranscription() {
        guard !appliedRecording, let recording, recording.jobState == "completed", let transcript = recording.transcript else { return }
        text += (text.isEmpty ? "" : "\n") + transcript
        appliedRecording = true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("记录结果或反思").font(.title2)
            Text("关联：" + action.title + " · 第 \(action.version) 版").foregroundStyle(.secondary)
            Picker("类型", selection: $kind) { Text("实际结果").tag("outcome"); Text("我的反思").tag("reflection") }.pickerStyle(.segmented).disabled(saving)
            HStack {
                if recordingID != nil, model.dictationActive {
                    Button("停止并转写") { model.stopDictation() }.disabled(model.dictationBusy)
                    Text("正在录制这条任务的结果…").foregroundStyle(.secondary)
                } else if waitingForVoice {
                    ProgressView().controlSize(.small); Text("Qwen 正在本机转写…").foregroundStyle(.secondary)
                } else if recordingID == nil {
                    Button("口述进展或结果", systemImage: "mic") {
                        Task { recordingID = await model.startFeedbackDictation(); if recordingID == nil { errorText = model.status } }
                    }.disabled(saving || model.dictationBusy || model.dictationActive || model.fullRecordingBusy)
                } else {
                    Text(appliedRecording ? "口述已填入下方，可核对修改。原始录音保留。" : "转写未完成，录音已保留；也可以直接写下结果。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $text).frame(minHeight: 180).border(.secondary.opacity(0.2)).disabled(saving || waitingForVoice)
            Text("这是可选记录，原话与原行动保持关联。开启下方选项后，应用会自动核对思想变化与目标下一步；不会把反馈当成事实已验证。").font(.caption).foregroundStyle(.secondary)
            if !errorText.isEmpty { Text(errorText).font(.callout).foregroundStyle(.red) }
            Toggle("将反馈文字用于整理知识、更新思想与目标", isOn: $allowFollowup).font(.caption).disabled(saving)
            HStack {
                Button("取消", action:dismiss).disabled(saving || (recordingID != nil && (model.dictationActive || model.dictationBusy)))
                Spacer(); Text("\(text.unicodeScalars.count)/4000").font(.caption)
                Button(saving ? "正在保存…" : "保存反馈") {
                    saving = true; errorText = ""
                    Task {
                        let savedRecording = recording?.state == "saved" ? recordingID : nil
                        if await model.saveFeedback(action,kind:ActionFeedbackKind(rawValue:kind)!,text:text,recordingSourceID:savedRecording,commandID:commandID,allowCloud:allowFollowup) { dismiss() }
                        else { errorText = model.status }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || waitingForVoice || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.unicodeScalars.count > 4000)
            }
        }.padding(24).frame(width:620)
            .onChange(of: recording?.transcriptVersionID) { _, _ in applyTranscription() }
            .interactiveDismissDisabled(saving || (recordingID != nil && model.dictationActive))
    }
}

struct RestoredLibraryView: View {
    @StateObject private var model: ControlCenter
    init(path: String) { _model = StateObject(wrappedValue: ControlCenter(root: URL(fileURLWithPath:path,isDirectory:true))) }
    var body: some View { WorkspaceView(model:model) }
}
struct PackageRestoreView: View {
    let dismiss: () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var package: URL?
    @State private var summary: PackageSummary?
    @State private var parent: URL?
    @State private var folderName = "VoiceOS-恢复-" + String(ISO8601DateFormatter().string(from:Date()).prefix(10))
    @State private var restoring = false
    @State private var errorText = ""
    @State private var restored: URL?
    private var destination: URL? {
        guard let parent, !folderName.isEmpty, folderName != ".", folderName != "..", !folderName.contains("/"), !folderName.contains("\0") else { return nil }
        return parent.appendingPathComponent(folderName,isDirectory:true)
    }
    private func choosePackage() {
        let panel = NSOpenPanel(); panel.title = "选择 VoiceOS 迁移包文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            package = nil; summary = nil; errorText = ""
            do { summary = try VoiceOSStore.packageSummary(at:url); package = url }
            catch { errorText = error.localizedDescription }
        }
    }
    private func chooseParent() {
        let panel = NSOpenPanel(); panel.title = "选择新资料库的上级文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK { parent = panel.url; errorText = "" } }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("从迁移包恢复").font(.title2)
            Text("恢复到一个新资料库，保留当前资料库。完成后可在新窗口打开；提醒事项需要重新连接。").foregroundStyle(.secondary)
            Button("选择迁移包文件夹…",action:choosePackage).disabled(restoring || restored != nil)
            if let package, let summary {
                Text(package.path).font(.caption).textSelection(.enabled)
                Text("包版本 \(summary.version) · \(summary.sourceCount) 份资料 · \(summary.mediaIncluded ? "包含原件" : "结构化记录")")
                Text(summary.omittedAssetCount > 0 ? "\(summary.omittedAssetCount) 份原件未打包：恢复后可读文字与历史，无法播放缺失原件。" : "清单中没有省略的原件。恢复时仍会核对文件与关联完整性。").font(.callout)
            }
            Button("选择保存位置…",action:chooseParent).disabled(restoring || restored != nil)
            TextField("新资料库文件夹名称",text:$folderName).disabled(restoring || restored != nil)
            if let destination { Text(destination.path).font(.caption).textSelection(.enabled) }
            if !errorText.isEmpty { Text(errorText).foregroundStyle(.red).textSelection(.enabled) }
            if let restored { Text("恢复完成 · 当前库保留，外部连接未启用").foregroundStyle(.green); Button("打开恢复的资料库") { openWindow(id:"restored-library",value:restored.path); dismiss() } }
            HStack {
                Button(restored == nil ? "取消" : "完成",action:dismiss).disabled(restoring)
                Spacer()
                if restored == nil {
                    Button(restoring ? "正在校验与恢复…" : "校验并恢复") {
                        guard let package, let destination else { return }
                        guard !destination.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(package.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { errorText = "请选择迁移包之外的新资料库位置"; return }
                        restoring = true; errorText = ""
                        Task {
                            do { try await VoiceOSStore.restorePackage(from:package,to:destination,inspector:NativeMediaInspector()); restored = destination }
                            catch { errorText = error.localizedDescription }
                            restoring = false
                        }
                    }.keyboardShortcut(.defaultAction).disabled(restoring || package == nil || destination == nil)
                }
            }
        }.padding(24).frame(width:640)
    }
}

private struct VoiceOSControllerKey: FocusedValueKey { typealias Value = ControlCenter }
extension FocusedValues {
    var voiceOSController: ControlCenter? {
        get { self[VoiceOSControllerKey.self] }
        set { self[VoiceOSControllerKey.self] = newValue }
    }
}

struct CognitiveFeedbackView: View {
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("静默回顾").font(.title2)
            Text("可以直接关闭，不要求回应。这里显示已接纳的关联提案和主动查找的相关原文。").font(.callout).foregroundStyle(.secondary)
            Picker("显示方式",selection:Binding(get:{ model.quietMode },set:{ mode in Task { await model.changeQuietMode(mode) } })) {
                Text("正常显示").tag(CognitiveFeedbackMode.normal)
                Text("减少显示 · 一次一条").tag(CognitiveFeedbackMode.reduced)
                Text("暂停显示").tag(CognitiveFeedbackMode.paused)
            }.pickerStyle(.segmented)
            Text(model.quietStatus).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if model.quietFeedback.isEmpty && model.associationFeedback.isEmpty {
                        Text(model.quietMode == .paused ? "已暂停静默回顾，原文与历史保留。" : "暂无可显示的相关原文。无需回复或补做任务。")
                    }
                    ForEach(model.associationFeedback) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("与这次表达有关 · AI关系提案").font(.headline)
                            Text(item.proposal.relation.displayName).font(.caption).foregroundStyle(.secondary)
                            AssociationQuestionsView(item: item, model: model)
                            Text("为何现在相关：" + item.proposal.reason).textSelection(.enabled)
                            Text("这次原话：" + item.proposal.current.quote).textSelection(.enabled)
                            Text("历史原话：" + item.proposal.historicalQuote).textSelection(.enabled)
                            Text(item.historical.document.name + " · " + item.historical.document.createdAt).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("查看这次原话") { Task { if await model.openAssociation(item, historical: false) { dismiss() } } }
                                Button("查看历史出处") { Task { if await model.openAssociation(item, historical: true) { dismiss() } } }
                                Button("忽略关联") { Task { await model.ignoreAssociation(item) } }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(model.quietFeedback) { item in
                        VStack(alignment:.leading,spacing:8) {
                            Text("你查找的是：\(item.query)").font(.headline).textSelection(.enabled)
                            Text("模型选中的相关原文 · \(item.hit.document.origin == "user" ? "用户表达" : "外部资料")").font(.caption).foregroundStyle(.secondary)
                            Text(item.hit.document.text).textSelection(.enabled)
                            Text(item.hit.document.name + " · " + item.hit.document.createdAt).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("查看原文与出处") { Task { if await model.openQuietFeedback(item) { dismiss() } } }
                                Button("忽略这条") { Task { await model.ignoreQuietFeedback(item) } }
                            }
                        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack { Spacer(); Button("完成",action:dismiss).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width:720,height:560).task { await model.refreshQuietFeedback() }
    }
}

struct HistorySearchView: View {
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var query = ""
    @State private var question = ""
    @State private var selectedIDs: Set<String> = []
    @State private var semantic = false
    private var candidates: [RetrievalHit] { (model.retrievalResult?.hits ?? []).filter { selectedIDs.contains($0.id) } }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("查找历史文字").font(.title2)
            TextField(semantic ? "输入想找回的问题或想法" : "先输入原文关键词",text:$query).onSubmit { model.searchHistory(query:query,semantic:semantic) }
            Toggle("按意思找原文（本机）",isOn:$semantic).disabled(!model.semanticAvailable)
            Text(model.semanticAvailable ? "查找仅在本机进行；按意思找到的只是候选。选中原文后，可单独让文本模型判断与你的问题是否直接相关。" : "关键词查找在本机进行。这个构建尚未包含本地语义资源；选中原文后仍可单独判断相关性。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.searchingHistory ? "正在查找…" : "查找") { model.searchHistory(query:query,semantic:semantic) }.disabled(model.searchingHistory || query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || query.unicodeScalars.count > 512)
                if model.searchingHistory { Button("停止查找") { model.cancelHistorySearch() } }
                Text("\(query.unicodeScalars.count)/512").font(.caption)
            }
            Text(model.retrievalStatus).font(.caption)
            RelevanceSearchPanel(model:model,coordinator:model.relevance,question:$question,candidates:candidates,dismiss:dismiss)
            ScrollView {
                if let result = model.retrievalResult {
                    if result.hits.isEmpty { Text("未找到候选。不代表历史中一定没有相关内容，可以换个表述或关键词。").foregroundStyle(.secondary) }
                    ForEach(result.hits) { hit in
                        VStack(alignment:.leading,spacing:6) {
                            Text(model.records.first(where: { $0.id == hit.document.sourceID })?.displayTitle ?? hit.document.name).font(.headline)
                            Toggle("加入相关性判断",isOn:Binding(get:{ selectedIDs.contains(hit.id) },set:{ value in
                                if value { selectedIDs.insert(hit.id) } else { selectedIDs.remove(hit.id) }
                            })).disabled(!selectedIDs.contains(hit.id) && selectedIDs.count >= 8)
                            Text("\(hit.method == "exact" ? "文字匹配" : "语义候选 · 待核对") · \(hit.document.origin == "user" ? "用户原文" : "外部原文 · 说话人待核对") · \(hit.document.localOnly ? "仅本地" : "文本可用于云端")").font(.caption).foregroundStyle(.secondary)
                            Text(hit.document.text).textSelection(.enabled)
                            Text(hit.document.createdAt).font(.caption).foregroundStyle(.secondary)
                            Button("查看原文与出处") { Task { if await model.openRetrievalHit(hit) { dismiss() } } }
                            Divider()
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
            }
            Button("完成",action:dismiss)
        }.padding(24).frame(width:720,height:740)
        .onChange(of:query) { selectedIDs = []; model.cancelHistorySearch() }
        .onChange(of:selectedIDs) { model.relevance.cancel() }
        .onChange(of:question) { model.relevance.cancel() }
        .onChange(of:semantic) { selectedIDs = []; model.cancelHistorySearch() }
        .onDisappear { model.cancelHistorySearch() }
    }
}

struct RelevanceSearchPanel: View {
    @ObservedObject var model: ControlCenter
    @ObservedObject var coordinator: RelevanceQueryCoordinator
    @Binding var question: String
    let candidates: [RetrievalHit]
    let dismiss: () -> Void
    private var scalars: Int { question.unicodeScalars.count + candidates.reduce(0) { $0 + $1.document.text.unicodeScalars.count } }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            TextField("想找回的问题或想法",text:$question)
            Text("已选 \(candidates.count)/8 份原文 · 问题与原文共 \(scalars)/4000 字符").font(.caption)
            Text("判断时发送本次问题与所选原文，不发送音视频。仅本地资料需先到出处页面授权；相关不表示支持或已验证，也不创建行动。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("准备所选原文") { Task { await model.prepareRelevance(query:question,candidates:candidates) } }
                    .disabled(coordinator.busy || candidates.isEmpty || question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || question.unicodeScalars.count > 512 || scalars > 4000)
                Button("用文本模型判断") { model.judgeRelevance() }
                    .disabled(coordinator.busy || coordinator.snapshot == nil || !model.modelConfigured)
                if coordinator.busy { Button("停止判断") { coordinator.stop() } }
                if !model.modelConfigured { Button("配置文本模型…") { model.chooseTextModel() } }
            }
            Text(coordinator.status).font(.caption).accessibilityIdentifier("relevanceStatus")
            if let usage = coordinator.usage {
                Text("输入 \(usage["input_tokens"].map(String.init) ?? "未知") · 输出 \(usage["output_tokens"].map(String.init) ?? "未知") token · 账单费用未知").font(.caption).foregroundStyle(.secondary)
            }
            if let hits = coordinator.hits {
                ForEach(hits) { hit in
                    HStack(alignment:.top) {
                        Text(hit.document.text).lineLimit(3).textSelection(.enabled)
                        Spacer()
                        Button("核对相关原文") { Task { if await model.openRetrievalHit(hit) { dismiss() } } }
                    }
                }
            }
        }.padding(12).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
    }
}

@MainActor
extension ControlCenter {
    var discussionWritable:Bool { discussionSession?.state == "active" && discussionSession?.validity == "current" }
    var discussionCanSend:Bool {
        guard discussionWritable,modelConfigured,!discussionTurns.isEmpty,let last=discussionTurns.last,
              !discussionReplies.contains(where: { $0.replyToTurnID == last.id }) else { return false }
        let ids=discussionHistory.map(\.sourceID)+discussionTurns.map(\.sourceID)
        return ids.allSatisfy { id in records.contains(where: { $0.id == id && !$0.localOnly }) }
    }
    var discussionCanExtract:Bool {
        guard let session=discussionSession,session.state == "ended",session.validity == "current",outcomeModel != nil,
              discussionOutcomes.isEmpty,!discussionTurns.isEmpty,understandingWorker == nil,!discussionSending,!discussionSaving,!discussionExtracting,!dictationActive,
              !discussionReplies.contains(where: { $0.state == "reserved" }) else { return false }
        let inputs=discussionHistory.map { ($0.sourceID,$0.transcriptVersionID) }+discussionTurns.map { ($0.sourceID,$0.transcriptVersionID) }
        return inputs.allSatisfy { id,version in records.contains { $0.id == id && $0.transcriptVersionID == version && !$0.localOnly } }
    }
    func extractDiscussionOutcome() {
        guard let store,let session=discussionSession,let port=outcomeModel,discussionCanExtract,outcomeWorker == nil else { return }
        discussionExtracting=true;discussionStatus="正在整理整段已授权文字；已有成果沿用，未登记结果不会自动重发。"
        outcomeWorker=Task {
            do {
                let input=try await store.prepareReusableConversationOutcome(id:session.id,expectedVersion:session.version,destination:.cloud)
                let ids=try await store.performConversationOutcome(input,using:port)
                discussionStatus=ids.isEmpty ? "整段成果已保存 · 没有新增陈述，已有成果身份保留。":"整段成果已保存 · \(ids.count)条新陈述待核对；明确行动遵循已有清单授权。"
            } catch { discussionStatus=error.localizedDescription }
            await refresh();requestReminderRefresh()
            discussionExtracting=false;outcomeWorker=nil
        }
    }
    var discussionRecordings:[SourceRecord] {
        records.filter { record in record.origin == "user" && record.kind == "audio" && record.state == "saved" && (record.transcript ?? "").unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) && !discussionTurns.contains(where: { $0.sourceID == record.id }) && !discussionHistory.contains(where: { $0.sourceID == record.id }) }
    }
    func refreshDiscussion() async {
        guard let store else { return }
        do {
            discussionList=try await store.conversations()
            guard let id=discussionSession?.id else { return }
            let session=try await store.conversation(id:id),turns=try await store.conversationUserTurns(conversationID:id)
            let replies=try await store.discussionAttempts(conversationID:id),history=try await store.conversationHistorySources(conversationID:id)
            let derivations=try await store.discussionClaimDerivations(conversationID:id),outcomes=try await store.conversationOutcomes(conversationID:id)
            let reflection = try await store.conversationReflectionFocus(conversationID: id)
            guard discussionSession?.id == id else { return }
            discussionSession=session;discussionTurns=turns;discussionReplies=replies;discussionHistory=history;discussionDerivations=derivations;discussionOutcomes=outcomes
            discussionReflection = reflection
        } catch { discussionStatus=error.localizedDescription }
    }
    @discardableResult
    func openDiscussion(_ id:String) async -> Bool {
        guard let store,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive else {
            discussionStatus = "讨论正在保存或回复，请稍后再打开历史。"; return false
        }
        discussionSaving = true; defer { discussionSaving = false }
        do {
            discussionSession=try await store.conversation(id:id);discussionRecordingID=nil
            discussionStatus="已打开讨论历史；没有自动发送。"
            await refreshDiscussion(); return true
        } catch { discussionStatus=error.localizedDescription; return false }
    }
    func beginDiscussion(_ record:SourceRecord) async -> Bool {
        guard let store,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive else { return false }
        discussionSaving=true;defer { discussionSaving=false }
        do {
            let members=record.recordingExpression?.sourceIDs ?? [record.id]
            let sources=try await store.recordingContextSourceIDs(sourceIDs:members)
            let id=try await store.beginConversation(sourceIDs:sources)
            discussionSession=try await store.conversation(id:id);discussionRecordingID=nil
            discussionStatus=members.count > 1 ? "已带上本次连续表达的全部录音，输入问题后直接发送。" : "已带上这份材料，输入问题后直接发送。"
            await refreshDiscussion();return true
        } catch { status=error.localizedDescription;return false }
    }
    func beginThoughtDiscussion(_ claim: CandidateClaim) async -> Bool {
        guard let store, !discussionSaving, !discussionSending, !discussionExtracting, !dictationActive else { return false }
        discussionSaving = true; defer { discussionSaving = false }
        do {
            let id = try await store.beginConversationForThought(claimID: claim.id)
            discussionSession = try await store.conversation(id: id); discussionRecordingID = nil
            discussionStatus = "已带上这条思考、相关旧观点与任务结果，输入后直接发送。"
            await refreshDiscussion(); return true
        } catch { status = error.localizedDescription; return false }
    }
    func loadReflection(_ interval: DateInterval) async throws -> ConversationReflectionFocus {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        return try await store.reflection(start: interval.start, end: interval.end, timeZoneID: Calendar.current.timeZone.identifier)
    }
    func loadReflectionQuestions() async throws -> [ReflectionQuestion] {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        return try await store.reflectionQuestions()
    }
    func loadTopicResurfacing() async throws -> [ReflectionTopicResurfacing] {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        return try await store.topicResurfacing()
    }
    func loadTopicFeedback() async throws -> [ReflectionTopicFeedback] {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        return try await store.reflectionTopicFeedback()
    }
    func saveTopicFeedback(_ id: String, mode: CognitiveFeedbackMode, snooze: Bool) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try await store.saveTopicFeedback(questionID: id, mode: mode, snooze: snooze)
    }
    func markTopicReviewed(_ id: String) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try await store.markTopicReviewed(questionID: id)
    }
    func linkTopicClaim(questionID: String, claimID: String, expectedReviewVersion: Int) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try await store.linkTopicClaim(questionID: questionID, claimID: claimID, expectedReviewVersion: expectedReviewVersion)
    }
    func linkTopicAction(questionID: String, actionID: String, expectedVersion: Int) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try await store.linkTopicAction(questionID: questionID, actionID: actionID, expectedVersion: expectedVersion)
    }
    func loadReflectionQuestionDetails(_ id: String) async throws -> (entries: [ReflectionQuestionEntry], sourceIDs: [String]) {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        let entries = try await store.reflectionQuestionEntries(questionID: id)
        let ids = try await store.reflectionQuestionSourceIDs(questionID: id)
        return (entries, ids)
    }
    func createReflectionQuestion(_ title: String, allowCloud: Bool) async throws -> ReflectionQuestion {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        let question = try await store.createReflectionQuestion(title: title)
        if allowCloud { _ = try await store.setSourceLocalOnly(sourceID: question.sourceID, expectedVersion: 1, localOnly: false) }
        await refresh()
        return question
    }
    func renameReflectionQuestion(_ id: String, title: String, allowCloud: Bool) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try await store.renameReflectionQuestion(id: id, title: title)
        if let question = try await store.reflectionQuestions().first(where: { $0.id == id }),
           let source = try await store.sources().first(where: { $0.id == question.sourceID }), source.localOnly == allowCloud {
            _ = try await store.setSourceLocalOnly(sourceID: source.id, expectedVersion: source.policyVersion, localOnly: !allowCloud)
        }
        await refresh()
    }
    func saveReflectionQuestionEntry(questionID: String, kind: ReflectionQuestionEntryKind, text: String, sourceIDs: [String], allowCloud: Bool) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        let entry = try await store.addReflectionQuestionEntry(questionID: questionID, kind: kind, text: text, sourceIDs: sourceIDs)
        if allowCloud { _ = try await store.setSourceLocalOnly(sourceID: entry.sourceID, expectedVersion: 1, localOnly: false) }
        await refresh()
    }
    func linkReflectionQuestionSource(questionID: String, sourceID: String, linked: Bool) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        if linked { try await store.linkReflectionQuestionSource(questionID: questionID, sourceID: sourceID) }
        else { try await store.unlinkReflectionQuestionSource(questionID: questionID, sourceID: sourceID) }
    }
    func stopReflectionQuestionEntry(_ id: String) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try await store.stopReflectionQuestionEntry(id: id)
        await refresh()
    }
    func enqueueAssistant(_ action: ActionRecord, instruction: String, questionID: String?, allowCloud: Bool) async -> Bool {
        guard let store, assistantModel != nil, allowCloud else {
            assistantStatus = "请配置模型，并允许本次交付要求用于云端代办"; return false
        }
        do {
            let claims = try await store.candidateClaims()
            let catalog = try await store.sources()
            let ids = Set(claims.first(where: { $0.id == action.claimID })?.references.map(\.sourceID) ?? [])
            guard !ids.isEmpty, catalog.filter({ ids.contains($0.id) }).allSatisfy({ !$0.localOnly }) else {
                throw VoiceOSError("任务依据仍为仅本地。请在资料库允许对应原文用于云端并更新理解，再委托当前任务；不会自动更改已有资料的许可。")
            }
            _ = try await store.enqueueAssistantExecution(actionID: action.id, expectedVersion: action.version, instruction: instruction, questionID: questionID, allowInstructionCloud: true)
            assistantStatus = "委托已保存，AI 助理正在准备交付"
            await refresh(); resumeAssistantExecutions(); return true
        } catch { assistantStatus = error.localizedDescription; await refresh(); return false }
    }
    func retryAssistant(_ execution: AssistantExecutionRecord) async {
        do { try await store?.retryAssistantExecution(id: execution.id); assistantStatus = "已重新排队"; await refresh(); resumeAssistantExecutions() }
        catch { assistantStatus = error.localizedDescription }
    }
    func retryAssistantAssessment(_ issue: AssistantAssessmentIssue) async {
        guard let store, let port = assistantModel, !assistantBusy else { return }
        assistantBusy = true
        defer { assistantBusy = false }
        do {
            try await store.retryAssistantAssessment(actionID: issue.actionID, expectedVersion: issue.actionVersion, using: port)
            assistantStatus = "意图已重新识别；明确委托才会执行"
            await refresh()
            resumeAssistantExecutions()
        } catch { assistantStatus = error.localizedDescription; await refresh() }
    }
    func cancelAssistant(_ execution: AssistantExecutionRecord) async {
        do { try await store?.cancelAssistantExecution(id: execution.id); assistantStatus = "已取消这份代办，保留委托记录"; await refresh() }
        catch { assistantStatus = error.localizedDescription }
    }
    func attachAssistantResult(_ execution: AssistantExecutionRecord, questionID: String) async -> Bool {
        guard let store else { return false }
        do {
            try await store.attachAssistantExecution(id: execution.id, questionID: questionID)
            assistantStatus = "AI 成果已接回主题，可继续讨论和记录自己的判断"
            await refresh(); return true
        } catch { assistantStatus = error.localizedDescription; return false }
    }
    func beginAssistantDiscussion(_ execution: AssistantExecutionRecord) async -> Bool {
        guard let store else { return false }
        do {
            guard let current = try await store.assistantExecutions().first(where: { $0.id == execution.id }), current.validity == "current", current.state == "completed", let resultID = current.resultSourceID else { throw VoiceOSError("这份交付已变化，请核对当前依据") }
            let ids = current.sourceIDs + [resultID]
            let catalog = try await store.sources()
            let focus: ConversationReflectionFocus
            if let questionID = current.questionID {
                let topic = try await store.reflectionForTopic(questionID: questionID, timeZoneID: Calendar.current.timeZone.identifier)
                var sourceIDs = topic.sourceIDs
                for id in ids where !sourceIDs.contains(id) { sourceIDs.append(id) }
                var combined = try await store.reflectionContentsForSources(sourceIDs: sourceIDs, timeZoneID: Calendar.current.timeZone.identifier)
                combined.question = topic.question
                focus = combined
            } else {
                focus = try await store.reflectionContentsForSources(sourceIDs: ids, timeZoneID: Calendar.current.timeZone.identifier)
            }
            guard catalog.contains(where: { $0.id == resultID }) else { throw VoiceOSError("交付原文尚未准备好") }
            let opened = await beginReflectionDiscussion(focus)
            if opened { discussionStatus = "已带上 AI 交付与原始任务依据，输入后直接发送。" }
            return opened
        } catch { assistantStatus = error.localizedDescription; return false }
    }
    private func resumeAssistantExecutions() {
        guard initialized, let store, let port = assistantModel, assistantWorker == nil, !dictationActive, !fullRecordingBusy else { return }
        assistantWorker = Task {
            assistantBusy = true
            defer { assistantBusy = false; assistantWorker = nil }
            do {
                assistantStatus = "正在检查明确委托，并推进已保存的代办…"
                // Deliver queued work first; discovering other tasks must not
                // postpone an explicit delegation made in the foreground.
                while try await store.processNextAssistantExecution(using: port, onProgress: { [weak self] in await self?.refresh() }) { try Task.checkCancellation() }
                try await store.discoverAutomaticAssistantExecutions(using: port)
                await refresh()
                while try await store.processNextAssistantExecution(using: port, onProgress: { [weak self] in await self?.refresh() }) { try Task.checkCancellation() }
                assistantStatus = "AI 代办状态已更新；成果可在任务或工作台查看"
                await refresh()
            } catch { assistantStatus = "AI 代办尚未完成：" + error.localizedDescription; await refresh() }
        }
    }
    func loadTopicReflection(_ id: String) async throws -> ConversationReflectionFocus {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        return try await store.reflectionForTopic(questionID: id, timeZoneID: Calendar.current.timeZone.identifier)
    }
    func loadQuestionReflection(_ id: String, interval: DateInterval, period: ReflectionPeriod) async throws -> ConversationReflectionFocus {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        var focus = try await store.reflectionForQuestion(questionID: id, start: interval.start, end: interval.end, timeZoneID: Calendar.current.timeZone.identifier)
        focus.period = period
        return focus
    }
    func beginReflectionDiscussion(_ focus: ConversationReflectionFocus) async -> Bool {
        guard let store, !discussionSaving, !discussionSending, !discussionExtracting, !dictationActive else { return false }
        discussionSaving = true; defer { discussionSaving = false }
        do {
            let id = try await store.beginConversationForReflection(focus)
            discussionSession = try await store.conversation(id: id); discussionRecordingID = nil
            discussionStatus = focus.isTopicOverview ? "已带上这个主题跨时间的完整材料，输入后直接发送。" : "已带上这个周期的完整原文、思想关联与实际结果，输入后直接发送。"
            await refreshDiscussion(); return true
        } catch { status = error.localizedDescription; return false }
    }
    func beginActionDiscussion(_ action: ActionRecord) async -> Bool {
        guard let store, !discussionSaving, !discussionSending, !discussionExtracting, !dictationActive else { return false }
        discussionSaving = true; defer { discussionSaving = false }
        do {
            let id = try await store.beginConversationForAction(actionID: action.id)
            discussionSession = try await store.conversation(id: id); discussionRecordingID = nil
            discussionStatus = "正在讨论：" + action.title + "。已带上来源、所属目标与实际反馈；发言后再发送。"
            await refreshDiscussion(); return true
        } catch { status = error.localizedDescription; return false }
    }
    func saveDiscussionText(_ text:String,allowCloud:Bool) async -> Bool {
        guard let store,let session=discussionSession,discussionWritable,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive else { return false }
        discussionSaving=true;defer { discussionSaving=false }
        do {
            let source=try await store.recordUserExpression(text)
            if allowCloud { _=try await store.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false) }
            _=try await store.appendConversationUserSource(conversationID:session.id,sourceID:source,expectedVersion:session.version)
            discussionStatus="本轮个人原文已保存并关联；尚未调用模型。"
            await refresh();return true
        } catch { discussionStatus="关联未完成，已保存原文可在资料库核对："+error.localizedDescription;await refresh();return false }
    }
    func startDiscussionDictation() async {
        guard discussionWritable,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive else { return }
        await startDictation()
        if dictationActive,let source=dictationSource { discussionRecordingID=source;discussionStatus="正在录制本轮口述；停止、本地转写与核对后再关联和发送。" }
    }
    func attachDiscussionRecording(allowCloud:Bool) async -> Bool {
        guard let store,let session=discussionSession,let id=discussionRecordingID,
              let record=discussionRecordings.first(where: { $0.id == id }),discussionWritable,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive,!dictationBusy else { return false }
        discussionSaving=true;defer { discussionSaving=false }
        do {
            if allowCloud,record.localOnly { _=try await store.setSourceLocalOnly(sourceID:id,expectedVersion:record.policyVersion,localOnly:false) }
            if allowCloud { try await ensureTranscriptReviewed(sourceID:id) }
            _=try await store.appendConversationUserSource(conversationID:session.id,sourceID:id,expectedVersion:session.version)
            discussionRecordingID=nil;discussionStatus="口述原文已关联；尚未发送，音频保留本机。"
            await refresh();return true
        } catch { discussionStatus=error.localizedDescription;await refresh();return false }
    }
    func sendDiscussion() async {
        guard let store,let session=discussionSession,let port=discussionModel,discussionCanSend,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive else { return }
        discussionSending=true;defer { discussionSending=false }
        discussionStatus="正在回复本轮文字；可结束讨论，未登记结果不会自动重发。"
        do {
            let input=try await store.prepareConversationInput(id:session.id,expectedVersion:session.version,destination:.cloud)
            _=try await store.performConversationReply(input,using:port)
            discussionStatus="AI回复已保存；分析不表示你已认可或决定行动。"
        } catch { discussionStatus=error.localizedDescription }
        await refreshDiscussion()
        queueTopicOrganization()
    }
    func refreshSourceDiscussions() async {
        guard let store,let source=selected else { sourceDiscussions=[];return }
        do {
            let linked=try await store.conversationsForSource(sourceID:source)
            if selected == source { sourceDiscussions=linked }
        } catch { if selected == source { sourceDiscussions=[];status=error.localizedDescription } }
    }
    func retainDiscussionCandidate(_ reply:DiscussionAttemptRecord,index:Int) async -> Bool {
        guard let store,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive else { return false }
        discussionSaving=true;defer { discussionSaving=false }
        do {
            let id=try await store.retainDiscussionAICandidate(attemptID:reply.id,partIndex:index)
            await refresh()
            if let claim=claims.first(where: { $0.id == id }) { selected=claim.references.first?.sourceID }
            discussionStatus="已本地保留为待核对 AI 候选；没有调用模型或创建任务。"
            return true
        } catch { discussionStatus=error.localizedDescription;return false }
    }
    func canUnderstandDiscussionTurn(_ turn:ConversationUserTurn)->Bool {
        modelConfigured && discussionSession?.validity == "current" && understandingWorker == nil && !discussionSending && !discussionSaving && !discussionExtracting && !dictationActive && records.contains(where: { $0.id == turn.sourceID && $0.transcriptVersionID == turn.transcriptVersionID && !$0.localOnly && $0.origin == "user" && $0.speaker == "user" })
    }
    func understandDiscussionTurn(_ turn:ConversationUserTurn) {
        guard let store,let session=discussionSession,let port=textModel,canUnderstandDiscussionTurn(turn) else { return }
        selected=turn.sourceID;understandingSource=turn.sourceID
        status="正在整理所选个人发言的观点与明确行动…"
        understandingWorker=Task {
            do {
                let result=try await store.continueConversationUserUnderstanding(conversationID:session.id,turnID:turn.id,using:port)
                await applyUnderstandingContinuation(result, sourceID: turn.sourceID)
            } catch { status=error.localizedDescription }
            await refresh();requestReminderRefresh();resumeKnowledgeReviews()
            understandingSource=nil;understandingWorker=nil
        }
    }
    func endDiscussion() async {
        guard let store,let session=discussionSession,session.state == "active",!discussionSaving,!dictationActive else { return }
        do { try await store.endConversation(id:session.id,expectedVersion:session.version);discussionStatus="讨论已结束，历史保留；不表示认可AI内容。" }
        catch { discussionStatus=error.localizedDescription }
        await refreshDiscussion()
    }
}

private extension ExpressionRelation {
    var displayName: String {
        switch self {
        case .continuation: "可能延续旧想法"
        case .qualification: "可能补充限定条件"
        case .possibleCorrection: "可能修正，尚未确认"
        case .sameQuestion: "可能讨论同一问题 · AI 关系提案"
        }
    }
}

extension CognitiveContentKind {
    var displayName: String {
        switch self {
        case .statement: "陈述候选"
        case .question: "问题候选"
        case .hypothesis: "猜想候选"
        case .reflection: "反思候选"
        case .unclassified: "内容类型未分类"
        }
    }
}

extension ControlCenter {
    private func ensureTranscriptReviewed(sourceID: String, retry: Bool = false) async throws {
        guard let store, let source = try await store.sources().first(where: { $0.id == sourceID }), source.needsTranscriptionReview else { return }
        guard !source.localOnly, let version = source.transcriptVersionID,
              let speech = speechPort as? LocalQwenSpeechPort, let configuration = textConfigurationFile,
              let script = Bundle.main.url(forResource: "organize_podcast", withExtension: "py") else {
            throw VoiceOSError("请配置 Qwen 与文本模型，并允许这份文字处理后再校正；音频仍仅本机")
        }
        let key = sourceID + ":" + version + ":" + String(source.policyVersion)
        if !retry, let failure = transcriptReviewFailures[key] { throw VoiceOSError(failure) }
        if let existing = transcriptReviewWorker {
            guard transcriptReviewSourceID == sourceID else { throw VoiceOSError("另一份完整转写正在校正，请稍后重试") }
            try await existing.value; return
        }
        transcriptReviewSourceID = sourceID
        transcriptReviewStatus = "AI 正在直接校正完整逐字稿，完成后自动采用校正稿。"
        let work = Task {
            let root = await store.root
            let folder = root.appendingPathComponent("整理/转写校正/" + sourceID + "/" + version + "-" + String(source.policyVersion))
            _ = try await store.writeOrganizingInput(sourceID: sourceID, to: folder, reviewTranscriptOnly: true)
            try await FullRecordingOrganizer.organize(folder: folder, script: script, python: speech.pythonExecutable,
                configuration: configuration, log: folder.appendingPathComponent("校正日志.txt"), reviewTranscriptOnly: true)
            try Task.checkCancellation()
            let policy = try await store.sourcePolicy(sourceID: sourceID)
            guard policy.version == source.policyVersion, !policy.localOnly else { throw VoiceOSError("校正期间文字许可已变化，未接纳旧结果") }
            _ = try await store.applyTranscriptQualityResult(sourceID: sourceID, expectedVersionID: version, from: folder)
        }
        transcriptReviewWorker = work
        defer { transcriptReviewWorker = nil; transcriptReviewSourceID = nil }
        do {
            try await work.value
            transcriptReviewFailures[key] = nil
            transcriptReviewStatus = "全文转写校正已完成；仍有疑点的地方保留待核对。"
            await refresh()
        } catch {
            transcriptReviewFailures[key] = error.localizedDescription
            transcriptReviewStatus = "转写校正尚未完成：" + error.localizedDescription
            throw error
        }
    }
    func reviewTranscription(sourceID: String) async {
        guard !fullRecordingBusy else { return }
        do { try await ensureTranscriptReviewed(sourceID: sourceID, retry: true); scheduleProcessing(); resumeKnowledgeReviews() }
        catch { transcriptReviewStatus = error.localizedDescription }
        await refresh()
    }
    func reviewKnowledge(sourceID: String, retry: Bool = false) async {
        guard let store, knowledgeReviewModel != nil else { return }
        do {
            try await ensureTranscriptReviewed(sourceID: sourceID)
            _ = try await store.enqueueKnowledgeReview(sourceID: sourceID, retry: retry)
            await refresh(); resumeKnowledgeReviews()
        } catch { knowledgeReviewStatus = error.localizedDescription }
    }
    private func resumeKnowledgeReviews() {
        guard initialized, let store, let port = knowledgeReviewModel, knowledgeReviewWorker == nil,
              !fullRecordingBusy, !dictationActive else { return }
        knowledgeReviewWorker = Task {
            knowledgeReviewBusy = true
            defer { knowledgeReviewBusy = false; knowledgeReviewWorker = nil }
            do {
                let sources = try await store.sources()
                let claims = try await store.latestCandidateClaimsBySource()
                for source in sources where source.origin == "user" && source.speaker == "user" &&
                    ["saved", "reference_only"].contains(source.state) && !source.localOnly &&
                    !source.needsTranscriptionReview && !(claims[source.id] ?? []).isEmpty {
                    do { _ = try await store.enqueueKnowledgeReview(sourceID: source.id) }
                    catch { knowledgeReviewStatus = "知识核查尚未排入：" + error.localizedDescription }
                }
                var attempted = Set<String>()
                while let next = try await store.pendingKnowledgeReviews().first(where: { !attempted.contains($0.id) }) {
                    try Task.checkCancellation(); attempted.insert(next.id)
                    knowledgeReviewStatus = "正在查证知识判断，核对来源与适用条件…"
                    await refresh()
                    let result = try await store.processKnowledgeReview(sourceID: next.sourceID, using: port)
                    knowledgeReviewStatus = result.state == "completed"
                        ? (result.issues.isEmpty ? "本次未提出需要纠偏的知识判断。" : "已保存 \(result.issues.count) 条知识核查建议与依据。")
                        : (result.error ?? "知识核查尚未完成，可手动重试。")
                    await refresh()
                }
            } catch { knowledgeReviewStatus = error.localizedDescription; await refresh() }
        }
    }
}
