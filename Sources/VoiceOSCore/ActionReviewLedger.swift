import Foundation

public enum ActionReviewRelation: String, Codable, Sendable {
    case same, different
}

public struct ActionReviewPair: Identifiable, Sendable, Equatable {
    public let expressionID: String
    public let decisionsDigest: String
    public let oldActionID: String
    public let newActionID: String
    public let oldTitle: String
    public let newTitle: String
    public let oldKind: String
    public let newKind: String
    public let oldState: String
    public let newState: String
    public let oldHasReminderLink: Bool
    public let sourceID: String
    public let quote: String
    public let mergeBlockedReason: String?
    public var id: String { expressionID + ":" + oldActionID + ":" + newActionID }
    public var isMergeable: Bool { mergeBlockedReason == nil }
}

public enum ActionReviewJudgment: Sendable, Equatable {
    case pair(oldActionID: String, newActionID: String, relation: ActionReviewRelation)
    case acknowledgeExpression
}

public struct ActionReviewResolutionReceipt: Sendable, Equatable {
    public let id: String
    public let expressionID: String
    public let decisionsDigest: String
    public let judgment: ActionReviewJudgment
    public let survivorActionID: String?
    public let dismissedActionID: String?
    public let createdAt: String
}

private func actionReviewPairKey(_ old: String, _ new: String) -> String { old + "\u{1}" + new }

/// The one derived review state every gate reads. Stored decisions are never
/// rewritten; user judgments are applied only to the digest they answered.
public struct ActionReviewLedger: Sendable {
    public let expressionID: String
    public let decisionsDigest: String
    public let isAcknowledged: Bool
    public let unresolvedPairs: [ActionReviewPair]
    public let canAcknowledge: Bool
    let state: String
    let taskReviewPending: Bool?
    let decisions: [RecordingExpressionActionDecision]?
    let resolvedPairs: Set<String>

    public func requiresReview(actionID: String) -> Bool {
        if isAcknowledged { return false }
        guard state == "completed" else { return true }
        guard let decisions else { return taskReviewPending == true }
        let uncertain = decisions.filter { $0.relation == "uncertain" }
        guard uncertain.allSatisfy({ $0.possibleNewIDs != nil }) else { return true }
        let unresolvedCandidateIDs = Set(uncertain.flatMap { decision in
            (decision.possibleNewIDs ?? []).filter {
                !resolvedPairs.contains(actionReviewPairKey(decision.oldID, $0))
            }
        })
        let oldStillPaused = uncertain.contains { decision in
            let candidates = decision.possibleNewIDs ?? []
            return decision.oldID == actionID &&
                (candidates.isEmpty || candidates.contains {
                    !resolvedPairs.contains(actionReviewPairKey(decision.oldID, $0))
                })
        }
        let sameWithPossible = decisions.contains {
            $0.relation == "same" && $0.oldID == actionID && unresolvedCandidateIDs.contains($0.newID)
        }
        return oldStillPaused || unresolvedCandidateIDs.contains(actionID) || sameWithPossible
    }

    public func unresolvedPairs(for actionID: String) -> [ActionReviewPair] {
        unresolvedPairs.filter { $0.oldActionID == actionID || $0.newActionID == actionID }
    }
}

extension ActionReviewLedger {
    static func buildMap(expressions: [RecordingExpression], actions: [ActionRecord],
                         resolutions: [ActionReviewResolutionRecord],
                         acknowledgements: [ExpressionReviewAcknowledgementRecord],
                         linkedActionIDs: Set<String>) -> [String: ActionReviewLedger] {
        let actionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        var result: [String: ActionReviewLedger] = [:]
        for expression in expressions where result[expression.id] == nil {
            result[expression.id] = build(expression: expression, actionsByID: actionsByID,
                                          resolutions: resolutions, acknowledgements: acknowledgements,
                                          linkedActionIDs: linkedActionIDs)
        }
        return result
    }

