import SwiftUI
import AppKit
import Combine
import ServiceManagement
import AVKit
import UniformTypeIdentifiers
import UserNotifications
import VoiceOSCore
import VoiceOSPlatform

enum WorkspaceErrorRetry: Equatable {
    case localSpeech, textModel, export(includeMedia: Bool), reload
}

enum WorkspaceRoute: Equatable {
    case actions, search, settings, discussion, weeklyReview
}

enum WorkspacePageRequest: Equatable {
    case home, themes, materials, notes, actions, monitor, initiate, back, processing
}

/// Which workspace segments one refresh publishes. Interactive keeps the fast
/// core and secondary lists; full keeps the startup, activation, and timer path.
enum RefreshScope: Sendable {
    case interactive, full, assistant, knowledge
}

private struct RefreshPlan {
    var coreSecondary = false
    var full = false
    var assistant = false
    var knowledge = false
    init(_ scope: RefreshScope) {
        switch scope {
        case .interactive: coreSecondary = true
        case .full: full = true
        case .assistant: assistant = true
        case .knowledge: knowledge = true
        }
    }
    mutating func merge(_ other: RefreshPlan) {
        coreSecondary = coreSecondary || other.coreSecondary
        full = full || other.full
        assistant = assistant || other.assistant
        knowledge = knowledge || other.knowledge
    }
}

struct ImportFileResult: Identifiable {
    let id = UUID()
    let fileName: String
    let succeeded: Bool
    let message: String
    /// 成功保存后的材料 id，用于报告里直接打开这次导入的内容。
    var sourceID: String? = nil
}

struct ImportBatchReport: Identifiable {
    let id = UUID()
    let results: [ImportFileResult]
    var failureCount: Int { results.filter { !$0.succeeded }.count }
}

struct ImportBatchReportView: View {
    let report: ImportBatchReport
    let dismiss: () -> Void
    /// 成功行的「查看」：关闭报告并打开这次导入的材料。
    var open: (String) -> Void = { _ in }
    /// This sheet hangs off the scene root, outside WorkspaceView's palette
    /// injection, so resolve the stored theme directly.
    private var palette: WorkspacePalette {
        WorkspacePalette(theme: WorkspaceTheme(rawValue: UserDefaults.standard.string(forKey: "voiceos.workspaceTheme") ?? "") ?? .graphite)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入结果").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            Text(report.failureCount == 0
                ? "\(report.results.count) 份都已保存。"
                : "成功 \(report.results.count - report.failureCount) 份，失败 \(report.failureCount) 份。")
                .vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.results) { result in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.succeeded ? palette.success : palette.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.fileName).vosFont(WorkspaceText.body)
                                Text(result.message).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                            if let sourceID = result.sourceID {
                                Button("查看") { open(sourceID) }
                                    .buttonStyle(.plain)
                                    .vosFont(WorkspaceText.meta)
                                    .foregroundStyle(palette.accent)
                                    .help("打开这次导入的材料")
                            }
                        }
                    }
                }.padding(.vertical, 2)
            }.frame(maxHeight: 340)
            HStack {
                Spacer()
                Button("完成", action: dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(palette.canvas)
    }
}

