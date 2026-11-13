import Foundation

struct ActionReviewResolutionRecord: Identifiable, Sendable {
    let id: String
    let expressionID: String
    let decisionsDigest: String
    let oldActionID: String
    let newActionID: String
    let relation: String
    let commandID: String
    let inputFingerprint: String
    let createdAt: String
}

struct ExpressionReviewAcknowledgementRecord: Identifiable, Sendable {
    let id: String
    let expressionID: String
    let decisionsDigest: String
    let commandID: String
    let inputFingerprint: String
    let createdAt: String
}

enum ActionReviewSchema {
    static let migration53: [String] = [
        """
        CREATE TABLE action_review_resolutions (
          id TEXT PRIMARY KEY,
          expression_id TEXT NOT NULL,
          decisions_digest TEXT NOT NULL,
          old_action_id TEXT NOT NULL REFERENCES actions(id),
          new_action_id TEXT NOT NULL REFERENCES actions(id),
          relation TEXT NOT NULL CHECK(relation IN ('same','different')),
          command_id TEXT NOT NULL UNIQUE,
          input_fingerprint TEXT NOT NULL,
          actor TEXT NOT NULL CHECK(actor='user'),
          created_at TEXT NOT NULL,
          UNIQUE(expression_id,decisions_digest,old_action_id,new_action_id),
          CHECK(old_action_id<>new_action_id)
        )
        """,
        "CREATE INDEX action_review_resolutions_expression ON action_review_resolutions(expression_id,decisions_digest)",
        "CREATE UNIQUE INDEX action_review_one_same ON action_review_resolutions(expression_id,decisions_digest,old_action_id) WHERE relation='same'",
        """
        CREATE TABLE expression_review_acknowledgements (
          id TEXT PRIMARY KEY,
          expression_id TEXT NOT NULL,
          decisions_digest TEXT NOT NULL,
          command_id TEXT NOT NULL UNIQUE,
          input_fingerprint TEXT NOT NULL,
          actor TEXT NOT NULL CHECK(actor='user'),
          created_at TEXT NOT NULL,
          UNIQUE(expression_id,decisions_digest)
        )
        """,
        "CREATE INDEX expression_review_acks_expression ON expression_review_acknowledgements(expression_id)"
    ]
}

extension VoiceOSStore {
    func actionReviewResolutions() throws -> [ActionReviewResolutionRecord] {
        try db.query("SELECT * FROM action_review_resolutions ORDER BY created_at,id").map {
            ActionReviewResolutionRecord(
                id: $0["id"]!, expressionID: $0["expression_id"]!, decisionsDigest: $0["decisions_digest"]!,
                oldActionID: $0["old_action_id"]!, newActionID: $0["new_action_id"]!, relation: $0["relation"]!,
                commandID: $0["command_id"]!, inputFingerprint: $0["input_fingerprint"]!, createdAt: $0["created_at"]!)
        }
    }

    func actionReviewAcknowledgements() throws -> [ExpressionReviewAcknowledgementRecord] {
        try db.query("SELECT * FROM expression_review_acknowledgements ORDER BY created_at,id").map {
            ExpressionReviewAcknowledgementRecord(
                id: $0["id"]!, expressionID: $0["expression_id"]!, decisionsDigest: $0["decisions_digest"]!,
                commandID: $0["command_id"]!, inputFingerprint: $0["input_fingerprint"]!, createdAt: $0["created_at"]!)
        }
    }

    func actionReviewLedgers() throws -> [String: ActionReviewLedger] {
        let linked = Set(try db.query("SELECT action_id FROM reminder_links").compactMap { $0["action_id"] })
        return ActionReviewLedger.buildMap(
            expressions: try recordingExpressions(),
            actions: try actions(includeHistory: true),
            resolutions: try actionReviewResolutions(),
            acknowledgements: try actionReviewAcknowledgements(),
            linkedActionIDs: linked)
    }

    func actionReviewLedger(expressionID: String) throws -> ActionReviewLedger? {
        try actionReviewLedgers()[expressionID]
    }

