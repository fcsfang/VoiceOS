import Foundation

/// One synchronous store read supplies a coherent workspace. No actor suspension
/// can mix an old task list with a newly corrected source halfway through a refresh.
public struct WorkspaceSnapshot: Sendable {
    public init() {}
    public var sources: [SourceRecord] = []
    public var claims: [CandidateClaim] = []
    public var currentClaimsBySource: [String: [CandidateClaim]] = [:]
    public var questions: [QuestionRecord] = []
    public var questionHistories: [String: [QuestionRevision]] = [:]
    public var claimOrigins: [DiscussionClaimDerivation] = []
    public var outcomeOrigins: [ConversationOutcomeOrigin] = []
    public var actions: [ActionRecord] = []
    public var actionClarifications: [String: String] = [:]
    public var assistantExecutions: [AssistantExecutionRecord] = []
    public var assistantAssessmentIssues: [AssistantAssessmentIssue] = []
    /// The validation read behind `assistantExecutions`; resume steps reuse it
    /// only while nothing froze after this snapshot was taken.
    var assistantValidation: AssistantValidationContext? = nil
    public var taskInitiations: [TaskInitiationRecord] = []
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
    public var actionReviewLedgers: [String: ActionReviewLedger] = [:]
    /// Secondary reads can freeze stale contexts; the caller should re-read core.
    public var contextValidityChanged = false
}

/// Startup reads the core snapshot first so the library list can paint, then the
/// secondary pieces. The full scope keeps the original single-read contract.
public enum WorkspaceSnapshotScope: Sendable {
    case full, core, secondary, assistant, knowledge
}