@MainActor
final class ControlCenter: ObservableObject {
    private let spotlightIndexer = SpotlightIndexer()
    private var markdownMirror: MarkdownMirror?
    private var mirrorWorker: Task<Void, Never>?
    private var mirrorPending = false
    private var spotlightWorker: Task<Void, Never>?
    private var spotlightPending = false
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
                textCaptureDraftIssue = "旧草稿无法读取或另存，暂未覆盖；可以继续记录。"
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
        catch { textCaptureDraftIssue = "草稿暂未自动保存：" + error.localizedDescription + "；请先保存当前草稿。" }
    }
    @Published var records: [SourceRecord] = []
    @Published private(set) var recordsRevision = 0
    @Published private(set) var secondaryRevision = 0
    /// Advances when a note revision is saved, so the home timeline picks up a
    /// title or preview that changed while it stayed open.
    @Published private(set) var materialNotesRevision = 0
    func materialNoteDidSave() { materialNotesRevision &+= 1 }
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
            if let store {
                try await store.renameRecording(sourceID: record.id, title: title)
                actionUndoStack.record(.materialTitle(MaterialTitleChange(sourceID: record.id, title: record.displayTitle,
                    from: record.presentation?.manualTitle, to: title?.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
            await refresh(); queueRecordingTitles(); return true
        } catch { recordingTitleStatus = error.localizedDescription; return false }
    }
    @Published var recentClueOverrides: [RecentClueOverride] = []
    func renameRecentClue(_ clue: String, title: String?) async -> Bool {
        guard let store else { status = "资料库尚未打开，无法修改线索标题"; return false }
        do {
            try await store.setRecentClueTitle(clue: clue, title: title, commandID: "recent-clue-title:" + UUID().uuidString)
            await refresh(); return true
        } catch { status = error.localizedDescription; return false }
    }
    func mergeRecentClue(_ clue: String, into target: String) async -> Bool {
        guard let store else { status = "资料库尚未打开，无法合并线索"; return false }
        do {
            try await store.mergeRecentClue(clue, into: target, commandID: "recent-clue-merge:" + UUID().uuidString)
            await refresh(); return true
        } catch { status = error.localizedDescription; return false }
    }
    func setRecentClueHidden(_ clue: String, hidden: Bool) async -> Bool {
        guard let store else { status = "资料库尚未打开，无法隐藏线索"; return false }
        do {
            try await store.setRecentClueHidden(clue: clue, hidden: hidden, commandID: "recent-clue-hidden:" + UUID().uuidString)
            await refresh(); return true
        } catch { status = error.localizedDescription; return false }
    }
    @discardableResult
    func manageMaterial(_ record: SourceRecord, disposition: MaterialDisposition) async -> String? {
        guard let store else { return nil }
        do {
            let catalog=Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0) })
            let ids=record.recordingExpression(in:catalog)?.sourceIDs ?? [record.id]
            try await store.setMaterialDisposition(sourceIDs:ids,disposition:disposition)
            actionUndoStack.record(.materialDisposition(MaterialDispositionChange(sourceIDs:ids,title:record.displayTitle,from:record.disposition,to:disposition)))
            await refresh()
            switch disposition {
            case .archived: status="材料已归档，可在材料页的“已归档”中恢复；历史依据仍保留。"
            case .trashed: status="材料已移入回收站；原件与历史保留，系统提醒事项未修改。"
            case .active: status="材料已恢复；从回收站恢复的内容仅本机保存，旧理解不自动启用。"
            }
            return nil
        } catch {
            let message = error.localizedDescription
            status = message
            await refresh()
            return message
        }
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
    /// Sheet-scoped views cannot navigate the workspace themselves; they ask
    /// for a source and the workspace consumes the request from its own state.
    @Published var pendingWorkspaceSourceID: String?
    func requestWorkspaceSource(_ id: String) { pendingWorkspaceSourceID = id }
    /// 从独立面板（速记）回来时用：窗口可能已关闭，先唤起主窗口再打开这份材料。
    func revealSource(_ id: String) {
        (NSApp.delegate as? ApplicationDelegate)?.openMainWindow()
        requestWorkspaceSource(id)
    }
    @Published var pendingWorkspaceRoute: WorkspaceRoute?
    @Published var pendingWorkspacePageRequest: WorkspacePageRequest?
    @Published var pendingWorkspaceTaskID: String?
    // 消息监测：页面与处理页共用同一份报告、来源与推送状态。
    @Published var monitorSources: [MonitorSource] = []
    @Published var monitorReports: [MonitorReport] = []
    @Published var monitorItemsByReport: [String: [MonitorItem]] = [:]
    @Published var monitorEvidence: [String: [MonitorItemEvidence]] = [:]
    @Published var monitorSourceStats: [String: MonitorSourceStat] = [:]
    @Published var monitorSettings = MonitorSettingsBootstrap.loaded.settings
    @Published private(set) var monitorSettingsDecodeFailed = MonitorSettingsBootstrap.loaded.decodeFailed
    @Published private(set) var monitorSettingsSaveFailed = false
    @Published private(set) var monitorQQSettingsDecodeFailed = false
    /// One-shot request from the settings page; the monitor view consumes it.
    @Published var monitorSettingsRequested = false
    @Published var monitorChecking = false
    @Published var monitorPhase = ""
    @Published var monitorStatus = ""
    /// Set by WorkspaceMonitorView; refreshes skip the monitor store reads
    /// while the page is closed because opening it reloads anyway.
    var monitorPageVisible = false
    @Published var monitorQQConversations: [QQMonitorConversation] = []
    @Published var monitorQQConversationStatus = ""
    @Published var monitorQQDiagnostics: [QQMonitorDiagnosisItem] = []
    @Published var monitorQQDiagnosisStatus = ""
    @Published var monitorPushStatus = ""
    @Published var monitorTestPushStatus = ""
    @Published var monitorAttentionRevision = 0
    var monitorWorker: Task<Void, Never>?
    var monitorReloadWorker: Task<Void, Never>?
    var monitorReloadPending = false
    var monitorReloadForceItems = false
    var monitorObservers: [NSObjectProtocol] = []
    var monitorTimer: Timer?
    var monitorAnalysisModel: ResponsesNotificationAnalysisPort?
    func recordMonitorSettingsSave(success: Bool) {
        monitorSettingsSaveFailed = !success
        if success { monitorSettingsDecodeFailed = false }
    }
    func recordMonitorQQSettingsLoad(decodeFailed: Bool) {
        monitorQQSettingsDecodeFailed = decodeFailed
    }
    func clearMonitorQQSettingsDecodeFailure() {
        monitorQQSettingsDecodeFailed = false
    }
    @Published var recentCompletions: [WorkspaceCompletionRecord] = []
    @Published var noticeAuthorization: LocalNoticeAuthorization = .notRequested
    /// Bumped when a failed processing item is dismissed, so the sidebar dot
    /// and the processing page re-read the persisted dismissal list.
    @Published var processingDismissalRevision = 0
    func ignoreProcessingFailure(_ id: String) {
        ProcessingDismissals.ignore(id)
        processingDismissalRevision += 1
    }
    @Published var showingCaptureComposer = false
    @Published var onboardingRequested = false
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
            quietStatus = "关联属于 AI 提案；问题状态来自单独登记的历史，不因关联判断而改变，无需回应。"
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
            case .completed: associationStatuses[id] = result.attempt?.proposals.isEmpty == true ? "关联判断已完成，没有直接相关提案。" : "历史关联已保存；关系属于 AI 提案，未改变观点或行动。"
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
    @Published var backupStatusText = ""
    @Published var lastBackupAt: Date?
    @Published var checkingLibraryHealth = false
    @Published var libraryHealthText = ""
    @Published private(set) var libraryHealthProblem = false
    @Published var storageUsage: LibraryStorageUsage?
    @Published var storageScanBusy = false
    @Published var backupCleanupStatus = ""
    @Published var backupPruning = false
    @Published var backupRunning = false
    @Published var localSpeechDeleteStatus = ""
    @Published var localSpeechDeleting = false
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginStatus = "未开启"
    @Published var workspaceLastError: String?
    @Published var workspaceLastErrorRetry: WorkspaceErrorRetry?
    @Published var exporting = false
    @Published var importing = false
    @Published var importReport: ImportBatchReport?
    private var recentFileImportResults: [ImportFileResult] = []
    @Published var fullRecordingInput: FullRecordingInput?
    @Published var fullRecordingBusy = false
    @Published var fullRecordingStatus = ""
    @Published var fullRecordingDetail = ""
    @Published var fullRecordingCount: Int?
    @Published var fullRecordingOutput: URL?
    /// 最近一次完整整理产出的材料；完成面板据此提供「打开这篇笔记」。
    @Published var fullRecordingCompletedSourceID: String?
    @Published var fullRecordingImportIssue: String?
    private var fullRecordingWorker: Task<Void, Never>?
    private var fullRecordingLog: URL?
    private(set) var fullRecordingSourceID: String?
    @Published private(set) var organizingSourceID: String?
    private var backgroundOrganizationQueue: [String] = []
    private var backgroundOrganizationWorker: Task<Void, Never>?
    let recordingInbox: RecordingInbox
    private var folderWatch: FolderWatch?
    var folderWatchActive: Bool { folderWatch?.isWatching == true }
    private var textConfigurationFile: URL?
    @Published var changingPolicy = false
    @Published var understandingSource: String?
    @Published var modelConfigured = false
    @Published var modelSummary = "尚未配置文本模型"
    @Published var speechSummary = "Qwen 本地转写 · 尚未配置"
    private var speechPort: (any SpeechPort)?
    var speechConfigured: Bool { speechPort is LocalQwenSpeechPort }
    /// 文本模型是否可用：内部配置与导入的配置文件都算就绪；文件不再是前置条件。
    var textModelConfigured: Bool { modelConfigured }
    var modelConfigurationName: String? { textConfigurationFile?.lastPathComponent }
    var modelConfigurationPath: String? { textConfigurationFile?.path }
    /// 应用内配置（或导入的配置文件）转成 Python 子进程环境。地址、型号与核对强度
    /// 都跟随设置页；密钥只存在于内存与子进程环境，不写盘、不打印。
    var textModelOrganizerEnvironment: [String: String]? {
        // 只有端口策略已接受的配置才会交给 Python：避免设置页里一个尚未通过
        // 校验的地址把密钥带进整理脚本。
        guard modelConfigured else { return nil }
        if let config = TextModelConfiguration.load(), let key = TextModelKeychain.apiKey(), !key.isEmpty,
           let url = URL(string: config.baseURL), url.scheme != nil {
            return ["VOICEOS_TEXT_BASE_URL": url.absoluteString, "VOICEOS_TEXT_API_KEY": key,
                    "VOICEOS_TEXT_MODEL": config.model, "VOICEOS_TEXT_EFFORT": config.reviewEffort]
        }
        if let file = textConfigurationFile, let settings = try? LocalTextModel.inspect(file) {
            return ["VOICEOS_TEXT_BASE_URL": settings.address.absoluteString, "VOICEOS_TEXT_API_KEY": settings.key,
                    "VOICEOS_TEXT_MODEL": settings.model, "VOICEOS_TEXT_EFFORT": settings.reviewEffort]
        }
        return nil
    }
    var recordingModelIssue: String? {
        if !speechConfigured { return "尚未配置本地 Qwen 转写模型。" }
        if !textModelConfigured { return "尚未配置文本模型。" }
        if Bundle.main.url(forResource: "organize_podcast", withExtension: "py") == nil { return "应用缺少完整整理脚本，请更新应用。" }
        return nil
    }
    var speechModelBusy: Bool { dictationActive || dictationBusy || fullRecordingBusy || importing || understandingSource != nil || worker != nil }
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
        } catch {
            let message="无法启用本地 Qwen，请核对配置与模型；保留当前转写器"
            status=message
            reportWorkspaceError(message,retry:.localSpeech)
        }
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
    @Published private(set) var pausedActionBatch: PausedActionBatchRun?
    private var pausedActionBatchWorker: Task<Void, Never>?
    private var sourceReidentifyWorker: Task<Void, Never>?
    private var segmentExtractionModel: ResponsesSegmentExtractionPort?
    private var segmentAggregationModel: ResponsesSegmentAggregationPort?
    private var textModel: ResponsesModelPort?
    private var englishModel: ResponsesEnglishPracticePort?
    @Published var englishSnapshot: EnglishPracticeSnapshot?
    @Published var englishAttempts: [EnglishFeedbackAttemptRecord] = []
    @Published var englishBusy = false
    @Published var englishStatus = "选择一份我的英文原话，再明确发送文本反馈。"
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
    /// Carries review failures from the previous session into the in-memory
    /// dictionary so the processing page shows them after a restart.
    private func restoreTranscriptReviewFailures() async {
        guard let store, let stored = try? await store.storedTranscriptionReviewFailures() else { return }
        for (key, reason) in stored where transcriptReviewFailures[key] == nil {
            transcriptReviewFailures[key] = reason
        }
    }
    private var transcriptReviewWorker: Task<Void, Error>?
    private var transcriptReviewFailures: [String: String] = [:]
    private var assistantWorker: Task<Void, Never>?
    @Published var assistantExecutions: [AssistantExecutionRecord] = []
    @Published var assistantAssessmentIssues: [AssistantAssessmentIssue] = []
    @Published var assistantBusy = false
    @Published var assistantStatus = ""
    @Published var taskInitiations: [TaskInitiationRecord] = []
    @Published var initiationStatus = ""
    @Published var initiationBusy = false
    @Published var initiationText = ""
    @Published var initiationSourceID: String?
    private var initiationModel: ResponsesTaskInitiationPort?
    func generateTaskInitiation(text: String, sourceID: String?, mode: TaskInitiationMode, allowCloud: Bool) async -> Bool {
        guard !initiationBusy else { return false }
        guard let store else { initiationStatus = "资料库尚未打开"; return false }
        guard let port = initiationModel else { initiationStatus = "尚未配置文本模型；请先在设置中连接模型"; return false }
        guard allowCloud else { initiationStatus = "请先允许这段原话用于云端，再继续"; return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { initiationStatus = "先写下或从材料带入一段原话"; return false }
        guard trimmed.unicodeScalars.count <= 4000 else { initiationStatus = "原话超过 4000 字；请拆分或精简后再生成"; return false }
        initiationBusy = true
        defer { initiationBusy = false }
        do {
            let chosenID = try await initiationSource(for: trimmed, preferred: sourceID, store: store)
            if let source = try await store.sources().first(where: { $0.id == chosenID }), source.localOnly {
                _ = try await store.setSourceLocalOnly(sourceID: chosenID, expectedVersion: source.policyVersion, localOnly: false)
            }
            let input = try await store.taskInitiationInput(sourceID: chosenID, mode: mode)
            initiationStatus = "正在判断是直接回答，还是整理成启动材料…"
            let proposal = try await port.initiate(input)
            guard !TaskInitiationComposer.needsClarifyFallback(proposal) else {
                initiationStatus = TaskInitiationComposer.clarifyFallbackMessage
                return false
            }
            _ = try await store.recordTaskInitiation(input, proposal: proposal)
            initiationText = ""; initiationSourceID = nil
            await refresh()
            initiationStatus = proposal.route == .captureOnly ? "已按原意仅记录；没有生成提示词、教程或任务。"
                : proposal.route == .clarify ? "需要先回答一个关键问题，才能继续。"
                : proposal.route == .answer ? "已直接回答；可以复制回答，或归档保存。"
                : "启动材料已生成；可以预览、编辑或复制。"
            return true
        } catch {
            initiationStatus = "启动材料未生成：" + error.localizedDescription
            return false
        }
    }
    private func initiationSource(for text: String, preferred: String?, store: VoiceOSStore) async throws -> String {
        if let preferred, let source = try await store.sources().first(where: { $0.id == preferred }),
           source.origin == "user", source.speaker == "user", ["saved", "reference_only"].contains(source.state),
           source.transcript == text {
            return source.id
        }
        return try await store.recordUserExpression(text)
    }
    func directAnswerTaskInitiation(_ record: TaskInitiationRecord, allowCloud: Bool) async -> String? {
        guard !initiationBusy else { return nil }
        guard allowCloud else { initiationStatus = "请先允许这段原话用于云端，再直接回答"; return nil }
        guard let port = initiationModel else { initiationStatus = "尚未配置文本模型；请先在设置中连接模型"; return nil }
        initiationBusy = true
        defer { initiationBusy = false }
        initiationStatus = "正在直接回答…"
        do {
            let reply = try await port.answer(record.input)
            initiationStatus = "已直接回答；可以复制这段回答。"
            return reply
        } catch {
            initiationStatus = "直接回答未完成：" + error.localizedDescription
            return nil
        }
    }
    func answerTaskInitiation(_ record: TaskInitiationRecord, answer: String) async -> Bool {
        guard !initiationBusy else { return false }
        guard let store else { return false }
        guard let port = initiationModel else { initiationStatus = "尚未配置文本模型；请先在设置中连接模型"; return false }
        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { initiationStatus = "请先填写澄清回答"; return false }
        initiationBusy = true
        defer { initiationBusy = false }
        do {
            let input = try await store.taskInitiationInput(sourceID: record.sourceID, mode: .direct,
                                                            preferredRoute: record.input.preferredRoute, answer: clean)
            initiationStatus = "正在按你的回答整理…"
            let proposal = try await port.initiate(input)
            _ = try await store.recordTaskInitiationClarification(id: record.id, answer: clean, proposal: proposal)
            await refresh()
            initiationStatus = "已按你的回答生成启动材料。"
            return true
        } catch {
            initiationStatus = "按回答生成未完成：" + error.localizedDescription
            return false
        }
    }
    func skipTaskInitiationClarification(_ record: TaskInitiationRecord) async -> Bool {
        guard !initiationBusy else { return false }
        guard let store else { return false }
        initiationBusy = true
        do {
            try await store.discardTaskInitiation(id: record.id)
            await refresh()
        } catch {
            initiationBusy = false
            initiationStatus = error.localizedDescription
            return false
        }
        initiationBusy = false
        return await generateTaskInitiation(text: record.input.text, sourceID: record.sourceID, mode: .direct, allowCloud: true)
    }
    func switchTaskInitiationRoute(_ record: TaskInitiationRecord, to route: TaskInitiationRoute) async -> Bool {
        guard !initiationBusy else { return false }
        guard record.state == "draft" else { initiationStatus = "只有草稿可以更换路线"; return false }
        guard route != .clarify else { initiationStatus = "直接生成时不能改用澄清路线"; return false }
        guard route != record.route else { return true }
        guard let store else { return false }
        initiationBusy = true
        defer { initiationBusy = false }
        do {
            if route == .captureOnly {
                let proposal = TaskInitiationProposal(isTaskInitiation: true, route: .captureOnly,
                                                      title: record.proposal.title, reason: "用户选择仅记录")
                _ = try await store.replaceTaskInitiation(id: record.id, preferredRoute: .captureOnly, proposal: proposal)
            } else {
                guard let port = initiationModel else { initiationStatus = "尚未配置文本模型；请先在设置中连接模型"; return false }
                let input = try await store.taskInitiationInput(sourceID: record.sourceID, mode: .direct,
                                                                preferredRoute: route, answer: record.input.answer)
                initiationStatus = "正在按新路线重新整理…"
                let proposal = try await port.initiate(input)
                _ = try await store.replaceTaskInitiation(id: record.id, preferredRoute: route, proposal: proposal)
            }
            await refresh()
            initiationStatus = "已换到「" + taskInitiationRouteLabel(route) + "」路线。"
            return true
        } catch {
            initiationStatus = "更换路线未完成：" + error.localizedDescription
            return false
        }
    }
    func setTaskInitiationPreference(_ record: TaskInitiationRecord, preference: TaskInitiationPreference) async -> Bool {
        guard !initiationBusy else { return false }
        guard let store else { return false }
        initiationBusy = true
        defer { initiationBusy = false }
        do {
            _ = try await store.setTaskInitiationPreference(id: record.id, preference: preference)
            await refresh()
            initiationStatus = preference == .quickDelivery ? "执行偏好：优先快速交付。" : "执行偏好：边做边学，交付时解释关键实现。"
            return true
        } catch {
            initiationStatus = error.localizedDescription
            return false
        }
    }
    func confirmTaskInitiation(_ record: TaskInitiationRecord, artifact: String) async -> Bool {
        guard !initiationBusy else { return false }
        guard let store else { return false }
        initiationBusy = true
        defer { initiationBusy = false }
        do {
            _ = try await store.confirmTaskInitiation(id: record.id, artifact: artifact)
            await refresh()
            initiationStatus = record.route == .answer
                ? "已归档保存这条回答；可在启动记录里打开「查看归档」。"
                : "已确认这份启动材料；尚未执行，也没有创建任务或提醒。"
            return true
        } catch {
            initiationStatus = error.localizedDescription
            return false
        }
    }
    func markTaskInitiationCopied(_ record: TaskInitiationRecord, artifact: String) async -> Bool {
        guard !initiationBusy else { return false }
        guard let store else { return false }
        initiationBusy = true
        defer { initiationBusy = false }
        do {
            _ = try await store.markTaskInitiationCopied(id: record.id, artifact: artifact)
            await refresh()
            initiationStatus = "已复制；复制不代表任务已执行或完成。"
            return true
        } catch {
            initiationStatus = error.localizedDescription
            return false
        }
    }
    func discardTaskInitiation(_ record: TaskInitiationRecord) async -> Bool {
        guard !initiationBusy else { return false }
        guard let store else { return false }
        initiationBusy = true
        defer { initiationBusy = false }
        do {
            try await store.discardTaskInitiation(id: record.id)
            await refresh()
            initiationStatus = "已删除这条启动记录；原话仍保留在材料中。"
            return true
        } catch {
            initiationStatus = error.localizedDescription
            return false
        }
    }
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
    @Published var workspaceLoaded = false
    private var lastFullReloadGeneration: Int64?
    private var lastBackgroundResumeGeneration: Int64?
    @Published var textSize: AppTextSize = AppTextSize(rawValue: UserDefaults.standard.string(forKey: "voiceos.textSize.v1") ?? "") ?? .standard
    func setTextSize(_ value: AppTextSize) {
        textSize = value
        UserDefaults.standard.set(value.rawValue, forKey: "voiceos.textSize.v1")
    }
    @Published var startupIssue = ""
    @Published var player: AVPlayer?
    private var playbackBoundary: Any?
    private var playbackGeneration = 0
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
    @Published var actionClarifications: [String: String] = [:]
    @Published var stalledOutcomes: [ActionRecord] = []
    @Published var homeSnapshot = RecentContentHomeSnapshot(days: [], digests: [:])
    private(set) var sourcePageIndex = SourcePageIndex()
    @Published var actionReviewLedgers: [String: ActionReviewLedger] = [:]
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
    @Published var actionUndoStack = ActionUndoStack()
    var isUndoingActionChange = false
    @Published var actionVersions: [ActionRevision] = []
    @Published var feedbackRecords: [ActionFeedbackRecord] = []
    @Published var activeActionTitle = ""
    @Published var savingFeedback = false
    @Published var reminderLinks: [ReminderLink] = []
    @Published var reminderSyncAnomalies = ReminderSyncAnomalySummary.empty
    @Published var reminderCalendars: [ReminderCalendar] = []
    @Published var reminderCalendarID = ""
    @Published var proposedReminderCalendarID = ""
    @Published var reminderAccess: ReminderAccess?
    @Published var reminderSyncStatus = "尚未启用自动回读"
    @Published var reminderLastError = ""
    private var reminderObservers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var reminderTimer: Timer?
    private var followupTimer: Timer?
    private lazy var reminderRefresh = ReminderRefreshCoordinator { [weak self] in await self?.automaticReminderRefresh() }

    @Published var remindersBusy = false
    @Published var choosingReminderCalendar = false
    private let reminders = NativeReminders()
    var reminderCalendarTitle: String { reminderCalendars.first { $0.id == reminderCalendarID }?.title ?? (reminderAccess?.enabled == true ? reminderAccess!.title : "未选择清单") }
    var remindersPermissionDenied: Bool { NativeReminders.authorizationStatus() == .denied }
    var reminderPermission: RemindersAuthorization { NativeReminders.authorizationStatus() }
    /// A completion or reopen that could not reach Apple Reminders. It follows
    /// the reminder compensation lifecycle: persist the intent first, write
    /// only after an authorized readback, and drop it once readback agrees.
    /// The value lives in VoiceOSCore so its persistence and failure transition
    /// are covered by the check suite.
    @Published private(set) var pendingReminderSyncs: [String: PendingReminderSync] = [:]
    @Published var deliveryReadAt: [String: String] = [:]
    static func loadPendingReminderSyncs() -> [String: PendingReminderSync] {
        guard let data = UserDefaults.standard.data(forKey: "voiceos.pendingReminderSyncs.v1"),
              let decoded = try? JSONDecoder().decode([String: PendingReminderSync].self, from: data) else { return [:] }
        return decoded
    }
    static func loadDeliveryReadAt() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "voiceos.deliveryRead.v1"),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }
    var reminderSyncUnavailable: Bool { remindersPermissionDenied || reminderAccess?.enabled != true || !reminders.isAuthorized }
    func isDeliveryUnread(_ execution: AssistantExecutionRecord) -> Bool {
        execution.state == "completed" && execution.validity == "current" && deliveryReadAt[execution.id] != execution.updatedAt
    }
    var unreadDeliveryCount: Int { assistantExecutions.filter { isDeliveryUnread($0) }.count }
    var unreadDeliveries: [AssistantExecutionRecord] { assistantExecutions.filter { isDeliveryUnread($0) } }
    func markDeliveryRead(_ execution: AssistantExecutionRecord) {
        guard isDeliveryUnread(execution) else { return }
        deliveryReadAt[execution.id] = execution.updatedAt
        if let data = try? JSONEncoder().encode(deliveryReadAt) { UserDefaults.standard.set(data, forKey: "voiceos.deliveryRead.v1") }
    }
    func sortedAssistantDeliveries(_ executions: [AssistantExecutionRecord]) -> [AssistantExecutionRecord] {
        executions.sorted { left, right in
            let leftUnread = isDeliveryUnread(left), rightUnread = isDeliveryUnread(right)
            if leftUnread != rightUnread { return leftUnread }
            return left.updatedAt > right.updatedAt
        }
    }
    var pendingReminderSyncList: [PendingReminderSync] { pendingReminderSyncs.values.sorted { $0.createdAt < $1.createdAt } }
    func pendingReminderSync(for actionID: String) -> PendingReminderSync? { pendingReminderSyncs[actionID] }
    func canCompleteLocally(_ action: ActionRecord) -> Bool {
        action.kind == "task" && action.state == LocalActionState.open.rawValue && action.validity == "current"
            && reminderSyncUnavailable
            && reminderLinks.contains { $0.actionID == action.id && $0.state == "linked" && $0.externalID != nil }
    }
    func savePendingReminderSyncs() {
        if let data = try? JSONEncoder().encode(pendingReminderSyncs) { UserDefaults.standard.set(data, forKey: "voiceos.pendingReminderSyncs.v1") }
    }
    func enqueuePendingReminderSync(_ action: ActionRecord, link: ReminderLink, externalID: String, desiredState: LocalActionState) {
        pendingReminderSyncs[action.id] = PendingReminderSync(actionID: action.id, linkID: link.id, calendarID: link.calendarID,
            externalID: externalID, marker: "voiceos-action:" + link.id, title: action.title,
            desiredState: desiredState.rawValue, createdAt: ISO8601DateFormatter().string(from: Date()))
        savePendingReminderSyncs()
    }
    func removePendingReminderSync(actionID: String) {
        guard pendingReminderSyncs.removeValue(forKey: actionID) != nil else { return }
        savePendingReminderSyncs()
    }
    func recordPendingReminderSyncFailure(actionID: String, reason: String) {
        guard var entry = pendingReminderSyncs[actionID] else { return }
        entry.recordFailure(reason, at: ISO8601DateFormatter().string(from: Date()))
        pendingReminderSyncs[actionID] = entry
        savePendingReminderSyncs()
    }
    func recordingActionRequiresReview(_ action:ActionRecord) -> Bool {
        let sourceIDs=Set(claims.first(where: { $0.id == action.claimID })?.references.map(\.sourceID) ?? [])
        return records.contains { source in
            guard let expression=source.presentation?.expression else { return false }
            guard sourceIDs.contains(source.id) || expression.previousActionIDs.contains(action.id) else { return false }
            return actionReviewLedgers[expression.id]?.requiresReview(actionID:action.id) ?? true
        }
    }
    func actionReviewPairs(for action: ActionRecord) -> [ActionReviewPair] {
        actionReviewLedgers.values.flatMap { $0.unresolvedPairs(for: action.id) }.sorted { $0.id < $1.id }
    }
    static weak var primary: ControlCenter?
    private let rootOverride: URL?
    private(set) var libraryRoot: URL?
    var libraryTitle: String { rootOverride == nil ? "VoiceOS" : "独立资料库 · " + rootOverride!.lastPathComponent }
    init(root: URL? = nil) {
        rootOverride=root
        pendingReminderSyncs = ControlCenter.loadPendingReminderSyncs()
        deliveryReadAt = ControlCenter.loadDeliveryReadAt()
        recordingInbox=RecordingInbox(libraryRoot:root ?? ProcessInfo.processInfo.environment["VOICEOS_DATA_DIR"].map { URL(fileURLWithPath:$0) })
        // Only the app's main model (no root) backs the app-level menu action.
        if root == nil, ControlCenter.primary == nil { ControlCenter.primary = self }
    }
    var store: VoiceOSStore?
    @Published var workspaceTopics: [ReflectionQuestion] = []
    @Published var workspaceTopicSources: [String: [String]] = [:]
    @Published private(set) var topicsRevision = 0
    @Published var workspaceBriefing: WorkspaceBriefing?
    @Published var organizingTopics = false
    @Published var topicOrganizationStatus = ""
    private let topicCooldown = TopicOrganizationCooldown()
    private var topicModel: ResponsesTopicOrganizationPort?
    var recordingExpressionModel: ResponsesRecordingExpressionPort?
    private var topicWorker: Task<Void, Never>?
    private var topicAttemptDigest: String?
    private var topicPending = false
    private var topicForcePending = false
    private var topicTopUpPending = false
    @Published var materialNoteStates: [String: MaterialNoteState] = [:]
    /// 会话内同步的「该材料已有可读笔记」缓存，供页头首帧决定版式。
    @Published var materialNotePresence: [String: Bool] = [:]
    /// 首页批量笔记读取的会话级缓存：视图重建时首帧就能用笔记标题与预览，
    /// 不再先按旧标题渲染再跳变。按表达键存放每条最新一版，只增不减。
    @Published var materialNoteRows: [String: StoredMaterialNote] = [:]
    var materialNoteModel: ResponsesMaterialNotePort?
    private var topicDomainBackfillStarted = false
    /// 升级后旧主题还没有人生维度：启动时用一次低成本归类补齐，不重跑整套
    /// 主题整理。每个运行期只尝试一次；失败就等下次启动或下次整理。
    private func startTopicDomainBackfillIfNeeded() {
        guard !topicDomainBackfillStarted, initialized, let store, let port = topicModel else { return }
        topicDomainBackfillStarted = true
        Task {
            do {
                let written = try await store.backfillTopicDomains(using: port)
                if written > 0 { await refresh() }
            } catch {
                // 模型暂时不可用：复位标志，模型重配或下一次全量刷新时再试。
                topicDomainBackfillStarted = false
            }
        }
    }
    func queueTopicOrganization(retry: Bool = false, topUp: Bool = false) {
        guard initialized, topicModel != nil else { return }
        topicForcePending = topicForcePending || retry
        topicTopUpPending = topicTopUpPending || topUp
        if topicWorker != nil { topicPending = true; return }
        if retry || topUp { topicAttemptDigest = nil }
        topicWorker = Task {
            defer { topicWorker = nil; organizingTopics = false }
            repeat {
                topicPending = false
                let force = topicForcePending, top = !force && topicTopUpPending
                topicForcePending = false; topicTopUpPending = false
                do {
                    guard let store, let port = topicModel, let input = try await store.prepareTopicOrganization() else { return }
                    if !force && !top, try await !store.needsTopicOrganizationRefresh() { return }
                    if !force && !top, let waiting = topicCooldown.waitingMessage() { topicOrganizationStatus = waiting; return }
                    topicAttemptDigest = input.digest
                    organizingTopics = true; topicOrganizationStatus = "AI 正在先整理主题骨架，再分批写正文…"
                    _ = try await store.organizeTopics(using: port, force: force, topUp: top)
                    topicCooldown.recordSuccess()
                    topicOrganizationStatus = "主题与首页简报已更新"
                    await refresh()
                } catch let incomplete as TopicOrganizationIncomplete {
                    topicCooldown.recordFailure(reason: incomplete.localizedDescription)
                    topicOrganizationStatus = incomplete.localizedDescription
                    await refresh()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        topicOrganizationStatus = "主题整理已取消；已完成的主题会保留"
                    } else {
                        topicCooldown.recordFailure(reason: error.localizedDescription)
                        topicOrganizationStatus = TopicOrganizationCooldown.failureMessage(reason: error.localizedDescription)
                        await refresh()
                    }
                }
            } while topicPending && !Task.isCancelled
        }
    }
    /// Views read this instead of the topic page's corner text. A pending body
    /// or an active cooldown both belong in the processing/home attention list.
    var topicOrganizationPendingTopicCount: Int {
        workspaceTopics.filter { $0.organization?.bodyPending == true }.count
    }
    var topicOrganizationNeedsAttention: Bool {
        topicOrganizationPendingTopicCount > 0 || topicCooldown.remainingSeconds() != nil
    }
    var topicOrganizationAttentionText: String? {
        let pending = topicOrganizationPendingTopicCount
        if pending > 0 { return "主题整理未完成 · \(pending) 个主题待补齐" }
        guard let waiting = topicCooldown.waitingMessage() else { return nil }
        return waiting
    }

    @Published var dictationBusy = false
    @Published var dictationActive = false
    private(set) var dictationStartedAt: Date?
    private var dictationStatusBase = ""
    private var dictationDiscarding = false
    var dictationHotKeyConflict: Bool { !GlobalHotKeyCenter.shared.isRegistered(.toggleDictation) }
    private var dictationSource: String?
    private var dictationInterrupted = false
    private var dictationFullOrganization = false
    private let dictation = NativeDictation()
    @Published private(set) var microphoneAuthorization = NativeDictation.authorizationStatus()
    private var dictationObservers: [NSObjectProtocol] = []
    var dictationBusyReason: String? {
        if dictationBusy { return "正在封存上一段录音，请稍候" }
        return nil
    }
    static func clockText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    var dictationElapsedText: String {
        guard let dictationStartedAt else { return "" }
        return Self.clockText(Date().timeIntervalSince(dictationStartedAt))
    }
    func noteDictationClock(_ text: String) {
        guard dictationActive, !dictationBusy, !dictationStatusBase.isEmpty else { return }
        status = dictationStatusBase + " · 已录 " + text
    }
    func refreshMicrophoneAuthorization() { microphoneAuthorization = NativeDictation.authorizationStatus() }
    func requestMicrophoneAccess() async -> Bool {
        let granted = await dictation.requestPermission()
        microphoneAuthorization = NativeDictation.authorizationStatus()
        return granted
    }
    func startDictation(processAfterTranscription: Bool = false) async {
        guard let store, dictationBusyReason == nil, !dictationActive else { status = dictationBusyReason ?? "正在录音，停止后才能开始下一段"; return }
        if processAfterTranscription, let issue = recordingModelIssue {
            status = issue + "无法录制并完整整理"
            return
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
            dictationSource = intent.sourceID; dictationInterrupted = false; dictationDiscarding = false
            try dictation.start(at:intent.stagingURL,maximumDuration:duration) { [weak self] success in Task { await self?.finishDictation(success:success) } }
            dictationStartedAt = Date(); dictationActive = true; selected = intent.sourceID
            status = duration.map { "正在进行\($0)秒限时采集 · 到时自动停止 · 仅本地" } ?? "正在录制我的口述 · 仅本地；停止后才核对并封存原件"
            if processAfterTranscription { status = "正在录制 · 停止后完整转写并整理所有意图；仅文字用于云端" }
            dictationStatusBase = status
            await refresh()
        } catch {
            if let id = dictationSource { try? await store.interruptDictation(sourceID:id) }
            dictationSource = nil; dictationActive = false; dictationFullOrganization = false
            dictationStartedAt = nil; dictationStatusBase = ""; dictationDiscarding = false
            status = error.localizedDescription; await refresh()
        }
    }
    func stopDictation(interrupted:Bool = false) {
        guard dictationActive, !dictationBusy else { return }
        dictationInterrupted = interrupted; dictationBusy = true
        dictationStartedAt = nil; dictationStatusBase = ""
        status = interrupted ? "录制因系统中断结束，保留片段待核对" : "正在停止录制并核对原件…"
        dictation.stop()
    }
    func cancelAndDiscardDictation() {
        guard dictationActive, !dictationBusy, dictationSource != nil else { status = "没有可取消的录音"; return }
        dictationDiscarding = true
        dictationBusy = true
        dictationStartedAt = nil; dictationStatusBase = ""
        status = "正在取消并丢弃这段口述…"
        dictation.stop()
    }
    var canToggleCaptureDictation: Bool {
        // 文本模型缺失不再拦住口述：录下来先存原音，配置后再整理。
        initialized && !dictationBusy
    }
    func toggleCaptureDictation() {
        if dictationActive {
            stopDictation()
        } else {
            Task { await startDictation(processAfterTranscription: recordingModelIssue == nil) }
        }
    }
    private func finishDictation(success:Bool) async {
        guard let store, let id = dictationSource else { return }
        let organize = dictationFullOrganization
        let discard = dictationDiscarding
        dictationFullOrganization = false
        dictationDiscarding = false
        dictationSource = nil; dictationActive = false
        dictationStartedAt = nil; dictationStatusBase = ""
        defer { dictationBusy = false }
        if discard {
            await discardDictation(store: store, sourceID: id, recorded: success)
            await refresh()
            if discussionRecordingID == id {
                discussionRecordingID = nil
                discussionStatus = "本轮口述已取消并丢弃。"
            }
            return
        }
        if success && !dictationInterrupted {
            do { try await store.sealDictation(sourceID:id); status = "口述原件已保存 · 本地转写随后处理" }
            catch { try? await store.interruptDictation(sourceID:id); status = "录制封存未完成：" + error.localizedDescription + "；片段保留待核对，未报告保存成功" }
        } else {
            try? await store.interruptDictation(sourceID:id); status = "录制未正常结束，片段保留待核对；未报告保存成功"
        }
        await refresh()
        if discussionRecordingID == id {
            discussionStatus=records.first(where: { $0.id == id })?.state == "saved" ? "本轮口述原件已保存；等待本地转写与核对，尚未关联和发送。" : "本轮录制尚未正常保存，片段保留待核对；尚未关联和发送。"
        }
        if organize, records.first(where: { $0.id == id })?.state == "saved" {
            enqueueBackgroundOrganization(sourceID: id)
        } else { scheduleProcessing(); resumeRecordingFollowups() }
    }
    private func discardDictation(store: VoiceOSStore, sourceID: String, recorded: Bool) async {
        guard recorded else {
            try? await store.interruptDictation(sourceID: sourceID)
            status = "录音未正常结束；已取消，片段保留待核对，未进入转写与整理"
            return
        }
        do {
            try await store.sealDictation(sourceID: sourceID)
            let audio = records.first(where: { $0.id == sourceID }).flatMap { record in
                libraryRoot.map { $0.appendingPathComponent(record.relativePath) }
            }
            if let audio { try? FileManager.default.removeItem(at: audio) }
            let removed = audio.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
            // Quarantine blocks the queued transcription job and keeps export from expecting the deleted file.
            if removed { _ = try? await store.playableURL(sourceID: sourceID) }
            try await store.setMaterialDisposition(sourceIDs: [sourceID], disposition: .trashed)
            removeDictationStaging(sourceID: sourceID)
            status = removed
                ? "这段口述已取消并丢弃；未进入转写与整理"
                : "这段口述已取消；音频未能删除，原件保留在回收站，未进入转写与整理"
        } catch {
            try? await store.interruptDictation(sourceID: sourceID)
            status = "取消并丢弃未完成：" + error.localizedDescription + "；片段保留待核对，未进入转写与整理"
        }
    }
    private func removeDictationStaging(sourceID: String) {
        guard let root = libraryRoot, let record = records.first(where: { $0.id == sourceID }) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("staging/\(record.assetID).part.caf"))
    }
    func recoverDictation(_ record:SourceRecord) async {
        guard let store, !dictationBusy, !dictationActive else { return }
        dictationBusy = true; defer { dictationBusy = false }
        do { try await store.sealDictation(sourceID:record.id); status = "可解码片段已保存；它是中断片段，不代表完整表达"; await refresh(); scheduleProcessing() }
        catch { status = "片段尚不能完整解码，保留待核对"; await refresh() }
    }
    func startFeedbackDictation() async -> String? {
        guard speechPort is LocalQwenSpeechPort, !dictationActive, !dictationBusy else {
            status = dictationBusyReason ?? "请先配置 Qwen 转写"; return nil
        }
        await startDictation()
        return dictationActive ? dictationSource : nil
    }
    private var worker: Task<Void, Never>?
    private var resumedSavedRecordingExpressions = false
    func start() async {
        guard store == nil else { return }
        StartupTrace.mark("start.begin")
        startupIssue = ""
        do {
            let root: URL
            if let override = rootOverride { root = override }
            else if let path = ProcessInfo.processInfo.environment["VOICEOS_DATA_DIR"] { root = URL(fileURLWithPath: path, isDirectory: true) }
            else { root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("VoiceOS", isDirectory: true) }
            libraryRoot = root
            outcomePreferenceKey = "voiceos.outcomeFollowup.skipped:" + root.standardizedFileURL.path
            skippedOutcomeKeys = Set(UserDefaults.standard.stringArray(forKey: outcomePreferenceKey) ?? [])
            let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
            self.store = store
            StartupTrace.mark("start.storeInit")
            try await store.recover()
            StartupTrace.mark("start.recoverDone")
            markdownMirror = MarkdownMirror(directory: root.appendingPathComponent("Mirror", isDirectory: true))
            backupLibrary(at: root)
            restoreTextCaptureDraft(at: root)
            initialized = true; status = "准备就绪 · 媒体只在本机处理"
            StartupTrace.mark("start.initialized")
            restoreSpeechSelection()
            if let path = ProcessInfo.processInfo.environment["VOICEOS_MODEL_CONFIG_FILE"] {
                configureTextModel(URL(fileURLWithPath: path), resume: false)
            } else if restoreInternalTextModelConfiguration() {
                // 应用内部配置优先：模型、地址、强度都在设置页维护。
            } else if UserDefaults.standard.bool(forKey: "voiceos.textModelConfigurationCleared.v1") {
                // The user cleared the configuration in settings; do not fall
                // back to the bundle's development .env on the next launch.
            } else if let path = UserDefaults.standard.string(forKey: "voiceos.textModelConfigPath.v1") ?? Bundle.main.object(forInfoDictionaryKey: "VoiceOSModelConfigurationPath") as? String {
                configureTextModel(URL(fileURLWithPath: path), resume: false)
            }
            await refresh(.full)
            StartupTrace.mark("start.refreshDone")
            await restoreTranscriptReviewFailures()
            do { if try await store.recoverRecordingFollowups() { await refresh(.full) } }
            catch { status = error.localizedDescription }
            scheduleProcessing()
            installReminderRefresh()
            installMonitorSchedule()
            dictationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.flushTextCaptureDraft(); self?.stopDictation(interrupted:true) } })
            dictationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.stopDictation(interrupted:true) } })
            dictationObservers.append(NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.flushTextCaptureDraft(); self?.stopDictation(interrupted:true) } })
            requestReminderRefresh()
            resumeRecordingFollowups()
            resumeFolderWatch()
            queueRecordingTitles()
            if modelConfigured { resumeKnowledgeReviews() }
            StartupTrace.mark("start.end")
                recordingInbox.start(canProcess: { [weak self] in
                    guard let self else { return false }
                    return self.initialized && self.modelConfigured && self.speechPort is LocalQwenSpeechPort && self.organizingSourceID == nil && !self.fullRecordingBusy && self.worker == nil && self.understandingWorker == nil && !self.dictationActive && !self.dictationBusy && !self.importing && self.pausedActionBatch?.isRunning != true
                }, resumeSaved: { [weak self] in
                    await self?.resumeSavedRecordingExpressions()
                }, receive: { [weak self] batch, finished in
                    guard let self else { finished(Dictionary(uniqueKeysWithValues:batch.map { ($0.digest,.needsAttention("应用已关闭")) })); return }
                    self.organizeAutomaticRecordings(batch,finished:finished)
                })
        } catch {
            store = nil; initialized = false; workspaceLoaded = false
            startupIssue = error.localizedDescription
            status = "资料库尚未打开：" + error.localizedDescription
        }
    }
    private var refreshWorker: Task<Bool, Never>?
    private var pendingRefreshPlan: RefreshPlan?
    func refresh(_ scope: RefreshScope = .interactive) async {
        if scope == .full { startTopicDomainBackfillIfNeeded() }
        let request = RefreshPlan(scope)
        if var pending = pendingRefreshPlan { pending.merge(request); pendingRefreshPlan = pending }
        else { pendingRefreshPlan = request }
        if let refreshWorker { await refreshWorker.value; return }
        let work = Task { () -> Bool in
            defer { refreshWorker = nil }
            var didWork = false
            while let plan = pendingRefreshPlan, !Task.isCancelled {
                pendingRefreshPlan = nil
                if await reloadWorkspace(plan) { didWork = true }
            }
            return didWork
        }
        refreshWorker = work
        let didWork = await work.value
        guard didWork else { StartupTrace.mark("refresh.idleSkip"); return }
        StartupTrace.mark("refresh.reloaded")
        if monitorPageVisible { await reloadMonitorState() }
        writeMarkdownMirror()
        updateSpotlightIndex()
        StartupTrace.mark("refresh.backgroundQueued")
    }
    func retryBackup() {
        guard let root = libraryRoot else { return }
        backupLibrary(at: root)
    }
    func revealBackups() {
        guard let root = libraryRoot else { return }
        let directory = root.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
    func revealLibraryRoot() {
        guard let root = libraryRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
    private var backupRetentionPreference: Int {
        let stored = UserDefaults.standard.object(forKey: "voiceos.backupRetention") as? Int ?? 7
        return [3, 7, 14].contains(stored) ? stored : 7
    }
    func refreshStorageUsage() {
        guard let root = libraryRoot else { return }
        storageScanBusy = true
        Task {
            let usage = await Task.detached(priority: .utility) { DatabaseBackup.storageUsage(root: root) }.value
            storageUsage = usage
            storageScanBusy = false
        }
    }
    func cleanupOldBackups(retain: Int) {
        guard let root = libraryRoot, !backupPruning else { return }
        let directory = root.appendingPathComponent("Backups", isDirectory: true)
        backupPruning = true
        backupCleanupStatus = "正在清理旧备份…"
        Task {
            do {
                let result = try await Task.detached(priority: .utility) { () -> (backups: Int, orphans: Int) in
                    let backups = try DatabaseBackup.prune(directory: directory, retain: retain)
                    let orphans = DatabaseBackup.removeOrphanSidecars(directory: directory)
                    return (backups, orphans)
                }.value
                recordBackupSummary(DatabaseBackup.availability(directory: directory))
                if result.backups == 0 && result.orphans == 0 {
                    backupCleanupStatus = "没有需要清理的旧备份"
                } else {
                    backupCleanupStatus = "已清理 \(result.backups) 份旧备份" + (result.orphans > 0 ? "与 \(result.orphans) 个孤儿侧车文件" : "")
                }
                refreshStorageUsage()
            } catch {
                backupCleanupStatus = "清理失败：" + error.localizedDescription
            }
            backupPruning = false
        }
    }
    func deleteLocalSpeechModel() {
        guard let root = libraryRoot, !localSpeechDeleting else { return }
        guard !speechModelBusy else { localSpeechDeleteStatus = "转录或录音进行中，结束后再删除"; return }
        let directory = root.appendingPathComponent("LocalSpeech", isDirectory: true)
        localSpeechDeleting = true
        localSpeechDeleteStatus = "正在删除本地语音模型…"
        Task {
            let result: Result<Int, Error> = await Task.detached(priority: .utility) { () -> Result<Int, Error> in
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: directory.path) else { return .success(0) }
                do {
                    let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    for item in contents { try fileManager.removeItem(at: item) }
                    return .success(contents.count)
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let count):
                speechPort = nil
                speechSummary = "Qwen 本地转写 · 模型已删除，需重新下载"
                localSpeechDeleteStatus = count > 0 ? "本地语音模型已删除；重新下载后可再次启用" : "没有可删除的本地语音模型"
                refreshStorageUsage()
            case .failure(let error):
                localSpeechDeleteStatus = "删除失败：" + error.localizedDescription
            }
            localSpeechDeleting = false
        }
    }
    func refreshLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginStatus = "已开启，登录后自动启动"
        case .notRegistered:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "未开启"
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "已注册，需在系统设置 › 通用 › 登录项中允许"
        case .notFound:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "系统尚未登记此应用，无法设置登录启动"
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "登录启动状态未知"
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "voiceos.launchAtLogin")
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLaunchAtLogin()
        } catch {
            launchAtLoginStatus = "设置失败：" + error.localizedDescription
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }
    private func backupLibrary(at root: URL) {
        guard !backupRunning else { return }
        backupRunning = true
        let database = root.appendingPathComponent("voiceos.sqlite")
        let directory = root.appendingPathComponent("Backups", isDirectory: true)
        let retain = backupRetentionPreference
        Task.detached(priority: .utility) { [weak self] in
            defer { Task { await MainActor.run { self?.backupRunning = false } } }
            do {
                _ = try DatabaseBackup.createDailyIfNeeded(database: database, directory: directory, retain: retain)
                DatabaseBackup.removeOrphanSidecars(directory: directory)
                let availability = DatabaseBackup.availability(directory: directory)
                await MainActor.run { self?.recordBackupSummary(availability) }
            } catch {
                NSLog("VoiceOS 数据库备份失败：\(error.localizedDescription)")
                await MainActor.run { self?.backupStatusText = DatabaseBackup.failureText(error) }
            }
        }
    }
    private func recordBackupSummary(_ availability: DatabaseBackup.BackupAvailability) {
        switch availability {
        case .summary(let summary):
            lastBackupAt = summary.date
            backupStatusText = DatabaseBackup.successText(at: summary.date, count: summary.count)
        case .none:
            lastBackupAt = nil
            backupStatusText = ""
        case .unreadable:
            lastBackupAt = nil
            backupStatusText = "备份目录无法读取"
        }
    }
    /// One-shot library check: live integrity and references, originals on disk,
    /// and a quick_check of the newest backup. Re-runnable from the same button.
    func checkLibraryHealth() {
        guard !checkingLibraryHealth else { return }
        guard let root = libraryRoot, let store else {
            libraryHealthProblem = true
            libraryHealthText = "资料库尚未打开，无法检查"
            return
        }
        checkingLibraryHealth = true
        libraryHealthProblem = false
        libraryHealthText = "正在检查资料库…"
        let database = root.appendingPathComponent("voiceos.sqlite")
        let backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        Task {
            defer { checkingLibraryHealth = false }
            do {
                let integrity = try await store.integrityCheck()
                let scan = try await Task.detached(priority: .utility) {
                    try DatabaseBackup.scanSourceAssets(database: database, root: root)
                }.value
                let backup = await Task.detached(priority: .utility) {
                    DatabaseBackup.verifyLatestBackup(directory: backupDirectory)
                }.value
                var issues: [String] = []
                if !integrity { issues.append("主库完整性或引用检查未通过") }
                if !scan.missing.isEmpty {
                    let sample = scan.missing.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
                    issues.append("\(scan.missing.count) 份原件缺失（\(sample)\(scan.missing.count > 3 ? " 等" : "")）")
                }
                if backup.file == nil {
                    issues.append("还没有备份")
                } else if !backup.ok, let file = backup.file {
                    issues.append("最新备份抽查未通过：" + file.lastPathComponent)
                }
                if issues.isEmpty {
                    let when = backup.date?.formatted(date: .abbreviated, time: .shortened) ?? "时间未知"
                    libraryHealthText = "资料库正常 · \(scan.sourceCount) 份原件 · 最近备份 \(when) 通过"
                    libraryHealthProblem = false
                } else {
                    libraryHealthText = "\(issues.count) 项问题：" + issues.joined(separator: "；")
                    libraryHealthProblem = true
                }
            } catch {
                libraryHealthProblem = true
                libraryHealthText = "检查失败：\(error.localizedDescription)（资料库：\(root.path)）"
            }
        }
    }
    private func writeMarkdownMirror() {
        guard markdownMirror != nil else { return }
        mirrorPending = true
        guard mirrorWorker == nil else { return }
        mirrorWorker = Task { [weak self] in
            defer { self?.mirrorWorker = nil }
            repeat {
                guard let self else { return }
                self.mirrorPending = false
                guard let mirror = self.markdownMirror else { return }
                let sources = self.records, claims = self.claims, actions = self.actionRecords
                let written = await Task.detached(priority: .utility) { () -> MarkdownMirror? in
                    var copy = mirror
                    return (try? copy.write(sources: sources, claims: claims, actions: actions)) == true ? copy : nil
                }.value
                if let written { self.markdownMirror = written }
            } while (self?.mirrorPending ?? false) && !Task.isCancelled
        }
    }
    private func updateSpotlightIndex() {
        spotlightPending = true
        guard spotlightWorker == nil else { return }
        spotlightWorker = Task { [weak self] in
            defer { self?.spotlightWorker = nil }
            repeat {
                guard let self else { return }
                self.spotlightPending = false
                let indexer = self.spotlightIndexer, sources = self.records, claims = self.claims, actions = self.actionRecords, topics = self.workspaceTopics
                await Task.detached(priority: .utility) {
                    await indexer.index(sources: sources, claims: claims, actions: actions, topics: topics)
                }.value
            } while (self?.spotlightPending ?? false) && !Task.isCancelled
        }
    }
    /// Recompute the home snapshot from the published arrays it derives from,
    /// so a render only reads it.
    private func publishHomeSnapshot() {
        // Same review gate the materials list and source page read.
        let reviewed = Set(actionRecords.lazy.filter { self.sourcePageIndex.requiresReview($0.id) }.map(\.id))
        // 线索的隐藏/合并入口已随「成品优先」撤掉；旧覆盖不再过滤收件箱，
        // 否则被隐藏线索下的待办会永久消失且无处恢复。
        homeSnapshot = RecentContentHomeSnapshot.build(sources: records, claims: claims, actions: actionRecords,
                                                       overrides: [], reviewRequiredActionIDs: reviewed)
    }
    private func applyCoreSnapshot(_ snapshot: WorkspaceSnapshot, reminderAnomalies: ReminderSyncAnomalySummary = .empty) {
        records = snapshot.sources
        recordsRevision &+= 1
        claims = snapshot.claims
        currentClaimsBySource = snapshot.currentClaimsBySource
        questionRecords = snapshot.questions
        questionRevisions = snapshot.questionHistories
        claimOrigins = snapshot.claimOrigins
        outcomeOrigins = snapshot.outcomeOrigins
        actionRecords = snapshot.actions
        actionClarifications = snapshot.actionClarifications
        recentClueOverrides = snapshot.recentClueOverrides
        actionReviewLedgers = snapshot.actionReviewLedgers
        // Pause review reads the ledgers, so the index builds after them.
        sourcePageIndex = SourcePageIndex(records: records, claims: claims, actions: actionRecords,
                                          currentClaimsBySource: currentClaimsBySource, ledgers: actionReviewLedgers)
        // The home snapshot filters tasks by that same index, so it publishes after it.
        publishHomeSnapshot()
        taskInitiations = snapshot.taskInitiations
        recentOutcomes = snapshot.recentOutcomes
        compensationPlans = snapshot.compensationPlans
        compensationGrants = snapshot.compensationGrants
        compensationOperations = snapshot.compensationOperations
        reminderLinks = snapshot.reminderLinks
        reminderSyncAnomalies = reminderAnomalies
        reminderAccess = snapshot.reminderAccess
        reminderCalendarID = reminderAccess?.enabled == true ? reminderAccess!.calendarID : ""
        if reminderAccess?.enabled == false { reminderSyncStatus = "提醒事项连接已暂停 · 外部任务和历史保留" }
        workspaceTopics = snapshot.topics
        workspaceTopicSources = snapshot.topicSources
        topicsRevision &+= 1
        attempts = snapshot.attempts
        processingIntents = snapshot.processingIntents
        recordingRequests = snapshot.recordingRequests
        segmentedBatches = snapshot.segmentedBatches
        segmentedCognitiveCounts = snapshot.segmentedCognitiveCounts
        segmentedAssociationStates = snapshot.segmentedAssociationStates
        StartupTrace.mark("core.records=\(records.count) claims=\(claims.count) actions=\(actionRecords.count)")
        secondaryRevision &+= 1
    }
    private func applySecondarySnapshot(_ snapshot: WorkspaceSnapshot) {
        outcomeFollowups = snapshot.outcomeFollowups
        correctionImpacts = snapshot.correctionImpacts
        scheduleIntents = snapshot.scheduleIntents
        scheduleOperations = snapshot.scheduleOperations
        scheduleGrants = snapshot.scheduleGrants
        schedulePreviews = snapshot.schedulePreviews
        workspaceBriefing = snapshot.briefing
        recordingFollowups = snapshot.recordingFollowups
        StartupTrace.mark("secondary.followups=\(recordingFollowups.count)")
        secondaryRevision &+= 1
    }
    private func applyAssistantSnapshot(_ snapshot: WorkspaceSnapshot) {
        assistantExecutions = snapshot.assistantExecutions
        assistantAssessmentIssues = snapshot.assistantAssessmentIssues
        StartupTrace.mark("secondary.assistant=\(assistantExecutions.count) issues=\(assistantAssessmentIssues.count)")
        secondaryRevision &+= 1
    }
    @discardableResult
    private func reloadWorkspace(_ plan: RefreshPlan) async -> Bool {
        guard let store else { return false }
        if plan.full {
            return await reloadFullWorkspace(store: store)
        }
        await reloadScopedWorkspace(plan, store: store)
        return true
    }
    @discardableResult
    private func reloadFullWorkspace(store: VoiceOSStore) async -> Bool {
        let generation = await store.dataGeneration
        if workspaceLoaded, generation == lastFullReloadGeneration {
            StartupTrace.mark("reload.skipped")
            return false
        }
        StartupTrace.mark("reload.begin")
        var contextsFroze = false
        var coreSnapshotApplied = false
        var latestClaimsBySource: [String: [CandidateClaim]]?
        var assistantSnapshot: WorkspaceSnapshot?
        do {
            let snapshot = try await StartupTrace.measureAsync("reload.workspaceSnapshot") { try await store.workspaceSnapshot(.core) }
            if workspaceLastErrorRetry == .reload { clearWorkspaceError() }
            latestClaimsBySource = snapshot.currentClaimsBySource
            // Publish the core lists together, without awaits between related data sets.
            applyCoreSnapshot(snapshot, reminderAnomalies: try await store.reminderSyncAnomalies())
            coreSnapshotApplied = true
            StartupTrace.mark("reload.published")
            await validateCoreSelection(store: store)
        }
        catch { status = error.localizedDescription; reportWorkspaceError(error.localizedDescription, retry: .reload) }
        workspaceLoaded = true
        StartupTrace.mark("reload.firstScreen")
        do {
            let light = try await StartupTrace.measureAsync("reload.secondarySnapshot") { try await store.workspaceSnapshot(.secondary) }
            applySecondarySnapshot(light)
            contextsFroze = light.contextValidityChanged
            StartupTrace.mark("reload.secondaryPublished")
            try? await Task.yield()
            let assistant = try await StartupTrace.measureAsync("reload.assistantSnapshot") { try await store.workspaceSnapshot(.assistant) }
            applyAssistantSnapshot(assistant)
            assistantSnapshot = assistant
            contextsFroze = contextsFroze || assistant.contextValidityChanged
            StartupTrace.mark("reload.assistantPublished")
            try? await Task.yield()
            followupValidity = try await StartupTrace.measureAsync("reload.followupValidity") {
                try await store.recordingFollowupValidities(recordingFollowups,
                    catalogRows: coreSnapshotApplied ? records : nil,
                    claimRows: coreSnapshotApplied ? claims : nil,
                    actionRows: coreSnapshotApplied ? actionRecords : nil,
                    latest: coreSnapshotApplied && !contextsFroze ? latestClaimsBySource : nil)
            }
            StartupTrace.mark("reload.validityPublished")
            let knowledge = try await StartupTrace.measureAsync("reload.knowledgeSnapshot") { try await store.workspaceSnapshot(.knowledge) }
            knowledgeReviews = knowledge.knowledgeReviews
            StartupTrace.mark("reload.knowledgePublished")
            stalledOutcomes = try await StartupTrace.measureAsync("reload.stalledOutcomes") { (try? await store.stalledOutcomes()) ?? [] }
            englishAttempts = try await StartupTrace.measureAsync("reload.englishAttempts") { try await store.englishFeedbackAttempts() }
            await StartupTrace.measureAsync("reload.relevanceValidate") { await relevance.validate(store:store) }
            await StartupTrace.measureAsync("reload.quietFeedback") { await refreshQuietFeedback() }
            await StartupTrace.measureAsync("reload.sourceDiscussions") { await refreshSourceDiscussions() }
            if contextsFroze {
                applyCoreSnapshot(try await store.workspaceSnapshot(.core), reminderAnomalies: try await store.reminderSyncAnomalies())
                StartupTrace.mark("reload.coreRepublished")
            }
        }
        catch { status = error.localizedDescription }
        await StartupTrace.measureAsync("reload.discussion") { await refreshDiscussion() }
        resumeAssistantExecutions(snapshot: contextsFroze ? nil : assistantSnapshot)
        queueTopicOrganization()
        lastFullReloadGeneration = await store.dataGeneration
        return true
    }
    private func reloadScopedWorkspace(_ plan: RefreshPlan, store: VoiceOSStore) async {
        StartupTrace.mark("reload.begin")
        var contextsFroze = false
        if plan.coreSecondary {
            do {
                let snapshot = try await StartupTrace.measureAsync("reload.coreSecondarySnapshot") { try await store.workspaceSnapshot(.coreSecondary) }
                applyCoreSnapshot(snapshot, reminderAnomalies: try await store.reminderSyncAnomalies())
                workspaceLoaded = true
                StartupTrace.mark("reload.firstScreen")
                await validateCoreSelection(store: store)
                applySecondarySnapshot(snapshot)
                contextsFroze = snapshot.contextValidityChanged
                StartupTrace.mark("reload.coreSecondaryPublished")
            } catch { status = error.localizedDescription; reportWorkspaceError(error.localizedDescription, retry: .reload) }
        }
        if plan.assistant {
            do {
                let assistant = try await StartupTrace.measureAsync("reload.assistantSnapshot") { try await store.workspaceSnapshot(.assistant) }
                applyAssistantSnapshot(assistant)
                contextsFroze = contextsFroze || assistant.contextValidityChanged
                StartupTrace.mark("reload.assistantPublished")
                resumeAssistantExecutions(snapshot: contextsFroze ? nil : assistant)
            } catch { status = error.localizedDescription }
        }
        if plan.knowledge {
            do {
                let knowledge = try await StartupTrace.measureAsync("reload.knowledgeSnapshot") { try await store.workspaceSnapshot(.knowledge) }
                knowledgeReviews = knowledge.knowledgeReviews
                StartupTrace.mark("reload.knowledgePublished")
                resumeKnowledgeReviews()
            } catch { status = error.localizedDescription }
        }
    }
    private func validateCoreSelection(store: VoiceOSStore) async {
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
    }
    func chooseTextModel() {
        let panel = NSOpenPanel()
        panel.title = "选择本地文本模型配置"; panel.prompt = "使用配置"
        panel.showsHiddenFiles = true; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url { self.configureTextModel(url) }
        }
    }
    private func configureTextModel(_ file: URL, resume: Bool = true) {
        do {
            // 文件只作为导入入口：读取后把地址、密钥、模型与强度迁移进应用内部
            // 配置（密钥进钥匙串），之后不再依赖这个文件。
            let suite = try LocalTextModel.loadSuite(from: file, segmentRequestTimeout: 600, segmentStreaming: true)
            if let settings = try? LocalTextModel.inspect(file) {
                try? TextModelKeychain.save(settings.key)
                TextModelConfiguration(baseURL: settings.address.absoluteString, model: settings.model,
                                       noteEffort: settings.noteEffort, topicEffort: settings.topicEffort,
                                       reviewEffort: settings.reviewEffort).save()
                UserDefaults.standard.removeObject(forKey: "voiceos.textModelConfigPath.v1")
            }
            installTextModelSuite(suite, configurationName: file.lastPathComponent, resume: resume)
            UserDefaults.standard.set(false, forKey: "voiceos.textModelConfigurationCleared.v1")
            textConfigurationFile = file
        } catch {
            status = error.localizedDescription
            reportWorkspaceError(error.localizedDescription,retry:.textModel)
        }
    }
    /// 设置页保存内部配置：先让端口策略接受这份地址与密钥，再落盘；校验失败不留半保存状态。
    func applyTextModelConfiguration(_ config: TextModelConfiguration, apiKey: String) async -> Bool {
        guard let url = URL(string: config.baseURL) else { status = "服务地址无效"; return false }
        do {
            let suite = try LocalTextModel.loadSuite(
                settings: LocalTextModel.Settings(address: url, key: apiKey, model: config.model,
                                                  noteEffort: config.noteEffort, topicEffort: config.topicEffort,
                                                  reviewEffort: config.reviewEffort),
                segmentRequestTimeout: 600, segmentStreaming: true)
            do {
                try TextModelKeychain.save(apiKey)
            } catch {
                status = "无法把密钥保存到系统钥匙串：" + error.localizedDescription + "（请在弹窗中点「允许」后重试）"
                return false
            }
            config.save()
            UserDefaults.standard.removeObject(forKey: "voiceos.textModelConfigPath.v1")
            UserDefaults.standard.set(false, forKey: "voiceos.textModelConfigurationCleared.v1")
            textConfigurationFile = nil
            installTextModelSuite(suite, configurationName: config.model, resume: true)
            return true
        } catch {
            status = "配置未保存：" + error.localizedDescription + "；可先点「测试连接」确认服务"
            return false
        }
    }
    /// 探针结果里带上规范化的候选地址，便于诊断 /v1 重复拼接这类问题。
    func textModelEndpointHint(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL) else { return "服务地址无效" }
        return url.appendingPathComponent("responses").absoluteString
    }
    /// 用给定配置发一次极小请求，验证地址、密钥与模型可用；返回面向用户的结果与延迟。
    func testTextModelConfiguration(_ config: TextModelConfiguration, apiKey: String) async -> String {
        guard let url = URL(string: config.baseURL)?.appendingPathComponent("responses") else { return "服务地址无效" }
        guard !apiKey.isEmpty else { return "没有可用的密钥：请填写后点「保存并启用」（若已在弹窗中拒绝钥匙串访问，请允许后重试）" }
        let payload: [String: Any] = ["model": config.model, "store": false,
            "reasoning": ["effort": "minimal"], "max_output_tokens": 32, "truncation": "disabled",
            "instructions": "你是连通性探针。只回复两个字符：ok",
            "input": [["role": "user", "content": "ping"]]]
        do {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let started = Date()
            let reply = try await DirectModelHTTPTransport().send(request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard reply.status == 200 else {
                let body = String(decoding: reply.body.prefix(200), as: UTF8.self)
                return "连接失败：HTTP \(reply.status) · \(url.absoluteString)" + (body.isEmpty ? "" : " · " + body)
            }
            guard let object = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
                  object["status"] is String else { return "连接失败：响应格式无效 · \(url.absoluteString)" }
            return "连接正常 · \(config.model) · \(ms) ms · \(url.absoluteString)"
        } catch {
            return "连接失败：" + error.localizedDescription + " · \(url.absoluteString)"
        }
    }
    /// 启动时优先使用应用内部配置；没有时才回退到开发用的配置文件路径。
    private func restoreInternalTextModelConfiguration() -> Bool {
        guard let config = TextModelConfiguration.load(),
              let key = TextModelKeychain.apiKey(),
              let url = URL(string: config.baseURL),
              let suite = try? LocalTextModel.loadSuite(
                settings: LocalTextModel.Settings(address: url, key: key, model: config.model,
                                                  noteEffort: config.noteEffort, topicEffort: config.topicEffort,
                                                  reviewEffort: config.reviewEffort),
                segmentRequestTimeout: 600, segmentStreaming: true) else { return false }
        installTextModelSuite(suite, configurationName: config.model, resume: false)
        return true
    }
    private func installTextModelSuite(_ suite: LocalTextModel.Suite, configurationName: String, resume: Bool) {
        // Long segmented cognition uses the explicitly validated SSE
        // transport and 600-second window. Its versioned identity prevents
        // queued non-streaming attempts from being silently replayed.
        let port = suite.cognition
        discussionModel=suite.discussion;outcomeModel=suite.outcome
        recordingTitleModel=suite.recordingTitles
        topicModel=suite.topics; topicAttemptDigest=nil; materialNoteModel=suite.note
        topicDomainBackfillStarted = false
        startTopicDomainBackfillIfNeeded()
        recordingExpressionModel=suite.recordingExpressions
        assistantModel=suite.assistant
        initiationModel=suite.initiation
        followupModel=suite.followup;englishModel=suite.english;associationModel=suite.association;reminderFieldModel=suite.reminderFields
        knowledgeReviewModel=suite.knowledgeReview
        relevance.cancel();relevanceModel=suite.relevance
        segmentExtractionModel=suite.segmentExtraction;segmentAggregationModel=suite.segmentAggregation
        monitorAnalysisModel=suite.notificationAnalysis
        textModel = port; modelConfigured = true
        modelSummary = configurationName + " · " + port.configuration.provider.replacingOccurrences(of: "responses:", with: "")
        status = "文本模型已就绪 · 只处理你选择并授权的文字"
        // 之前因配置未就绪而暂缓的录音，现在立刻续上，不等暂缓间隔到期。
        recordingInbox.resumeDeferred()
        // A queued intent may have been restored before the user selected a
        // configuration. Wake the durable worker exactly once after the
        // new model identity is installed; scheduleProcessing() itself
        // remains the single-owner gate for concurrent work. Startup defers
        // this to after the first screen so model work cannot hold the store
        // actor while the library is opening.
        if resume {
            scheduleProcessing()
            queueRecordingTitles()
            resumeRecordingFollowups()
            resumeAssistantExecutions()
            resumeKnowledgeReviews()
            queueTopicOrganization()
        }
    }
    /// Clears every model port so AI entries read as unconfigured, and remembers
    /// the choice so the bundle's development .env is not reloaded on launch.
    func clearTextModel() {
        discussionModel = nil
        outcomeModel = nil
        recordingTitleModel = nil
        topicModel = nil; topicAttemptDigest = nil
        materialNoteModel = nil
        recordingExpressionModel = nil
        assistantModel = nil
        initiationModel = nil
        followupModel = nil
        englishModel = nil
        associationModel = nil
        reminderFieldModel = nil
        knowledgeReviewModel = nil
        relevance.cancel(); relevanceModel = nil
        segmentExtractionModel = nil
        segmentAggregationModel = nil
        monitorAnalysisModel = nil
        textModel = nil
        textConfigurationFile = nil
        modelConfigured = false
        modelSummary = "尚未配置文本模型"
        UserDefaults.standard.removeObject(forKey: "voiceos.textModelConfigPath.v1")
        TextModelConfiguration.clear()
        TextModelKeychain.delete()
        UserDefaults.standard.set(true, forKey: "voiceos.textModelConfigurationCleared.v1")
        status = "已清除文本模型配置；AI 功能暂停，直到重新选择配置"
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
                    self.fullRecordingOutput = nil; self.fullRecordingImportIssue = nil
                    self.fullRecordingCompletedSourceID = nil
                    self.fullRecordingInput = FullRecordingInput(url: url, media: media)
                } catch { self.fullRecordingImportIssue = error.localizedDescription }
            }
        }
    }
    func importFullRecordingAsExternal(_ input: FullRecordingInput) {
        guard let store, !importing, !fullRecordingBusy else { fullRecordingStatus = "请等待当前处理结束"; return }
        importing = true
        fullRecordingStatus = "正在保存为外部资料…"
        Task {
            defer { importing = false }
            do {
                selected = try await store.importFile(input.url)
                fullRecordingInput = nil
                fullRecordingStatus = "已作为外部资料导入；原文件保留"
                await refresh(); scheduleProcessing()
            } catch { fullRecordingStatus = error.localizedDescription }
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
        // 自动入口的失败原因要能直接指向用户可修的那一项，而不是笼统的「请等待」。
        let blocker: String? = {
            if !initialized || !modelConfigured { return "文本模型尚未就绪；请先在设置中连接" }
            if !(speechPort is LocalQwenSpeechPort) { return "本地 Qwen 转写尚未配置" }
            if recordingExpressionModel == nil { return "文本模型端口尚未就绪" }
            if textModelOrganizerEnvironment == nil { return "文本模型配置不完整；请在设置中重新保存" }
            if Bundle.main.url(forResource:"organize_podcast",withExtension:"py") == nil { return "应用缺少完整整理脚本" }
            if organizingSourceID != nil || fullRecordingBusy { return "另一段录音正在整理；空闲后自动重试" }
            return nil
        }()
        guard blocker == nil,let store,var speech=speechPort as? LocalQwenSpeechPort,let grouping=recordingExpressionModel,
              let configuration=textModelOrganizerEnvironment,let script=Bundle.main.url(forResource:"organize_podcast",withExtension:"py"),organizingSourceID == nil,!fullRecordingBusy else {
            finished(Dictionary(uniqueKeysWithValues:batch.map { ($0.digest,.deferred(blocker ?? "前置条件尚未就绪，稍后自动继续")) }));return
        }
        fullRecordingBusy=true;fullRecordingCount=nil
        fullRecordingCompletedSourceID=nil
        fullRecordingWorker=Task {
            let refreshTask=watchFullRecording()
            var outcomes:[String:RecordingInboxOutcome]=[:]
            var firstProcessedID:String?
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
                        if firstProcessedID == nil { firstProcessedID = id }
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
                            try await FullRecordingOrganizer.organize(folder:folder,script:script,python:speech.pythonExecutable,modelEnvironment:configuration,log:log,reviewTranscriptOnly:true)
                            _ = try await store.applyTranscriptQualityResult(sourceID:id,expectedVersionID:version,from:folder)
                            try? await store.clearTranscriptionReviewFailure(sourceID: id)
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
                try await understandPendingRecordingExpressions(store:store,speech:speech,grouping:grouping,modelEnvironment:configuration,script:script)
                if let firstID = firstProcessedID {
                    fullRecordingCompletedSourceID = firstID
                    LocalNotice.post(title: "录音已整理", body: "这次录音的笔记、观点与任务已保存。", sourceID: firstID)
                }
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
    @discardableResult
    private func resumeSavedRecordingExpressions() async -> Task<Void, Never>? {
        guard !resumedSavedRecordingExpressions,organizingSourceID == nil,worker == nil,understandingWorker == nil,!dictationActive,!dictationBusy,let store,
              let speech=speechPort as? LocalQwenSpeechPort,let grouping=recordingExpressionModel,
              let configuration=textModelOrganizerEnvironment,let script=Bundle.main.url(forResource:"organize_podcast",withExtension:"py"),
              !fullRecordingBusy else { return nil }
        resumedSavedRecordingExpressions=true
        do {
            try await store.enrollPreviouslyImportedAutomaticRecordings()
            let corrected=try await store.sources().contains { $0.presentation?.correctedSourceIDs != nil }
            // A corrected programme deliberately invalidates the old pair. Repair
            // its saved versions before asking for fresh semantic grouping.
            let newInput=corrected ? nil : try await store.prepareRecordingExpressions()
            let pending=try await store.recordingExpressions().contains { $0.state != "completed" }
            try await acknowledgeCompletedRecordingExpressions(store:store)
            guard newInput != nil || pending || corrected else { return nil }
        } catch { setFullRecordingStatus(error.localizedDescription);return nil }
        fullRecordingBusy=true;fullRecordingCount=nil
        let task=Task {
            let refreshTask=watchFullRecording()
            defer { refreshTask.cancel();fullRecordingBusy=false;fullRecordingWorker=nil;fullRecordingLog=nil;fullRecordingSourceID=nil;scheduleProcessing();resumeRecordingFollowups();resumeKnowledgeReviews() }
            do {
                setFullRecordingStatus("正在为已接收录音补充连续表达判断，复用完整转写…")
                try await preparePendingCorrectedRecordingContexts()
                _ = try await store.connectRecordingExpressions(using:grouping)
                try await understandPendingRecordingExpressions(store:store,speech:speech,grouping:grouping,modelEnvironment:configuration,script:script)
                try await acknowledgeCompletedRecordingExpressions(store:store)
                requestReminderRefresh();queueRecordingTitles();queueTopicOrganization()
                setFullRecordingStatus("已接收录音的连续表达已整理，原始分段保留")
            } catch { setFullRecordingStatus("连续表达尚未整理完成，重开应用后继续："+error.localizedDescription) }
            await refresh()
        }
        fullRecordingWorker=task
        return task
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
    private func understandPendingRecordingExpressions(store:VoiceOSStore,speech:LocalQwenSpeechPort,grouping:ResponsesRecordingExpressionPort,modelEnvironment:[String:String],script:URL) async throws {
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
            try await FullRecordingOrganizer.organize(folders:folders,script:script,python:speech.pythonExecutable,modelEnvironment:modelEnvironment,log:log)
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
        if error is CancellationError { return .deferred("处理被中断，将从已保存的转写与分组继续") }
        // 按 HTTP 状态分类：408/429 与 5xx 是瞬时问题；401/403 是密钥或权限问题，需要用户处理。
        if let status = Self.httpStatus(in: message) {
            if status == 401 || status == 403 {
                return .needsAttention("文本服务拒绝访问（HTTP \(status)）；请检查模型密钥与权限，重新保存后重试")
            }
            if status == 408 || status == 429 || (500...599).contains(status) {
                return .retryableFailure(message)
            }
            return .needsAttention(message)
        }
        let temporary=["网络","timed out","connection","response.completed","本批录音","素材仍在更新","尚未完成","没有完成回执"]
        return temporary.contains { message.localizedCaseInsensitiveContains($0) } ? .retryableFailure(message) : .needsAttention(message)
    }
    private static func httpStatus(in message:String) -> Int? {
        guard let range=message.range(of: #"HTTP (\d{3})"#, options:.regularExpression) else { return nil }
        return Int(message[range].dropFirst(5))
    }
    /// 完成面板的「打开这篇笔记」：收起面板并打开这次录音的材料页。
    func openCompletedFullRecording(_ sourceID: String) {
        fullRecordingInput = nil
        requestWorkspaceSource(sourceID)
    }
    /// 只保存本人音轨、不转写不整理：转写或文本模型缺失时仍可先把原音留在本机。
    func saveFullRecordingOnly(_ input: FullRecordingInput, track: Int) {
        guard let store, !fullRecordingBusy, !importing else { status = "请等待当前处理结束"; return }
        fullRecordingBusy = true
        fullRecordingCompletedSourceID = nil
        fullRecordingCount = nil
        fullRecordingStatus = "正在保存本人音轨…"
        fullRecordingWorker = Task {
            defer { fullRecordingBusy = false; fullRecordingWorker = nil }
            do {
                // 与完整整理共用同一个幂等键：先「只保存原件」再「完整转写并整理」
                // 会复用同一份材料，重复点击也不会入库第二份。
                let attrs = try FileManager.default.attributesOfItem(atPath: input.url.path)
                let identity = input.url.path + ":\(track):" + String(describing: attrs[.size]) + ":" + String(describing: attrs[.modificationDate])
                let command = "full-recording:" + identity
                if let existing = try await store.importedSourceID(commandID: command) {
                    fullRecordingCompletedSourceID = existing
                    fullRecordingStatus = "这份本人音轨已保存过，未重复导入"
                    return
                }
                let root = await store.root
                let staging = root.appendingPathComponent("整理/仅保存原件")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let log = staging.appendingPathComponent("处理日志.txt")
                let audio = staging.appendingPathComponent(input.url.deletingPathExtension().lastPathComponent + "_音轨\(track).wav")
                if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
                try await FullRecordingOrganizer.extract(input.url, track: track, to: audio, log: log)
                let id = try await store.importPersonalAudio(audio, commandID: command)
                try FileManager.default.removeItem(at: audio)
                await refresh()
                fullRecordingCompletedSourceID = id
                fullRecordingStatus = "已保存本人音轨；配置模型后可再完整整理"
                LocalNotice.post(title: "录音已保存", body: "本人音轨已保存在本机，可在材料页查看。", sourceID: id)
            } catch is CancellationError {
                fullRecordingStatus = "已停止；原件保留在原处"
            } catch {
                fullRecordingStatus = error.localizedDescription
            }
        }
    }
    func organizeRecording(_ input: FullRecordingInput, track: Int, importCommand: String? = nil, finished: ((Bool) -> Void)? = nil) {
        guard FullRecordingOrganizer.decide(track: track, ownVoice: true, in: input.media).importsAsPersonal else {
            fullRecordingStatus = "完整整理只能使用本人音轨"
            lastRecordingOutcome = .needsAttention(fullRecordingStatus); finished?(false); return
        }
        guard let store, var speech = speechPort as? LocalQwenSpeechPort, organizingSourceID == nil, !fullRecordingBusy, worker == nil,
              understandingWorker == nil, !dictationActive, let configuration = textModelOrganizerEnvironment,
              let script = Bundle.main.url(forResource: "organize_podcast", withExtension: "py") else {
            fullRecordingStatus = organizingSourceID != nil ? "上一段口述正在后台整理，完成后可重新整理" : (recordingModelIssue ?? "请等待当前处理结束或重新打开资料库")
            lastRecordingOutcome = .needsAttention(fullRecordingStatus); finished?(false); return
        }
        fullRecordingBusy = true; fullRecordingCount = nil
        fullRecordingCompletedSourceID = nil
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
                    success = true; fullRecordingCompletedSourceID = id; setFullRecordingStatus("这份素材已完整整理，未重复调用模型"); return
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
                try await completeFullOrganization(sourceID: id, speech: speech, modelEnvironment: configuration, script: script)
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
    @discardableResult
    func organizeFullTranscript(_ record: SourceRecord) -> Task<Void, Never>? {
        if record.presentation?.expression != nil || record.presentation?.recordingContext != nil {
            guard !fullRecordingBusy,worker == nil,understandingWorker == nil else { status="当前录音仍在处理，完成后可重新整理";return nil }
            return Task {
                do { try await queueWholeRecordingUnderstanding(sourceID:record.id) }
                catch { status="原文已保留，整体整理尚未排入："+error.localizedDescription }
            }
        } else { return organizeSavedRecording(sourceID: record.id, transcribeFirst: false) }
    }
    private func queueWholeRecordingUnderstanding(sourceID:String) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        _ = try await store.queueRecordingUnderstanding(sourceID:sourceID,previousActionIDs:actionRecords.map(\.id))
        resumedSavedRecordingExpressions=false
        await refresh()
        status="已排入完整表达重新整理，保留原任务身份、完成与实际反馈。"
        guard let worker = await resumeSavedRecordingExpressions() else {
            throw VoiceOSError("整体整理未能开始；请确认本地转写与文本模型配置")
        }
        await worker.value
    }
    @discardableResult
    private func organizeSavedRecording(sourceID: String, transcribeFirst: Bool) -> Task<Void, Never>? {
        guard let inputs = savedRecordingOrganizationInputs() else { status = recordingModelIssue ?? "请先配置模型"; return nil }
        guard organizingSourceID == nil, !fullRecordingBusy, worker == nil, understandingWorker == nil else {
            status = organizingSourceID == nil ? "请等待当前处理结束" : "上一段口述正在后台整理，完成后可重新识别"; return nil
        }
        fullRecordingBusy = true; fullRecordingCount = nil; fullRecordingOutput = nil
        fullRecordingSourceID = sourceID
        let task = Task {
            let refreshTask = watchFullRecording()
            defer { refreshTask.cancel(); fullRecordingBusy = false; fullRecordingWorker = nil; fullRecordingLog = nil; fullRecordingSourceID = nil; scheduleProcessing(); resumeRecordingFollowups(); resumeKnowledgeReviews() }
            do { try await runSavedRecordingOrganization(sourceID: sourceID, transcribeFirst: transcribeFirst, inputs: inputs) }
            catch is CancellationError { setFullRecordingStatus("已停止；录音、逐字稿和已完成的整理结果保留") }
            catch { setFullRecordingStatus(error.localizedDescription) }
            await refresh()
        }
        fullRecordingWorker = task
        return task
    }
    private func enqueueBackgroundOrganization(sourceID: String) {
        guard organizingSourceID != sourceID, !backgroundOrganizationQueue.contains(sourceID) else { return }
        backgroundOrganizationQueue.append(sourceID)
        startBackgroundOrganizationIfIdle()
    }
    private func startBackgroundOrganizationIfIdle() {
        guard backgroundOrganizationWorker == nil, !backgroundOrganizationQueue.isEmpty else { return }
        backgroundOrganizationWorker = Task {
            defer { backgroundOrganizationWorker = nil }
            while !backgroundOrganizationQueue.isEmpty, !Task.isCancelled {
                while worker != nil || fullRecordingBusy || understandingWorker != nil || transcriptReviewSourceID != nil {
                    try? await Task.sleep(for: .milliseconds(400))
                    if Task.isCancelled { return }
                }
                let sourceID = backgroundOrganizationQueue.removeFirst()
                organizingSourceID = sourceID
                setFullRecordingStatus("上一段口述正在后台整理，可继续口述")
                let refreshTask = watchFullRecording()
                let title = records.first(where: { $0.id == sourceID })?.displayTitle ?? "上一段口述"
                do {
                    guard let inputs = savedRecordingOrganizationInputs() else { throw VoiceOSError(recordingModelIssue ?? "请先配置本地转写与文本模型") }
                    try await runSavedRecordingOrganization(sourceID: sourceID, transcribeFirst: true, inputs: inputs)
                    refreshTask.cancel()
                    setFullRecordingStatus("上一段口述已整理完成 · 可查看观点与任务")
                    recordCompletion(category: "口述整理", title: title, sourceID: sourceID)
                    LocalNotice.post(title: "口述整理完成", body: "「" + title + "」的观点与任务已保存。", sourceID: sourceID)
                } catch is CancellationError {
                    refreshTask.cancel()
                    setFullRecordingStatus("后台整理已停止；录音、逐字稿与已完成结果保留")
                } catch {
                    refreshTask.cancel()
                    let reason = error.localizedDescription
                    setFullRecordingStatus("上一段口述整理未完成：" + reason)
                    LocalNotice.post(title: "口述整理未完成", body: "「" + title + "」：" + reason, sourceID: sourceID)
                }
                processingActivity = nil
                fullRecordingLog = nil
                organizingSourceID = nil
                await refresh()
            }
            scheduleProcessing()
        }
    }
    private func savedRecordingOrganizationInputs() -> (speech: LocalQwenSpeechPort, configuration: [String: String], script: URL)? {
        guard let speech = speechPort as? LocalQwenSpeechPort, let configuration = textModelOrganizerEnvironment,
              let script = Bundle.main.url(forResource: "organize_podcast", withExtension: "py") else { return nil }
        return (speech, configuration, script)
    }
    private func runSavedRecordingOrganization(sourceID: String, transcribeFirst: Bool, inputs: (speech: LocalQwenSpeechPort, configuration: [String: String], script: URL)) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        var speech = inputs.speech
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
            if let failed = try await store.sources().first(where: { $0.id == sourceID && $0.jobState == "failed" }) {
                throw VoiceOSError(failed.error ?? "本地转写未完成；已保存的分段进度保留")
            }
            try Task.checkCancellation()
        }
        try await completeFullOrganization(sourceID: sourceID, speech: speech, modelEnvironment: inputs.configuration, script: inputs.script)
    }
    private func completeFullOrganization(sourceID: String, speech: LocalQwenSpeechPort, modelEnvironment: [String: String], script: URL) async throws {
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
        try await FullRecordingOrganizer.organize(folder: folder, script: script, python: speech.pythonExecutable, modelEnvironment: modelEnvironment, log: log, reviewTranscriptOnly: true)
        try Task.checkCancellation()
        _ = try await store.applyTranscriptQualityResult(sourceID: sourceID, expectedVersionID: version, from: folder)
        try? await store.clearTranscriptionReviewFailure(sourceID: sourceID)
        await refresh()
        setFullRecordingStatus("全文校正已保存，正在整理观点、任务与已有任务的接续…")
        try await FullRecordingOrganizer.organize(folder: folder, script: script, python: speech.pythonExecutable, modelEnvironment: modelEnvironment, log: log)
        try Task.checkCancellation()
        let count = try await store.ingestOrganizedPodcast(at: base, allowReminderWrites: reminderAccess?.enabled == true && reminderAccess?.title == "VoiceOS", requireAPIReview: true)
        fullRecordingCount = count
        fullRecordingOutput = base
        fullRecordingCompletedSourceID = sourceID
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
        if let sourceID = organizingSourceID {
            let label = message.hasPrefix("上一段口述") ? message : "上一段口述正在后台整理 · " + message
            if processingActivity?.sourceID != sourceID || processingActivity?.label != label {
                processingActivity = .init(sourceID: sourceID, label: label)
            }
        }
        if !dictationActive, !dictationBusy, status != message { status = message }
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
    private var followupEnqueueing = Set<String>()
    func refreshFollowup(_ sourceID: String) {
        guard followupEnqueueing.insert(sourceID).inserted else { return }
        Task {
            defer { followupEnqueueing.remove(sourceID) }
            do { _ = try await store?.enqueueRecordingFollowup(sourceID: sourceID, retry: true); await refresh(.interactive); resumeRecordingFollowups() }
            catch { followupStatus = error.localizedDescription }
        }
    }
    func retryAllFailedFollowups() {
        Task {
            for receipt in workspaceFailedFollowups {
                do { _ = try await store?.enqueueRecordingFollowup(sourceID: receipt.sourceID, retry: true) }
                catch { followupStatus = error.localizedDescription }
            }
            await refresh(.interactive); resumeRecordingFollowups()
        }
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
                    status = intent.state == .queued ? "个人表达已排队 · 原始录音仍在本机" : "已有处理回执：\(workspaceStateLabel(intent.state.rawValue))；未重复排队"
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
    @discardableResult
    func understandSegmented(_ record: SourceRecord) -> Task<Void, Never>? {
        guard let store,let extraction=segmentExtractionModel,let aggregation=segmentAggregationModel,
              understandingWorker == nil,!discussionExtracting,!record.localOnly,
              record.origin == "user",record.speaker == "user",["audio","user_text"].contains(record.kind),
              (record.transcript ?? "").unicodeScalars.count>4000 else { return nil }
        understandingSource=record.id;status="正在分段理解文字 · 原始音视频仍在本机"
        let task=Task {
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
                else { status="分段处理记录：\(workspaceStateLabel(result.state.rawValue)) · 未重复发送未知或已结束的请求" }
            } catch { status=error.localizedDescription }
            await refresh();requestReminderRefresh();resumeKnowledgeReviews()
            understandingSource=nil;understandingWorker=nil
        }
        understandingWorker=task
        return task
    }
    /// Explicit whole-batch retry for a long-recording batch whose model output
    /// failed local validation. The store keeps the rejected record as history
    /// and enqueues a fresh batch under a new command; this only drives it.
    @discardableResult
    func retrySegmentedBatch(_ batch: SegmentedProcessingBatch) -> Task<Void, Never>? {
        guard let store,let extraction=segmentExtractionModel,let aggregation=segmentAggregationModel,
              understandingWorker == nil,!discussionExtracting else { return nil }
        let sourceID=batch.scope.plan.source.sourceID
        understandingSource=sourceID;status="正在整批重试长录音的分段理解 · 原文与旧记录保留"
        let task=Task {
            do {
                let fresh=try await store.retryRejectedSegmentedBatch(id:batch.id,extraction:extraction.configuration,aggregation:aggregation.configuration)
                segmentedBatches=try await store.segmentedProcessingBatches()
                let result=try await store.processSegmentedCognition(batchID:fresh.id,extraction:extraction,aggregation:aggregation)
                if let ids=result.claimIDs {
                    status="长表达认知已保存 · \(ids.count) 条候选；正在核对历史关联"
                    await associateUnderstoodExpression(sourceID,segmentedBatchID:fresh.id)
                    status="长表达认知已保存 · \(ids.count) 条候选；"+(associationStatuses[sourceID] ?? "关联未完成")
                }
                else { status="分段重试记录：\(workspaceStateLabel(result.state.rawValue)) · 未重复发送未知或已结束的请求" }
            } catch { status=error.localizedDescription }
            await refresh();requestReminderRefresh();resumeKnowledgeReviews()
            understandingSource=nil;understandingWorker=nil
        }
        understandingWorker=task
        return task
    }
    func cancelSegmented(_ id: String) {
        guard let store else { return }
        Task {
            do { _ = try await store.cancelSegmentedProcessingBatch(id:id);status="已停止分段处理 · 原文与处理历史保留" }
            catch { status=error.localizedDescription }
            await refresh()
        }
    }

    var workspaceBusySourceIDs: Set<String> {
        var busy = Set<String>()
        if let understandingSource { busy.insert(understandingSource) }
        if fullRecordingBusy, let fullRecordingSourceID { busy.insert(fullRecordingSourceID) }
        if let sourceID = processingActivity?.sourceID { busy.insert(sourceID) }
        if let transcriptReviewSourceID { busy.insert(transcriptReviewSourceID) }
        for intent in processingIntents where intent.state == .queued || intent.state == .running { busy.insert(intent.sourceID) }
        for batch in segmentedBatches where batch.state == .queued { busy.insert(batch.scope.plan.source.sourceID) }
        for request in recordingRequests where request.state == "waiting" || request.state == "enqueued" { busy.insert(request.sourceID) }
        return busy
    }

    var pausedActionBatchPreview: PausedActionBatchPlan {
        var snapshot = WorkspaceSnapshot()
        snapshot.sources = records
        snapshot.claims = claims
        snapshot.currentClaimsBySource = currentClaimsBySource
        snapshot.actions = actionRecords
        snapshot.actionReviewLedgers = actionReviewLedgers
        snapshot.processingIntents = processingIntents
        snapshot.segmentedBatches = segmentedBatches
        snapshot.recordingRequests = recordingRequests
        return PausedActionBatch.plan(snapshot: snapshot, additionallyBusySources: workspaceBusySourceIDs)
    }

    var pausedActionBatchUnavailableReason: String? {
        if pausedActionBatch?.isRunning == true || isPausedActionBatchConfirming { return "另一批重新识别正在进行" }
        if !modelConfigured || textModel == nil { return "需要先配置文本模型" }
        if sourceReidentifyWorker != nil || understandingWorker != nil || fullRecordingBusy || transcriptReviewSourceID != nil ||
            processingActivity != nil || worker != nil || importing || dictationActive || dictationBusy || discussionExtracting {
            return "另一项处理正在进行，完成后再继续"
        }
        return nil
    }

    private var isPausedActionBatchConfirming: Bool {
        if case .some(.confirming) = pausedActionBatch?.phase { return true }
        return false
    }

    func preparePausedActionBatch() async {
        guard let store else { status = "资料库尚未打开"; return }
        do {
            let snapshot = try await store.workspaceSnapshot()
            let plan = PausedActionBatch.plan(snapshot: snapshot, additionallyBusySources: workspaceBusySourceIDs)
            guard plan.isBatchable else { status = "没有可以批量重新识别的暂停待办。"; return }
            pausedActionBatch = PausedActionBatchRun(plan: plan, phase: .confirming, stopRequested: false)
        } catch { status = error.localizedDescription }
    }

    func startPausedActionBatch() {
        guard let run = pausedActionBatch, case .confirming = run.phase, pausedActionBatchWorker == nil else { return }
        pausedActionBatch?.phase = .running(PausedActionBatchProgress(done: 0, total: run.plan.targets.count,
                                                                      currentSourceID: nil, currentTitle: ""))
        pausedActionBatch?.stopRequested = false
        let plan = run.plan
        pausedActionBatchWorker = Task { await runPausedActionBatch(plan) }
    }

    func stopPausedActionBatch() {
        guard pausedActionBatch?.isRunning == true else { return }
        // Stop is cooperative: the in-flight model call must finish rather than
        // become an unknown result.
        pausedActionBatch?.stopRequested = true
    }

    func cancelPausedActionBatch() {
        guard pausedActionBatch?.isRunning != true else { return }
        pausedActionBatch = nil
    }

    func dismissPausedActionBatch() { cancelPausedActionBatch() }

    private func runPausedActionBatch(_ plan: PausedActionBatchPlan) async {
        var updated: [PausedActionBatchSummary.Updated] = []
        var skipped: [PausedActionBatchSummary.Skipped] = []
        var failed: [PausedActionBatchSummary.Failed] = []
        var stoppedRemaining = 0
        for (index, target) in plan.targets.enumerated() {
            if pausedActionBatch?.stopRequested == true {
                stoppedRemaining = plan.targets.count - index
                break
            }
            pausedActionBatch?.phase = .running(PausedActionBatchProgress(done: index, total: plan.targets.count,
                                                                          currentSourceID: target.sourceID,
                                                                          currentTitle: title(for: target.sourceID)))
            let before = await evaluatePausedActionIDs(target.actionIDs)
            if before.remaining.isEmpty {
                skipped.append(.init(sourceID: target.sourceID, reason: .noLongerPaused, message: nil))
                continue
            }
            let receipt = await reidentifySource(target.sourceID)
            switch receipt {
            case .skipped(let reason):
                skipped.append(.init(sourceID: target.sourceID, reason: reason, message: nil))
            case .failed(let message):
                let after = await evaluatePausedActionIDs(target.actionIDs)
                failed.append(.init(sourceID: target.sourceID, message: message, remainingActionIDs: after.remaining))
            case .finished(let reused):
                let after = await evaluatePausedActionIDs(target.actionIDs)
                if after.remaining.isEmpty {
                    updated.append(.init(sourceID: target.sourceID, reused: reused))
                } else {
                    let explanation = await pauseExplanation(for: target.sourceID)
                    failed.append(.init(sourceID: target.sourceID,
                                        message: explanation + "（仍有 \(after.remaining.count) 条暂停待办）",
                                        remainingActionIDs: after.remaining))
                }
            }
            await refresh()
        }
        await refresh()
        requestReminderRefresh()
        let allActionIDs = Array(Set(plan.targets.flatMap(\.actionIDs))).sorted()
        let final = await evaluatePausedActionIDs(allActionIDs)
        pausedActionBatch?.phase = .finished(PausedActionBatchSummary(
            updated: updated, skipped: skipped, failed: failed, stoppedRemaining: stoppedRemaining,
            resolvedActionIDs: final.resolved, remainingActionIDs: final.remaining,
            reviewOnlyActionIDs: plan.reviewOnlyActionIDs, withdrawnActionIDs: plan.withdrawnActionIDs,
            unattachedActionIDs: plan.unattachedActionIDs))
        pausedActionBatch?.stopRequested = false
        pausedActionBatchWorker = nil
        scheduleProcessing()
    }

    func reidentify(_ record: SourceRecord) {
        guard sourceReidentifyWorker == nil, understandingWorker == nil, pausedActionBatch?.isRunning != true else { return }
        understandingSource = record.id
        sourceReidentifyWorker = Task {
            _ = await reidentifySource(record.id)
            await refresh(); requestReminderRefresh(); resumeKnowledgeReviews()
            understandingSource = nil
            sourceReidentifyWorker = nil
        }
    }

    private func reidentifySource(_ sourceID: String) async -> SourceReidentifyReceipt {
        guard let store else { return .failed("资料库尚未打开") }
        guard let source = try? await store.sources().first(where: { $0.id == sourceID }) else { return .failed("材料已不存在") }
        guard let textModel else { return .failed("需要先配置文本模型") }
        let localRetrieval: any LocalRetrievalPort
        if let semanticRetrieval { localRetrieval = semanticRetrieval } else { localRetrieval = retrieval }
        do {
            switch PausedActionBatch.route(for: source) {
            case .textUnderstanding:
                try await ensureTranscriptReviewed(sourceID: sourceID)
                let result = try await store.reidentifySource(
                    SourceReidentificationRequest(sourceID: sourceID, pausedActionIDs: pausedActionIDs(for: sourceID),
                                                  cognition: textModel.configuration,
                                                  association: associationModel?.configuration,
                                                  semantic: semanticRetrieval != nil),
                    cognitionPort: textModel, associationPort: associationModel, retrieval: localRetrieval)
                applyReidentificationResult(result)
                if case .completed = result, !isPersonal(source) {
                    await associateUnderstoodExpression(sourceID)
                    await processFollowup(sourceID: sourceID)
                }
                switch result {
                case .completed(let report):
                    if report.remainingActionIDs.isEmpty { return .finished(reused: report.reused) }
                    let explanation = await pauseExplanation(for: sourceID)
                    return .failed(explanation + "（仍有 \(report.remainingActionIDs.count) 条暂停待办）")
                case .skipped(let reason):
                    return .skipped(reason)
                case .failed(let message):
                    return .failed(message)
                }
            case .segmented:
                guard let task = understandSegmented(source) else { return .failed("当前条件不能分段重新识别") }
                await task.value
                return await finishedByEvaluation(sourceID)
            case .wholeRecording:
                guard let task = organizeFullTranscript(source) else { return .failed("当前条件不能按完整录音重新识别") }
                await task.value
                return await finishedByEvaluation(sourceID)
            }
        } catch is CancellationError {
            return .skipped(.noLongerPaused)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func applyReidentificationResult(_ result: SourceReidentificationResult) {
        switch result {
        case .completed(let report):
            status = (report.reused ? "沿用已有理解" : "理解完成") + " · \(report.claimIDs.count) 条候选待核对"
        case .skipped:
            status = "已跳过这次重新识别 · 原文与历史保留"
        case .failed(let message):
            status = message
        }
    }

    private func isPersonal(_ source: SourceRecord) -> Bool {
        source.origin == "user" && source.speaker == "user" && ["user_text", "audio"].contains(source.kind)
    }

    private func pausedActionIDs(for sourceID: String) -> [String] {
        let references = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0.references) })
        return actionRecords.filter { action in
            guard action.kind == "task",
                  references[action.claimID]?.contains(where: { $0.sourceID == sourceID }) == true,
                  let reason = WorkspaceActionPause.reason(for: action, sources: records, claims: claims,
                                                           currentClaimsBySource: currentClaimsBySource,
                                                           actions: actionRecords,
                                                           ledgers: actionReviewLedgers) else { return false }
            return reason == .extractionPaused
        }.map(\.id).sorted()
    }

    private func evaluatePausedActionIDs(_ actionIDs: [String]) async -> (resolved: [String], remaining: [String], reasons: [String: WorkspaceActionPauseReason]) {
        guard !actionIDs.isEmpty else { return ([], [], [:]) }
        guard let store else { return ([], actionIDs, [:]) }
        guard let snapshot = try? await store.workspaceSnapshot(.coreSecondary) else { return ([], actionIDs, [:]) }
        return WorkspaceActionPause.evaluate(actionIDs: actionIDs, sources: snapshot.sources, claims: snapshot.claims,
                                             currentClaimsBySource: snapshot.currentClaimsBySource, actions: snapshot.actions,
                                             ledgers: snapshot.actionReviewLedgers)
    }

    private func pauseExplanation(for sourceID: String) async -> String {
        guard let store else { return "仍有待办保持暂停，请打开材料查看原因。" }
        return (try? await store.understandingPauseExplanation(sourceID: sourceID)) ?? "仍有待办保持暂停，请打开材料查看原因。"
    }

    private func finishedByEvaluation(_ sourceID: String) async -> SourceReidentifyReceipt {
        let evaluation = await evaluatePausedActionIDs(pausedActionIDs(for: sourceID))
        if evaluation.remaining.isEmpty { return .finished(reused: false) }
        let explanation = await pauseExplanation(for: sourceID)
        return .failed(explanation + "（仍有 \(evaluation.remaining.count) 条暂停待办）")
    }

    private func title(for sourceID: String) -> String {
        records.first(where: { $0.id == sourceID })?.displayTitle ?? ""
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
    var canUnderstandCapturedText: Bool { modelConfigured && understandingWorker == nil && !discussionExtracting }
    func saveCapturedText(_ text: String, title: String, ownership: TextCaptureOwnership, allowCloud: Bool, commandID: String) async -> String? {
        guard let store else { return nil }
        let process = allowCloud && canUnderstandCapturedText
        do {
            let id = try await store.recordCapturedText(text, title: title, ownership: ownership, commandID: commandID)
            let policy = try await store.sourcePolicy(sourceID: id)
            if policy.localOnly != !process {
                _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: !process)
            }
            await refresh()
            guard process else {
                status = allowCloud ? "完整原文已保存 · 仅本机；模型暂不可用" : "完整原文已保存 · 仅本机"
                return id
            }
            guard canUnderstandCapturedText, let record = records.first(where: { $0.id == id }) else {
                status = "完整原文已保存；模型暂不可用，可稍后从资料页整理。"; return id
            }
            if ownership == .personal, text.unicodeScalars.count > 4000 { understandSegmented(record) }
            else { understand(record) }
            return id
        } catch { status = error.localizedDescription; await refresh(); return nil }
    }
    func acceptCaptureURL(_ url: URL) async -> Bool {
        guard let link = CaptureLink.parse(url) else { status = "抓取链接无效，未保存"; return false }
        return await acceptCaptureRequest(text: link.text, title: link.title, url: link.url, successURL: link.successURL) != nil
    }
    /// 保存一段抓取内容；成功返回材料 id，供调用方收起界面并回到这次内容。
    @discardableResult
    func acceptCaptureRequest(text: String?, title: String?, url: String?, successURL: URL?, context: String? = nil) async -> String? {
        guard let store else { status = "资料库尚未打开，未保存"; return nil }
        let body = [text, url].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        guard let body else { status = "抓取内容为空，未保存"; return nil }
        let metadataURL = url.flatMap { value -> String? in
            guard let scheme = URL(string: value)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return value
        }
        let commandID = CaptureDedupe.commandID(text: body)
        let previousID = try? await store.importedSourceID(commandID: commandID)
        do {
            let id = try await store.recordCapturedText(body, title: title ?? "", ownership: .external, sourceURL: metadataURL, captureContext: context, commandID: commandID)
            let policy = try await store.sourcePolicy(sourceID: id)
            if !policy.localOnly { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: true) }
            await refresh()
            if let successURL, let callback = CaptureLink.successCallback(successURL, sourceID: id) { NSWorkspace.shared.open(callback) }
            status = previousID == nil ? "已存入外部资料，仅本机保存" : "与刚才的内容相同，已合并"
            return id
        } catch {
            status = "抓取未保存：" + error.localizedDescription
            await refresh()
            return nil
        }
    }
    func captureClipboardText() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "剪贴板没有文字"; return }
        let context = FrontContextReader.current()?.display
        Task { _ = await acceptCaptureRequest(text: text, title: nil, url: nil, successURL: nil, context: context) }
    }
    func captureClipboardHistory(_ text: String) {
        Task { _ = await acceptCaptureRequest(text: text, title: nil, url: nil, successURL: nil, context: "剪贴板历史") }
    }
    func chooseWatchFolder() {
        guard makeFolderWatch() != nil else { status = "资料库尚未打开，无法监听文件夹"; return }
        let panel = NSOpenPanel(); panel.title = "选择要监听的文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.startWatchingFolder(url)
            }
        }
    }
    func stopWatchingFolder() {
        guard folderWatch?.isWatching == true else { return }
        folderWatch?.stop()
        status = "已停止监听文件夹"
    }
    private func startWatchingFolder(_ url: URL) {
        guard let watch = makeFolderWatch() else { status = "资料库尚未打开，无法监听文件夹"; return }
        if watch.start(folder: url) { status = "正在监听文件夹：" + url.lastPathComponent }
        else { status = "无法监听文件夹：" + url.lastPathComponent }
    }
    private func resumeFolderWatch() {
        makeFolderWatch()?.resume()
    }
    private func makeFolderWatch() -> FolderWatch? {
        if let existing = folderWatch { return existing }
        guard store != nil, let root = libraryRoot else { return nil }
        let watch = FolderWatch(root: root)
        watch.onFiles = { [weak self] urls in
            guard let self else { return false }
            return await self.acceptDroppedFiles(urls)
        }
        folderWatch = watch
        return watch
    }
    @discardableResult
    func acceptDroppedFiles(_ urls: [URL]) async -> Bool {
        var media: [URL] = [], textFiles: [URL] = [], images: [URL] = [], pdfs: [URL] = [], unsupported: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "txt" || ext == "md" { textFiles.append(url) }
            else if ext == "pdf" { pdfs.append(url) }
            else if SourceAttachment.mime(forFileExtension: ext) != nil { images.append(url) }
            else if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) || type.conforms(to: .movie) { media.append(url) }
            else { unsupported.append(url.lastPathComponent) }
        }
        var succeeded = true
        recentFileImportResults = []
        if !media.isEmpty, !(await importFiles(media, notify: false)) { succeeded = false }
        var results = recentFileImportResults
        for url in textFiles {
            let savedID = await importCapturedTextFile(url)
            results.append(.init(fileName: url.lastPathComponent, succeeded: savedID != nil, message: savedID != nil ? "已保存文字" : status, sourceID: savedID))
            if savedID == nil { succeeded = false }
        }
        for url in pdfs {
            let savedID = await acceptPDFCapture(url)
            results.append(.init(fileName: url.lastPathComponent, succeeded: savedID != nil, message: savedID != nil ? "已读取 PDF 文字，仅本机保存" : status, sourceID: savedID))
            if savedID == nil { succeeded = false }
        }
        for url in images {
            let savedID = await acceptImageCapture(url)
            results.append(.init(fileName: url.lastPathComponent, succeeded: savedID != nil, message: savedID != nil ? "已识别图片文字，仅本机保存" : status, sourceID: savedID))
            if savedID == nil { succeeded = false }
        }
        if !unsupported.isEmpty {
            status = "暂不支持这些文件类型：" + unsupported.joined(separator: "、")
            results.append(contentsOf: unsupported.map { .init(fileName: $0, succeeded: false, message: "暂不支持这种文件格式") })
        }
        if urls.count > 1 { importReport = ImportBatchReport(results: results) }
        notifyImportFinished(results)
        return succeeded
    }
    private func importCapturedTextFile(_ url: URL) async -> String? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "文字文件为空，未保存"; return nil }
            return await acceptCaptureRequest(text: text, title: nil, url: nil, successURL: nil)
        } catch { status = "无法读取文字文件：" + error.localizedDescription; return nil }
    }
    private func acceptImageCapture(_ url: URL) async -> String? {
        guard let store else { status = "资料库尚未打开，未保存"; return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let text: String
        do { text = try await ImageOCR.recognize(fileURL: url) }
        catch { status = "图片识别失败：" + error.localizedDescription; return nil }
        do {
            let title = String(url.deletingPathExtension().lastPathComponent.prefix(100))
            let id = try await store.recordCapturedText(text, title: title, ownership: .external, commandID: UUID().uuidString)
            let policy = try await store.sourcePolicy(sourceID: id)
            if !policy.localOnly { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: true) }
            await refresh()
            do {
                _ = try await store.attachSourceFile(sourceID: id, fileURL: url)
                status = "已识别图片文字，仅本机保存"
            } catch { status = "已识别图片文字，原图保存失败：" + error.localizedDescription }
            return id
        } catch {
            status = error.localizedDescription
            await refresh()
            return nil
        }
    }
    private func acceptPDFCapture(_ url: URL) async -> String? {
        guard let store else { status = "资料库尚未打开，未保存"; return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let text: String
        do { text = try await Task.detached(priority: .userInitiated) { try PDFText.extract(fileURL: url).text }.value }
        catch { status = "PDF 读取失败：" + error.localizedDescription; return nil }
        do {
            let title = String(url.deletingPathExtension().lastPathComponent.prefix(100))
            let id = try await store.recordCapturedText(text, title: title, ownership: .external, commandID: UUID().uuidString)
            let policy = try await store.sourcePolicy(sourceID: id)
            if !policy.localOnly { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: true) }
            await refresh()
            do {
                _ = try await store.attachSourceFile(sourceID: id, fileURL: url)
                status = "已读取 PDF「\(url.lastPathComponent)」的文字，仅本机保存"
            } catch { status = "已读取 PDF 文字，原件保存失败：" + error.localizedDescription }
            return id
        } catch {
            status = error.localizedDescription
            await refresh()
            return nil
        }
    }
    func ocrImage(_ url: URL) async -> (text: String, title: String)? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try await ImageOCR.recognize(fileURL: url)
            return (text, String(url.deletingPathExtension().lastPathComponent.prefix(100)))
        } catch {
            status = "图片识别失败：" + error.localizedDescription
            return nil
        }
    }
    func export(includeMedia: Bool) {
        guard !exporting else { return }
        let panel = NSSavePanel()
        panel.title = includeMedia ? "导出资料与原件" : "导出结构化资料"
        panel.nameFieldStringValue = "VoiceOS-导出-" + ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.prompt = "导出"
        panel.begin { response in
            guard response == .OK, let url = panel.url, let store = self.store else { return }
            self.exporting = true
            Task {
                defer { self.exporting = false }
                do { try await store.exportPackage(to: url, includeMedia: includeMedia); self.status = "已导出资料" + (includeMedia ? "和完整原件" : "；原件未包含，可另选打包") }
                catch {
                    self.status = error.localizedDescription
                    self.reportWorkspaceError(error.localizedDescription,retry:.export(includeMedia: includeMedia))
                }
            }
        }
    }
    func clearWorkspaceError() {
        workspaceLastError = nil
        workspaceLastErrorRetry = nil
    }
    func retryWorkspaceError() {
        let retry = workspaceLastErrorRetry
        clearWorkspaceError()
        switch retry {
        case .localSpeech: chooseLocalSpeech()
        case .textModel: chooseTextModel()
        case .export(let includeMedia): export(includeMedia: includeMedia)
        case .reload: Task { await refresh(.full) }
        case nil: break
        }
    }
    private func reportWorkspaceError(_ message: String, retry: WorkspaceErrorRetry) {
        workspaceLastError = message
        workspaceLastErrorRetry = retry
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
    @discardableResult
    func importFiles(_ urls: [URL], personalAudio: Bool = false, notify: Bool = true) async -> Bool {
        guard let store, !importing else { return false }
        importing = true
        defer { importing = false }
        var results: [ImportFileResult] = []
        var importedIDs: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            status = "正在保存：\(url.lastPathComponent)"
            do {
                let id = personalAudio ? try await store.importPersonalAudio(url) : try await store.importFile(url)
                selected = id
                importedIDs.append(id)
                recordCompletion(category: "导入", title: url.lastPathComponent, sourceID: id)
                results.append(.init(fileName: url.lastPathComponent, succeeded: true, message: speechConfigured ? "已保存原件，正在本地转写" : "已保存原件；配置本地 Qwen 后可转写", sourceID: id))
            } catch {
                status = error.localizedDescription
                results.append(.init(fileName: url.lastPathComponent, succeeded: false, message: error.localizedDescription))
            }
            if access { url.stopAccessingSecurityScopedResource() }
            await refresh()
        }
        let failures = results.filter { !$0.succeeded }.count
        recentFileImportResults = results
        if urls.count > 1 {
            importReport = ImportBatchReport(results: results)
            if failures > 0 { status = "导入完成 · 成功 \(urls.count - failures) 份，失败 \(failures) 份 · 逐文件结果见导入结果" }
        }
        if failures == 0 { status = "已可靠保存 \(urls.count) 个原件 · 正在本地转写" }
        scheduleProcessing()
        if failures == 0 { status = "导入完成 · 可查看原件和转写状态" }
        if notify { notifyImportFinished(results, importedIDs: importedIDs) }
        return failures == 0
    }
    private func notifyImportFinished(_ results: [ImportFileResult], importedIDs: [String] = []) {
        guard !results.isEmpty else { return }
        let failures = results.filter { !$0.succeeded }
        var remainingIDs = importedIDs.makeIterator()
        let succeededIDs = results.compactMap { $0.succeeded ? remainingIDs.next() : nil }
        let sourceID = succeededIDs.count == 1 ? succeededIDs[0] : nil
        if failures.isEmpty {
            let next = speechConfigured ? "正在本地转写。" : "配置本地 Qwen 后可转写。"
            LocalNotice.post(title: "导入完成", body: "已可靠保存 \(results.count) 份材料，" + next, sourceID: sourceID)
        } else {
            let detail = failures.prefix(3).map { $0.fileName + "：" + $0.message }.joined(separator: "；")
            LocalNotice.post(title: "导入未全部完成", body: "成功 \(results.count - failures.count) 份，失败 \(failures.count) 份。" + detail + (failures.count > 3 ? "；等" : ""), sourceID: sourceID)
        }
    }
    private func scheduleProcessing() {
        guard worker == nil, organizingSourceID == nil, !fullRecordingBusy, !dictationActive,
              pausedActionBatch?.isRunning != true, sourceReidentifyWorker == nil else { return }
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
                } else { status = "表达处理状态：\(workspaceStateLabel(result.state.rawValue))" }
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
    func retryRecordingRequest(_ request: RecordingProcessingRequest) async {
        guard let store, let cognition = textModel, let association = associationModel else {
            status = "请先配置理解与关联模型，再重新核对录音处理"; return
        }
        do {
            try await store.retryRecordingProcessingRequest(id: request.id)
            try await store.reconcileRecordingProcessingRequests(cognition: cognition.configuration, association: association.configuration,
                segmentExtraction: segmentExtractionModel?.configuration, segmentAggregation: segmentAggregationModel?.configuration)
            if let latest = try await store.recordingProcessingRequests().first(where: { $0.id == request.id }), latest.state == "blocked" {
                status = "重新核对后仍受当前条件限制" + (latest.error.map { "：" + $0 } ?? "")
            } else { status = "已按当前条件重新核对录音处理请求" }
            await refresh()
            scheduleProcessing()
        } catch { status = error.localizedDescription; await refresh() }
    }
    func cancelProcessingIntent(_ intent: ExpressionProcessingIntentRecord) async {
        guard let store, [.queued, .running].contains(intent.state) else { return }
        do {
            _ = try await store.cancelExpressionProcessingIntent(id: intent.id, reason: "用户从处理记录取消")
            status = "已取消表达处理 · 已发出的模型请求保留历史，不自动重发"
            await refresh()
        } catch { status = error.localizedDescription; await refresh() }
    }
    func reprocessProcessingIntent(_ intent: ExpressionProcessingIntentRecord) async {
        guard let store else { return }
        guard let cognition = textModel else { status = "请先配置文字模型，再重新理解"; return }
        do {
            let created = try await store.reprocessExpressionProcessingIntent(id: intent.id, cognition: cognition.configuration,
                association: associationModel?.configuration)
            status = created.state == .queued ? "已用新的处理命令重新理解 · 旧结果保留为历史" : "已重新排队理解"
            await refresh()
            scheduleProcessing()
        } catch { status = error.localizedDescription; await refresh() }
    }
    func ignoreProcessingIntent(_ intent: ExpressionProcessingIntentRecord) async {
        guard let store else { return }
        do {
            _ = try await store.ignoreExpressionProcessingIntent(id: intent.id, reason: "用户选择不再处理这次失败")
            status = "已忽略这次理解失败 · 原文与处理记录保留"
            await refresh()
        } catch { status = error.localizedDescription; await refresh() }
    }
    func stopPlayback() {
        playbackGeneration += 1
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
            let generation = playbackGeneration
            let playback = AVPlayer(url: url)
            player = playback
            await playback.seek(to: CMTime(value: Int64(milliseconds), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard playbackGeneration == generation, player === playback else { return false }
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
        reminderLastError = ""
        do {
            reminderCalendars = try await reminders.authorize()
            proposedReminderCalendarID = reminderCalendarID
            choosingReminderCalendar = true
            status = "请选择明确授权的清单 · 本次尚未更改连接"
            reminderSyncStatus = "系统权限可用 · 清单授权范围保持原设置"
        } catch {
            status = error.localizedDescription
            reminderLastError = error.localizedDescription
            reminderSyncStatus = "系统权限核对未完成 · 保留既有连接"
        }
    }
    func saveReminderConnection() async {
        guard !remindersBusy else { return }
        guard let store, let calendar = reminderCalendars.first(where: { $0.id == proposedReminderCalendarID }) else { return }
        remindersBusy = true; defer { remindersBusy = false }
        do {
            reminderAccess = try await store.setReminderAccess(calendarID: calendar.id, title: calendar.title, enabled: true, expectedVersion: reminderAccess?.version ?? 0)
            choosingReminderCalendar = false
            reminderLastError = ""
            status = "提醒事项持续授权已保存"
            reminderSyncStatus = "正在核对所选清单的任务"
            await refresh(); requestReminderRefresh()
        } catch {
            status = error.localizedDescription
            reminderLastError = error.localizedDescription
        }
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
        } catch {
            remindersBusy = false
            status = error.localizedDescription
            reminderLastError = error.localizedDescription
        }
    }
    func disconnectReminders() async {
        guard let store, let access = reminderAccess else { return }
        do {
            _ = try await store.setReminderAccess(calendarID: access.calendarID, title: access.title, enabled: false, expectedVersion: access.version)
            reminderRefresh.stop()
            reminderLastError = ""
            await refresh(); reminderSyncStatus = "提醒事项连接已暂停 · 外部任务和历史保留"
        } catch {
            status = error.localizedDescription
            reminderLastError = error.localizedDescription
        }
    }
    /// Reuses the reminder compensation lifecycle for completions the correction
    /// table cannot express: `reminder_compensation_plans` is gated on a
    /// correction impact and its executor writes due dates, so the local half of
    /// this write-readback pair is persisted here and replayed after reconnect.
    private func changeLinkedActionLocally(_ action: ActionRecord, state: LocalActionState, link: ReminderLink,
                                           externalID: String, successorID: String?) async throws -> ActionChangeReceipt {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        if state == .completed {
            let successor = try await store.completeActionWithRecurrence(id: action.id)
            enqueuePendingReminderSync(action, link: link, externalID: externalID, desiredState: .completed)
            return ActionChangeReceipt(successorID: successor, keptSuccessorID: nil)
        }
        // Undoing a completion that never reached Reminders means dropping the
        // queued write; the external reminder was never changed.
        if pendingReminderSyncs[action.id]?.desiredState == LocalActionState.completed.rawValue {
            removePendingReminderSync(actionID: action.id)
        } else {
            enqueuePendingReminderSync(action, link: link, externalID: externalID, desiredState: .open)
        }
        let kept = try await store.reopenActionWithRecurrence(id: action.id, successorID: successorID)
        return ActionChangeReceipt(successorID: nil, keptSuccessorID: kept)
    }
    /// The explicit failure action: complete in VoiceOS even when the reminder
    /// write path cannot be used right now.
    func completeActionLocally(_ action: ActionRecord) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        guard let link = reminderLinks.first(where: { $0.actionID == action.id }), let externalID = link.externalID else {
            status = "这条行动没有可同步的提醒事项关联"; return false
        }
        savingAction = true; defer { savingAction = false }
        do {
            guard let current = try await store.actions(includeHistory: true).first(where: { $0.id == action.id }),
                  current.state == LocalActionState.open.rawValue, current.validity == "current" else {
                throw VoiceOSError("任务已变化，请重新核对")
            }
            let receipt = try await changeLinkedActionLocally(current, state: .completed, link: link, externalID: externalID, successorID: nil)
            recordActionChange(current, from: .open, to: .completed, successorID: receipt.successorID)
            status = "已本地完成，连接恢复前不会同步到提醒事项"
            await refresh()
            await queueActionFollowups([current.id])
            return true
        } catch {
            status = error.localizedDescription
            await refresh()
            return false
        }
    }
    @discardableResult
    private func flushPendingReminderSyncs(access: ReminderAccess) async -> Int {
        guard let store, reminders.isAuthorized, !pendingReminderSyncs.isEmpty else { return 0 }
        var written = 0
        for entry in pendingReminderSyncList {
            guard entry.calendarID == access.calendarID else {
                recordPendingReminderSyncFailure(actionID: entry.actionID, reason: "提醒事项清单已变化，等待原清单授权后重试")
                continue
            }
            do {
                guard let link = reminderLinks.first(where: { $0.id == entry.linkID }),
                      let current = try await store.actions(includeHistory: true).first(where: { $0.id == entry.actionID }) else {
                    removePendingReminderSync(actionID: entry.actionID)
                    continue
                }
                guard current.state == entry.desiredState else {
                    // The task moved on locally; the queued write no longer describes the user's intent.
                    removePendingReminderSync(actionID: entry.actionID)
                    continue
                }
                guard ["linked", "unknown"].contains(link.state) else {
                    recordPendingReminderSyncFailure(actionID: entry.actionID, reason: link.state == "conflict"
                        ? "提醒关联匹配到多条或身份已变化，请在提醒事项核对中处理"
                        : "提醒事项中找不到关联任务，请先重新回读")
                    continue
                }
                try await reminders.setCompletion(calendarID: entry.calendarID, externalID: entry.externalID, marker: entry.marker,
                                                  completed: entry.desiredState == LocalActionState.completed.rawValue) {
                    guard let currentAccess = try await store.reminderAccess(), currentAccess.enabled, currentAccess.version == access.version,
                          let latest = try await store.actions(includeHistory: true).first(where: { $0.id == entry.actionID }),
                          latest.state == entry.desiredState else { throw VoiceOSError("任务或连接已变化，请重新核对") }
                }
                try await store.readReminder(linkID: entry.linkID, calendarID: entry.calendarID, using: reminders, expectedAccessVersion: access.version)
                removePendingReminderSync(actionID: entry.actionID)
                written += 1
            } catch {
                // Keep the latest reason with the queued write; a later success removes it.
                recordPendingReminderSyncFailure(actionID: entry.actionID, reason: error.localizedDescription)
            }
        }
        return written
    }
    /// Manual "稍后核对": retry the queued completions now.
    func retryPendingReminderSyncs() async {
        guard let access = reminderAccess, access.enabled else { status = "提醒事项连接已暂停，恢复连接并授权后会自动写入"; return }
        guard reminders.isAuthorized else { status = "系统提醒事项权限不可用，请在系统设置中允许后重试"; return }
        guard !remindersBusy else { status = "正在处理其他提醒事项操作，请稍后再试"; return }
        remindersBusy = true
        let written = await flushPendingReminderSyncs(access: access)
        remindersBusy = false
        if pendingReminderSyncs.isEmpty {
            status = "本地变更已写入提醒事项并回读"; reminderSyncStatus = status
        } else if written > 0 {
            let reasons = pendingReminderSyncList.compactMap(\.lastFailureReason).map(WorkspaceProcessingErrorText.display)
            status = "已写入 \(written) 项，其余仍需核对" + (reasons.isEmpty ? "" : " · 最近原因：" + reasons.prefix(2).joined(separator:"；"))
            reminderSyncStatus = status
        } else {
            let reasons = pendingReminderSyncList.compactMap(\.lastFailureReason).map(WorkspaceProcessingErrorText.display)
            status = reasons.isEmpty ? "尚未写入提醒事项，连接恢复后再试" : "尚未写入提醒事项 · 最近原因：" + reasons.prefix(2).joined(separator:"；")
            reminderSyncStatus = status
        }
        await refresh()
    }
    private func installReminderRefresh() {
        guard reminderObservers.isEmpty else { return }
        reminderObservers.append(reminders.observeChanges { [weak self] in self?.requestReminderRefresh() })
        reminderObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.refresh(.full); self?.requestReminderRefresh(); self?.resumeRecordingFollowups(); self?.resumeKnowledgeReviews(); await self?.refreshNoticeAuthorization() } })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.requestReminderRefresh(); self?.resumeRecordingFollowups(); self?.resumeKnowledgeReviews() } }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.requestReminderRefresh() } }
        followupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, let store = self.store else { return }
            let generation = await store.dataGeneration
            if generation != self.lastBackgroundResumeGeneration {
                self.lastBackgroundResumeGeneration = generation
                self.resumeRecordingFollowups()
                self.resumeAssistantExecutions()
                self.resumeKnowledgeReviews()
            }
            await self.refresh(.full)
        } }
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
        guard let store else { status = "资料库尚未打开，无法保存提醒设置"; return false }
        guard let access = reminderAccess, access.enabled else { status = "提醒事项连接已暂停，请先恢复连接"; return false }
        guard !remindersBusy else { status = "正在处理其他提醒事项操作，请稍后再试"; return false }
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
        var stageFailures:[String] = []
        if await flushPendingReminderSyncs(access: access) > 0 { reminderSyncStatus = "已把本地变更写入提醒事项并回读" }
        // Each stage stands alone: a failure keeps its reason and never skips readback.
        do { try await store.syncRecordingExpressionReminders(using:reminders) }
        catch { stageFailures.append("提醒补录：" + error.localizedDescription) }
        // Field inference must not hold up completion readback or recording intake.
        if reminderFieldWorker == nil, let reminderFieldModel {
            do {
                if !(try await store.prepareReminderFields()).tasks.isEmpty {
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
            } catch { stageFailures.append("提醒字段：" + error.localizedDescription) }
        }
        do {
            try await store.refreshAuthorizedReminders(expectedAccessVersion: access.version, using: reminders, requireReviewedFields: true)
            if reminderAccess?.version == access.version {
                if let failure = stageFailures.first { reminderSyncStatus = "已回读既有任务 · " + failure }
                else if let failure = reminderFieldFailure { reminderSyncStatus = "已回读既有任务，提醒字段待重试：" + failure }
                else if reminderFieldWorker != nil { reminderSyncStatus = "已回读既有任务 · 新任务日期和优先级正在后台核对" }
                else { reminderSyncStatus = "已自动核对「\(access.title)」的关联任务" }
            }
        } catch {
            stageFailures.append("回读：" + error.localizedDescription)
            if reminderAccess?.version == access.version {
                reminderSyncStatus = "自动同步未全部完成 · 已保存各任务状态，不自动重建 · " + (stageFailures.first ?? error.localizedDescription)
            }
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
        savingFeedback = true
        var saved = true
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
            status = allowCloud ? "结果原话已关联原行动，知识与思想跟进将在后台整理" : "结果原话已关联原行动 · 仅本地保存"
        } catch { status = error.localizedDescription; saved = false }
        savingFeedback = false
        if saved { scheduleProcessing() }
        Task { await refresh() }
        return saved
    }
    @discardableResult
    func changeAction(_ action: ActionRecord, state: LocalActionState, successorID: String? = nil) async -> ActionChangeReceipt? {
        guard let store else { return nil }
        guard !savingAction else { status = "正在保存其他更改，请稍后重试"; return nil }
        savingAction = true
        var changed = false
        var receipt: ActionChangeReceipt?
        var localFallback = false
        do {
            if state != .dismissed, let link = reminderLinks.first(where: { $0.actionID == action.id }), let id = link.externalID {
                do {
                    guard let access = reminderAccess, access.enabled, access.calendarID == link.calendarID, !remindersBusy else { throw VoiceOSError("请先恢复提醒事项连接，或在 Apple 提醒事项中更改完成状态") }
                    remindersBusy = true; defer { remindersBusy = false; requestReminderRefresh() }
                    try await reminders.setCompletion(calendarID: link.calendarID, externalID: id, marker: "voiceos-action:" + link.id, completed: state == .completed) {
                        guard let currentAccess = try await store.reminderAccess(), currentAccess.enabled, currentAccess.version == access.version,
                              let current = try await store.actions(includeHistory: true).first(where: { $0.id == action.id }), current.validity == "current", current.version == action.version else { throw VoiceOSError("任务或连接已变化，请重新核对") }
                    }
                    try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: reminders, expectedAccessVersion: access.version)
                    removePendingReminderSync(actionID: action.id)
                    if state == .completed {
                        receipt = ActionChangeReceipt(successorID: try await store.completeActionWithRecurrence(id: action.id), keptSuccessorID: nil)
                        status = "完成状态已同步并回读；可以补充实际结果或收获"
                    } else if state == .open {
                        let kept = try await store.reopenActionWithRecurrence(id: action.id, successorID: successorID)
                        receipt = ActionChangeReceipt(successorID: nil, keptSuccessorID: kept)
                        status = kept == nil ? "行动状态已保存" : "已重新跟进 · 下一次已保留"
                    } else {
                        status = "行动状态已保存"
                    }
                } catch {
                    guard (state == .completed || state == .open), !(error is CancellationError) else { throw error }
                    receipt = try await changeLinkedActionLocally(action, state: state, link: link, externalID: id, successorID: successorID)
                    localFallback = true
                }
            } else {
                if state == .completed {
                    receipt = ActionChangeReceipt(successorID: try await store.completeActionWithRecurrence(id: action.id), keptSuccessorID: nil)
                } else if state == .open {
                    let kept = try await store.reopenActionWithRecurrence(id: action.id, successorID: successorID)
                    receipt = ActionChangeReceipt(successorID: nil, keptSuccessorID: kept)
                    if kept != nil { status = "已重新跟进 · 下一次已保留" } else { status = "行动状态已保存" }
                } else {
                    _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: state)
                    status = "行动状态已保存"
                }
            }
            changed = true
        } catch { status = error.localizedDescription }
        savingAction = false
        if changed, !isUndoingActionChange, let previous = LocalActionState(rawValue: action.state) {
            recordActionChange(action, from: previous, to: state, successorID: receipt?.successorID)
        }
        if changed, localFallback {
            status = state == .completed ? "已本地完成，连接恢复前不会同步到提醒事项" : "已本地撤销，连接恢复前不会同步到提醒事项"
        }
        Task { await refresh(); await queueActionFollowups([action.id]) }
        return receipt
    }
    func promoteAction(_ action: ActionRecord) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.promoteAction(actionID: action.id, expectedVersion: action.version,
                                              commandID: "workspace-promote:" + action.id + ":" + String(action.version))
            await refresh()
            guard actionRecords.first(where: { $0.id == action.id })?.kind == "task" else { throw VoiceOSError("转为待办未能保存，请重试") }
            status = "已转为待办"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func openNextActions(of outcomeID: String) -> [ActionRecord] {
        actionRecords.filter { $0.parentID == outcomeID && $0.state == "open" }
    }
    func completeOutcome(_ action: ActionRecord) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.completeOutcome(actionID: action.id, expectedVersion: action.version,
                                                commandID: "workspace-complete-outcome:" + action.id + ":" + String(action.version))
            await refresh()
            guard actionRecords.first(where: { $0.id == action.id })?.state == "completed" else { throw VoiceOSError("目标达成未能保存，请重试") }
            status = "已标记达成"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func detachNextAction(_ action: ActionRecord) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.detachNextAction(actionID: action.id, expectedVersion: action.version,
                                                 commandID: "workspace-detach-next:" + action.id + ":" + String(action.version))
            await refresh()
            guard actionRecords.first(where: { $0.id == action.id })?.parentID == nil else { throw VoiceOSError("摘除下一步未能保存，请重试") }
            status = "已摘除下一步"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func clarifyAction(_ action: ActionRecord, decision: ActionClarificationDecision) async -> Bool {
        guard let store, !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.clarifyAction(actionID: action.id, expectedVersion: action.version, decision: decision,
                                              commandID: "workspace-clarify:" + action.id + ":" + decision.rawValue)
            await refresh()
            guard actionClarifications[action.id] == decision.rawValue else { throw VoiceOSError("澄清未能保存，请重试") }
            status = decision == .commit ? "已记为承诺" : decision == .opportunity ? "已放到问题与目标" : "已放下这条行动"
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func resolveActionReview(_ pair: ActionReviewPair, judgment: ActionReviewRelation) async -> Bool {
        guard let store else { status = "资料库尚未打开，无法核对行动关系"; return false }
        guard !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            let receipt = try await store.resolveActionReview(
                expressionID: pair.expressionID,
                judgment: .pair(oldActionID: pair.oldActionID, newActionID: pair.newActionID, relation: judgment),
                expectedDecisionsDigest: pair.decisionsDigest,
                commandID: "action-review-ui:\(pair.id):\(judgment.rawValue)")
            await refresh()
            requestReminderRefresh()
            status = judgment == .same ? "已核对为同一件事 · 接回原记录" : "已核对为两件事 · 原记录保留为历史"
            showTask(receipt.survivorActionID ?? pair.newActionID)
            return true
        } catch {
            status = error.localizedDescription
            await refresh()
            return false
        }
    }
    func acknowledgeActionReview(expressionID: String) async -> Bool {
        guard let store else { status = "资料库尚未打开，无法核对当前理解"; return false }
        guard let ledger = actionReviewLedgers[expressionID], ledger.canAcknowledge else {
            status = "仍有行动关系需要逐条核对"; return false
        }
        guard !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.resolveActionReview(
                expressionID: expressionID, judgment: .acknowledgeExpression,
                expectedDecisionsDigest: ledger.decisionsDigest,
                commandID: "action-review-ack:\(expressionID):\(ledger.decisionsDigest)")
            await refresh()
            requestReminderRefresh()
            status = "已核对当前理解 · AI 提取保持原样，不再因此暂停"
            return true
        } catch {
            status = error.localizedDescription
            await refresh()
            return false
        }
    }
    func confirmExternalCompletion(_ candidate: ExternalCompletionCandidate) async -> Bool {
        guard let store else { status = "资料库尚未打开，无法登记外部完成"; return false }
        guard !savingAction else { status = "正在保存其他更改，请稍后重试"; return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.confirmExternalCompletion(actionID: candidate.actionID, expectedVersion: candidate.expectedVersion,
                                                          linkID: candidate.linkID, expectedObservationID: candidate.observationID,
                                                          commandID: candidate.commandID)
            do {
                _ = try await store.completeActionWithRecurrence(id: candidate.actionID)
                status = "外部完成已登记 · 已进入结果队列"
            } catch {
                status = "外部完成已登记；下一次重复任务未生成：" + error.localizedDescription
            }
            await refresh()
            return true
        } catch {
            status = error.localizedDescription
            await refresh()
            return false
        }
    }
    func reviewHistory(_ claim: CandidateClaim) async {
        do { claimHistory = try await store?.claimReviewHistory(claimID: claim.id) ?? [] }
        catch { status = error.localizedDescription }
    }
    func play(_ record: SourceRecord) async {
        do { if let url = try await store?.playableURL(sourceID: record.id) { NSWorkspace.shared.open(url) } }
        catch { status = error.localizedDescription; await refresh() }
    }
    private var retryingSourceIDs = Set<String>()
    func retry(_ record: SourceRecord) async {
        guard retryingSourceIDs.insert(record.id).inserted else { return }
        defer { retryingSourceIDs.remove(record.id) }
        do { try await store?.retryTranscription(sourceID: record.id); await refresh(); scheduleProcessing() }
        catch { status = error.localizedDescription }
    }
}

