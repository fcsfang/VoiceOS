import Foundation

/// One synchronous store read supplies a coherent workspace. No actor suspension
/// can mix an old task list with a newly corrected source halfway through a refresh.
public struct WorkspaceSnapshot: Sendable {
    public var sources: [SourceRecord] = []
    public var claims: [CandidateClaim] = []
    public var currentClaimsBySource: [String: [CandidateClaim]] = [:]
    public var questions: [QuestionRecord] = []
    public var questionHistories: [String: [QuestionRevision]] = [:]
    public var claimOrigins: [DiscussionClaimDerivation] = []
    public var outcomeOrigins: [ConversationOutcomeOrigin] = []
    public var actions: [ActionRecord] = []
    public var assistantExecutions: [AssistantExecutionRecord] = []
    public var assistantAssessmentIssues: [AssistantAssessmentIssue] = []
    public var knowledgeReviews: [KnowledgeReviewRecord] = []
    public var recentOutcomes: [ActionFeedbackRecord] = []
    public var outcomeFollowups: [ActionRecord] = []
    public var correctionImpacts: [CorrectionActionImpact] = []
    public var compensationPlans: [ReminderCompensationPlan] = []
    public var compensationGrants: [ReminderCompensationGrant] = []
    public var compensationOperations: [ReminderCompensationOperation] = []
    public var scheduleIntents: [ActionScheduleIntent] = []
    public var scheduleOperations: [ReminderScheduleOperation] = []
    public var scheduleGrants: [ReminderScheduleGrant] = []
    public var schedulePreviews: [String: ReminderScheduleDecision] = [:]
    public var reminderLinks: [ReminderLink] = []
    public var reminderAccess: ReminderAccess?
    public var topics: [ReflectionQuestion] = []
    public var topicSources: [String: [String]] = [:]
    public var briefing: WorkspaceBriefing?
    public var recordingFollowups: [RecordingFollowupReceipt] = []
    public var followupValidity: [String: RecordingFollowupValidity] = [:]
    public var attempts: [String: [ModelAttemptRecord]] = [:]
    public var processingIntents: [ExpressionProcessingIntentRecord] = []
    public var recordingRequests: [RecordingProcessingRequest] = []
    public var segmentedBatches: [SegmentedProcessingBatch] = []
    public var segmentedCognitiveCounts: [String: Int] = [:]
    public var segmentedAssociationStates: [String: String] = [:]
}

extension VoiceOSStore {
    public func workspaceSnapshot() throws -> WorkspaceSnapshot {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        var result = WorkspaceSnapshot()
        result.questions = try questions()
        result.questionHistories = try questionHistories()
        result.claimOrigins = try discussionClaimOrigins()
        result.outcomeOrigins = try conversationOutcomeOrigins()
        result.assistantExecutions = try assistantExecutions()
        result.assistantAssessmentIssues = try assistantAssessmentIssues()
        result.knowledgeReviews = try knowledgeReviews()
        result.recentOutcomes = try recentActionOutcomes()
        result.correctionImpacts = try correctionActionImpacts()
        result.compensationPlans = try reminderCompensationPlans()
        result.compensationGrants = try reminderCompensationGrants()
        result.compensationOperations = try reminderCompensationOperations()
        result.scheduleIntents = try actionScheduleIntents()
        result.scheduleOperations = try reminderScheduleOperations()
        result.scheduleGrants = try reminderScheduleGrants()
        result.reminderLinks = try reminderLinks()
        result.reminderAccess = try reminderAccess()
        if let access = result.reminderAccess, access.enabled {
            for intent in result.scheduleIntents {
                result.schedulePreviews[intent.id] = try? previewReminderSchedule(intentID: intent.id, expectedAccessVersion: access.version)
            }
        }
        result.topics = try reflectionQuestions()
        result.topicSources = try reflectionQuestionSources()
        result.briefing = try workspaceBriefing()
        result.recordingFollowups = try recordingFollowups()
        result.followupValidity = try recordingFollowupValidities(result.recordingFollowups)
        result.processingIntents = try processingIntents()
        result.recordingRequests = try recordingProcessingRequests()
        result.segmentedBatches = try segmentedProcessingBatches()
        for batch in result.segmentedBatches {
            if let ids = try segmentedCognitiveClaimIDs(batchID: batch.id) { result.segmentedCognitiveCounts[batch.id] = ids.count }
            if let attempt = try committedSegmentedAssociationAttempt(batchID: batch.id) {
                result.segmentedAssociationStates[batch.id] = attempt.validity == "current" ? attempt.state : "frozen"
            }
        }
        for request in result.recordingRequests {
            if let id = request.segmentedBatchID, let state = request.segmentedAssociationState, result.segmentedAssociationStates[id] == nil {
                result.segmentedAssociationStates[id] = state
            }
        }
        result.actions = try actions(includeHistory: true)
        if result.actions.contains(where: { $0.kind == "task" && $0.state == "completed" && $0.validity == "current" }) {
            result.outcomeFollowups = try pendingOutcomeFollowups()
        }
        result.claims = try candidateClaims(includeFrozen: true)
        result.currentClaimsBySource = try latestCandidateClaimsBySource(includeFrozen: true)
        result.attempts = try modelAttemptsBySource()
        result.sources = try sources()
        return result
    }
}
