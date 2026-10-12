import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import VoiceOSCore
import VoiceOSPlatform

@MainActor
final class ControlCenter: ObservableObject {
    @Published var records: [SourceRecord] = []
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
            if selected == id { selectedAssociationFeedback = items; selectedAssociationAttempts = attempts }
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
        query.isEmpty ? records : records.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.transcript?.localizedCaseInsensitiveContains(query) ?? false) }
    }
    @Published var status = "正在检查资料库…"
    @Published var importing = false
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
        speechSummary=selection.backend == .qwen ? "Qwen 本地转写 · 最多30秒定位范围" : "Apple 本地转写 · 明确选择的备选"
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
    func useAppleSpeech() {
        guard worker == nil,!dictationActive else { status="请等待当前处理结束后切换转写器";return }
        do {
            try installSpeechSelection(.init(backend:.apple),persist:true)
            status="已保存 Apple 本地转写备选；已有逐字稿保持原版本"
            scheduleProcessing()
        } catch { status="无法保存本地转写选择" }
    }
    @Published var attempts: [String: [ModelAttemptRecord]] = [:]
    @Published var processingIntents: [ExpressionProcessingIntentRecord] = []
    @Published var recordingRequests: [RecordingProcessingRequest] = []
    @Published var segmentationPlan: TranscriptSegmentationPlan?
    @Published var segmentationStatus = ""
    @Published var segmentedBatches: [SegmentedProcessingBatch] = []
    @Published var segmentedCognitiveCounts: [String:Int] = [:]
    @Published var segmentedAssociationStates: [String:String] = [:]
    private var segmentExtractionModel: ResponsesSegmentExtractionPort?
    private var segmentAggregationModel: ResponsesSegmentAggregationPort?
    private var textModel: ResponsesModelPort?
    private var englishModel: ResponsesEnglishPracticePort?
    @Published var englishSnapshot: EnglishPracticeSnapshot?
    @Published var englishAttempts: [EnglishFeedbackAttemptRecord] = []
    @Published var englishBusy = false
    @Published var englishStatus = "选择一份我的英文原话，再明确发送文本反馈。"
    private var understandingWorker: Task<Void, Never>?
    @Published var initialized = false
    @Published var player: AVPlayer?
    @Published var history: [TranscriptVersion] = []
    @Published var claims: [CandidateClaim] = []
    @Published var questionRecords: [QuestionRecord] = []
    @Published var questionRevisions: [String: [QuestionRevision]] = [:]
    @Published var savingQuestion = false
    @Published var claimHistory: [ClaimReviewVersion] = []
    @Published var reviewingClaim = false
    @Published var actionRecords: [ActionRecord] = []
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
    private lazy var reminderRefresh = ReminderRefreshCoordinator { [weak self] in await self?.automaticReminderRefresh() }

    @Published var remindersBusy = false
    @Published var choosingReminderCalendar = false
    private let reminders = NativeReminders()
    var reminderCalendarTitle: String { reminderCalendars.first { $0.id == reminderCalendarID }?.title ?? (reminderAccess?.enabled == true ? reminderAccess!.title : "未选择清单") }
    func reminderSourceAllowed(_ action: ActionRecord) -> Bool {
        guard let claim = claims.first(where: { $0.id == action.claimID }) else { return false }
        return !claim.references.isEmpty && claim.references.allSatisfy { ref in records.contains { $0.id == ref.sourceID && !$0.localOnly } }
    }
    private let rootOverride: URL?
    var libraryTitle: String { rootOverride == nil ? "VoiceOS" : "独立资料库 · " + rootOverride!.lastPathComponent }
    init(root: URL? = nil) { rootOverride = root }
    private var store: VoiceOSStore?
    @Published var dictationBusy = false
    @Published var dictationActive = false
    private var dictationSource: String?
    private var dictationInterrupted = false
    private let dictation = NativeDictation()
    private var dictationObservers: [NSObjectProtocol] = []
    func startDictation(processAfterTranscription: Bool = false) async {
        guard let store, !dictationBusy, !dictationActive else { return }
        let processingConfigurations: (ModelConfiguration, ModelConfiguration)?
        if processAfterTranscription {
            guard let cognition = textModel, let association = associationModel else { status = "请先配置文本模型，再选择录制并处理"; return }
            processingConfigurations = (cognition.configuration, association.configuration)
        } else { processingConfigurations = nil }
        dictationBusy = true; defer { dictationBusy = false }
        let duration: TimeInterval?
        if let raw = ProcessInfo.processInfo.environment["VOICEOS_TEST_CAPTURE_SECONDS"] {
            guard let seconds = Double(raw), seconds.isFinite, seconds > 0, seconds <= 60 else { status = "限时采集参数无效，未开启麦克风"; return }
            duration = seconds
        } else { duration = nil }
        guard await dictation.requestPermission() else { status = "麦克风未获授权，未开始录制；仍可导入文件"; return }
        do {
            let intent: RecordingIntent
            if let configs = processingConfigurations {
                intent = try await store.beginProcessingDictation(cognition: configs.0, association: configs.1, segmentExtraction:segmentExtractionModel?.configuration,segmentAggregation:segmentAggregationModel?.configuration)
            } else { intent = try await store.beginDictation() }
            dictationSource = intent.sourceID; dictationInterrupted = false
            try dictation.start(at:intent.stagingURL,maximumDuration:duration) { [weak self] success in Task { await self?.finishDictation(success:success) } }
            dictationActive = true; selected = intent.sourceID
            status = duration.map { "正在进行\($0)秒限时采集 · 到时自动停止 · 仅本地" } ?? "正在录制我的口述 · 仅本地；停止后才核对并封存原件"
            if processingConfigurations != nil { status = "正在录制并处理 · 请求已保存；封存及本地转写后处理文字，原始音频不上传" }
            await refresh()
        } catch {
            if let id = dictationSource { try? await store.interruptDictation(sourceID:id) }
            dictationSource = nil; dictationActive = false; status = error.localizedDescription; await refresh()
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
        scheduleProcessing()
    }
    func recoverDictation(_ record:SourceRecord) async {
        guard let store, !dictationBusy, !dictationActive else { return }
        dictationBusy = true; defer { dictationBusy = false }
        do { try await store.sealDictation(sourceID:record.id); status = "可解码片段已保存；它是中断片段，不代表完整表达"; await refresh(); scheduleProcessing() }
        catch { status = "片段尚不能完整解码，保留待核对"; await refresh() }
    }
    private var worker: Task<Void, Never>?
    func start() async {
        guard store == nil else { return }
        do {
            let root: URL
            if let override = rootOverride { root = override }
            else if let path = ProcessInfo.processInfo.environment["VOICEOS_DATA_DIR"] { root = URL(fileURLWithPath: path, isDirectory: true) }
            else { root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("VoiceOS", isDirectory: true) }
            let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
            self.store = store
            try await store.recover()
            initialized = true; status = "准备就绪 · 媒体只在本机处理"
            restoreSpeechSelection()
            if let path = ProcessInfo.processInfo.environment["VOICEOS_MODEL_CONFIG_FILE"] {
                configureTextModel(URL(fileURLWithPath: path))
            }
            await refresh()
            scheduleProcessing()
            installReminderRefresh()
            dictationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.stopDictation(interrupted:true) } })
            dictationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.stopDictation(interrupted:true) } })
            dictationObservers.append(NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.stopDictation(interrupted:true) } })
            requestReminderRefresh()
        } catch { status = error.localizedDescription }
    }
    func refresh() async {
        do {
            claims = try await store?.candidateClaims(includeFrozen: true) ?? []
            questionRecords = try await store?.questions() ?? []
            var questionHistory: [String: [QuestionRevision]] = [:]
            for question in questionRecords { questionHistory[question.id] = try await store?.questionHistory(questionID: question.id) ?? [] }
            questionRevisions = questionHistory
            claimOrigins = try await store?.discussionClaimOrigins() ?? []
            outcomeOrigins = try await store?.conversationOutcomeOrigins() ?? []
            actionRecords = try await store?.actions(includeHistory: true) ?? []
            reminderLinks = try await store?.reminderLinks() ?? []
            reminderAccess = try await store?.reminderAccess()
            reminderCalendarID = reminderAccess?.enabled == true ? reminderAccess!.calendarID : ""
            if reminderAccess?.enabled == false { reminderSyncStatus = "提醒事项连接已暂停 · 外部任务和历史保留" }
            records = try await store?.sources() ?? []
            if let plan = segmentationPlan, !records.contains(where: { $0.id == plan.source.sourceID && $0.transcriptVersionID == plan.source.transcriptVersionID && $0.policyVersion == plan.policyVersion && ["saved","reference_only"].contains($0.state) }) {
                segmentationPlan = nil; segmentationStatus = "原话或授权已变化，请重新查看分段"
            }
            if let result = retrievalResult, result.hits.contains(where: { hit in
                !records.contains { $0.id == hit.document.sourceID && $0.transcriptVersionID == hit.document.transcriptVersionID && $0.policyVersion == hit.document.policyVersion && ["saved","reference_only"].contains($0.state) }
            }) { cancelHistorySearch(); retrievalStatus = "历史资料已变化，请重新查找" }

            if let store {
                await relevance.validate(store:store)
                await refreshQuietFeedback()
                await refreshDiscussion()
                await refreshSourceDiscussions()
                var loaded: [String: [ModelAttemptRecord]] = [:]
                for record in records { loaded[record.id] = try await store.modelAttempts(sourceID: record.id) }
                attempts = loaded
                englishAttempts = try await store.englishFeedbackAttempts()
                processingIntents = try await store.processingIntents()
                recordingRequests = try await store.recordingProcessingRequests()
                segmentedBatches = try await store.segmentedProcessingBatches()
                var cognitiveCounts: [String:Int]=[:]
                for batch in segmentedBatches { if let ids=try await store.segmentedCognitiveClaimIDs(batchID:batch.id) { cognitiveCounts[batch.id]=ids.count } }
                segmentedCognitiveCounts=cognitiveCounts
                var associations: [String:String]=[:]
                for batch in segmentedBatches {
                    if let attempt=try await store.committedSegmentedAssociationAttempt(batchID:batch.id) { associations[batch.id]=attempt.validity == "current" ? attempt.state : "frozen" }
                }
                for request in recordingRequests {
                    if let batchID=request.segmentedBatchID,let state=request.segmentedAssociationState,associations[batchID] == nil { associations[batchID]=state }
                }
                segmentedAssociationStates=associations
            }
        }
        catch { status = error.localizedDescription }
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
            let suite=try LocalTextModel.loadSuite(from:file),port=suite.cognition
            discussionModel=suite.discussion;outcomeModel=suite.outcome
            englishModel=suite.english;associationModel=suite.association
            relevance.cancel();relevanceModel=suite.relevance
            segmentExtractionModel=suite.segmentExtraction;segmentAggregationModel=suite.segmentAggregation
            textModel = port; modelConfigured = true
            modelSummary = "gpt-6.1-sol · " + port.configuration.provider.replacingOccurrences(of: "responses:", with: "")
            status = "文本模型已就绪 · 只处理你选择并授权的文字"
            // A queued intent may have been restored before the user selected a
            // configuration. Wake the durable worker exactly once after the
            // new model identity is installed; scheduleProcessing() itself
            // remains the single-owner gate for concurrent work.
            scheduleProcessing()
        } catch { status = error.localizedDescription }
    }
    func prepareEnglishPractice(current: SourceRecord, priorIDs: [String]) async {
        guard let store, !englishBusy else { return }
        englishBusy = true
        defer { englishBusy = false }
        do {
            englishSnapshot = try await store.prepareEnglishPractice(currentSourceID: current.id, priorSourceIDs: priorIDs, destination: .cloud)
            englishStatus = "已准备 \(priorIDs.count) 份旧练习；发送前仍会再次核对文字版本和授权。"
        } catch { englishSnapshot = nil; englishStatus = error.localizedDescription }
    }
    func performEnglishPractice() async {
        guard let store, let port = englishModel, let snapshot = englishSnapshot, !englishBusy else { return }
        englishBusy = true; englishStatus = "正在发送选定文字；不上传原始音频，不自动重试。"
        do {
            let record = try await store.performEnglishFeedback(snapshot, using: port)
            englishStatus = record.state == "completed" ? "反馈已保存；建议仍只属于英文练习记录，不进入认知或行动。" : "反馈结果未知；不会自动重发。"
        } catch { englishStatus = error.localizedDescription }
        englishAttempts = (try? await store.englishFeedbackAttempts()) ?? englishAttempts
        englishBusy = false
    }
    func understand(_ record: SourceRecord) {
        guard let store, let port = textModel, understandingWorker == nil, !discussionExtracting, !record.localOnly,
              !(record.transcript ?? "").isEmpty else { return }
        understandingSource = record.id
        status = "正在理解所选文字 · 原始音视频仍在本机"
        // Application-owned: changing selection or closing the window does not resend/cancel.
        understandingWorker = Task {
            do {
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
            await refresh(); requestReminderRefresh()
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
                // Model reconfiguration alone cannot regenerate this expression.
                let batches=try await store.segmentedProcessingBatches()
                let prior=batches.first { $0.scope.plan.source.sourceID == record.id && $0.scope.plan.source.transcriptVersionID == record.transcriptVersionID && $0.scope.plan.policyVersion == record.policyVersion }
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
            await refresh();requestReminderRefresh()
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
        guard worker == nil else { return }
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
        // Refresh while the durable worker runs; closing the window does not cancel it.
        let refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { refreshTask.cancel() }
        if let selectedSpeech = speechPort {
            do { try await store.processTranscriptions(using: selectedSpeech) }
            catch { status = error.localizedDescription }
        }
        if let cognition = textModel, let association = associationModel {
            do { try await store.reconcileRecordingProcessingRequests(cognition: cognition.configuration, association: association.configuration,segmentExtraction:segmentExtractionModel?.configuration,segmentAggregation:segmentAggregationModel?.configuration) }
            catch { status = error.localizedDescription }
        }
        await processExpressionQueue(store)
        if let extraction=segmentExtractionModel,let aggregation=segmentAggregationModel {
            do {
                let requests=try await store.recordingProcessingRequests().filter { $0.state == "enqueued" && $0.segmentedBatchID != nil && $0.segmentedAssociationState == nil }
                for request in requests {
                    guard let batchID=request.segmentedBatchID,try await store.segmentedProcessingBatch(id:batchID).state == .queued else { continue }
                    await refresh() // Publish the durable batch before the first model await.
                    try await store.processRecordingSegmentPlan(requestID:request.id,extraction:extraction,aggregation:aggregation,retrieval:semanticRetrieval ?? retrieval,semantic:semanticRetrieval != nil,association:associationModel)
                    requestReminderRefresh()
                }
            } catch { status=error.localizedDescription }
        }
        await refresh()
    }
    private func processExpressionQueue(_ store: VoiceOSStore) async {
        guard let cognition = textModel else { return }
        let association = associationModel
        let local: any LocalRetrievalPort = semanticRetrieval ?? retrieval
        while let intent = try? await store.processingIntents().first(where: { $0.state == .queued }) {
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
                } else { status = "表达处理状态：\(result.state.rawValue)" }
                requestReminderRefresh()
            } catch { status = error.localizedDescription; break }
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
    func playSpan(_ record: SourceRecord, milliseconds: Int) async {
        do {
            guard let url = try await store?.playableURL(sourceID: record.id) else { return }
            player?.pause()
            let playback = AVPlayer(url: url)
            player = playback
            await playback.seek(to: CMTime(value: Int64(milliseconds), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
            playback.play()
        } catch { status = error.localizedDescription; await refresh() }
    }
    func historyFor(_ record: SourceRecord) async {
        do { history = try await store?.transcriptHistory(sourceID: record.id) ?? [] }
        catch { status = error.localizedDescription }
    }
    func correct(_ record: SourceRecord, text: String) async -> Bool {
        guard let store, let version = record.transcriptVersionID else { return false }
        do {
            _ = try await store.correctTranscript(sourceID: record.id, expectedVersionID: version, text: text)
            await refresh(); status = "更正已保存 · 原件和旧逐字稿保留"; return true
        } catch { status = error.localizedDescription; return false }
    }
    func changeTextPolicy(_ record: SourceRecord) async {
        guard let store, !changingPolicy else { return }
        changingPolicy = true
        defer { changingPolicy = false }
        do {
            _ = try await store.setSourceLocalOnly(sourceID: record.id, expectedVersion: record.policyVersion, localOnly: !record.localOnly)
            await refresh(); status = "文本处理权限已更新 · 原始音频仍仅本机"
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
        reminderObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.requestReminderRefresh() } })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.requestReminderRefresh() } }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.requestReminderRefresh() } }
    }
    private func requestReminderRefresh() {
        guard reminderAccess?.enabled == true else { return }
        reminderRefresh.request()
    }
    private func automaticReminderRefresh() async {
        guard let store, let access = reminderAccess, access.enabled else { return }
        if remindersBusy { return }
        guard reminders.isAuthorized else { reminderSyncStatus = "系统权限不可用 · 自动回读暂停"; return }
        remindersBusy = true
        defer { remindersBusy = false }
        do {
            try await store.refreshAuthorizedReminders(expectedAccessVersion: access.version, using: reminders)
            try Task.checkCancellation()
            if reminderAccess?.version == access.version { reminderSyncStatus = "已自动核对「\(access.title)」的关联任务" }
        } catch {
            if reminderAccess?.version == access.version { reminderSyncStatus = "自动回读未完成 · 保留历史，不自动重建" }
        }
        await refresh()
    }
    func sendReminder(_ action: ActionRecord) async {
        guard let store, let access = reminderAccess, access.enabled, !remindersBusy, !reminderCalendarID.isEmpty else { return }
        remindersBusy = true; defer { remindersBusy = false; requestReminderRefresh() }
        do {
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
    func saveFeedback(_ action: ActionRecord, kind: ActionFeedbackKind, text: String, commandID: String) async -> Bool {
        guard let store, !savingFeedback else { return false }
        savingFeedback = true; defer { savingFeedback = false }
        do {
            selected = try await store.recordActionFeedback(actionID: action.id, expectedVersion: action.version, kind: kind, text: text, commandID: commandID)
            await refresh(); status = "结果或反思已保存并关联原行动 · 未改变完成或证据状态"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func changeAction(_ action: ActionRecord, state: LocalActionState) async {
        guard let store, !savingAction else { return }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: state)
            status = "行动状态已保存 · 观点仍需独立验证"
        } catch { status = error.localizedDescription }
        await refresh()
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

struct EnglishInputPreview: View {
    let snapshot: EnglishPracticeSnapshot
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("待发送的英文练习文字").font(.title2)
            Text("以下是完整选定文字；关闭此窗口不会发送。发送时会再次核对版本与授权，原始音频不上传。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(snapshot.context.sources.enumerated()), id: \.element.sourceID) { index, source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(index == 0 ? "本次练习" : "旧练习 \(index)").font(.headline)
                            Text(source.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("返回", action: dismiss).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 640, height: 480)
    }
}
struct EnglishPracticeView: View {
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var currentID = ""
    @State private var priorIDs: Set<String> = []
    @State private var showingInput = false
    private var sources: [SourceRecord] {
        model.records.filter { $0.origin == "user" && $0.speaker == "user" && !($0.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ["saved", "reference_only"].contains($0.state) }
    }
    private var current: SourceRecord? { sources.first { $0.id == currentID } }
    private var priorCandidates: [SourceRecord] { sources.filter { $0.id != currentID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("英文表达反馈").font(.title2)
            Text("只发送选定的个人文字和出处；原始音频不会上传。反馈独立保存，不创建认知候选、行动或提醒事项。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("本次练习", selection: $currentID) {
                Text("选择一份我的英文原话").tag("")
                ForEach(sources) { source in
                    Text(String((source.transcript ?? source.name).prefix(90))).tag(source.id)
                }
            }
            .disabled(model.englishBusy)
            .onChange(of: currentID) { _, _ in priorIDs = priorIDs.filter { $0 != currentID }; model.englishSnapshot = nil; model.englishStatus = "选择已变化，请重新准备并核对文字。" }
            Text("可选旧练习（最多 2 份）").font(.headline)
            ScrollView {
                ForEach(priorCandidates) { source in
                    Toggle(isOn: Binding(get: { priorIDs.contains(source.id) }, set: { value in
                        if value { if priorIDs.count < 2 { priorIDs.insert(source.id) } }
                        else { priorIDs.remove(source.id) }
                        model.englishSnapshot = nil; model.englishStatus = "选择已变化，请重新准备并核对文字。"
                    })) {
                        VStack(alignment: .leading) { Text(source.name); Text(source.transcript ?? "").lineLimit(2).font(.caption).foregroundStyle(.secondary) }
                    }.disabled(model.englishBusy || (!priorIDs.contains(source.id) && priorIDs.count >= 2))
                }
            }.frame(maxHeight: model.englishAttempts.isEmpty ? 210 : 110)
            Text(model.englishStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("准备并核对文字") { if let current { Task { await model.prepareEnglishPractice(current: current, priorIDs: Array(priorIDs)); showingInput = model.englishSnapshot != nil } } }
                    .disabled(current == nil || model.englishBusy)
                Button(model.englishBusy ? "正在发送…" : "发送文本反馈") { Task { await model.performEnglishPractice() } }
                    .disabled(model.englishSnapshot == nil || model.englishBusy || !model.modelConfigured)
                if !model.modelConfigured { Button("配置文本模型…") { model.chooseTextModel() } }
                if model.englishSnapshot != nil { Button("查看待发送文字…") { showingInput = true } }
                Spacer(); Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
            }
            if !model.englishAttempts.isEmpty {
                Divider(); Text("反馈历史（\(model.englishAttempts.count)）").font(.headline)
                ScrollView {
                ForEach(model.englishAttempts) { attempt in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(attempt.state == "completed" ? "已保存" : attempt.state == "reserved" ? "等待结果" : "未完成 · 不自动重发") · \(attempt.createdAt)").font(.caption)
                        if let reason = attempt.error { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        Text("用量：\(attempt.inputTokens.map(String.init) ?? "未知") / \(attempt.outputTokens.map(String.init) ?? "未知") tokens · 费用未知").font(.caption).foregroundStyle(.secondary)
                        if attempt.validity == "frozen" { Text("历史反馈 · 依据或授权已变化，暂停当前使用").font(.caption).foregroundStyle(.orange) }
                        if let result = attempt.result {
                            ForEach(Array(result.suggestions.enumerated()), id: \.offset) { index, suggestion in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("建议 \(index + 1) · \(suggestion.kind.rawValue)").font(.callout.bold())
                                    Text("原句：\(suggestion.original.quote)").textSelection(.enabled)
                                    Text("建议：\(suggestion.suggestedText)").textSelection(.enabled)
                                    Text(suggestion.explanation).font(.caption).foregroundStyle(.secondary)
                                    if suggestion.possibleTranscriptIssue { Text("可能是转写问题，需人工核对").font(.caption).foregroundStyle(.orange) }
                                }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                            }
                            ForEach(Array(result.comparisons.enumerated()), id: \.offset) { _, comparison in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("本次：\(comparison.current.quote)").textSelection(.enabled)
                                    Text("旧练习：\(comparison.prior.quote)").textSelection(.enabled)
                                    Text("比较：\(comparison.explanation)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("文字建议不代表发音、熟练度或学习效果判断。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }.padding(24).frame(width: 700, height: 600)
        .sheet(isPresented: $showingInput) {
            if let snapshot = model.englishSnapshot { EnglishInputPreview(snapshot: snapshot) { showingInput = false } }
        }
        .task { if currentID.isEmpty { currentID = sources.first?.id ?? "" } }
    }
}
struct CenterView: View {
    @ObservedObject var model: ControlCenter
    @State private var editing: SourceRecord?
    @State private var showHistory = false
    @State private var showingSegmentation = false
    @State private var correctingClaim: CandidateClaim?
    @State private var showClaimHistory = false
    @State private var actionClaim: CandidateClaim?
    @State private var showActionHistory = false
    @State private var writingExpression = false
    @State private var feedbackAction: ActionRecord?
    @State private var showingRestore = false
    @State private var searching = false
    @State private var showingQuietFeedback = false
    @State private var showingDiscussion = false
    @State private var showingEnglishPractice = false
    @Environment(\.openWindow) private var openWindow
    private var activeProcessingCount: Int {
        model.processingIntents.filter { [.queued, .running].contains($0.state) }.count + model.recordingRequests.filter { $0.state == "waiting" }.count + model.segmentedBatches.filter { canStopSegmented($0) }.count
    }
    private func canStopSegmented(_ batch: SegmentedProcessingBatch) -> Bool {
        guard batch.state == .queued else { return false }
        return model.segmentedCognitiveCounts[batch.id] == nil || model.segmentedAssociationStates[batch.id] == nil || model.segmentedAssociationStates[batch.id] == "reserved" || model.segmentedAssociationStates[batch.id] == "inFlight"
    }
    private func segmentedState(_ batch: SegmentedProcessingBatch) -> String {
        if let count=model.segmentedCognitiveCounts[batch.id] {
            let association=model.segmentedAssociationStates[batch.id]
            let label: String
            switch association {
            case "completed": label="历史关联已保存"
            case "unknown": label="关联结果未知，不自动重发"
            case "frozen": label="历史关联冻结"
            case "noCandidates": label="本机未召回可用的授权历史候选"
            case "budgetExceeded": label="历史关联超过处理预算，未发送"
            case "paused": label="历史关联已暂停"
            case "localOnly": label="历史关联仅本机"
            case "modelUnavailable": label="历史关联模型未配置"
            case "cancelled": label="已停止后续关联"
            case "reserved", "inFlight": label="历史关联处理中"
            default: label="关联待核对"
            }
            return "认知记录已保存（\(count)条） · \(label) · \(batch.state == .frozen ? "迁移冻结" : batch.state == .blocked ? "来源已变化" : batch.state == .cancelled ? "已停止后续处理" : "保留原处理身份")"
        }
        switch batch.state {
        case .queued: return model.understandingSource == batch.scope.plan.source.sourceID ? "正在分段处理" : "等待继续分段处理"
        case .blocked: return "处理已阻塞"
        case .cancelled: return "已停止后续处理"
        case .frozen: return "迁移后冻结"
        case .unknown: return "请求结果未知，不自动重发"
        case .rejected: return "响应未接纳"
        }
    }
    private func recordingRequestState(_ state: String) -> String {
        switch state {
        case "waiting": return "等待封存和本地转写"
        case "enqueued": return "已移交处理队列"
        case "blocked": return "已阻断 · 需核对"
        case "cancelled": return "已取消"
        case "frozen": return "迁移后冻结"
        default: return "状态待核对"
        }
    }
    private func processingState(_ intent: ExpressionProcessingIntentRecord) -> String {
        switch intent.state {
        case .queued: return "等待处理"
        case .running: return intent.phase == .cognition ? "正在理解" : "正在关联"
        case .completed: return intent.associationAttemptID == nil ? "理解已完成 · 本次未发送关联判断" : "理解与关联判断已完成"
        case .unknown: return "结果未知 · 不自动重发"
        case .blocked: return "已阻塞 · 需核对"
        case .cancelled: return "已取消"
        case .frozen: return "冻结历史"
        case .rejected: return "未接纳"
        }
    }
    private func processingSourceName(_ intent: ExpressionProcessingIntentRecord) -> String {
        model.records.first(where: { $0.id == intent.sourceID })?.name ?? String(intent.sourceID.prefix(8))
    }
    private func chooseLibrary() {
        let panel = NSOpenPanel(); panel.title = "打开已有 VoiceOS 资料库"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard FileManager.default.fileExists(atPath:url.appendingPathComponent("voiceos.sqlite").path) else { model.status = "所选文件夹不是已有的 VoiceOS 资料库"; return }
            openWindow(id:"restored-library",value:url.path)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }
    var body: some View {
        NavigationSplitView {
            List(model.filtered, selection: $model.selected) { record in
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.name).lineLimit(2)
                    Text(label(record)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5).tag(record.id)
            }
            .navigationTitle("资料库")
            .searchable(text: $model.query, prompt: "搜索文件名或逐字稿")
            .overlay { if model.records.isEmpty { ContentUnavailableView("从一段表达开始", systemImage: "waveform", description: Text("开始口述或导入音视频，保存原件并生成本地逐字稿。")) } }
        } detail: {
            if let record = model.records.first(where: { $0.id == model.selected }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(record.name).font(.title2).textSelection(.enabled)
                        HStack { Label(label(record), systemImage: record.state == "saved" ? "checkmark.circle" : "exclamationmark.circle"); Spacer(); Text(record.kind == "user_text" ? "文字" : (record.kind == "video" ? "视频" : "音频")) }
                        Text("\(record.origin == "user" ? "我的直接表达" : "外部资料 · 说话人待核对") · \(record.localOnly ? "仅本机处理" : "文本可用于云端")").font(.callout).foregroundStyle(.secondary)
                        if record.kind == "audio", record.origin == "user", record.state == "interrupted" {
                            Text("这次口述未正常封存。可尝试保存能完整解码的片段，不能视为整次表达完整。").font(.callout)
                            Button("核对并保存录制片段") { Task { await model.recoverDictation(record) } }.disabled(model.dictationBusy || model.dictationActive)
                        }
                        if let actionID = record.feedbackActionID, let action = model.actionRecords.first(where: { $0.id == actionID }) {
                            Text("\(record.feedbackKind == "outcome" ? "结果记录" : "反思记录") · 关联行动第 \(record.feedbackActionVersion ?? 1) 版").font(.caption)
                            Button("查看关联行动") { Task { await model.actionHistory(action); showActionHistory = true } }
                        }
                        Button(record.localOnly ? "允许这份资料的文本用于云端" : "将这份资料限制为仅本地") { Task { await model.changeTextPolicy(record) } }.disabled(model.changingPolicy)
                        Text("此选项仅授权文本。理解个人表达后，会从已授权历史中寻找关联并进行一次文字判断；原始音视频仍仅本机。").font(.caption).foregroundStyle(.secondary)
                        if !model.sourceDiscussions.isEmpty {
                            Menu("查看关联讨论") {
                                ForEach(model.sourceDiscussions) { session in
                                    Button(String(session.id.prefix(8))+" · "+(session.state == "ended" ? "已结束" : "进行中")) {
                                        Task { await model.openDiscussion(session.id);showingDiscussion=true }
                                    }
                                }
                            }.disabled(model.discussionSending || model.discussionSaving || model.discussionExtracting || model.dictationActive)
                        }
                        Button("继续讨论",systemImage:"bubble.left.and.bubble.right") {
                            Task { if await model.beginDiscussion(record) { showingDiscussion = true } }
                        }.disabled((record.transcript ?? "").isEmpty || !["saved","reference_only"].contains(record.state) || model.discussionSaving || model.discussionSending || model.discussionExtracting || model.dictationActive)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button(model.understandingSource == record.id ? "正在理解…" : record.origin == "user" ? "理解并关联历史" : "理解这份文字", systemImage: "sparkles") { model.understand(record) }
                                    .disabled(!model.modelConfigured || record.localOnly || (record.transcript ?? "").isEmpty || (record.transcript ?? "").unicodeScalars.count > 4000 || model.understandingSource != nil || model.discussionExtracting)
                                if (record.transcript ?? "").unicodeScalars.count>4000,record.origin == "user",record.speaker == "user",["audio","user_text"].contains(record.kind) {
                                    Button("分段理解长表达",systemImage:"sparkles") { model.understandSegmented(record) }
                                        .disabled(!model.modelConfigured || record.localOnly || model.understandingSource != nil || model.discussionExtracting)
                                }
                                if model.understandingSource == record.id { ProgressView().controlSize(.small) }
                                Button("配置文本模型…") { model.chooseTextModel() }.disabled(model.understandingSource != nil || model.discussionExtracting)
                            }
                            HStack {
                                Menu("本地转写器") {
                                    Button("启用本地 Qwen…") { model.chooseLocalSpeech() }
                                    Button("使用 Apple 本地转写") { model.useAppleSpeech() }
                                }
                                Text(model.speechSummary).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(model.modelSummary).font(.caption).foregroundStyle(.secondary)
                            ForEach(model.segmentedBatches.filter { $0.scope.plan.source.sourceID == record.id }) { batch in
                                HStack {
                                    Text("\(segmentedState(batch)) · \(batch.scope.plan.segments.count) 段").font(.caption)
                                    if canStopSegmented(batch) { Button("停止后续处理") { model.cancelSegmented(batch.id) }.font(.caption) }
                                }
                                if let error=batch.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                            }

                            if record.localOnly { Text("允许这份资料的文本用于云端后，可以理解文字。").font(.caption).foregroundStyle(.secondary) }
                            if let attempts = model.attempts[record.id], !attempts.isEmpty {
                                DisclosureGroup("理解与候选整理记录（\(attempts.count)）") {
                                    ForEach(attempts) { attempt in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(attemptLabel(attempt)).font(.callout)
                                            if attempt.executionKind != "discussion_derivation" { Text("\(attempt.model) · \(attempt.provider.replacingOccurrences(of: "discussion_outcome:", with: "").replacingOccurrences(of: "responses:", with: ""))").font(.caption).foregroundStyle(.secondary) }
                                            if attempt.executionKind == "discussion_derivation" {
                                                Text("本地保留讨论 AI 段落 · 没有新增模型调用或费用").font(.caption).foregroundStyle(.secondary)
                                            } else { Text("输入 \(attempt.usage?["input_tokens"].map(String.init) ?? "未知") / 输出 \(attempt.usage?["output_tokens"].map(String.init) ?? "未知") tokens · 实际费用未知").font(.caption).foregroundStyle(.secondary) }
                                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        if let associationStatus = model.associationStatuses[record.id] { Text(associationStatus).font(.caption).foregroundStyle(.secondary) }
                        if !model.selectedAssociationAttempts.isEmpty && model.selectedAssociationAttempts.allSatisfy({ $0.currentSourceID == record.id }) {
                            DisclosureGroup("关联判断历史（\(model.selectedAssociationAttempts.count)）") {
                                ForEach(model.selectedAssociationAttempts) { attempt in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text((attempt.state == "completed" ? "关联已完成" : attempt.state == "reserved" ? "关联在途预留" : "关联结果未知 · 不自动重发") + (attempt.validity == "frozen" ? " · 冻结历史" : ""))
                                        Text("输入 \(attempt.usage?["input_tokens"].map(String.init) ?? "未知") / 输出 \(attempt.usage?["output_tokens"].map(String.init) ?? "未知") tokens · 实际费用未知").font(.caption).foregroundStyle(.secondary)
                                        if let error = attempt.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                        if !model.selectedAssociationFeedback.isEmpty && model.selectedAssociationFeedback.allSatisfy({ $0.currentSourceID == record.id }) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("与这次表达有关 · AI关系提案").font(.headline)
                                ForEach(model.selectedAssociationFeedback) { item in
                                    AssociationQuestionsView(item: item, model: model)
                                    Text(item.proposal.reason).textSelection(.enabled)
                                    Text("这次原话：" + item.proposal.current.quote).font(.callout).textSelection(.enabled)
                                    Text("历史原话：" + item.proposal.historicalQuote).font(.callout).textSelection(.enabled)
                                }
                                Button("核对关联与双方出处…") { model.quietAssociationSourceID = record.id; showingQuietFeedback = true }
                            }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text("\(record.kind == "user_text" ? "原始文字" : String(format: "%.1f 秒", record.duration ?? 0)) · \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        if record.state == "saved" { Button("打开保存的原件", systemImage: "play.circle") { Task { await model.play(record) } } }
                        Divider()
                        HStack {
                            Text(record.kind == "user_text" ? "表达原文" : "逐字稿").font(.headline)
                            Spacer()
                            if record.transcript != nil {
                                Button("更正文字") { editing = record }
                                Button("版本历史") { Task { await model.historyFor(record); showHistory = true } }
                                Button("查看原话分段") { Task { showingSegmentation = await model.previewSegmentation(record) } }
                            }
                        }
                        if let transcript = record.transcript {
                            Text("本次文字 \(transcript.unicodeScalars.count) 字符 · 单次处理上限 4000 字符").font(.caption).foregroundStyle(.secondary)
                            if transcript.unicodeScalars.count > 4000 { Text("超出单次处理范围；原话完整保留。本人录音可使用分段理解；完整文字与历史须满足关联预算。").font(.caption).foregroundStyle(.orange) }
                            if !model.segmentationStatus.isEmpty { Text(model.segmentationStatus).font(.caption).foregroundStyle(.orange) }
                            if transcript.isEmpty { Text("本次转写没有返回文字。可以播放原件核对；这不代表音轨没有人声。").foregroundStyle(.secondary) }
                            else if transcript.unicodeScalars.count > 4000 {
                                DisclosureGroup("完整逐字稿（\(transcript.unicodeScalars.count) 字符）") { Text(transcript).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                            } else { Text(transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            Text(record.kind == "user_text" ? "用户原文 · 无媒体时间定位" : record.transcriptionBackend?.hasPrefix("Qwen3-ASR") == true ? "Qwen 本地转写 · 最多30秒音频范围，非词级定位" : record.spans.contains(where: { $0.startMS != nil }) ? "Apple 本地转写 · 中文 · 识别时间定位待核对" : "中文逐字稿 · 时间定位未确认").font(.caption).foregroundStyle(.secondary)
                            if !record.spans.isEmpty {
                                DisclosureGroup("来源片段") {
                                    ForEach(record.spans) { span in
                                        VStack(alignment: .leading, spacing: 6) {
                                            if let start = span.startMS, let end = span.endMS, record.state == "saved" {
                                                Button("\(timeLabel(start))—\(timeLabel(end)) · 播放核对", systemImage: "play.circle") { Task { await model.playSpan(record, milliseconds: start) } }
                                            } else { Text("时间未确认").font(.caption).foregroundStyle(.secondary) }
                                            Text(quote(span, text: transcript)).textSelection(.enabled)
                                        }.padding(.vertical, 6)
                                    }
                                }
                            }
                            if let player = model.player { VideoPlayer(player: player).frame(height: record.kind == "video" ? 260 : 80) }
                        } else { Text(transcriptStatus(record)).foregroundStyle(.secondary) }
                        if let error = record.error { Text(error).foregroundStyle(.orange) }
                        let related = model.claims.filter { $0.references.contains(where: { $0.sourceID == record.id }) }
                        if !related.isEmpty {
                            Divider()
                            DisclosureGroup("认知候选与历史（\(related.count)）") {
                                ForEach(related) { claim in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(claim.contentKind?.displayName ?? "内容类型未分类").font(.caption).foregroundStyle(.secondary)
                                        Text(claim.statement).textSelection(.enabled)
                                        Text("\(claim.ownership == "ai_candidate" ? "AI 候选" : (claim.ownership == "external" ? "外部主张" : (claim.ownership == "user_tentative" ? "我的暂定表达" : "归属待核对"))) · 未验证 · \(claim.validity == "frozen" ? "依据或授权已变化，暂停使用" : (claim.reviewState == "rejected" ? "已停止当前使用" : "出处可回溯"))").font(.caption).foregroundStyle(.secondary)
                                        if let origin=model.claimOrigins.first(where: { $0.claimID == claim.id }) {
                                            Text(origin.referenceKind == "context_anchor" ? "来自讨论 AI 分析；下方原文只定位讨论触发点，不是结论证据。" : "来自讨论 AI 分析；模型引用保留，引用不代表结论已经验证。").font(.caption).foregroundStyle(.secondary)
                                            Button("查看原讨论 AI 段落") { Task { await model.openDiscussion(origin.conversationID);showingDiscussion=true } }
                                        }
                                        if let origin=model.outcomeOrigins.first(where: { $0.claimID == claim.id }) {
                                            Text(origin.referenceKind == "context_anchor" ? "来自讨论成果；下方只定位讨论触发点，不是 AI 结论证据。" : "来自讨论成果；个人原话和 AI 引文分开保留，仍未验证。").font(.caption).foregroundStyle(.secondary)
                                            Button("查看讨论成果与完整出处") { Task { await model.openDiscussion(origin.conversationID);showingDiscussion=true } }
                                        }
                                        Text(claim.reviewState == "endorsed" ? "明确认可 · 不等于已验证或已经理解" : (claim.reviewState == "rejected" ? "已拒绝 · 保留历史，不用于当前认知" : "尚未认可")).font(.caption).foregroundStyle(.secondary)
                                        HStack {
                                            Button("我认可这个观点") { Task { _ = await model.review(claim, action: .endorse) } }
                                                .disabled(model.reviewingClaim || claim.validity == "frozen" || claim.reviewState == "endorsed")
                                            Button("拒绝候选") { Task { _ = await model.review(claim, action: .reject) } }
                                                .disabled(model.reviewingClaim || claim.validity == "frozen" || claim.reviewState == "rejected")
                                            Button("更正认知") { correctingClaim = claim }.disabled(model.reviewingClaim || claim.validity == "frozen")
                                            Button("审阅历史") { Task { await model.reviewHistory(claim); showClaimHistory = true } }
                                        }
                                        if let question = model.questionRecords.first(where: { $0.seed.claimID == claim.id }) {
                                            QuestionStateView(question: question, model: model)
                                        } else if claim.contentKind == .question {
                                            Text("解决状态尚未登记").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Button("记录行动意图") { actionClaim = claim }.disabled(claim.validity == "frozen" || claim.reviewState == "rejected")
                                        ForEach(Array(claim.references.enumerated()), id: \.offset) { _, ref in
                                            if ref.sourceID == record.id, ref.transcriptVersionID == record.transcriptVersionID,
                                               let span = record.spans.first(where: { $0.id == ref.spanID }), let text = record.transcript {
                                                Text(((model.claimOrigins.first(where: { $0.claimID == claim.id })?.referenceKind == "context_anchor" || model.outcomeOrigins.first(where: { $0.claimID == claim.id })?.referenceKind == "context_anchor") ? "讨论触发原文（不证明 AI 猜想）：" : "引用原文：") + quote(span, text: text)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                            } else if ref.sourceID == record.id {
                                                Button("查看历史逐字稿依据") { Task { await model.historyFor(record); showHistory = true } }
                                            }
                                        }
                                    }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        let relatedActions = model.actionRecords.filter { action in related.contains { $0.id == action.claimID } }
                        if !relatedActions.isEmpty {
                            DisclosureGroup("行动与机会池（\(relatedActions.count)）") {
                                ForEach(relatedActions) { action in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(action.title).font(.headline)
                                        Text("\(action.kind == "task" ? "明确任务" : (action.kind == "opportunity" ? "探索意图" : "AI 建议")) · \(action.state == "completed" ? "已完成" : (action.state == "dismissed" ? "暂不跟进" : "待跟进")) · 第 \(action.version) 版").font(.caption)
                                        Text(action.validity == "frozen" ? "认知或授权已变化，暂停使用；历史保留" : "本地意图记录 · 外部同步状态见下方").font(.caption).foregroundStyle(.secondary)
                                        Text("认知依据：第 \(action.claimReviewVersion) 版").font(.caption).foregroundStyle(.secondary)
                                        if !action.note.isEmpty { Text(action.note) }
                                        HStack {
                                            if action.state == "open" {
                                                if action.kind == "task" { Button("标记任务完成") { Task { await model.changeAction(action, state: .completed) } } }
                                                Button("暂不跟进") { Task { await model.changeAction(action, state: .dismissed) } }
                                            } else { Button("重新跟进") { Task { await model.changeAction(action, state: .open) } } }
                                        }.disabled(model.savingAction || action.validity == "frozen")
                                        let link = model.reminderLinks.first { $0.actionID == action.id }
                                        if let link {
                                            Text("提醒事项：" + reminderLabel(link.state)).font(.caption).foregroundStyle(.secondary)
                                            if let title = link.remoteTitle { Text("外部标题：" + title).font(.caption) }
                                            if let at = link.lastCheckedAt ?? link.lastObservedAt { Text("最近核对：" + at).font(.caption).foregroundStyle(.secondary) }
                                            if let done = link.remoteCompleted { Text(done ? "外部回读：已完成" : "外部回读：未完成").font(.caption) }
                                            Button("回读提醒事项") { Task { await model.readReminder(link) } }.disabled(model.remindersBusy || model.reminderCalendarID != link.calendarID)
                                        } else if action.kind == "task" {
                                            Text("当前只同步任务标题，不设置期限或提醒时间。").font(.caption).foregroundStyle(.secondary)
                                            Text("目标清单：" + model.reminderCalendarTitle).font(.caption).foregroundStyle(.secondary)
                                            if !model.reminderSourceAllowed(action) { Text("依据包含仅本地资料，不可外发").font(.caption).foregroundStyle(.secondary) }
                                            Button("发送到所选提醒事项清单") { Task { await model.sendReminder(action) } }
                                                .disabled(model.remindersBusy || model.reminderCalendarID.isEmpty || action.validity == "frozen" || action.state != "open" || !model.reminderSourceAllowed(action))
                                        }
                                        Button("记录结果或反思") { feedbackAction = action }.disabled(model.savingFeedback)
                                        Button("行动历史") { Task { await model.actionHistory(action); showActionHistory = true } }
                                        Divider()
                                    }.padding(.vertical, 8)
                                }
                            }
                        }
                        if ["failed", "blocked"].contains(record.jobState ?? ""), record.state == "saved" {
                            Button("重试本地转写") { Task { await model.retry(record) } }
                        }
                        Spacer()
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { ContentUnavailableView("选择一份资料", systemImage: "doc.text.magnifyingglass", description: Text("原件和逐字稿保存在 VoiceOS 自己的资料库中。")) }
        }
        .toolbar {
            Menu {
                if model.processingIntents.isEmpty && model.recordingRequests.isEmpty && model.segmentedBatches.isEmpty {
                    Text("暂无表达处理记录")
                } else {
                    ForEach(model.recordingRequests) { request in
                        Text("录音处理 · \(recordingRequestState(request.state)) · \(model.records.first(where: { $0.id == request.sourceID })?.name ?? request.sourceID)")
                        if let error = request.error { Text(error) }
                        if request.state == "waiting" {
                            Text("等待封存和本地转写；未发起模型请求")
                            Button("取消文字处理（保留录音）") { Task { await model.cancelRecordingRequest(request) } }
                        }
                        Divider()
                    }
                    ForEach(model.segmentedBatches) { batch in
                        Text("\(segmentedState(batch)) · \(model.records.first(where: { $0.id == batch.scope.plan.source.sourceID })?.name ?? batch.scope.plan.source.sourceID)")
                        if let error=batch.error { Text(error) }
                        if canStopSegmented(batch) {
                            Button("停止这次分段处理") { model.cancelSegmented(batch.id) }
                        }
                        Divider()
                    }
                    ForEach(model.processingIntents) { intent in
                        Text("\(processingState(intent)) · \(processingSourceName(intent))")
                        if let error = intent.error, !error.isEmpty { Text(error) }
                        if [.queued, .running].contains(intent.state) {
                            Button("取消这次处理") { Task { await model.cancelProcessingIntent(intent) } }
                        }
                        Divider()
                    }
                }
            } label: {
                Label(activeProcessingCount == 0 ? "处理记录" : "处理 \(activeProcessingCount)", systemImage: activeProcessingCount == 0 ? "clock.arrow.circlepath" : "hourglass")
            }.disabled(!model.initialized)
            if model.dictationActive {
                Button("停止并保存口述",systemImage:"stop.circle.fill") { model.stopDictation() }.disabled(model.dictationBusy)
            } else {
                Menu("开始我的口述", systemImage: "mic") {
                    Button("录制并本地保存") { Task { await model.startDictation() } }
                    Button("录制并处理文字（原始音频不上传）") { Task { await model.startDictation(processAfterTranscription: true) } }.disabled(!model.modelConfigured)
                }.disabled(!model.initialized || model.dictationBusy)
            }
            Button("讨论记录",systemImage:"bubble.left.and.bubble.right") { Task { await model.refreshDiscussion(); showingDiscussion = true } }.disabled(!model.initialized)
            Button("静默回顾", systemImage:"text.bubble") { model.quietAssociationSourceID = nil; showingQuietFeedback = true }.disabled(!model.initialized)
            Button("查找历史文字", systemImage: "text.magnifyingglass") { searching = true }.disabled(!model.initialized)
            Button("英文表达反馈", systemImage: "character.book.closed") { showingEnglishPractice = true }.disabled(!model.initialized)
            Button("连接提醒事项…") { Task { await model.connectReminders() } }.disabled(!model.initialized || model.remindersBusy)
            if model.reminderAccess?.enabled == true { Button("暂停提醒事项连接") { Task { await model.disconnectReminders() } } }
            Button("记录我的表达", systemImage: "square.and.pencil") { writingExpression = true }.disabled(!model.initialized)
            Menu("导入文件", systemImage: "square.and.arrow.down") {
                Button("外部音频或视频…") { model.chooseFiles() }
                Button("仅含我声音的录音…") { model.chooseFiles(personalAudio: true) }
            }.disabled(!model.initialized || model.importing)
            Menu {
                Button("打开已有资料库…",action:chooseLibrary)
                Button("从迁移包恢复…") { showingRestore = true }
                Divider()
                Button("导出结构化资料…") { model.export(includeMedia: false) }
                Button("导出资料与原件…") { model.export(includeMedia: true) }
            } label: { Label("导出资料", systemImage: "square.and.arrow.up") }.disabled(!model.initialized || model.importing || model.dictationBusy || model.dictationActive)
        }
        .safeAreaInset(edge: .bottom) { HStack { Text(model.status).font(.caption).lineLimit(2); Text(model.reminderSyncStatus).font(.caption).foregroundStyle(.secondary); Spacer(); Text("开发预览 · 文本理解与来源核对").font(.caption).foregroundStyle(.secondary) }.padding(10).background(.bar) }
        .focusedSceneValue(\.voiceOSController, model)
        .navigationTitle(model.libraryTitle)
        .sheet(isPresented: $showingSegmentation) { TranscriptSegmentationView(model:model) { showingSegmentation = false } }
        .sheet(isPresented: $showingDiscussion) { DiscussionView(model:model) { showingDiscussion = false } }
        .sheet(isPresented: $searching) { HistorySearchView(model:model) { searching = false } }
        .sheet(isPresented: $showingQuietFeedback) { CognitiveFeedbackView(model:model) { showingQuietFeedback = false } }
        .sheet(isPresented: $showingEnglishPractice) { EnglishPracticeView(model: model) { showingEnglishPractice = false } }
        .sheet(isPresented: $showingRestore) { PackageRestoreView { showingRestore = false } }
        .sheet(item: $feedbackAction) { action in ActionFeedbackView(action: action, model: model) { feedbackAction = nil } }
        .sheet(isPresented: $writingExpression) { UserExpressionView(model: model) { writingExpression = false } }
        .sheet(item: $editing) { record in
            TranscriptCorrectionView(record: record, model: model) { editing = nil }
        }
        .sheet(isPresented: $showHistory) {
            VStack(alignment: .leading, spacing: 12) {
                Text("逐字稿版本历史").font(.title2)
                ScrollView {
                    ForEach(model.history) { version in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("第 \(version.number) 版 · \(version.reason == "original" ? "本地识别原稿" : "识别文字更正")\(version.isCurrent ? " · 当前" : " · 历史")").font(.headline)
                            Text(version.text.isEmpty ? "（空文字）" : version.text).textSelection(.enabled)
                            Divider()
                        }
                    }
                }
                HStack { Spacer(); Button("完成") { showHistory = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 660, height: 440)
        }
        .sheet(isPresented: $model.choosingReminderCalendar) {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择提醒事项清单").font(.title2)
                Text("系统权限覆盖全部提醒事项。VoiceOS 只在你明确选定的清单内处理任务。保存授权后会核对已有关联，并自动创建已提取、允许外发的普通明确任务。").foregroundStyle(.secondary)
                Picker("授权清单", selection: $model.proposedReminderCalendarID) {
                    Text("请选择清单").tag("")
                    ForEach(model.reminderCalendars) { calendar in Text(calendar.title).tag(calendar.id) }
                }
                Text("此清单持续授权保存在本机。重开、变化或唤醒后核对关联任务，并自动发送已提取、文本允许外发的普通明确任务，可随时停止；导出恢复不会携带此权限。").font(.caption)
                HStack { Button("取消") { model.choosingReminderCalendar = false }; Spacer(); Button("保存连接授权") { Task { await model.saveReminderConnection() } }.disabled(model.proposedReminderCalendarID.isEmpty) }
            }.padding(24).frame(width: 600)
        }
        .sheet(isPresented: $showActionHistory) {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.activeActionTitle).font(.title2)
                Text("行动状态与结果历史").font(.headline)
                Text("任务完成不等于观点已验证。").foregroundStyle(.secondary)
                ScrollView {
                    ForEach(model.actionVersions) { version in
                        VStack(alignment: .leading) {
                            Text("第 \(version.version) 版 · \(version.state == "completed" ? "已完成" : (version.state == "dismissed" ? "暂不跟进" : "待跟进"))")
                            if !version.note.isEmpty { Text(version.note) }
                            Text(version.actor == "external" ? "来自提醒事项回读" : (version.actor == "ai" ? "AI 行动候选" : "用户表达或明确操作")).font(.caption)
                            Text(version.createdAt).font(.caption).foregroundStyle(.secondary)
                            Divider()
                        }
                    }
                    ForEach(model.feedbackRecords) { feedback in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(feedback.kind == "outcome" ? "结果" : "反思") · 关联第 \(feedback.actionVersion) 版").font(.headline)
                            Text(feedback.text).textSelection(.enabled)
                            Text("用户记录 · 不自动验证观点").font(.caption).foregroundStyle(.secondary)
                            if feedback.sourceState == "quarantined" { Text("原件不可用，保留历史文本").font(.caption).foregroundStyle(.secondary) }
                            Button("查看反馈原文") { model.selected = feedback.sourceID; showActionHistory = false }
                            Divider()
                        }
                    }
                }
                Button("完成") { showActionHistory = false }
            }.padding(24).frame(width: 600, height: 380)
        }
        .sheet(item: $actionClaim) { claim in
            ActionCreationView(claim: claim, model: model) { actionClaim = nil }
        }
        .sheet(item: $correctingClaim) { claim in
            ClaimCorrectionView(claim: claim, model: model) { correctingClaim = nil }
        }
        .sheet(isPresented: $showClaimHistory) {
            VStack(alignment: .leading, spacing: 12) {
                Text("认知审阅历史").font(.title2)
                Text("认可不等于已验证；更正不代表真实观点变化。").foregroundStyle(.secondary)
                ScrollView {
                    ForEach(model.claimHistory) { revision in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("第 \(revision.version) 版 · \(reviewReason(revision.reason))").font(.headline)
                            Text(revision.statement).textSelection(.enabled)
                            Text("\(ownershipLabel(revision.ownership)) · \(reviewLabel(revision.decision))").font(.caption).foregroundStyle(.secondary)
                            if !revision.note.isEmpty { Text("原因：" + revision.note).font(.callout) }
                            Divider()
                        }
                    }
                }
                HStack { Spacer(); Button("完成") { showClaimHistory = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 660, height: 440)
        }
        .onChange(of: model.selected) { _, _ in model.player?.pause(); model.player = nil; model.sourceDiscussions=[];Task { await model.refreshSourceDiscussions(); await model.refreshAssociationSelection() } }
        .frame(minWidth: 840, minHeight: 540)
        .task { await model.start() }
    }
    private func reminderLabel(_ state: String) -> String {
        switch state {
        case "linked": return "唯一关联已回读"
        case "missing": return "未找到关联项，不自动重建"
        case "conflict": return "关联或状态冲突，保留双方内容"
        default: return "结果待核对，不自动重发"
        }
    }
    private func ownershipLabel(_ value: String) -> String {
        value == "user_tentative" ? "用户暂定表达" : value == "external" ? "外部主张" : (value == "ai_candidate" ? "AI 候选" : "归属待核对")
    }
    private func reviewLabel(_ value: String) -> String {
        value == "endorsed" ? "明确认可" : (value == "rejected" ? "已拒绝" : "待核对")
    }
    private func reviewReason(_ reason: String) -> String {
        switch reason {
        case "explicit_endorsement": return "明确认可"
        case "explicit_rejection": return "拒绝候选"
        case "correction": return "认知更正"
        case "discussion_ai_original": return "讨论 AI 段落原文 · 本地保留"
        default: return "模型原始结果"
        }
    }
    private func attemptLabel(_ attempt: ModelAttemptRecord) -> String {
        if attempt.executionKind == "discussion_derivation" { return attempt.state == "completed" ? "本地候选已保留" : "本地整理未完成 · 可回到讨论显式恢复" }
        switch attempt.state {
        case "completed": return attempt.contextState == "stale" ? "已完成 · 依据或授权已变化，保留历史" : "已完成 · 结果待核对"
        case "reserved": return "正在处理；重启后结果可能未知，不自动重发"
        case "unknown": return "结果未知 · 不自动重发"
        default: return "未接纳结果 · 不自动重发"
        }
    }
    private func quote(_ span: TranscriptSpan, text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard span.textStart >= 0, span.textEnd >= span.textStart, span.textEnd <= scalars.count else { return "片段定位无效，请检查资料" }
        return String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd]))
    }
    private func timeLabel(_ ms: Int) -> String { String(format: "%02d:%02d", ms / 60000, (ms / 1000) % 60) }
    private func label(_ record: SourceRecord) -> String {
        if record.state == "receiving", record.origin == "user", record.kind == "audio" { return "录制待封存" }
        switch record.state {
        case "saved": return "原件已保存"
        case "quarantined": return "原件需要检查"
        case "reference_only": return "原件未随包附带"
        case "interrupted": return "保存未完成"
        default: return "正在保存"
        }
    }
    private func transcriptStatus(_ record: SourceRecord) -> String {
        switch record.jobState {
        case "queued": return "等待本地转写"
        case "running": return "正在本地转写…"
        case "failed", "blocked": return "转写暂未完成"
        default: return "完整保存后开始转写"
        }
    }
}
private struct TranscriptCorrectionView: View {
    let record: SourceRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var text: String
    @State private var saving = false
    init(record: SourceRecord, model: ControlCenter, dismiss: @escaping () -> Void) {
        self.record = record; self.model = model; self.dismiss = dismiss
        _text = State(initialValue: record.transcript ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更正逐字稿").font(.title2)
            Text("仅更正识别文字；原件和旧逐字稿保留。新文字的时间定位会标为未确认。").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).border(.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("取消", action: dismiss).disabled(saving)
                Button("保存更正") {
                    saving = true
                    Task { let saved = await model.correct(record, text: text); saving = false; if saved { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(saving || text == record.transcript)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 660, height: 440)
    }
}
private struct ClaimCorrectionView: View {
    let claim: CandidateClaim
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var text: String
    @State private var ownership: String
    @State private var note = ""
    @State private var saving = false
    init(claim: CandidateClaim, model: ControlCenter, dismiss: @escaping () -> Void) {
        self.claim = claim; self.model = model; self.dismiss = dismiss
        _text = State(initialValue: claim.statement); _ownership = State(initialValue: claim.ownership)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更正认知").font(.title2)
            Text("修正 AI 的表述或归属；更正后重新待核对。原始模型结果、出处和历史保留。").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).border(.secondary.opacity(0.3))
            Picker("内容归属", selection: $ownership) {
                Text("用户暂定表达").tag("user_tentative"); Text("外部主张").tag("external"); Text("AI 候选").tag("ai_candidate"); Text("归属待核对").tag("unresolved")
            }
            TextField("更正原因（必填）", text: $note)
            HStack {
                Spacer(); Button("取消", action: dismiss).disabled(saving)
                Button("保存更正") {
                    saving = true
                    Task {
                        let saved = await model.review(claim, action: .correct, statement: text, ownership: CandidateOwnership(rawValue: ownership), note: note)
                        saving = false; if saved { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (text == claim.statement && ownership == claim.ownership))
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 660, height: 440)
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
        Window("VoiceOS", id: "control-center") { CenterView(model: model) }
        WindowGroup("独立资料库", id: "restored-library", for: String.self) { path in
            if let path = path.wrappedValue { RestoredLibraryView(path: path) }
        }
        .commands { CommandGroup(after: .newItem) { Button("导入音频或视频…") { focusedModel?.chooseFiles() }.keyboardShortcut("i").disabled(focusedModel?.initialized != true || focusedModel?.importing == true) } }
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

struct UserExpressionView: View {
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var text = ""
    @State private var saving = false
    @State private var commandID = UUID().uuidString
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("记录我的表达").font(.title2)
            Text("在这里写下你自己的想法或行动。引用他人时请明确说明；音视频导入仍按外部资料保存。").foregroundStyle(.secondary)
            TextEditor(text: $text).frame(minHeight: 200).border(.secondary.opacity(0.2)).disabled(saving)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            Text("原文先仅本地保存。允许文字用于云端并发起理解后，普通明确任务会按已保存的提醒事项清单授权自动发送；愿望与 AI 建议留在本地。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消", action: dismiss).disabled(saving)
                Spacer()
                Text("\(text.unicodeScalars.count)/4000").font(.caption)
                Button(saving ? "正在保存…" : "保存表达") {
                    saving = true
                    Task { if await model.saveExpression(text, commandID: commandID) { dismiss() }; saving = false }
                }.keyboardShortcut(.defaultAction).disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.unicodeScalars.count > 4000)
                Button(saving ? "正在排队…" : "保存并处理本次文字") {
                    saving = true
                    Task { if await model.saveAndProcessExpression(text, commandID: commandID) { dismiss() }; saving = false }
                }.disabled(saving || !model.modelConfigured || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.unicodeScalars.count > 4000)
            }
        }.padding(24).frame(width: 620)
    }
}

struct ActionFeedbackView: View {
    let action: ActionRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var kind = "outcome"
    @State private var text = ""
    @State private var saving = false
    @State private var errorText = ""
    @State private var commandID = UUID().uuidString
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("记录结果或反思").font(.title2)
            Text("关联：" + action.title + " · 第 \(action.version) 版").foregroundStyle(.secondary)
            Picker("类型", selection: $kind) { Text("实际结果").tag("outcome"); Text("我的反思").tag("reflection") }.pickerStyle(.segmented).disabled(saving)
            TextEditor(text: $text).frame(minHeight: 180).border(.secondary.opacity(0.2)).disabled(saving)
            Text("这是可选记录。原文先仅本地保存，保留与原行动的关联；不会自动改变任务状态、认可观点或标记已验证。").font(.caption).foregroundStyle(.secondary)
            if !errorText.isEmpty { Text(errorText).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("取消", action:dismiss).disabled(saving)
                Spacer(); Text("\(text.unicodeScalars.count)/4000").font(.caption)
                Button(saving ? "正在保存…" : "保存反馈") {
                    saving = true; errorText = ""
                    Task {
                        if await model.saveFeedback(action,kind:ActionFeedbackKind(rawValue:kind)!,text:text,commandID:commandID) { dismiss() }
                        else { errorText = model.status }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.unicodeScalars.count > 4000)
            }
        }.padding(24).frame(width:620)
    }
}

struct RestoredLibraryView: View {
    @StateObject private var model: ControlCenter
    init(path: String) { _model = StateObject(wrappedValue: ControlCenter(root: URL(fileURLWithPath:path,isDirectory:true))) }
    var body: some View { CenterView(model:model) }
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
                            Text(hit.document.name).font(.headline)
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
            guard discussionSession?.id == id else { return }
            discussionSession=session;discussionTurns=turns;discussionReplies=replies;discussionHistory=history;discussionDerivations=derivations;discussionOutcomes=outcomes
        } catch { discussionStatus=error.localizedDescription }
    }
    func openDiscussion(_ id:String) async {
        guard let store,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive else { return }
        do {
            discussionSession=try await store.conversation(id:id);discussionRecordingID=nil
            discussionStatus="已打开讨论历史；没有自动发送。"
            await refreshDiscussion()
        } catch { discussionStatus=error.localizedDescription }
    }
    func beginDiscussion(_ record:SourceRecord) async -> Bool {
        guard let store,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive else { return false }
        discussionSaving=true;defer { discussionSaving=false }
        do {
            let id=try await store.beginConversation(sourceIDs:[record.id])
            discussionSession=try await store.conversation(id:id);discussionRecordingID=nil
            discussionStatus="讨论已建立；发言保存后再明确发送。"
            await refreshDiscussion();return true
        } catch { status=error.localizedDescription;return false }
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
            await refresh();requestReminderRefresh()
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