enum LocalNoticeAuthorization: Equatable {
    case notRequested, authorized, denied
}

extension ControlCenter {
    var noticeAuthorizationDetail: String {
        switch noticeAuthorization {
        case .notRequested: return "未请求 · 第一次完成长任务时会询问一次；处理页也保留最近完成"
        case .authorized: return "已允许 · 长任务完成与核对结果会出现在通知中心"
        case .denied: return "系统已拒绝 · 完成提醒不会出现；可在系统通知设置中允许"
        }
    }
    func refreshNoticeAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let next: LocalNoticeAuthorization = status == .notDetermined ? .notRequested : status == .denied ? .denied : .authorized
        if noticeAuthorization != next { noticeAuthorization = next }
    }
    func openNoticeSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
}

/// Local completion notices for long work. The first notifiable event asks
/// once; a refused request stays silent and the in-app processing page is the
/// fallback surface.
@MainActor
enum LocalNotice {
    static let openSourceCategory = "voiceos.openSource"
    static let openSourceAction = "voiceos.openSource.action"
    private static var authorizationRequested = false
    private static var openSourceCategoryRegistered = false
    static func post(title: String, body: String, sourceID: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard !authorizationRequested else { return }
                authorizationRequested = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let sourceID {
                if !openSourceCategoryRegistered {
                    openSourceCategoryRegistered = true
                    let open = UNNotificationAction(identifier: openSourceAction, title: "打开材料", options: [.foreground])
                    center.setNotificationCategories([UNNotificationCategory(identifier: openSourceCategory, actions: [open], intentIdentifiers: [], options: [])])
                }
                content.categoryIdentifier = openSourceCategory
                content.userInfo = ["sourceID": sourceID]
            }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

final class NoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let sourceID = response.notification.request.content.userInfo["sourceID"] as? String
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run {
                (NSApp.delegate as? ApplicationDelegate)?.openMainWindow()
                // 整理/导入完成的通知点开就回到这次内容，不用先去列表里找。
                if let sourceID { ControlCenter.primary?.requestWorkspaceSource(sourceID) }
                else { ControlCenter.primary?.pendingWorkspacePageRequest = .processing }
            }
        } else if response.actionIdentifier == LocalNotice.openSourceAction, let sourceID {
            await MainActor.run {
                (NSApp.delegate as? ApplicationDelegate)?.openMainWindow()
                ControlCenter.primary?.requestWorkspaceSource(sourceID)
            }
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var noticeDelegate: NoticeDelegate?
    private var dictationKeyMonitor: Any?
    private var appIconObservation: NSKeyValueObservation?
    private var dictationIconObservation: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var dictationMenuItem: NSMenuItem?
    private var clipboardMenuItem: NSMenuItem?
    private let clipboardMonitor = ClipboardMonitor()
    private var clipboardHistoryMenuItem: NSMenuItem?
    private var todayOverviewMenuItems: [NSMenuItem] = []
    private var quickNoteMenuItem: NSMenuItem?
    private var watchMenuItem: NSMenuItem?
    private var stopWatchMenuItem: NSMenuItem?
    private var discardDictationMenuItem: NSMenuItem?
    private var dictationClockTimer: Timer?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppBrand.applyApplicationIcon()
        if Bundle.main.bundleIdentifier != nil {
            let notice = NoticeDelegate()
            noticeDelegate = notice
            UNUserNotificationCenter.current().delegate = notice
        }
        installGlobalHotKeys()
        appIconObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { AppBrand.applyApplicationIcon() }
        }
        installStatusItem()
        observeDictationIcon()
        // The scene model may be created after the delegate finishes launching.
        Task { @MainActor in self.observeDictationIcon() }
        clipboardMonitor.start()
        NSApp.servicesProvider = self
        // SwiftUI accepts only the import command on this scene, so Command-Shift-R is handled here.
        dictationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !event.isARepeat,
                  flags == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "r" else { return event }
            // Only the root library window may route here; standalone libraries keep their own dictation.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let model = ControlCenter.primary,
                      let keyWindow = NSApp.keyWindow,
                      keyWindow.title == model.libraryTitle || keyWindow.identifier?.rawValue == "control-center",
                      model.canToggleCaptureDictation else { return false }
                model.toggleCaptureDictation()
                return true
            }
            return handled ? nil : event
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            let drop = StatusItemDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onDrop = { [weak self] urls in self?.acceptDroppedFiles(urls) }
            button.addSubview(drop)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let dictation = menu.addItem(withTitle: "开始口述并自动整理（⌥⌘D）", action: #selector(toggleDictation), keyEquivalent: "")
        dictation.target = self
        dictationMenuItem = dictation
        let discardDictation = menu.addItem(withTitle: "取消并丢弃本次口述…", action: #selector(cancelAndDiscardDictation), keyEquivalent: "")
        discardDictation.target = self
        discardDictationMenuItem = discardDictation
        let clipboard = menu.addItem(withTitle: "捕获剪贴板文字（⌥⌘V）", action: #selector(captureClipboard), keyEquivalent: "")
        clipboard.target = self
        clipboardMenuItem = clipboard
        let history = menu.addItem(withTitle: "最近的剪贴板", action: nil, keyEquivalent: "")
        history.submenu = NSMenu(title: "最近的剪贴板")
        history.submenu?.autoenablesItems = false
        clipboardHistoryMenuItem = history
        let note = menu.addItem(withTitle: "速记（⌥⌘N）", action: #selector(openQuickNote), keyEquivalent: "")
        note.target = self
        quickNoteMenuItem = note
        menu.addItem(.separator())
        let watch = menu.addItem(withTitle: "监听文件夹…", action: #selector(chooseWatchFolder), keyEquivalent: "")
        watch.target = self
        watchMenuItem = watch
        let stopWatch = menu.addItem(withTitle: "停止监听", action: #selector(stopWatchingFolder), keyEquivalent: "")
        stopWatch.target = self
        stopWatchMenuItem = stopWatch
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(menuOpenSettings(_:)), keyEquivalent: "")
        settings.target = self
        let weekly = menu.addItem(withTitle: "每周回顾…", action: #selector(menuOpenWeeklyReview(_:)), keyEquivalent: "")
        weekly.target = self
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "打开 VoiceOS", action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        let quit = menu.addItem(withTitle: "退出 VoiceOS", action: #selector(quitApplication), keyEquivalent: "")
        quit.target = self
        item.menu = menu
        statusItem = item
        applyDictationState(ControlCenter.primary?.dictationActive == true)
    }

    private func observeDictationIcon() {
        guard dictationIconObservation == nil, let model = ControlCenter.primary else { return }
        dictationIconObservation = model.$dictationActive
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { self?.applyDictationState(active) }
            }
    }

    private func applyDictationState(_ active: Bool) {
        statusItem?.button?.image = AppBrand.menuBarImage(recording: active)
            ?? NSImage(systemSymbolName: active ? "record.circle.fill" : "waveform",
                       accessibilityDescription: active ? "VoiceOS 正在口述" : "VoiceOS")
        statusItem?.button?.toolTip = active ? "VoiceOS · 正在口述" : "VoiceOS"
        if active { startDictationClock() } else { stopDictationClock() }
    }

    private func startDictationClock() {
        guard dictationClockTimer == nil else { return }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(dictationClockTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        dictationClockTimer = timer
        dictationClockTick()
    }

    private func stopDictationClock() {
        dictationClockTimer?.invalidate()
        dictationClockTimer = nil
        statusItem?.button?.title = ""
    }

    @objc private func dictationClockTick() {
        guard let model = ControlCenter.primary, let start = model.dictationStartedAt else {
            if let model = ControlCenter.primary, model.dictationActive { dictationMenuItem?.title = "正在封存录音…" }
            stopDictationClock()
            return
        }
        let elapsed = ControlCenter.clockText(Date().timeIntervalSince(start))
        model.noteDictationClock(elapsed)
        statusItem?.button?.title = " " + elapsed
        statusItem?.button?.toolTip = "VoiceOS · 正在录音 " + elapsed
        dictationMenuItem?.title = "正在录音 " + elapsed + " · 停止并整理" + Self.dictationHotKeySuffix(model.dictationHotKeyConflict)
    }

    private static func dictationHotKeySuffix(_ conflict: Bool) -> String {
        conflict ? "（快捷键 ⌥⌘D 被其它应用占用）" : "（⌥⌘D）"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        observeDictationIcon()
        rebuildClipboardHistoryMenu()
        rebuildTodayOverviewMenu(model: ControlCenter.primary)
        guard let model = ControlCenter.primary else {
            clipboardHistoryMenuItem?.isEnabled = false
            dictationMenuItem?.title = "控制中心尚未准备好"
            dictationMenuItem?.isEnabled = false
            discardDictationMenuItem?.isEnabled = false
            clipboardMenuItem?.isEnabled = false
            quickNoteMenuItem?.isEnabled = false
            watchMenuItem?.isEnabled = false
            stopWatchMenuItem?.isEnabled = false
            return
        }
        let conflict = model.dictationHotKeyConflict
        let suffix = Self.dictationHotKeySuffix(conflict)
        if model.dictationBusy && model.dictationActive {
            dictationMenuItem?.title = "正在封存录音…"
        } else if model.dictationActive {
            let finish = model.recordingModelIssue == nil ? " · 停止并整理" : " · 停止并保存"
            dictationMenuItem?.title = "正在录音 " + model.dictationElapsedText + finish + suffix
        } else {
            let start = model.recordingModelIssue == nil ? "开始口述并自动整理" : "开始口述（先保存原音）"
            dictationMenuItem?.title = start + suffix
        }
        dictationMenuItem?.toolTip = conflict ? "快捷键 ⌥⌘D 被其它应用占用；可从菜单开始口述，或在设置中查看更换指引" : nil
        dictationMenuItem?.isEnabled = model.canToggleCaptureDictation
        discardDictationMenuItem?.title = "取消并丢弃本次口述…"
        discardDictationMenuItem?.toolTip = "停止录音并丢弃这段口述，不进入转写与整理"
        discardDictationMenuItem?.isEnabled = model.dictationActive && !model.dictationBusy
        clipboardMenuItem?.isEnabled = true
        quickNoteMenuItem?.isEnabled = true
        watchMenuItem?.isEnabled = true
        stopWatchMenuItem?.isEnabled = model.folderWatchActive
    }

    private func acceptDroppedFiles(_ urls: [URL]) {
        guard let model = ControlCenter.primary else { return }
        Task { _ = await model.acceptDroppedFiles(urls) }
    }

    @objc func captureText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "没有可保存的文字" as NSString
            return
        }
        guard let model = ControlCenter.primary else {
            error.pointee = "VoiceOS 尚未准备好" as NSString
            return
        }
        Task { _ = await model.acceptCaptureRequest(text: text, title: nil, url: nil, successURL: nil) }
    }

    @objc func captureFile(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "没有可保存的文件" as NSString
            return
        }
        guard let model = ControlCenter.primary else {
            error.pointee = "VoiceOS 尚未准备好" as NSString
            return
        }
        Task { _ = await model.acceptDroppedFiles(urls) }
    }

    @objc private func toggleDictation() {
        ControlCenter.primary?.toggleCaptureDictation()
    }

    @objc private func cancelAndDiscardDictation() {
        guard let model = ControlCenter.primary, model.dictationActive, !model.dictationBusy else {
            NSSound.beep()
            return
        }
        let elapsed = model.dictationElapsedText
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "取消并丢弃这段口述？"
        alert.informativeText = (elapsed.isEmpty ? "" : "已录 " + elapsed + "。") + "停止录音并丢弃这段口述，不进入转写与整理；音频会从本机删除，丢弃后无法恢复。"
        alert.addButton(withTitle: "继续录音")
        alert.addButton(withTitle: "取消并丢弃")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        model.cancelAndDiscardDictation()
    }

    @objc private func captureClipboard() {
        ControlCenter.primary?.captureClipboardText()
    }

    @objc private func openQuickNote() {
        QuickNoteController.shared.show()
    }

    @objc private func chooseWatchFolder() {
        ControlCenter.primary?.chooseWatchFolder()
    }

    @objc private func stopWatchingFolder() {
        ControlCenter.primary?.stopWatchingFolder()
    }

    private func installGlobalHotKeys() {
        let center = GlobalHotKeyCenter.shared
        let dictationRegistered = center.register(.toggleDictation) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.toggleDictation()
            }
        }
        let clipboardRegistered = center.register(.captureClipboard) {
            MainActor.assumeIsolated {
                if let model = ControlCenter.primary { model.captureClipboardText() }
            }
        }
        let quickNoteRegistered = center.register(.quickNote) {
            MainActor.assumeIsolated {
                QuickNoteController.shared.show()
            }
        }
        if !dictationRegistered { NSLog("VoiceOS 全局快捷键 ⌥⌘D 注册失败：可能被其它应用占用；口述仍可从菜单栏开始") }
        if !clipboardRegistered { NSLog("VoiceOS 全局快捷键 ⌥⌘V 注册失败：可能被其它应用占用") }
        if !quickNoteRegistered { NSLog("VoiceOS 全局快捷键 ⌥⌘N 注册失败：可能被其它应用占用") }
    }

    @objc fileprivate func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "control-center" || $0.title == "VoiceOS" }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // A closed Window scene has no NSWindow instance. LaunchServices recreates
        // it from the open event, which NSWorkspace does not deliver to a running
        // instance of the same app, so ask the opener that does.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", Bundle.main.bundleURL.path]
        try? opener.run()
    }

    @objc private func menuOpenSettings(_ sender: Any?) { openSettings() }
    @objc private func menuOpenWeeklyReview(_ sender: Any?) { openWeeklyReview() }

    func openSettings() {
        openMainWindow()
        ControlCenter.primary?.pendingWorkspaceRoute = .settings
    }

    func openDiscussion() {
        openMainWindow()
        ControlCenter.primary?.pendingWorkspaceRoute = .discussion
    }

    func openWorkspacePage(_ request: WorkspacePageRequest) {
        openMainWindow()
        ControlCenter.primary?.pendingWorkspacePageRequest = request
    }

    func openWorkspaceSearch() {
        openMainWindow()
        ControlCenter.primary?.pendingWorkspaceRoute = .search
    }

    func openWeeklyReview() {
        openMainWindow()
        ControlCenter.primary?.pendingWorkspaceRoute = .weeklyReview
    }

    func openCaptureComposer() {
        openMainWindow()
        ControlCenter.primary?.showingCaptureComposer = true
    }

    private func rebuildTodayOverviewMenu(model: ControlCenter?) {
        guard let menu = statusItem?.menu, let clipboard = clipboardMenuItem else { return }
        for item in todayOverviewMenuItems { menu.removeItem(item) }
        todayOverviewMenuItems = []
        guard let model else { return }
        let actions = model.actionRecords.filter { $0.kind == "task" && $0.state == "open" && $0.validity == "current" }
        let surface = ActionTimeSurface.build(actions: actions, schedules: model.scheduleIntents, links: model.reminderLinks, now: Date(), calendar: .current)
        let overdue = Array(surface.today.filter { $0.isOverdue }.prefix(3))
        let dueToday = Array(surface.today.filter { !$0.isOverdue }.prefix(3))
        var items: [NSMenuItem] = []
        let header = NSMenuItem(title: "今日一览", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)
        if overdue.isEmpty && dueToday.isEmpty {
            let empty = NSMenuItem(title: "今天没有待办", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            items.append(empty)
        } else {
            appendTodayOverviewSection("逾期", entries: overdue, to: &items)
            appendTodayOverviewSection("今天", entries: dueToday, to: &items)
        }
        let unscheduled = surface.anytime.filter { $0.due == nil }.count
        if unscheduled > 0 {
            let note = NSMenuItem(title: "另有 \(unscheduled) 条未排期任务", action: nil, keyEquivalent: "")
            note.isEnabled = false
            items.append(note)
        }
        let viewAllActions = NSMenuItem(title: "查看全部行动…", action: #selector(openTodayOverviewActions(_:)), keyEquivalent: "")
        viewAllActions.target = self
        items.append(viewAllActions)
        items.append(.separator())
        let index = menu.index(of: clipboard) + 1
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: index + offset) }
        todayOverviewMenuItems = items
    }

    private func appendTodayOverviewSection(_ label: String, entries: [ActionTimeEntry], to items: inout [NSMenuItem]) {
        guard !entries.isEmpty else { return }
        let title = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        title.isEnabled = false
        items.append(title)
        for entry in entries {
            let text = entry.action.title
            let row = NSMenuItem(title: text.count > 20 ? String(text.prefix(20)) + "…" : text, action: #selector(openTodayOverviewTask(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = entry.action.id
            items.append(row)
        }
    }

    @objc private func openTodayOverviewTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let model = ControlCenter.primary else { return }
        openMainWindow()
        model.pendingWorkspaceTaskID = id
    }

    @objc private func openTodayOverviewActions(_ sender: NSMenuItem) {
        openWorkspacePage(.actions)
    }

    @objc private func quitApplication() { NSApp.terminate(nil) }

    private func rebuildClipboardHistoryMenu() {
        guard let item = clipboardHistoryMenuItem, let submenu = item.submenu else { return }
        submenu.removeAllItems()
        let recent = Array(clipboardMonitor.history.entries.prefix(10))
        item.isEnabled = !recent.isEmpty
        guard !recent.isEmpty else {
            let empty = submenu.addItem(withTitle: "暂无记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        for entry in recent {
            let title = entry.text.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let row = submenu.addItem(withTitle: title.count > 60 ? String(title.prefix(60)) + "…" : title, action: #selector(captureClipboardHistory(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = entry.text
        }
    }

    @objc private func captureClipboardHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        ControlCenter.primary?.captureClipboardHistory(text)
    }
}
@main
struct VoiceOSApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model = ControlCenter()
    @FocusedValue(\.voiceOSController) private var focusedModel
    init() { StartupTrace.mark("app.init") }
    var body: some Scene {
        Window("VoiceOS", id: "control-center") {
            WorkspaceView(model: model).onboarding(model: model)
                .sheet(item: $model.importReport) { report in
                    ImportBatchReportView(report: report, dismiss: { model.importReport = nil },
                                          open: { id in
                                              model.importReport = nil
                                              model.requestWorkspaceSource(id)
                                          })
                }
                .sheet(isPresented: $model.showingCaptureComposer) {
                    TextCaptureView(model: model, draft: $model.textCaptureDraft,
                                    onSaved: { id in
                                        model.showingCaptureComposer = false
                                        model.requestWorkspaceSource(id)
                                    },
                                    dismiss: { model.showingCaptureComposer = false })
                        .frame(minWidth: WorkspaceMetrics.modalSmall, minHeight: 560)
                }
                .vosTextEnvironment(model.textSize)
        }
            .commands {
                CommandGroup(replacing: .appSettings) { Button("设置…") { delegate.openSettings() }.keyboardShortcut(",") }
                CommandGroup(after: .sidebar) {
                    Button("讨论") { delegate.openDiscussion() }
                    Button("查找…") { delegate.openWorkspaceSearch() }.keyboardShortcut("f")
                    Button("记录想法") { delegate.openCaptureComposer() }
                    Divider()
                    Button("笔记") { delegate.openWorkspacePage(.home) }.keyboardShortcut("1")
                    Button("主题") { delegate.openWorkspacePage(.themes) }.keyboardShortcut("2")
                    Button("材料") { delegate.openWorkspacePage(.materials) }.keyboardShortcut("3")
                    Button("行动") { delegate.openWorkspacePage(.actions) }.keyboardShortcut("4")
                    Button("启动") { delegate.openWorkspacePage(.initiate) }.keyboardShortcut("5")
                    Button("消息监测") { delegate.openWorkspacePage(.monitor) }.keyboardShortcut("6")
                    Button("返回") { delegate.openWorkspacePage(.back) }.keyboardShortcut("[")
                    Divider()
                    Button("每周回顾") { delegate.openWeeklyReview() }.keyboardShortcut("e", modifiers: [.command, .shift])
                }
                CommandMenu("记录") {
                    Button("口述") { ControlCenter.primary?.toggleCaptureDictation() }.keyboardShortcut("d", modifiers: [.command, .option])
                    Button("保存剪贴板") { ControlCenter.primary?.captureClipboardText() }.keyboardShortcut("v", modifiers: [.command, .option])
                    Button("速记") { QuickNoteController.shared.show() }.keyboardShortcut("n", modifiers: [.command, .option])
                    Button("在主窗口口述") { focusedModel?.toggleCaptureDictation() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(focusedModel?.canToggleCaptureDictation != true)
                    Button("导入音频或视频…") { focusedModel?.chooseFullRecording() }.keyboardShortcut("i").disabled(focusedModel?.initialized != true || focusedModel?.importing == true)
                }
            }
        WindowGroup("独立资料库", id: "restored-library", for: String.self) { path in
            if let path = path.wrappedValue { RestoredLibraryView(path: path) }
        }
        .commands {
            CommandGroup(after: .undoRedo) { Button("撤销上一次变更") { Task { await focusedModel?.undoLastChange() } }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(focusedModel?.canUndoChange != true) }
        }
    }
}

