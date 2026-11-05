import Foundation

/// The status line may name only work that is in flight. `completed` lets the
/// derivation ignore a busy flag that outlived its operation.
public struct WorkspaceProcessingStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case running
        case completed
    }

    public enum Display: Equatable, Sendable {
        case idle
        case running(String)
    }

    public static let idleTitle = "当前没有正在执行的处理"

    public var isInitializing: Bool
    public var hasStartupIssue: Bool
    public var isDictating: Bool
    public var isOrganizingRecording: Bool
    public var recordingStatus: String
    public var isSealingDictation: Bool
    public var isReviewingTranscript: Bool
    public var activityLabel: String?
    public var isUnderstanding: Bool
    public var isReplyingDiscussion: Bool
    public var isExtractingDiscussion: Bool
    public var knowledgeReview: Phase
    public var assistantExecution: Phase
    public var followup: Phase
    public var topicOrganization: Phase

    public init(
        isInitializing: Bool = false,
        hasStartupIssue: Bool = false,
        isDictating: Bool = false,
        isOrganizingRecording: Bool = false,
        recordingStatus: String = "",
        isSealingDictation: Bool = false,
        isReviewingTranscript: Bool = false,
        activityLabel: String? = nil,
        isUnderstanding: Bool = false,
        isReplyingDiscussion: Bool = false,
        isExtractingDiscussion: Bool = false,
        knowledgeReview: Phase = .idle,
        assistantExecution: Phase = .idle,
        followup: Phase = .idle,
        topicOrganization: Phase = .idle
    ) {
        self.isInitializing = isInitializing
        self.hasStartupIssue = hasStartupIssue
        self.isDictating = isDictating
        self.isOrganizingRecording = isOrganizingRecording
        self.recordingStatus = recordingStatus
        self.isSealingDictation = isSealingDictation
        self.isReviewingTranscript = isReviewingTranscript
        self.activityLabel = activityLabel
        self.isUnderstanding = isUnderstanding
        self.isReplyingDiscussion = isReplyingDiscussion
        self.isExtractingDiscussion = isExtractingDiscussion
        self.knowledgeReview = knowledgeReview
        self.assistantExecution = assistantExecution
        self.followup = followup
        self.topicOrganization = topicOrganization
    }

    public var display: Display {
        if isInitializing { return hasStartupIssue ? .idle : .running("正在恢复资料库与草稿") }
        if isDictating { return .running("正在录音，停止后保存并整理") }
        if isOrganizingRecording { return .running(recordingStatus.isEmpty ? "正在完整整理录音" : recordingStatus) }
        if isSealingDictation { return .running("正在封存录音与转写") }
        if isReviewingTranscript { return .running("AI 正在校正完整转写") }
        if let activityLabel, !activityLabel.isEmpty { return .running(activityLabel) }
        if isUnderstanding { return .running("正在理解当前材料") }
        if isReplyingDiscussion { return .running("正在回复讨论") }
        if isExtractingDiscussion { return .running("正在整理讨论成果") }
        if knowledgeReview == .running { return .running("正在核查知识理解") }
        if assistantExecution == .running { return .running("AI 正在执行代办") }
        if followup == .running { return .running("正在接续思想与目标") }
        if topicOrganization == .running { return .running("正在连接主题与更新简报") }
        return .idle
    }

    public var title: String {
        switch display {
        case .idle: return Self.idleTitle
        case .running(let title): return title
        }
    }

    /// Dictation and other foreground work outrank a paused batch's progress label.
    public func visibleTitle(preferringPausedBatch pausedBatchTitle: String?) -> String? {
        if case .running(let title) = display { return title }
        return pausedBatchTitle
    }

    public var isRunning: Bool {
        if case .running = display { return true }
        return false
    }
}