    @discardableResult
    public func resolveActionReview(expressionID: String, judgment: ActionReviewJudgment,
                                    expectedDecisionsDigest: String,
                                    commandID: String = UUID().uuidString) throws -> ActionReviewResolutionReceipt {
        guard !commandID.isEmpty else { throw VoiceOSError("核对命令为空") }
        guard let expression = try recordingExpressions().first(where: { $0.id == expressionID }) else {
            throw VoiceOSError("连续表达不存在或依据已变化")
        }
        guard expression.state == "completed", expression.reviewDigest == expectedDecisionsDigest else {
            throw VoiceOSError("行动核对依据已更新，请刷新后再核对")
        }
        switch judgment {
        case .pair(let oldID, let newID, let relation):
            guard oldID != newID, let decisions = expression.actionReviewDecisions,
                  decisions.contains(where: { decision in
                      decision.relation == "uncertain" && decision.oldID == oldID &&
                          (decision.possibleNewIDs ?? []).contains(newID)
                  }) else { throw VoiceOSError("这条行动关系不属于当前待核对范围") }
            let fingerprint = try Self.actionHash([expressionID, expectedDecisionsDigest, oldID, newID, relation.rawValue])
            if let row = try db.query("SELECT * FROM action_review_resolutions WHERE command_id=?", [commandID]).first {
                guard row["input_fingerprint"] == fingerprint, row["expression_id"] == expressionID else {
                    throw VoiceOSError("同一核对命令不能更换内容")
                }
                return Self.receipt(row)
            }
            if let row = try db.query("""
                SELECT * FROM action_review_resolutions
                WHERE expression_id=? AND decisions_digest=? AND old_action_id=? AND new_action_id=?
                """, [expressionID, expectedDecisionsDigest, oldID, newID]).first {
                guard row["relation"] == relation.rawValue else {
                    throw VoiceOSError("这条行动关系已经核对过，不能改判")
                }
                return Self.receipt(row)
            }
            let id = UUID().uuidString, now = Self.now()
            if relation == .same {
                try db.transaction {
                    guard let current = try recordingExpressions().first(where: { $0.id == expressionID }),
                          current.reviewDigest == expectedDecisionsDigest,
                          current.actionReviewDecisions?.contains(where: {
                              $0.relation == "uncertain" && $0.oldID == oldID &&
                                  ($0.possibleNewIDs ?? []).contains(newID)
                          }) == true else { throw VoiceOSError("行动核对依据已更新，请刷新后再核对") }
                    try insertResolution(id: id, expressionID: expressionID, digest: expectedDecisionsDigest,
                                         oldID: oldID, newID: newID, relation: relation,
                                         commandID: commandID, fingerprint: fingerprint, createdAt: now)
                    try applySameAdoption(oldActionID: oldID, newActionID: newID)
                }
            } else {
                try insertResolution(id: id, expressionID: expressionID, digest: expectedDecisionsDigest,
                                     oldID: oldID, newID: newID, relation: relation,
                                     commandID: commandID, fingerprint: fingerprint, createdAt: now)
            }
            return ActionReviewResolutionReceipt(
                id: id, expressionID: expressionID, decisionsDigest: expectedDecisionsDigest,
                judgment: judgment,
                survivorActionID: relation == .same ? oldID : nil,
                dismissedActionID: relation == .same ? newID : nil,
                createdAt: now)
        case .acknowledgeExpression:
            let fingerprint = try Self.actionHash([expressionID, expectedDecisionsDigest, "acknowledged"])
            if let row = try db.query("SELECT * FROM expression_review_acknowledgements WHERE command_id=?", [commandID]).first {
                guard row["input_fingerprint"] == fingerprint, row["expression_id"] == expressionID else {
                    throw VoiceOSError("同一核对命令不能更换内容")
                }
                return Self.acknowledgementReceipt(row)
            }
            if let row = try db.query("SELECT * FROM expression_review_acknowledgements WHERE expression_id=? AND decisions_digest=?",
                                      [expressionID, expectedDecisionsDigest]).first {
                return Self.acknowledgementReceipt(row)
            }
            guard let current = try actionReviewLedger(expressionID: expressionID),
                  current.decisionsDigest == expectedDecisionsDigest,
                  current.canAcknowledge else { throw VoiceOSError("仍有行动关系需要逐条核对") }
            let id = UUID().uuidString, now = Self.now()
            try db.execute("""
                INSERT INTO expression_review_acknowledgements
                (id,expression_id,decisions_digest,command_id,input_fingerprint,actor,created_at)
                VALUES(?,?,?,?,?,'user',?)
                """, [id, expressionID, expectedDecisionsDigest, commandID, fingerprint, now])
            return ActionReviewResolutionReceipt(
                id: id, expressionID: expressionID, decisionsDigest: expectedDecisionsDigest,
                judgment: .acknowledgeExpression, survivorActionID: nil, dismissedActionID: nil,
                createdAt: now)
        }
    }