extension View {
    /// Sheets attached at the scene root sit outside WorkspaceView's own
    /// text-size injection, so the scene applies the same values once here.
    func vosTextEnvironment(_ size: AppTextSize) -> some View {
        environment(\.vosTextScale, size.scale).dynamicTypeSize(size.dynamicType)
    }
}

struct ActionCreationView: View {
    @Environment(\.workspacePalette) private var palette
    let claim: CandidateClaim
    @ObservedObject var model: ControlCenter
    let close: () -> Void
    @State private var title = ""
    @State private var kind: ActionKind = .opportunity
    @State private var note = ""
    @State private var commandID = UUID().uuidString
    @State private var feedback = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("记录行动意图").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                Text("认可观点不等于承诺任务。选择明确任务，或先放入机会池；尚未写入提醒事项。").foregroundStyle(palette.secondaryText)
                Text("依据：" + claim.statement).lineLimit(4)
            }.padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 0) {
                WorkspaceSettingsRow(title: "意图", showsDivider: false) {
                    Picker("意图", selection: $kind) {
                        Text("探索意图 · 机会池").tag(ActionKind.opportunity)
                        Text("明确任务").tag(ActionKind.task)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                WorkspaceListDivider().padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("要做什么", text: $title).workspaceFieldSurface()
                    TextField("补充说明（可选）", text: $note).workspaceFieldSurface()
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            if !feedback.isEmpty { Text(feedback).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.horizontal, 24) }
            HStack {
                Button("取消", action: close).disabled(model.savingAction).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存意图") {
                    feedback = "正在保存意图…"
                    Task { if await model.createAction(claim, title: title, kind: kind, note: note, commandID: commandID) { close() } else { feedback = model.status } }
                }
                    .disabled(model.savingAction || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24)
        }.padding(.vertical, 24).frame(width: 600)
            .workspaceModalSurface()
    }
}

