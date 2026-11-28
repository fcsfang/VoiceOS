import Foundation
import CryptoKit

private struct ReminderSuccessorPending: Error {
    static let message = "外部完成已登记；下一次未生成，请重试"
}

public struct ReminderSnapshot: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let completed: Bool
    public let marker: String
    public let dueDate: ReminderDueDate?
    public let fields: ReminderFields?
    public init(id: String, title: String, completed: Bool, marker: String, dueDate: ReminderDueDate? = nil, fields: ReminderFields? = nil) {
        self.id = id; self.title = title; self.completed = completed; self.marker = marker; self.dueDate = dueDate; self.fields = fields
    }
}
public protocol RemindersPort: Sendable {
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot]
    func create(calendarID: String, title: String, marker: String, context: String) async throws
}
public struct ReminderLink: Identifiable, Sendable {
    public let id: String
    public let actionID: String
    public let calendarID: String
    public let state: String
    public let externalID: String?
    public let remoteTitle: String?
    public let remoteCompleted: Bool?
    public let lastObservedAt: String?
    public let lastCheckedAt: String?
    public let lastObservationID: String?
    public let remoteMarkerValid: Bool?
    public let remoteDueDate: ReminderDueDate?
}
public struct ReminderSyncAnomaly: Identifiable, Sendable, Equatable {
    public let id: String
    public let actionID: String
    public let actionTitle: String
    public let desiredTitle: String
    public let marker: String
    public let state: String
    public init(id: String, actionID: String, actionTitle: String, desiredTitle: String, marker: String, state: String) {
        self.id = id; self.actionID = actionID; self.actionTitle = actionTitle
        self.desiredTitle = desiredTitle; self.marker = marker; self.state = state
    }
}
public enum ReminderSyncFailureStage: String, Codable, Sendable, Equatable {
    case expression, activation
}
/// The newest per-task reminder sync failure. One row per task and stage; a
/// later success, a confirmed link, or a dropped update deletes it.
public struct ReminderSyncFailure: Identifiable, Sendable, Equatable {
    public let actionID: String
    public let actionTitle: String
    public let stage: ReminderSyncFailureStage
    public let reason: String
    public let failedAt: String
    public var id: String { actionID + ":" + stage.rawValue }
}
public struct ReminderSyncAnomalySummary: Sendable, Equatable {
    public let items: [ReminderSyncAnomaly]
    public let failures: [ReminderSyncFailure]
    public init(items: [ReminderSyncAnomaly] = [], failures: [ReminderSyncFailure] = []) { self.items = items; self.failures = failures }
    public static let empty = ReminderSyncAnomalySummary()
    public var total: Int { items.count }
    public var failureTotal: Int { failures.count }
    public func count(_ state: String) -> Int { items.filter { $0.state == state }.count }
}
/// One readback round observes one consistent local view. `reminder_links.action_id`
/// is unique, so the round exists to run the cognition barrier and the action load
/// once instead of once per link.
final class ReminderObservationRound {
    private var actionsByID: [String: ActionRecord]?
    var isLoaded: Bool { actionsByID != nil }
    func store(_ actions: [ActionRecord]) {
        actionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    }
    func action(id: String) -> ActionRecord? { actionsByID?[id] }
}
/// Counts full observation loads so the reconcile test can lock one load per round.
final class ReminderObservationStats: @unchecked Sendable {
    var fullObservationLoads = 0
}
extension VoiceOSStore {
    public func reminderContext(actionID: String) throws -> String {
        guard let action = try self.action(id: actionID, includeHistory: true),
              action.validity == "current", let claim = try candidateClaim(id: action.claimID) else { throw VoiceOSError("任务出处不可用或已变化") }
        var lines: [String] = []
        for sourceID in Set(claim.references.map(\.sourceID)).sorted() {
            guard let name = try db.query("SELECT name FROM sources WHERE id=?", [sourceID]).first?["name"] else { continue }
            let refs = claim.references.filter { $0.sourceID == sourceID }
            var spans: [TranscriptSpan] = []
            for version in Set(refs.map(\.transcriptVersionID)) {
                if let json = try db.query("SELECT spans_json FROM transcript_versions WHERE id=?", [version]).first?["spans_json"] {
                    spans += try JSONDecoder().decode([TranscriptSpan].self, from: Data(json.utf8)).filter { span in refs.contains { $0.spanID == span.id } }
                }
            }
            var ranges: [(Int, Int)] = []
            let timed = spans.compactMap { span -> (Int, Int)? in
                guard let start = span.startMS, let end = span.endMS else { return nil }; return (start, end)
            }.sorted { $0.0 < $1.0 }
            for (start, end) in timed {
                if let previous = ranges.last, start <= previous.1 + 1000 { ranges[ranges.count - 1].1 = max(previous.1, end) }
                else { ranges.append((start, end)) }
            }
            func time(_ ms: Int) -> String { let seconds = ms / 1000; return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
            let range = ranges.isEmpty ? "" : " [" + ranges.map { time($0.0) + "–" + time($0.1) }.joined(separator: "；") + "]"
            lines.append("来源：" + name + range)
        }
        if let original = try db.query("SELECT note FROM actions WHERE id=?", [actionID]).first?["note"], !original.isEmpty {
            lines.append("原话：" + original)
            if action.note != original, !action.note.isEmpty { lines.append("说明：" + action.note) }
        } else if !action.note.isEmpty { lines.append("说明：" + action.note) }
        if let detail = claim.statement.components(separatedBy: "\n说明：").dropFirst().first, !detail.isEmpty { lines.append("说明：" + detail) }
        return lines.joined(separator: "\n\n")
    }
    public func reminderLinks() throws -> [ReminderLink] {
        try db.query("SELECT l.*,o.id AS observation_id,o.marker_valid,o.title AS remote_title,o.completed AS remote_completed,o.created_at AS observed_at FROM reminder_links l LEFT JOIN reminder_observations o ON o.id=(SELECT id FROM reminder_observations WHERE link_id=l.id ORDER BY sequence DESC LIMIT 1) ORDER BY l.created_at,l.id").map {
            ReminderLink(id: $0["id"]!, actionID: $0["action_id"]!, calendarID: $0["calendar_id"]!, state: $0["state"]!, externalID: $0["external_id"], remoteTitle: $0["remote_title"], remoteCompleted: $0["remote_completed"].map { $0 == "1" }, lastObservedAt: $0["observed_at"], lastCheckedAt: $0["last_checked_at"], lastObservationID: $0["observation_id"], remoteMarkerValid: $0["marker_valid"].map { $0 == "1" }, remoteDueDate: try storedReminderDue(observationID: $0["observation_id"]))
        }
    }
    /// Links whose last readback could not confirm a single Apple reminder, plus
    /// per-task sync failures that stopped short of touching the link.
    public func reminderSyncAnomalies() throws -> ReminderSyncAnomalySummary {
        let items = try db.query("""
            SELECT l.id,l.action_id,l.desired_title,l.marker,l.state,a.title FROM reminder_links l
            JOIN actions a ON a.id=l.action_id WHERE l.state IN ('missing','conflict','unknown')
            ORDER BY CASE l.state WHEN 'missing' THEN 0 WHEN 'conflict' THEN 1 ELSE 2 END, a.title, l.id
            """).map {
                ReminderSyncAnomaly(id: $0["id"]!, actionID: $0["action_id"]!, actionTitle: $0["title"]!,
                                    desiredTitle: $0["desired_title"]!, marker: $0["marker"]!, state: $0["state"]!)
            }
        let failures = try db.query("""
            SELECT f.action_id,f.stage,f.reason,f.failed_at,a.title FROM reminder_sync_failures f
            JOIN actions a ON a.id=f.action_id ORDER BY f.failed_at,a.title,f.action_id
            """).compactMap { row -> ReminderSyncFailure? in
                guard let stage = row["stage"].flatMap(ReminderSyncFailureStage.init(rawValue:)) else { return nil }
                return ReminderSyncFailure(actionID: row["action_id"]!, actionTitle: row["title"]!, stage: stage,
                                           reason: row["reason"]!, failedAt: row["failed_at"]!)
            }
        return ReminderSyncAnomalySummary(items: items, failures: failures)
    }
    func recordReminderSyncFailure(actionID: String, stage: ReminderSyncFailureStage, reason: String,
                                   at timestamp: String = ISO8601DateFormatter().string(from: Date())) throws {
        try db.execute("INSERT INTO reminder_sync_failures(action_id,stage,reason,failed_at) VALUES(?,?,?,?) ON CONFLICT(action_id,stage) DO UPDATE SET reason=excluded.reason,failed_at=excluded.failed_at",
                       [actionID, stage.rawValue, reason, timestamp])
    }
    func clearReminderSyncFailure(actionID: String, stage: ReminderSyncFailureStage) throws {
        try db.execute("DELETE FROM reminder_sync_failures WHERE action_id=? AND stage=?", [actionID, stage.rawValue])
    }
    /// Rows whose cause is gone stop showing: an activation failure clears once
    /// its link is confirmed, an expression failure once no completed expression
    /// still lists the update.
    func clearResolvedReminderSyncFailures() throws {
        try db.execute("DELETE FROM reminder_sync_failures WHERE stage='activation' AND EXISTS(SELECT 1 FROM reminder_links l WHERE l.action_id=reminder_sync_failures.action_id AND l.state='linked')")
        let pending = Set(try recordingExpressions().filter { $0.state == "completed" }.flatMap { $0.reminderUpdates ?? [] })
        for row in try db.query("SELECT action_id FROM reminder_sync_failures WHERE stage='expression'") where !pending.contains(row["action_id"]!) {
            try clearReminderSyncFailure(actionID: row["action_id"]!, stage: .expression)
        }
    }
    /// One create attempt per action identity. Every subsequent invocation only reads.
    public func sendTaskToReminders(actionID: String, expectedVersion: Int, calendarID: String, using port: any RemindersPort, expectedAccessVersion: Int? = nil) async throws {
        try Task.checkCancellation()
        try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
        if let existing = try db.query("SELECT * FROM reminder_links WHERE action_id=?", [actionID]).first {
            guard existing["calendar_id"] == calendarID else { throw VoiceOSError("已有提醒事项尝试，不能更换清单重复创建") }
            try await readReminder(linkID: existing["id"]!, calendarID: calendarID, using: port, expectedAccessVersion: expectedAccessVersion); return
        }
        guard !calendarID.isEmpty, calendarID.utf8.count <= 4096,
              let action = try self.action(id: actionID), action.version == expectedVersion, action.kind == "task", action.intentActor == "user" else {
            throw VoiceOSError("只能把有效的明确任务发送到所选清单")
        }
        guard let claim = try eligibleReminderClaim(for: action, requiresLatest: false) else { throw VoiceOSError("行动依据仅限本机或连续表达仍待核对，不能写入提醒事项") }
        if expectedAccessVersion != nil {
            guard try reminderCognitionIsLatest(claim) else { throw VoiceOSError("行动认知批次已更新，停止历史任务外写") }
        }
        let id = UUID().uuidString; let marker = "voiceos-action:" + id
        try db.execute("INSERT INTO reminder_links(id,action_id,action_version,calendar_id,marker,desired_title,state,created_at) VALUES(?,?,?,?,?,?,'reserved',?)", [id,actionID,String(expectedVersion),calendarID,marker,action.title,ISO8601DateFormatter().string(from: Date())])
        activeReminderLinks.insert(id); defer { activeReminderLinks.remove(id) }
        do {
            try checkpoint(.reminderReserved)
            // Explicit preflight query. Absence after a prior attempt never permits recreation.
            let found = try await port.find(calendarID: calendarID, externalID: nil, marker: marker)
            try Task.checkCancellation()
            try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
            guard found.isEmpty else { throw VoiceOSError("操作标记已有匹配，停止新建并请回读") }
            guard let current = try self.action(id: actionID), current.version == expectedVersion,
                  let currentClaim = try eligibleReminderClaim(for: current, requiresLatest: false) else { throw VoiceOSError("发送前行动或依据已变化") }
            if expectedAccessVersion != nil {
                guard try reminderCognitionIsLatest(currentClaim) else { throw VoiceOSError("发送前认知批次已更新，停止历史任务外写") }
            }
            if let fields = current.intent?.reminderFields?.desired {
                let expected = current.intent?.reminderFields?.sourceVersions ?? [:]
                let currentSources = try sourceTranscriptRevisions(ids: Array(expected.keys))
                guard expected.allSatisfy({ currentSources[$0.key]?.versionID == $0.value }) else {
                    throw VoiceOSError("提醒字段的原话已变化，请重新核对")
                }
                guard let fieldsPort = port as? any RemindersFieldsPort else { throw VoiceOSError("当前连接不支持日期、通知和优先级") }
                try await fieldsPort.create(calendarID: calendarID, title: action.title, marker: marker, context: reminderContext(actionID: actionID), fields: fields)
            } else {
                try await port.create(calendarID: calendarID, title: action.title, marker: marker, context: reminderContext(actionID: actionID))
            }
            try checkpoint(.reminderSaved)
            // Save return is not readback evidence. Record ambiguity before the next await.
            try db.execute("UPDATE reminder_links SET state='unknown' WHERE id=?", [id])
            try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
            try Task.checkCancellation()
            let matches = try await port.find(calendarID: calendarID, externalID: nil, marker: marker)
            try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
            try Task.checkCancellation()
            try applyReminder(matches, linkID: id)
            if let desired = current.intent?.reminderFields?.desired {
                guard matches.count == 1, matches[0].fields == desired else { throw VoiceOSError("提醒字段未完成回读核对") }
            }
        } catch {
            try db.execute("UPDATE reminder_links SET state='unknown' WHERE id=? AND state='reserved'", [id])
            // Preserve cancellation for the refresh orchestrator: stopping a
            // send must also stop its follow-up reconciliation, even when a
            // connector returns normally after the task was cancelled.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error is ReminderSuccessorPending { throw VoiceOSError(ReminderSuccessorPending.message) }
            throw VoiceOSError("提醒事项结果尚未确认；尝试已保留，请回读，不会自动重建（\(error.localizedDescription)）")
        }
    }
    /// Read the claim once for permission and freshness checks at each preflight.
    /// Callers re-enter after an await wherever the operation requires revalidation.
    func eligibleReminderClaim(for action: ActionRecord, requiresLatest: Bool = true) throws -> CandidateClaim? {
        guard let claim = try candidateClaim(id: action.claimID), !claim.references.isEmpty else { return nil }
        let ledgers = try actionReviewLedgers()
        var checkedSources = Set<String>()
        for ref in claim.references where checkedSources.insert(ref.sourceID).inserted {
            guard let source=try db.query("SELECT local_only,presentation_json FROM sources WHERE id=?", [ref.sourceID]).first,source["local_only"] == "0" else { return nil }
            if let raw=source["presentation_json"],let expression=try JSONDecoder().decode(RecordingPresentation.self,from:Data(raw.utf8)).expression {
                guard let ledger = ledgers[expression.id], !ledger.requiresReview(actionID: action.id) else { return nil }
            }
        }
        if requiresLatest, try !reminderCognitionIsLatest(claim) { return nil }
        return claim
    }
    /// A source may be reprocessed while the connector's preflight is awaiting.
    /// Only new writes use this barrier; existing links still reconcile history.
    func reminderCognitionIsLatest(_ claim: CandidateClaim) throws -> Bool {
        guard !claim.references.isEmpty else { return false }
        for sourceID in Set(claim.references.map(\.sourceID)) {
            guard try latestCandidateClaims(for: sourceID).contains(where: { $0.id == claim.id }) else { return false }
        }
        return true
    }
    public func readReminder(linkID: String, calendarID: String, using port: any RemindersPort, expectedAccessVersion: Int? = nil) async throws {
        try await readReminder(linkID: linkID, calendarID: calendarID, using: port, expectedAccessVersion: expectedAccessVersion, observationRound: nil, observationStats: nil)
    }
    func readReminder(linkID: String, calendarID: String, using port: any RemindersPort, expectedAccessVersion: Int?, observationRound: ReminderObservationRound?, observationStats: ReminderObservationStats?) async throws {
        try Task.checkCancellation()
        try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
        guard !activeReminderLinks.contains(linkID) else { throw VoiceOSError("提醒事项操作正在进行") }
        guard let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [linkID]).first, link["calendar_id"] == calendarID else { throw VoiceOSError("只能回读明确选定清单内的关联任务") }
        activeReminderLinks.insert(linkID); defer { activeReminderLinks.remove(linkID) }
        do {
            let matches = try await port.find(calendarID: calendarID, externalID: link["external_id"], marker: link["marker"]!)
            try checkReminderAccess(calendarID: calendarID, expectedVersion: expectedAccessVersion)
            try Task.checkCancellation()
            try applyReminder(matches, linkID: linkID, observationRound: observationRound, observationStats: observationStats)
        } catch {
            try preserveConfirmedReminderLink(linkID)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error is ReminderSuccessorPending { throw VoiceOSError(ReminderSuccessorPending.message) }
            throw VoiceOSError("提醒事项回读失败，结果未知；没有修改或重建外部任务")
        }
    }
    private func preserveConfirmedReminderLink(_ linkID: String) throws {
        guard let row = try db.query("SELECT l.state,a.state AS action_state FROM reminder_links l JOIN actions a ON a.id=l.action_id WHERE l.id=?", [linkID]).first,
              row["state"] != "linked", row["action_state"] != "completed" else { return }
        try db.execute("UPDATE reminder_links SET state='unknown' WHERE id=?", [linkID])
    }
    func applyReminder(_ matches: [ReminderSnapshot], linkID: String, includingScheduleOperation: String? = nil, includingCompensationOperation: String? = nil, observationRound: ReminderObservationRound? = nil, observationStats: ReminderObservationStats? = nil) throws {
        guard let link = try db.query("SELECT * FROM reminder_links WHERE id=?", [linkID]).first else { throw VoiceOSError("提醒事项关联缺失") }
        guard matches.count == 1, let remote = matches.first else {
            try db.transaction {
                try db.execute("UPDATE reminder_links SET state=?,last_checked_at=? WHERE id=?", [matches.isEmpty ? "missing" : "conflict",ISO8601DateFormatter().string(from: Date()),linkID])
                _ = try observePendingScheduleOperations(matches, linkID: linkID, including: includingScheduleOperation)
                _ = try observePendingCompensationOperations(matches,linkID: linkID,including: includingCompensationOperation)
            }
            return
        }
        guard !remote.id.isEmpty, remote.id.utf8.count <= 4096, remote.title.unicodeScalars.count <= 10000, remote.marker.utf8.count <= 4096 else { throw VoiceOSError("提醒事项字段无效或过长") }
        try remote.dueDate?.validate()
        try remote.fields?.validate(allowingAlertsWithoutDue: true)
        let action: ActionRecord?
        if let observationRound {
            if !observationRound.isLoaded {
                observationRound.store(try actions(includeHistory: true))
                observationStats?.fullObservationLoads += 1
            }
            action = observationRound.action(id: link["action_id"]!)
        } else {
            action = try link["action_id"].flatMap { try self.action(id: $0, includeHistory: true) }
        }
        let validMarker = remote.marker == link["marker"]
        // Once identified, a copied marker on a replacement is a conflict,
        // not permission to transfer identity or complete the original task.
        let stableIdentity = link["external_id"] == nil || link["external_id"] == remote.id
        let observationID = UUID().uuidString
        let sequence = Int(try db.query("SELECT COUNT(*) AS n FROM reminder_observations WHERE link_id=?", [linkID]).first!["n"]!)! + 1
        var feedbackID: String?
        var conflict = !validMarker || !stableIdentity
        let baseline = try reminderStatusBaseline(link)
        var confirmedScheduleOperations: [String] = []
        var confirmedCompensations: [String] = []
        try db.transaction {
            if validMarker, stableIdentity, let action, let fields = remote.fields { try observeReminderFields(action: action, fields: fields) }
            if validMarker, stableIdentity, let action, action.validity == "current" {
                if remote.completed && action.state == "open" && action.version == baseline {
                    let revisionID = UUID().uuidString
                    let next = action.version + 1
                    let note = "Apple 提醒事项唯一关联项回读为已完成；不代表观点已验证"
                    let fields = [action.id,String(action.version),"completed",note]
                    let hash = SHA256.hash(data: try JSONSerialization.data(withJSONObject: fields)).map { String(format: "%02x", $0) }.joined()
                    try db.execute("INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at) VALUES(?,?,?,?,?,?,'external',?,?,?)", [revisionID,action.id,String(next),String(action.version),"completed",note,"reminder-feedback:"+observationID,hash,ISO8601DateFormatter().string(from: Date())])
                    try db.execute("UPDATE actions SET state='completed',version=? WHERE id=?", [String(next),action.id])
                    feedbackID = revisionID
                } else if remote.completed != (action.state == "completed") {
                    // External reopen or a local edit cannot silently overwrite either side.
                    conflict = true
                }
            }
            let prior = try db.query("SELECT * FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [linkID]).first
            let priorDue = try storedReminderDue(observationID: prior?["id"])
            let changed = prior?["external_id"] != remote.id || prior?["title"] != remote.title || prior?["completed"] != (remote.completed ? "1" : "0") || prior?["marker_valid"] != (validMarker ? "1" : "0") || priorDue != remote.dueDate
            if changed || feedbackID != nil {
                try db.execute("INSERT INTO reminder_observations(id,link_id,external_id,title,completed,marker_valid,feedback_revision_id,created_at,sequence) VALUES(?,?,?,?,?,?,?,?,?)", [observationID,linkID,remote.id,remote.title,remote.completed ? "1" : "0",validMarker ? "1" : "0",feedbackID,ISO8601DateFormatter().string(from: Date()),String(sequence)])
                if let due = remote.dueDate {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let json = String(decoding: try encoder.encode(due), as: UTF8.self)
                    try db.execute("INSERT INTO reminder_time_observations(id,due_json) VALUES(?,?)", [observationID,json])
                }
            }
            try db.execute("UPDATE reminder_links SET state=?,external_id=?,last_checked_at=? WHERE id=?", [conflict ? "conflict" : "linked",link["external_id"] ?? remote.id,ISO8601DateFormatter().string(from: Date()),linkID])
            confirmedScheduleOperations = try observePendingScheduleOperations(matches, linkID: linkID, including: includingScheduleOperation)
            confirmedCompensations = try observePendingCompensationOperations(matches,linkID: linkID,including: includingCompensationOperation)
            try checkpoint(.reminderFeedbackUncommitted)
        }
        try checkpoint(.reminderFeedbackCommitted)
        let completed = (try db.query("SELECT state FROM actions WHERE id=?", [link["action_id"]!]).first?["state"]) == "completed"
        var successorPending = false
        if completed, try db.query("SELECT action_id FROM action_recurrence WHERE action_id=?", [link["action_id"]!]).first != nil {
            do { _ = try completeActionWithRecurrence(id: link["action_id"]!) }
            catch { successorPending = true }
        }
        for _ in confirmedScheduleOperations { try checkpoint(.scheduleOperationCommitted) }
        for _ in confirmedCompensations { try checkpoint(.compensationOperationCommitted) }
        if successorPending { throw ReminderSuccessorPending() }
    }
    static func validateStoredReminders(_ db: Database) throws {
        let clarifiedOpportunities = try clarifiedOpportunityActionIDs(db)
        for link in try db.query("SELECT l.*,a.kind,a.title,a.state AS action_state,a.intent_json,a.version AS latest_version FROM reminder_links l JOIN actions a ON a.id=l.action_id") {
            let metadata=try link["intent_json"].map { try JSONDecoder().decode(ActionIntentMetadata.self,from:Data($0.utf8)) }
            let editedTitle = try !db.query("SELECT 1 FROM action_revisions WHERE action_id=? AND command_id LIKE 'content:%' AND note=? AND version<=?", [link["action_id"],link["desired_title"],link["action_version"]]).isEmpty
            let historicTitle=metadata?.expressionHistory?.contains { $0.fromTitle == link["desired_title"] } == true
            var withdrawn=false
            if let decision=metadata?.expressionWithdrawal,let version=metadata?.expressionWithdrawalVersionID,
               decision.oldID == link["action_id"],decision.relation == "withdraw",!decision.quote.isEmpty,
               let receipts=metadata?.expressionWithdrawalResponseIDs,receipts.count >= 2,Set(receipts).count == receipts.count,
               let original=try db.query("SELECT v.text,v.reason FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id WHERE v.id=? AND t.source_id=?",[version,decision.sourceID]).first {
                withdrawn=link["action_state"] == "dismissed" && link["desired_title"] == "已撤回 · "+(link["title"] ?? "") && (original["text"]?.contains(decision.quote) == true || original["reason"] == "ai_superseded")
            }
            guard (link["kind"] == "task" || clarifiedOpportunities.contains(link["action_id"]!)), link["marker"] == "voiceos-action:" + link["id"]!,
                  let pin = link["action_version"].flatMap(Int.init), let latest = link["latest_version"].flatMap(Int.init), pin <= latest,
                  (link["desired_title"] == link["title"] || historicTitle || editedTitle || withdrawn), !(link["calendar_id"] ?? "").isEmpty else { throw VoiceOSError("迁移提醒事项身份或行动版本不一致") }
            if pin > 1 { guard try db.query("SELECT id FROM action_revisions WHERE action_id=? AND version=?", [link["action_id"],String(pin)]).count == 1 else { throw VoiceOSError("迁移提醒事项缺少行动版本") } }
            let observations = try db.query("SELECT sequence FROM reminder_observations WHERE link_id=? ORDER BY sequence", [link["id"]])
            for (i, row) in observations.enumerated() { guard row["sequence"] == String(i+1) else { throw VoiceOSError("迁移提醒事项回读历史不连续") } }
            if link["state"] == "linked" {
                guard let last = try db.query("SELECT * FROM reminder_observations WHERE link_id=? ORDER BY sequence DESC LIMIT 1", [link["id"]]).first, last["marker_valid"] == "1", last["external_id"] == link["external_id"] else { throw VoiceOSError("迁移提醒事项缺少唯一回读记录") }
            }
        }
        for observation in try db.query("SELECT o.*,l.action_id,l.action_version FROM reminder_observations o JOIN reminder_links l ON l.id=o.link_id") {
            guard !(observation["external_id"] ?? "").isEmpty, (observation["title"]?.unicodeScalars.count ?? 10001) <= 10000 else { throw VoiceOSError("迁移提醒事项回读字段无效") }
            if let revisionID = observation["feedback_revision_id"] {
                guard observation["completed"] == "1", observation["marker_valid"] == "1", let revision = try db.query("SELECT * FROM action_revisions WHERE id=?", [revisionID]).first,
                      revision["actor"] == "external", revision["action_id"] == observation["action_id"], revision["state"] == "completed", revision["command_id"] == "reminder-feedback:" + observation["id"]! else { throw VoiceOSError("迁移提醒事项反馈与行动历史不一致") }
                let priorResolution = try db.query("SELECT action_version FROM reminder_status_resolutions WHERE link_id=? AND action_version<? ORDER BY action_version DESC LIMIT 1", [observation["link_id"],revision["version"]]).first
                guard revision["from_version"] == (priorResolution?["action_version"] ?? observation["action_version"]) else { throw VoiceOSError("迁移提醒事项反馈同步基线不一致") }
            }
        }
        for revision in try db.query("SELECT id FROM action_revisions WHERE actor='external'") {
            guard try db.query("SELECT id FROM reminder_observations WHERE feedback_revision_id=?", [revision["id"]]).count == 1 else { throw VoiceOSError("迁移外部完成反馈缺少唯一回读依据") }
        }
        try validateReminderStatusResolutions(db)
        for row in try db.query("SELECT * FROM reminder_time_observations") {
            guard let json = row["due_json"], json.utf8.count <= 4096 else { throw VoiceOSError("迁移提醒事项时间观测无效") }
            try JSONDecoder().decode(ReminderDueDate.self, from: Data(json.utf8)).validate()
        }
    }
    func storedReminderDue(observationID: String?) throws -> ReminderDueDate? {
        guard let observationID, let row = try db.query("SELECT due_json FROM reminder_time_observations WHERE id=?", [observationID]).first else { return nil }
        let due = try JSONDecoder().decode(ReminderDueDate.self, from: Data(row["due_json"]!.utf8))
        try due.validate()
        return due
    }
}
