import Foundation

public struct RecordingExpressionReminderEdit: Sendable {
    public let calendarID:String
    public let externalID:String
    public let marker:String
    public let expectedTitle:String
    public let desiredTitle:String
    public let withdraw:Bool
    public let expectedFields:ReminderFields?
}
public protocol RecordingExpressionRemindersPort: RemindersPort {
    func reconcileExpression(_ edit:RecordingExpressionReminderEdit,authorize:@Sendable () async throws -> Void) async throws -> ReminderSnapshot
}
extension VoiceOSStore {
    public func syncRecordingExpressionReminders(using port:any RecordingExpressionRemindersPort) async throws {
        guard let access=try reminderAccess(),access.enabled,access.title == "VoiceOS" else { return }
        let ledgers = try actionReviewLedgers()
        var failed = false
        for expression in try recordingExpressions() where expression.state == "completed" {
            guard let ledger = ledgers[expression.id] else { continue }
            for actionID in expression.reminderUpdates ?? [] {
                if ledger.requiresReview(actionID:actionID) { continue }
                try Task.checkCancellation()
                do {
                    try await applyExpressionReminderUpdate(actionID:actionID,expression:expression,access:access,using:port)
                    try clearReminderSyncFailure(actionID:actionID,stage:.expression)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The update stays queued; the latest reason replaces the old one.
                    failed = true
                    try recordReminderSyncFailure(actionID:actionID,stage:.expression,reason:error.localizedDescription)
                }
            }
        }
        if failed { throw VoiceOSError("部分提醒补录未完成；待同步记录已保留，稍后自动重试") }
    }
    private func applyExpressionReminderUpdate(actionID:String,expression:RecordingExpression,access:ReminderAccess,using port:any RecordingExpressionRemindersPort) async throws {
        guard let link=try db.query("SELECT * FROM reminder_links WHERE action_id=?",[actionID]).first else {
            try finishExpressionReminderUpdate(expressionID:expression.id,actionID:actionID);return
        }
        guard link["calendar_id"] == access.calendarID else { throw VoiceOSError("补录关联在其他提醒清单，保留原提醒") }
        guard let externalID=link["external_id"],!externalID.isEmpty else { throw VoiceOSError("补录关联缺少外部标识，等待回读补全") }
        guard let marker=link["marker"],let original=link["desired_title"] else { throw VoiceOSError("补录关联尚未确认唯一提醒，保留原提醒") }
        guard let action=try self.action(id: actionID, includeHistory: true) else { throw VoiceOSError("补录对应的任务已不存在，保留原提醒") }
        let withdrawal=action.state == "dismissed" && action.validity != "current"
        let desired=withdrawal ? "已撤回 · "+action.title : action.title
        let edit=RecordingExpressionReminderEdit(calendarID:access.calendarID,externalID:externalID,marker:marker,expectedTitle:original,desiredTitle:desired,withdraw:withdrawal,expectedFields:action.intent?.reminderFields?.desired)
        let snapshot=try await port.reconcileExpression(edit) { [self] in
            guard let latest=try await self.reminderAccess(),latest.enabled,latest.version == access.version,
                  try await self.recordingExpressions().contains(where: { $0.id == expression.id && $0.digest == expression.digest && $0.state == "completed" }),
                  let current=try await self.actionReviewLedger(expressionID: expression.id),
                  !current.requiresReview(actionID: actionID) else { throw VoiceOSError("补录提醒接续前授权或表达已变化") }
        }
        guard snapshot.id == externalID,snapshot.marker == marker,snapshot.completed || snapshot.title == desired,
              !withdrawal || snapshot.completed || (snapshot.fields?.alerts.isEmpty == true && snapshot.fields?.due == ReminderDueDate.none) else { throw VoiceOSError("补录提醒接续未通过回读，保留处理记录") }
        if !snapshot.completed { try db.execute("UPDATE reminder_links SET desired_title=? WHERE id=?",[desired,link["id"]]) }
        try await readReminder(linkID:link["id"]!,calendarID:access.calendarID,using:port,expectedAccessVersion:access.version)
        try finishExpressionReminderUpdate(expressionID:expression.id,actionID:actionID)
    }
    private func finishExpressionReminderUpdate(expressionID:String,actionID:String) throws {
        guard var expression=try recordingExpressions().first(where: { $0.id == expressionID }) else { return }
        expression.reminderUpdates?.removeAll { $0 == actionID }
        try db.transaction {
            for id in expression.sourceIDs {
                guard var presentation=try sourceRecord(id: id)?.presentation else { throw VoiceOSError("连续表达来源缺失") }
                presentation.expression=expression;try saveExpressionPresentation(presentation,sourceID:id)
            }
        }
    }
}