    static func build(expression: RecordingExpression, actionsByID: [String: ActionRecord],
                      resolutions: [ActionReviewResolutionRecord],
                      acknowledgements: [ExpressionReviewAcknowledgementRecord],
                      linkedActionIDs: Set<String>) -> ActionReviewLedger {
        let digest = expression.reviewDigest
        var resolvedPairs = Set<String>()
        for row in resolutions where row.expressionID == expression.id && row.decisionsDigest == digest {
            resolvedPairs.insert(actionReviewPairKey(row.oldActionID, row.newActionID))
        }
        let acknowledged = acknowledgements.contains {
            $0.expressionID == expression.id && $0.decisionsDigest == digest
        }
        var pairs: [ActionReviewPair] = []
        if let decisions = expression.actionReviewDecisions {
            for decision in decisions where decision.relation == "uncertain" {
                for candidate in decision.possibleNewIDs ?? []
                    where !resolvedPairs.contains(actionReviewPairKey(decision.oldID, candidate)) {
                    guard decision.oldID != candidate,
                          let old = actionsByID[decision.oldID],
                          let new = actionsByID[candidate] else { continue }
                    pairs.append(pair(expression: expression, decision: decision, old: old, new: new,
                                      digest: digest, hasLink: linkedActionIDs.contains(old.id)))
                }
            }
        }
        pairs.sort {
            $0.oldActionID == $1.oldActionID ? $0.newActionID < $1.newActionID : $0.oldActionID < $1.oldActionID
        }
        let hasNonPairPending: Bool
        if let decisions = expression.actionReviewDecisions {
            hasNonPairPending = decisions.contains {
                $0.relation == "uncertain" && ($0.possibleNewIDs ?? []).isEmpty
            }
        } else {
            hasNonPairPending = expression.taskReviewPending == true
        }
        return ActionReviewLedger(
            expressionID: expression.id, decisionsDigest: digest, isAcknowledged: acknowledged,
            unresolvedPairs: pairs,
            canAcknowledge: expression.state == "completed" && !acknowledged && pairs.isEmpty && hasNonPairPending,
            state: expression.state, taskReviewPending: expression.taskReviewPending,
            decisions: expression.actionReviewDecisions, resolvedPairs: resolvedPairs)
    }

    private static func pair(expression: RecordingExpression, decision: RecordingExpressionActionDecision,
                             old: ActionRecord, new: ActionRecord, digest: String, hasLink: Bool) -> ActionReviewPair {
        let blocked: String?
        if old.state == "dismissed" {
            blocked = "原记录已停止跟进，只能核对为两件事"
        } else if old.intent?.expressionHistory?.isEmpty == false {
            blocked = "原记录已有接续历史，只能核对为两件事"
        } else if new.state != "open" || new.validity != "current" {
            blocked = "这次识别已不是当前待办，只能核对为两件事"
        } else if old.state == "completed" && new.kind != "task" {
            blocked = "已完成的记录不能改变类型"
        } else {
            blocked = nil
        }
        return ActionReviewPair(
            expressionID: expression.id, decisionsDigest: digest,
            oldActionID: old.id, newActionID: new.id,
            oldTitle: old.title, newTitle: new.title,
            oldKind: old.kind, newKind: new.kind,
            oldState: old.state, newState: new.state, oldHasReminderLink: hasLink,
            sourceID: decision.sourceID, quote: decision.quote, mergeBlockedReason: blocked)
    }
}

public extension RecordingExpression {
    /// Binds a user judgment to this exact stored review generation. Re-extraction
    /// produces a different digest, so older judgments stop applying by themselves.
    var reviewDigest: String {
        guard let decisions = actionReviewDecisions else { return "no-decisions-v1" }
        let json = (try? VoiceOSStore.relevanceJSON(decisions)) ?? ""
        let pending = taskReviewPending == true ? "1" : "0"
        return VoiceOSStore.relevanceHash(Data(("action-review-v1\n" + id + "\n" + json + "\n" + pending).utf8))
    }
}