    private func insertResolution(id: String, expressionID: String, digest: String, oldID: String,
                                  newID: String, relation: ActionReviewRelation,
                                  commandID: String, fingerprint: String, createdAt: String) throws {
        try db.execute("""
            INSERT INTO action_review_resolutions
            (id,expression_id,decisions_digest,old_action_id,new_action_id,relation,command_id,input_fingerprint,actor,created_at)
            VALUES(?,?,?,?,?,?,?,?,'user',?)
            """, [id, expressionID, digest, oldID, newID, relation.rawValue, commandID, fingerprint, createdAt])
    }

    private func applySameAdoption(oldActionID: String, newActionID: String) throws {
        guard let old = try db.query("SELECT * FROM actions WHERE id=?", [oldActionID]).first,
              let new = try db.query("SELECT * FROM actions WHERE id=?", [newActionID]).first,
              old["state"] != "dismissed",
              new["state"] == "open", new["validity"] == "current" else {
            throw VoiceOSError("行动状态已变化，请刷新后再核对")
        }
        let oldMetadata = try old["intent_json"].map {
            try JSONDecoder().decode(ActionIntentMetadata.self, from: Data($0.utf8))
        }
        guard (oldMetadata?.expressionHistory ?? []).isEmpty else {
            throw VoiceOSError("原记录已有接续历史，只能核对为两件事")
        }
        let newMetadata = try new["intent_json"].map {
            try JSONDecoder().decode(ActionIntentMetadata.self, from: Data($0.utf8))
        }
        let oldClaimID = old["claim_id"]!, newClaimID = new["claim_id"]!
        let newKind = new["kind"]!
        let kind = old["kind"] == "task" || newKind == "task" ? "task" : newKind
        guard old["state"] != "completed" || kind == "task" else {
            throw VoiceOSError("已完成的记录不能改变类型")
        }
        var metadata = ActionIntentMetadata(
            intentType: kind == "task" ? "task" : (newMetadata?.intentType ?? "idea"),
            followupState: newMetadata?.followupState ?? oldMetadata?.followupState ?? "pending",
            uncertain: false)
        metadata.goalID = newMetadata?.goalID ?? oldMetadata?.goalID
        metadata.reminderFields = oldMetadata?.reminderFields
        metadata.expressionHistory = oldMetadata?.expressionHistory
        metadata.expressionWithdrawal = oldMetadata?.expressionWithdrawal
        metadata.expressionWithdrawalVersionID = oldMetadata?.expressionWithdrawalVersionID
        metadata.expressionWithdrawalResponseIDs = oldMetadata?.expressionWithdrawalResponseIDs
        try db.execute("""
            UPDATE actions SET claim_id=?,claim_review_version=?,title=?,note=?,kind=?,intent_json=?,validity='current'
            WHERE id=?
            """, [newClaimID, new["claim_review_version"]!, new["title"]!, new["note"]!, kind,
                   try Self.relevanceJSON(metadata), oldActionID])
        if oldClaimID != newClaimID {
            try db.execute("""
                UPDATE claims SET validity='frozen' WHERE id=?
                AND NOT EXISTS(SELECT 1 FROM actions WHERE claim_id=? AND validity='current')
                """, [oldClaimID, oldClaimID])
        }
        let item = RecordingExpressionActionItem(
            id: newActionID, claimID: newClaimID, title: new["title"]!, kind: newKind,
            note: new["note"]!, state: new["state"]!, version: Int(new["version"]!)!,
            claimReviewVersion: Int(new["claim_review_version"]!)!, statement: "")
        try dismissExpressionAction(item, note: "用户核对为同一件事：接回 " + oldActionID)
        try db.execute("UPDATE actions SET validity='frozen' WHERE id=?", [newActionID])
        try db.execute("UPDATE reminder_links SET desired_title=? WHERE action_id=?", [new["title"]!, oldActionID])
    }

