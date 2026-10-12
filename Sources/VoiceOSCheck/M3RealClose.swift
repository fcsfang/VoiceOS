import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// Closes the product-level M3 path for an already completed real personal
/// cognition: activate one eligible task, observe it, complete that exact item,
/// observe completion, and persist a linked user outcome expression.
func runM3ListReminderCalendars() async throws {
    let port = await MainActor.run { NativeReminders() }
    let calendars = try await port.authorize()
    let output = calendars.map { ["id": $0.id, "title": $0.title] }
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func runM3RealClose(_ args: [String]) async throws {
    guard args.count == 3 else { throw VoiceOSError("m3-real-close requires an existing runtime root and explicitly selected calendar ID") }
    let root = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
    let allowed = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("runtime").standardizedFileURL.resolvingSymlinksInPath()
    guard root.path.hasPrefix(allowed.path + "/") else { throw VoiceOSError("M3 真实闭环仅接受 runtime 内独立资料库") }
    let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
    try await store.recover()
    let port = await MainActor.run { NativeReminders() }
    let currentAccess = try await store.reminderAccess()
    let access = try await store.setReminderAccess(calendarID: args[2], title: "VoiceOS M3 真实闭环", enabled: true, expectedVersion: currentAccess?.version ?? 0)
    try await store.activateExtractedTasks(expectedAccessVersion: access.version, using: port)
    guard let link = try await store.reminderLinks().last,
          let action = try await store.actions(includeHistory: true).first(where: { $0.id == link.actionID }) else {
        throw VoiceOSError("真实认知没有产生可自主发送的普通任务")
    }
    try await store.readReminder(linkID: link.id, calendarID: access.calendarID, using: port, expectedAccessVersion: access.version)
    guard let linked = try await store.reminderLinks().first(where: { $0.id == link.id }), let externalID = linked.externalID else {
        throw VoiceOSError("提醒事项创建后没有得到唯一外部身份")
    }
    try await port.markCompleted(calendarID: access.calendarID, externalID: externalID)
    try await store.readReminder(linkID: link.id, calendarID: access.calendarID, using: port, expectedAccessVersion: access.version)
    guard let completedAction = try await store.actions(includeHistory: true).first(where: { $0.id == action.id }) else {
        throw VoiceOSError("完成回读后行动历史缺失")
    }
    let feedbackText = "我已经完成这项任务：\(completedAction.title)。这是对原任务的结果反馈，不代表原认知已被验证。"
    let feedbackSource = try await store.recordActionFeedback(actionID: completedAction.id, expectedVersion: completedAction.version, kind: .outcome, text: feedbackText, commandID: "m3-real-outcome-" + action.id)
    let output: [String: Any] = [
        "integrity": try await store.integrityCheck(),
        "source_id": link.actionID,
        "action_id": action.id,
        "action_title": completedAction.title,
        "reminder_state": (try await store.reminderLinks()).first(where: { $0.id == link.id })?.state ?? "missing",
        "external_id_observed": externalID,
        "feedback_source_id": feedbackSource,
        "external_task_writes": 1,
        "completion_observed": true,
        "audio_uploaded": false,
        "full_natural_case_A_complete": false
    ]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("m3-real-close-summary.json"), options: .atomic)
    print(String(decoding: data, as: UTF8.self))
}

func runM3AssociateFeedback(_ args: [String]) async throws {
    guard args.count == 4 else { throw VoiceOSError("m3-associate-feedback requires runtime root, feedback source ID and model config") }
    let root = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
    let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
    try await store.recover()
    guard let source = try await store.sources().first(where: { $0.id == args[2] }), source.kind == "user_text" else {
        throw VoiceOSError("关联入口只接受本次新建的用户结果表达")
    }
    if source.localOnly {
        _ = try await store.setSourceLocalOnly(sourceID: source.id, expectedVersion: source.policyVersion, localOnly: false, commandID: "m3-feedback-grant:" + source.id)
    }
    let suite = try LocalTextModel.loadSuite(from: URL(fileURLWithPath: args[3]))
    let semanticRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("runtime/bge-coreml-2026-10-11")
    let result = try await store.processExpressionAssociation(sourceID: source.id, retrieval: CoreMLRetrieval(root: semanticRoot), semantic: true, model: suite.association)
    let output: [String: Any] = [
        "source_id": source.id,
        "state": result.state.rawValue,
        "proposal_count": result.attempt?.proposals.count ?? 0,
        "candidate_count": result.attempt?.snapshot.candidates.count ?? 0,
        "integrity": try await store.integrityCheck(),
        "audio_uploaded": false,
        "historical_relation_stage": true
    ]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("m3-feedback-association-summary.json"), options: .atomic)
    print(String(decoding: data, as: UTF8.self))
}