extension VoiceOSStore {
    public func workspaceSnapshot(_ scope: WorkspaceSnapshotScope = .full) throws -> WorkspaceSnapshot {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        let wantsCore = scope == .full || scope == .core
        let wantsSecondary = scope == .full || scope == .secondary
        let wantsAssistant = scope == .full || scope == .assistant
        let wantsKnowledge = scope == .full || scope == .knowledge
        var result = WorkspaceSnapshot()
        func readCore() throws {
            result.questions = try StartupTrace.measure("snapshot.questions") { try questions() }
            result.questionHistories = try StartupTrace.measure("snapshot.questionHistories") { try questionHistories() }
            result.claimOrigins = try StartupTrace.measure("snapshot.claimOrigins") { try discussionClaimOrigins() }
            result.outcomeOrigins = try StartupTrace.measure("snapshot.outcomeOrigins") { try conversationOutcomeOrigins() }
            result.taskInitiations = try StartupTrace.measure("snapshot.taskInitiations") { try taskInitiations() }
            result.recentOutcomes = try StartupTrace.measure("snapshot.recentOutcomes") { try recentActionOutcomes() }
            result.compensationPlans = try StartupTrace.measure("snapshot.compensationPlans") { try reminderCompensationPlans() }
            result.compensationGrants = try StartupTrace.measure("snapshot.compensationGrants") { try reminderCompensationGrants() }
            result.compensationOperations = try StartupTrace.measure("snapshot.compensationOperations") { try reminderCompensationOperations() }
            result.reminderLinks = try StartupTrace.measure("snapshot.reminderLinks") { try reminderLinks() }
            result.reminderAccess = try StartupTrace.measure("snapshot.reminderAccess") { try reminderAccess() }
            result.topics = try StartupTrace.measure("snapshot.topics") { try reflectionQuestions() }
            result.topicSources = try StartupTrace.measure("snapshot.topicSources") { try reflectionQuestionSources() }
            result.processingIntents = try StartupTrace.measure("snapshot.processingIntents") { try processingIntents() }
            result.recordingRequests = try StartupTrace.measure("snapshot.recordingRequests") { try recordingProcessingRequests() }
            result.segmentedBatches = try StartupTrace.measure("snapshot.segmentedBatches") { try segmentedProcessingBatches() }
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
            result.actions = try StartupTrace.measure("snapshot.actions") { try actions(includeHistory: true) }
            result.actionClarifications = try StartupTrace.measure("snapshot.actionClarifications") { try actionClarifications() }
            result.claims = try StartupTrace.measure("snapshot.claims") { try candidateClaims(includeFrozen: true) }
            result.currentClaimsBySource = try StartupTrace.measure("snapshot.currentClaimsBySource") { try latestCandidateClaimsBySource(includeFrozen: true) }
            result.attempts = try StartupTrace.measure("snapshot.attempts") { try modelAttemptsBySource() }
            result.sources = try StartupTrace.measure("snapshot.sources") { try sources() }
            result.actionReviewLedgers = try StartupTrace.measure("snapshot.actionReviewLedgers") {
                ActionReviewLedger.buildMap(
                    expressions: try recordingExpressions(), actions: result.actions,
                    resolutions: try actionReviewResolutions(),
                    acknowledgements: try actionReviewAcknowledgements(),
                    linkedActionIDs: Set(result.reminderLinks.map(\.actionID)))
            }
        }
        if wantsCore {
            if scope == .core {
                // The first paint lists what is stored. Context revalidation freezes
                // stale rows and can hash media; the secondary read does that work.
                try withoutContextValidation { try readCore() }
            } else {
                try readCore()
            }
        }
        func readSecondary() throws {
            let freezesBefore = frozenContextCount
            result.correctionImpacts = try StartupTrace.measure("snapshot.correctionImpacts") { try correctionActionImpacts() }
            result.outcomeFollowups = try StartupTrace.measure("snapshot.outcomeFollowups") { try pendingOutcomeFollowups() }
            result.scheduleIntents = try StartupTrace.measure("snapshot.scheduleIntents") { try actionScheduleIntents() }
            result.scheduleOperations = try StartupTrace.measure("snapshot.scheduleOperations") { try reminderScheduleOperations() }
            result.scheduleGrants = try StartupTrace.measure("snapshot.scheduleGrants") { try reminderScheduleGrants() }
            result.reminderAccess = try reminderAccess()
            if let access = result.reminderAccess, access.enabled {
                for intent in result.scheduleIntents {
                    result.schedulePreviews[intent.id] = try? previewReminderSchedule(intentID: intent.id, expectedAccessVersion: access.version)
                }
            }
            result.briefing = try StartupTrace.measure("snapshot.briefing") { try workspaceBriefing() }
            result.recordingFollowups = try StartupTrace.measure("snapshot.recordingFollowups") { try recordingFollowups() }
            result.contextValidityChanged = frozenContextCount != freezesBefore
        }
        if wantsSecondary {
            if scope == .secondary {
                try withoutContextValidation { try readSecondary() }
            } else {
                try readSecondary()
            }
        }
        if wantsAssistant {
            let freezesBefore = frozenContextCount
            var validation: AssistantValidationContext?
            let executionsToken = StartupTrace.begin("snapshot.assistantExecutions")
            result.assistantExecutions = try assistantExecutions(context: &validation)
            StartupTrace.end(executionsToken)
            result.assistantAssessmentIssues = try StartupTrace.measure("snapshot.assistantAssessmentIssues") { try assistantAssessmentIssues(context: validation) }
            result.contextValidityChanged = result.contextValidityChanged || frozenContextCount != freezesBefore
            result.assistantValidation = result.contextValidityChanged ? nil : validation
        }
        if wantsKnowledge {
            result.knowledgeReviews = try StartupTrace.measure("snapshot.knowledgeReviews") { try knowledgeReviews() }
        }
        if scope == .full {
            // Validity follows assistant validation, which may freeze contexts.
            // Reuse this snapshot's reads only when nothing froze after they were
            // taken; a freeze changes claim validity, so those need a fresh read.
            let reusable = !result.contextValidityChanged
            result.followupValidity = try StartupTrace.measure("snapshot.followupValidity") {
                try recordingFollowupValidities(result.recordingFollowups,
                    catalogRows: reusable ? result.sources : nil,
                    claimRows: reusable ? result.claims : nil,
                    actionRows: reusable ? result.actions : nil,
                    latest: reusable ? result.currentClaimsBySource : nil)
            }
        }
        return result
    }
}