struct ActionFeedbackView: View {
    let action: ActionRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @Environment(\.workspacePalette) private var palette
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
            VStack(alignment: .leading, spacing: 8) {
                Text("记录结果或反思").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                Text("关联：" + action.title + " · 第 \(action.version) 版").foregroundStyle(palette.secondaryText)
            }.padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 0) {
                WorkspaceSettingsRow(title: "类型", showsDivider: false) {
                    Picker("类型", selection: $kind) { Text("实际结果").tag("outcome"); Text("我的反思").tag("reflection") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220).disabled(saving)
                }
                WorkspaceListDivider().padding(.horizontal, 20)
                HStack {
                    if recordingID != nil, model.dictationActive {
                        Button("停止并转写") { model.stopDictation() }.disabled(model.dictationBusy)
                        Text("正在录制这条任务的结果…").foregroundStyle(palette.secondaryText)
                    } else if waitingForVoice {
                        ProgressView().controlSize(.small); Text("Qwen 正在本机转写…").foregroundStyle(palette.secondaryText)
                    } else if recordingID == nil {
                        Button("口述进展或结果", systemImage: "mic") {
                            Task { recordingID = await model.startFeedbackDictation(); if recordingID == nil { errorText = model.status } }
                        }.disabled(saving || model.dictationBusy || model.dictationActive)
                    } else {
                        Text(appliedRecording ? "口述已填入下方，可核对修改。原始录音保留。" : "转写未完成，录音已保留；也可以直接写下结果。")
                            .vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                    }
                }
                    .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 46)
                WorkspaceListDivider().padding(.horizontal, 20)
                TextEditor(text: $text).frame(minHeight: 180).workspaceEditorSurface().disabled(saving || waitingForVoice)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            Text("可选记录，原话与原行动保持关联。开启下方选项后会自动核对思想变化与目标下一步；反馈不会当成已验证事实。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.horizontal, 24)
            if !errorText.isEmpty { Text(errorText).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger).padding(.horizontal, 24) }
            WorkspaceSettingsRow(title: "将反馈文字用于整理知识、更新思想与目标") {
                Toggle("将反馈文字用于整理知识、更新思想与目标", isOn: $allowFollowup).toggleStyle(.switch).labelsHidden().disabled(saving)
            }
            HStack {
                Button("取消", action:dismiss).disabled(saving || (recordingID != nil && (model.dictationActive || model.dictationBusy))).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer(); Text("\(text.unicodeScalars.count)/4000").vosFont(WorkspaceText.caption)
                Button(saving ? "正在保存…" : "保存反馈") {
                    saving = true; errorText = ""
                    Task {
                        let savedRecording = recording?.state == "saved" ? recordingID : nil
                        if await model.saveFeedback(action,kind:ActionFeedbackKind(rawValue:kind)!,text:text,recordingSourceID:savedRecording,commandID:commandID,allowCloud:allowFollowup) { dismiss() }
                        else { errorText = model.status }
                        saving = false
                    }
                }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(saving || waitingForVoice || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.unicodeScalars.count > 4000)
            }.padding(.horizontal, 24)
        }.padding(.vertical, 24).frame(width:620)
            .workspaceModalSurface()
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
    @Environment(\.workspacePalette) private var palette
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
            VStack(alignment:.leading,spacing:8) {
                Text("从迁移包恢复").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                Text("恢复到一个新资料库，保留当前资料库。完成后可在新窗口打开；提醒事项需要重新连接。").foregroundStyle(palette.secondaryText)
            }.padding(.horizontal, 24)
            VStack(alignment:.leading,spacing:0) {
                Button("选择迁移包文件夹…",action:choosePackage).disabled(restoring || restored != nil)
                    .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 46)
                if let package, let summary {
                    VStack(alignment:.leading,spacing:6) {
                        Text(package.path).vosFont(WorkspaceText.meta).textSelection(.enabled)
                        Text("包版本 \(summary.version) · \(summary.sourceCount) 份资料 · \(summary.mediaIncluded ? "包含原件" : "结构化记录")")
                        Text(summary.omittedAssetCount > 0 ? "\(summary.omittedAssetCount) 份原件未打包：恢复后可读文字与历史，无法播放缺失原件。" : "清单中没有省略的原件。恢复时仍会核对文件与关联完整性。").vosFont(WorkspaceText.body)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                }
                WorkspaceListDivider().padding(.horizontal, 20)
                Button("选择保存位置…",action:chooseParent).disabled(restoring || restored != nil)
                    .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 46)
                TextField("新资料库文件夹名称",text:$folderName).workspaceFieldSurface().disabled(restoring || restored != nil)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                if let destination { Text(destination.path).vosFont(WorkspaceText.meta).textSelection(.enabled).padding(.horizontal, 20) }
            }
            if !errorText.isEmpty { WorkspaceNoticeText(message: errorText, severity: .danger).padding(.horizontal, 24) }
            if let restored {
                VStack(alignment:.leading,spacing:8) {
                    Text("恢复完成 · 当前库保留，外部连接未启用").foregroundStyle(palette.success)
                    Button("打开恢复的资料库") { openWindow(id:"restored-library",value:restored.path); dismiss() }
                }.padding(.horizontal, 24)
            }
            HStack {
                Button(restored == nil ? "取消" : "完成",action:dismiss).disabled(restoring).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
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
                    }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(restoring || package == nil || destination == nil)
                }
            }.padding(.horizontal, 24)
        }.padding(.vertical, 24).frame(width:640)
            .workspaceModalSurface()
    }
}