    private static func receipt(_ row: [String: String]) -> ActionReviewResolutionReceipt {
        let relation = ActionReviewRelation(rawValue: row["relation"] ?? "") ?? .different
        return ActionReviewResolutionReceipt(
            id: row["id"]!, expressionID: row["expression_id"]!, decisionsDigest: row["decisions_digest"]!,
            judgment: .pair(oldActionID: row["old_action_id"]!, newActionID: row["new_action_id"]!, relation: relation),
            survivorActionID: relation == .same ? row["old_action_id"] : nil,
            dismissedActionID: relation == .same ? row["new_action_id"] : nil,
            createdAt: row["created_at"]!)
    }

    private static func acknowledgementReceipt(_ row: [String: String]) -> ActionReviewResolutionReceipt {
        ActionReviewResolutionReceipt(
            id: row["id"]!, expressionID: row["expression_id"]!, decisionsDigest: row["decisions_digest"]!,
            judgment: .acknowledgeExpression, survivorActionID: nil, dismissedActionID: nil,
            createdAt: row["created_at"]!)
    }

    static func validateStoredActionReviewResolutions(_ database: Database) throws {
        var expressionIDs = Set<String>()
        for row in try database.query("SELECT presentation_json FROM sources") {
            guard let raw = row["presentation_json"],
                  let expression = try? JSONDecoder().decode(RecordingPresentation.self, from: Data(raw.utf8)).expression else { continue }
            expressionIDs.insert(expression.id)
        }
        for row in try database.query("SELECT * FROM action_review_resolutions") {
            guard let id = row["id"], UUID(uuidString: id) != nil,
                  let expressionID = row["expression_id"], expressionIDs.contains(expressionID),
                  let digest = row["decisions_digest"], validDigest(digest),
                  let oldID = row["old_action_id"], let newID = row["new_action_id"], oldID != newID,
                  let relation = row["relation"], ["same", "different"].contains(relation),
                  row["actor"] == "user",
                  try database.query("SELECT id FROM actions WHERE id=?", [oldID]).count == 1,
                  try database.query("SELECT id FROM actions WHERE id=?", [newID]).count == 1,
                  let fingerprint = row["input_fingerprint"],
                  fingerprint == (try actionHash([expressionID, digest, oldID, newID, relation])) else {
                throw VoiceOSError("保存的行动关系核对记录不一致")
            }
        }
        for row in try database.query("SELECT * FROM expression_review_acknowledgements") {
            guard let id = row["id"], UUID(uuidString: id) != nil,
                  let expressionID = row["expression_id"], expressionIDs.contains(expressionID),
                  let digest = row["decisions_digest"], validDigest(digest),
                  row["actor"] == "user",
                  let fingerprint = row["input_fingerprint"],
                  fingerprint == (try actionHash([expressionID, digest, "acknowledged"])) else {
                throw VoiceOSError("保存的连续表达核对记录不一致")
            }
        }
    }

    private static func validDigest(_ digest: String) -> Bool {
        digest == "no-decisions-v1" ||
            (digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) })
    }
}