struct BackupLibraryRestoreView: View {
    let currentRoot: URL?
    let dismiss: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.workspacePalette) private var palette
    @State private var parent: URL?
    @State private var folderName: String
    @State private var restoring = false
    @State private var errorText = ""
    @State private var restored: URL?
    init(currentRoot: URL?, dismiss: @escaping () -> Void) {
        self.currentRoot = currentRoot
        self.dismiss = dismiss
        let stamp = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        _parent = State(initialValue: currentRoot?.deletingLastPathComponent())
        _folderName = State(initialValue: "VoiceOS-备份恢复-" + stamp)
    }
    private var backupDirectory: URL? { currentRoot?.appendingPathComponent("Backups", isDirectory: true) }
    private var backupSummary: DatabaseBackup.Summary? { backupDirectory.flatMap { DatabaseBackup.summary(directory: $0) } }
    private var destination: URL? {
        guard let parent, !folderName.isEmpty, folderName != ".", folderName != "..", !folderName.contains("/"), !folderName.contains("\0") else { return nil }
        let target = parent.appendingPathComponent(folderName, isDirectory: true)
        if let currentRoot, target.standardizedFileURL.path == currentRoot.standardizedFileURL.path { return nil }
        return target
    }
    private func chooseParent() {
        let panel = NSOpenPanel(); panel.title = "选择新资料库的上级文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK { parent = panel.url; errorText = "" } }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:8) {
                Text("从最近备份新建资料库").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                Text("取最近一份备份的数据库，加上当前资料库的原件副本，建立一个独立的新资料库；当前资料库不会被改动。完成后可在新窗口打开。").foregroundStyle(palette.secondaryText)
            }.padding(.horizontal, 24)
            if let summary = backupSummary {
                Text(DatabaseBackup.successText(at: summary.date, count: summary.count)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).padding(.horizontal, 24)
            } else {
                WorkspaceNoticeText(message: "还没有可用于恢复的备份。先完成一次备份再试（\(backupDirectory?.path ?? "备份目录不可用")）。", severity: .warning).padding(.horizontal, 24)
            }
            VStack(alignment:.leading,spacing:0) {
                Button("选择保存位置…", action: chooseParent).disabled(restoring || restored != nil)
                    .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 46)
                TextField("新资料库文件夹名称", text: $folderName).workspaceFieldSurface().disabled(restoring || restored != nil)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                if let destination { Text(destination.path).vosFont(WorkspaceText.meta).textSelection(.enabled).padding(.horizontal, 20) }
            }
            if !errorText.isEmpty { WorkspaceNoticeText(message: errorText, severity: .danger).padding(.horizontal, 24) }
            if let restored {
                VStack(alignment:.leading,spacing:8) {
                    Text("已从最近备份建立新资料库 · 当前库未改动").foregroundStyle(palette.success)
                    Text(restored.path).vosFont(WorkspaceText.meta).textSelection(.enabled)
                    HStack {
                        Button("打开新资料库") { openWindow(id:"restored-library",value:restored.path); dismiss() }
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([restored]) }
                    }
                }.padding(.horizontal, 24)
            }
            HStack {
                Button(restored == nil ? "取消" : "完成", action: dismiss).disabled(restoring)
                    .buttonStyle(.workspaceSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if restored == nil {
                    Button(restoring ? "正在建立新资料库…" : "新建资料库") {
                        guard let currentRoot, let destination else { return }
                        restoring = true; errorText = ""
                        Task {
                            do {
                                restored = try await Task.detached(priority: .userInitiated) {
                                    try DatabaseBackup.createLibraryFromLatestBackup(currentRoot: currentRoot, destination: destination)
                                }.value
                            } catch { errorText = error.localizedDescription }
                            restoring = false
                        }
                    }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(restoring || currentRoot == nil || destination == nil || backupSummary == nil)
                }
            }.padding(.horizontal, 24)
        }.padding(.vertical, 24).frame(width:640)
            .workspaceModalSurface()
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
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    var embedded = false
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            Text("静默回顾").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            WorkspaceSettingsCard(title: "显示方式", subtitle: "可以直接关闭。这里显示已接纳的关联提案和相关原文。") {
                VStack(alignment: .leading, spacing: 0) {
                    WorkspaceSettingsRow(title: "模式", showsDivider: false) {
                        Picker("显示方式",selection:Binding(get:{ model.quietMode },set:{ mode in Task { await model.changeQuietMode(mode) } })) {
                            Text("正常显示").tag(CognitiveFeedbackMode.normal)
                            Text("减少显示 · 一次一条").tag(CognitiveFeedbackMode.reduced)
                            Text("暂停显示").tag(CognitiveFeedbackMode.paused)
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    WorkspaceListDivider().padding(.horizontal, 20)
                    Text(model.quietStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ScrollView {
                VStack(alignment:.leading,spacing: WorkspaceMetrics.rowGap) {
                    if model.quietFeedback.isEmpty && model.associationFeedback.isEmpty {
                        Text(model.quietMode == .paused ? "已暂停静默回顾，原文与历史保留。" : "暂无可显示的相关原文。无需回复或补做任务。")
                    }
                    ForEach(model.associationFeedback) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("与这次表达有关 · AI 关系提案").vosFont(WorkspaceText.rowTitle)
                            Text(item.proposal.relation.displayName).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            AssociationQuestionsView(item: item, model: model)
                            Text("为何现在相关：" + item.proposal.reason).textSelection(.enabled)
                            Text("这次原话：" + item.proposal.current.quote).textSelection(.enabled)
                            Text("历史原话：" + item.proposal.historicalQuote).textSelection(.enabled)
                            Text(MaterialNaming.displayName(item.historical.document.name) + " · " + (ConversationReflectionFocus.date(item.historical.document.createdAt)?.formatted(date:.abbreviated,time:.shortened) ?? item.historical.document.createdAt)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            HStack {
                                Button("查看这次原话") { Task { if await model.openAssociation(item, historical: false) { dismiss() } } }
                                Button("查看历史出处") { Task { if await model.openAssociation(item, historical: true) { dismiss() } } }
                                Button("忽略关联") { Task { await model.ignoreAssociation(item) } }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.selection, in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(model.quietFeedback) { item in
                        VStack(alignment:.leading,spacing:8) {
                            Text("你查找的是：\(item.query)").vosFont(WorkspaceText.rowTitle).textSelection(.enabled)
                            Text("模型选中的相关原文 · \(item.hit.document.origin == "user" ? "用户表达" : "外部资料")").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            Text(item.hit.document.text).textSelection(.enabled)
                            Text(MaterialNaming.displayName(item.hit.document.name) + " · " + (ConversationReflectionFocus.date(item.hit.document.createdAt)?.formatted(date:.abbreviated,time:.shortened) ?? item.hit.document.createdAt)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            HStack {
                                Button("查看原文与出处") { Task { if await model.openQuietFeedback(item) { dismiss() } } }
                                Button("忽略这条") { Task { await model.ignoreQuietFeedback(item) } }
                            }
                        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(palette.selection,in:RoundedRectangle(cornerRadius:8))
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack { Spacer(); if !embedded { Button("完成",action:dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction) } }
        }.frame(maxWidth: 760, alignment: .leading).padding(24).frame(width: embedded ? nil : 820, height: embedded ? nil : 560).task { await model.refreshQuietFeedback() }
    }
}

struct HistorySearchView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    var embedded = false
    let dismiss: () -> Void
    @State private var query = ""
    @State private var question = ""
    @State private var selectedIDs: Set<String> = []
    @State private var semantic = false
    private var candidates: [RetrievalHit] { (model.retrievalResult?.hits ?? []).filter { selectedIDs.contains($0.id) } }
    var body: some View {
        VStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap) {
            Text("查找历史文字").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            WorkspaceSettingsCard(title: "查找", subtitle: model.semanticAvailable ? "查找仅在本机进行；按意思找到的只是候选。选中原文后，可单独让文本模型判断与你的问题是否直接相关。" : "关键词查找在本机进行。这个构建尚未包含本地语义资源；选中原文后仍可单独判断相关性。") {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(semantic ? "输入想找回的问题或想法" : "先输入原文关键词",text:$query).workspaceFieldSurface().onSubmit { model.searchHistory(query:query,semantic:semantic) }
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                    WorkspaceSettingsRow(title: "按意思找原文（本机）") {
                        Toggle("按意思找原文（本机）",isOn:$semantic).toggleStyle(.switch).labelsHidden().disabled(!model.semanticAvailable)
                    }
                    WorkspaceSettingsRow(title: "操作") {
                        HStack(spacing: 8) {
                            Button(model.searchingHistory ? "正在查找…" : "查找") { model.searchHistory(query:query,semantic:semantic) }.buttonStyle(.workspacePrimary).disabled(model.searchingHistory || query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || query.unicodeScalars.count > 512)
                            if model.searchingHistory { Button("停止查找") { model.cancelHistorySearch() }.buttonStyle(.workspaceSecondary) }
                            Text("\(query.unicodeScalars.count)/512").vosFont(WorkspaceText.caption)
                        }
                    }
                    WorkspaceListDivider().padding(.horizontal, 20)
                    Text(model.retrievalStatus).vosFont(WorkspaceText.meta)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            RelevanceSearchPanel(model:model,coordinator:model.relevance,question:$question,candidates:candidates,dismiss:dismiss)
            ScrollView {
                if let result = model.retrievalResult {
                    if result.hits.isEmpty { Text("未找到候选；可以换个说法或关键词。").foregroundStyle(palette.secondaryText) }
                    ForEach(result.hits) { hit in
                        VStack(alignment:.leading,spacing:6) {
                            Text(model.records.first(where: { $0.id == hit.document.sourceID })?.displayTitle ?? MaterialNaming.displayName(hit.document.name)).vosFont(WorkspaceText.rowTitle)
                            Toggle("加入相关性判断",isOn:Binding(get:{ selectedIDs.contains(hit.id) },set:{ value in
                                if value { selectedIDs.insert(hit.id) } else { selectedIDs.remove(hit.id) }
                            })).disabled(!selectedIDs.contains(hit.id) && selectedIDs.count >= 8)
                            Text("\(hit.method == "exact" ? "文字匹配" : "语义候选 · 待核对") · \(hit.document.origin == "user" ? "用户原文" : "外部原文 · 说话人待核对") · \(hit.document.localOnly ? "仅本地" : "文本可用于云端")").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            Text(hit.document.text).textSelection(.enabled)
                            Text(ConversationReflectionFocus.date(hit.document.createdAt)?.formatted(date:.abbreviated,time:.shortened) ?? "时间未知").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            Button("查看原文与出处") { Task { if await model.openRetrievalHit(hit) { dismiss() } } }
                            WorkspaceListDivider()
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
            }
            if !embedded { Button("完成",action:dismiss) }
        }.frame(maxWidth: 760, alignment: .leading).padding(24).frame(width: embedded ? nil : 820, height: embedded ? nil : 740)
        .onChange(of:query) { selectedIDs = []; model.cancelHistorySearch() }
        .onChange(of:selectedIDs) { model.relevance.cancel() }
        .onChange(of:question) { model.relevance.cancel() }
        .onChange(of:semantic) { selectedIDs = []; model.cancelHistorySearch() }
        .onDisappear { model.cancelHistorySearch() }
    }
}

struct RelevanceSearchPanel: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @ObservedObject var coordinator: RelevanceQueryCoordinator
    @Binding var question: String
    let candidates: [RetrievalHit]
    let dismiss: () -> Void
    private var scalars: Int { question.unicodeScalars.count + candidates.reduce(0) { $0 + $1.document.text.unicodeScalars.count } }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            TextField("想找回的问题或想法",text:$question)
            Text("已选 \(candidates.count)/8 份原文 · 问题与原文共 \(scalars)/4000 字符").vosFont(WorkspaceText.caption)
            Text("判断时发送本次问题与所选原文，不发送音视频。仅本地资料需先到出处页面授权；相关不表示支持或已验证，也不创建行动。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            HStack {
                Button("准备所选原文") { Task { await model.prepareRelevance(query:question,candidates:candidates) } }
                    .disabled(coordinator.busy || candidates.isEmpty || question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || question.unicodeScalars.count > 512 || scalars > 4000)
                Button("用文本模型判断") { model.judgeRelevance() }
                    .disabled(coordinator.busy || coordinator.snapshot == nil || !model.modelConfigured)
                if coordinator.busy { Button("停止判断") { coordinator.stop() } }
                if !model.modelConfigured { Button("配置文本模型…") { model.chooseTextModel() } }
            }
            Text(coordinator.status).vosFont(WorkspaceText.meta).accessibilityIdentifier("relevanceStatus")
            if let hits = coordinator.hits {
                ForEach(hits) { hit in
                    HStack(alignment:.top) {
                        Text(hit.document.text).lineLimit(3).textSelection(.enabled)
                        Spacer()
                        Button("核对相关原文") { Task { if await model.openRetrievalHit(hit) { dismiss() } } }
                    }
                }
            }
        }.padding(12).background(palette.selection,in:RoundedRectangle(cornerRadius:8))
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
    func mergeTopic(_ id: String, into targetID: String) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try await store.mergeReflectionQuestion(id: id, into: targetID)
        await refresh()
    }
    func promoteTopic(_ id: String) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try await store.promoteReflectionQuestion(id: id)
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
            await refresh(.assistant); resumeAssistantExecutions(); return true
        } catch { assistantStatus = error.localizedDescription; await refresh(.assistant); return false }
    }
    func analyzeThought(_ action: ActionRecord, fresh: Bool = false) async -> Bool {
        guard let store, assistantModel != nil else { assistantStatus = "请先配置文本模型"; return false }
        do {
            _ = try await store.enqueueAssistantExecution(actionID: action.id, expectedVersion: action.version, mode: .analysis, fresh: fresh)
            assistantStatus = "已开始分析；结果会保存在这条内容下"
            await refresh(.assistant); resumeAssistantExecutions(); return true
        } catch { assistantStatus = error.localizedDescription; await refresh(.assistant); return false }
    }
    /// A follow-up is its own analysis execution anchored to the same action.
    func askFollowup(_ action: ActionRecord, instruction: String) async -> Bool {
        guard let store, assistantModel != nil else { assistantStatus = "请先配置文本模型"; return false }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { assistantStatus = "请写下要追问的内容"; return false }
        do {
            _ = try await store.enqueueAssistantExecution(actionID: action.id, expectedVersion: action.version, instruction: text, mode: .analysis, fresh: true)
            assistantStatus = "追问已排队；结果会保存在这条问题下"
            await refresh(.assistant); resumeAssistantExecutions(); return true
        } catch { assistantStatus = error.localizedDescription; await refresh(.assistant); return false }
    }
    /// Queues a question's first answer and returns without waiting for it, so
    /// the clarify queue can advance to the next item right away.
    func enqueueTrialAnswer(_ action: ActionRecord) async -> Bool {
        guard let store else { assistantStatus = "资料库尚未打开"; return false }
        guard assistantModel != nil else { assistantStatus = "请先配置文本模型"; return false }
        do {
            _ = try await store.enqueueAssistantExecution(actionID: action.id, expectedVersion: action.version, mode: .analysis, fresh: true)
            assistantStatus = "已让 VoiceOS 先回答这条问题；结果会保存在问题下"
            Task { await refresh(.assistant); resumeAssistantExecutions() }
            return true
        } catch { assistantStatus = error.localizedDescription; return false }
    }
    @discardableResult
    func retryAssistant(_ execution: AssistantExecutionRecord) async -> Bool {
        do { try await store?.retryAssistantExecution(id: execution.id); assistantStatus = "已重新排队"; await refresh(.assistant); resumeAssistantExecutions(); return true }
        catch { assistantStatus = error.localizedDescription; return false }
    }
    func retryAssistantAssessment(_ issue: AssistantAssessmentIssue) async {
        guard let store, let port = assistantModel, !assistantBusy else { return }
        assistantBusy = true
        defer { assistantBusy = false }
        do {
            try await store.retryAssistantAssessment(actionID: issue.actionID, expectedVersion: issue.actionVersion, using: port)
            assistantStatus = "意图已重新识别；明确委托才会执行"
            await refresh(.assistant)
            resumeAssistantExecutions()
        } catch { assistantStatus = error.localizedDescription; await refresh(.assistant) }
    }
    func cancelAssistant(_ execution: AssistantExecutionRecord) async {
        do { try await store?.cancelAssistantExecution(id: execution.id); assistantStatus = "已取消这份代办，保留委托记录"; await refresh(.assistant) }
        catch { assistantStatus = error.localizedDescription }
    }
    func attachAssistantResult(_ execution: AssistantExecutionRecord, questionID: String) async -> Bool {
        guard let store else { return false }
        do {
            try await store.attachAssistantExecution(id: execution.id, questionID: questionID)
            assistantStatus = "AI 成果已接回主题，可继续讨论和记录自己的判断"
            await refresh(.assistant); return true
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
    private func resumeAssistantExecutions(snapshot: WorkspaceSnapshot? = nil) {
        guard initialized, let store, let port = assistantModel, assistantWorker == nil, !dictationActive, !fullRecordingBusy else { return }
        assistantWorker = Task {
            assistantBusy = true
            defer { assistantBusy = false; assistantWorker = nil }
            do {
                assistantStatus = "正在检查明确委托，并推进已保存的代办…"
                // Deliver queued work first; discovering other tasks must not
                // postpone an explicit delegation made in the foreground. The
                // reload snapshot skips revalidating an idle list and is reused
                // only while no write happened after it was taken.
                let idle = snapshot.map { !$0.assistantExecutions.contains { ["queued", "running"].contains($0.state) } } ?? false
                let steadyHint = idle ? snapshot : nil
                var changed = false
                var firstHint = snapshot
                while try await store.processNextAssistantExecution(using: port, onProgress: { [weak self] in await self?.refresh(.assistant) }, snapshot: firstHint) {
                    changed = true
                    firstHint = nil
                    try Task.checkCancellation()
                }
                if try await store.discoverAutomaticAssistantExecutions(using: port, snapshot: steadyHint) { changed = true }
                while try await store.processNextAssistantExecution(using: port, onProgress: { [weak self] in await self?.refresh(.assistant) }, snapshot: steadyHint) {
                    changed = true
                    try Task.checkCancellation()
                }
                assistantStatus = "AI 代办状态已更新；成果可在任务或工作台查看"
                if changed { await refresh(.assistant) }
            } catch { assistantStatus = "AI 代办尚未完成：" + error.localizedDescription; await refresh(.assistant) }
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
            await refresh(); await refreshDiscussion(); return true
        } catch { discussionStatus="关联未完成，已保存原文可在资料库核对："+error.localizedDescription;await refresh(); await refreshDiscussion(); return false }
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
            await refresh(); await refreshDiscussion(); return true
        } catch { discussionStatus=error.localizedDescription;await refresh(); await refreshDiscussion(); return false }
    }
    func sendDiscussion() async {
        guard let store,let session=discussionSession,let port=discussionModel,discussionCanSend,!discussionSaving,!discussionSending,!discussionExtracting,!dictationActive else { return }
        discussionSending=true;defer { discussionSending=false }
        discussionStatus="正在回复本轮文字；可结束讨论，未登记结果不会自动重发。"
        do {
            let input=try await store.prepareConversationInput(id:session.id,expectedVersion:session.version,destination:.cloud)
            _=try await store.performConversationReply(input,using:port)
            discussionStatus="AI 回复已保存；分析不表示你已认可或决定行动。"
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
        do { try await store.endConversation(id:session.id,expectedVersion:session.version);discussionStatus="讨论已结束，历史保留；不表示认可 AI 内容。" }
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
    func ensureTranscriptReviewed(sourceID: String, retry: Bool = false) async throws {
        guard let store, let source = try await store.sources().first(where: { $0.id == sourceID }), source.needsTranscriptionReview else { return }
        guard !source.localOnly, let version = source.transcriptVersionID,
              let speech = speechPort as? LocalQwenSpeechPort, let configuration = textModelOrganizerEnvironment,
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
                modelEnvironment: configuration, log: folder.appendingPathComponent("校正日志.txt"), reviewTranscriptOnly: true)
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
            try? await store.clearTranscriptionReviewFailure(sourceID: sourceID)
            transcriptReviewStatus = "全文转写校正已完成；仍有疑点的地方保留待核对。"
            recordCompletion(category: "转写核对", title: source.displayTitle, sourceID: sourceID)
            LocalNotice.post(title: "完整转写核对完成", body: "「\(source.displayTitle)」已可继续云端理解。", sourceID: sourceID)
            await refresh()
        } catch {
            let reason = error.localizedDescription
            transcriptReviewFailures[key] = reason
            try? await store.recordTranscriptionReviewFailure(sourceID: sourceID, reason: reason)
            transcriptReviewStatus = "转写校正尚未完成：" + reason
            LocalNotice.post(title: "完整转写核对未完成", body: "「\(source.displayTitle)」：" + reason, sourceID: sourceID)
            throw error
        }
    }
    func reviewTranscription(sourceID: String) async {
        guard !fullRecordingBusy, organizingSourceID == nil else { return }
        do { try await ensureTranscriptReviewed(sourceID: sourceID, retry: true); scheduleProcessing(); resumeKnowledgeReviews() }
        catch { transcriptReviewStatus = error.localizedDescription }
        await refresh()
    }
    func reviewKnowledge(sourceID: String, retry: Bool = false) async {
        guard let store, knowledgeReviewModel != nil else { return }
        do {
            try await ensureTranscriptReviewed(sourceID: sourceID)
            _ = try await store.enqueueKnowledgeReview(sourceID: sourceID, retry: retry)
            await refresh(.knowledge); resumeKnowledgeReviews()
        } catch { knowledgeReviewStatus = error.localizedDescription }
    }
    func retryAllFailedKnowledgeReviews() async {
        guard let store, knowledgeReviewModel != nil else { return }
        for review in workspaceFailedKnowledgeReviews {
            do {
                try await ensureTranscriptReviewed(sourceID: review.sourceID)
                _ = try await store.enqueueKnowledgeReview(sourceID: review.sourceID, retry: true)
            } catch { knowledgeReviewStatus = error.localizedDescription }
        }
        await refresh(.knowledge); resumeKnowledgeReviews()
    }
    func setKnowledgeReviewIssueState(_ state: KnowledgeReviewIssueState, reviewID: String, issueID: String) async {
        guard let store else { return }
        do {
            try await store.setKnowledgeReviewIssueState(reviewID: reviewID, issueID: issueID, state: state)
            await refresh(.knowledge)
        } catch { knowledgeReviewStatus = error.localizedDescription }
    }
    private func resumeKnowledgeReviews() {
        guard initialized, let store, let port = knowledgeReviewModel, knowledgeReviewWorker == nil,
              !fullRecordingBusy, !dictationActive else { return }
        knowledgeReviewWorker = Task {
            defer { knowledgeReviewWorker = nil }
            do {
                // New reviews enter the queue after recording organization or manual retry; this only drains it.
                var attempted = Set<String>()
                while let next = try await store.pendingKnowledgeReviews().first(where: { !attempted.contains($0.id) }) {
                    try Task.checkCancellation(); attempted.insert(next.id)
                    knowledgeReviewStatus = "正在查证知识判断，核对来源与适用条件…"
                    await refresh(.knowledge)
                    knowledgeReviewBusy = true
                    defer { knowledgeReviewBusy = false }
                    let result = try await store.processKnowledgeReview(sourceID: next.sourceID, using: port)
                    knowledgeReviewStatus = result.state == "completed"
                        ? (result.issues.isEmpty ? "本次未提出需要纠偏的知识判断。" : "已保存 \(result.issues.count) 条知识核查建议与依据。")
                        : (result.error ?? "知识核查尚未完成，可手动重试。")
                    await refresh(.knowledge)
                }
            } catch { knowledgeReviewStatus = error.localizedDescription; await refresh(.knowledge) }
        }
    }
}

extension ApplicationDelegate: VoiceOSIntentEndpoint {
    private func readyControlCenter() async -> ControlCenter? {
        let deadline = Date().addingTimeInterval(8)
        while true {
            if let model = ControlCenter.primary, model.initialized { return model }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor func captureVoiceOSIntent(text: String, title: String?) async -> Bool {
        guard let model = await readyControlCenter() else { return false }
        return await model.acceptCaptureRequest(text: text, title: title, url: nil, successURL: nil, context: "快捷指令") != nil
    }
    @MainActor func openTodayActions() -> Bool {
        guard let model = ControlCenter.primary else { return false }
        openMainWindow()
        model.pendingWorkspaceRoute = .actions
        return true
    }
    @MainActor func openSearch() -> Bool {
        guard let model = ControlCenter.primary else { return false }
        openMainWindow()
        model.pendingWorkspaceRoute = .search
        return true
    }
    @MainActor func toggleDictation() async -> DictationOutcome {
        guard let model = ControlCenter.primary, model.initialized else { return .notReady }
        if model.dictationActive {
            model.stopDictation()
            return .stopped
        }
        if let reason = model.dictationBusyReason { return .failed(reason) }
        // 文本模型缺失时 toggleCaptureDictation 会退化为只保存原音，不再拒绝。
        let previousStatus = model.status
        model.toggleCaptureDictation()
        // 首次麦克风授权或启动刷新可能让开始过程持续数秒；忙于启动时不报失败。
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if model.dictationActive { return .started }
            if !model.dictationBusy, model.status != previousStatus { return .failed(model.status) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if model.dictationActive { return .started }
        if model.dictationBusy { return .failed("口述仍在准备（可能需要麦克风授权），请稍后在菜单栏确认") }
        return .failed(model.status == previousStatus ? "口述没有开始，请检查麦克风权限" : model.status)
    }
}
