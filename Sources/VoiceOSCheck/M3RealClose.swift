import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// Closes the product-level M3 path for a real personal cognition: activate
/// eligible tasks, observe each exact item, and leave it open for the user.
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
    let beforeLinks = Set(try await store.reminderLinks().map(\.id))
    try await store.activateExtractedTasks(expectedAccessVersion: access.version, using: port)
    let createdLinks = try await store.reminderLinks().filter { !beforeLinks.contains($0.id) }
    guard !createdLinks.isEmpty else {
        throw VoiceOSError("真实认知没有产生可自主发送的普通任务")
    }
    var created: [[String: Any]] = []
    for link in createdLinks {
        try await store.readReminder(linkID: link.id, calendarID: access.calendarID, using: port, expectedAccessVersion: access.version)
        guard let linked = try await store.reminderLinks().first(where: { $0.id == link.id }), let externalID = linked.externalID else {
            throw VoiceOSError("提醒事项创建后没有得到唯一外部身份")
        }
        let current = try await store.reminderLinks().first(where: { $0.id == link.id })
        created.append(["action_id": link.actionID, "link_id": link.id, "external_id_observed": externalID,
                        "reminder_state": current?.state ?? "missing",
                        "completed": current?.remoteCompleted ?? false])
    }
    let actions = try await store.actions(includeHistory: true)
    let claims = try await store.candidateClaims(includeFrozen: true)
    let sourceIDs = Set(createdLinks.flatMap { link -> [String] in
        guard let action = actions.first(where: { $0.id == link.actionID }),
              let claim = claims.first(where: { $0.id == action.claimID }) else { return [] }
        return claim.references.map(\.sourceID)
    }).sorted()
    let output: [String: Any] = [
        "integrity": try await store.integrityCheck(),
        "source_ids": sourceIDs,
        "created_tasks": created,
        "external_task_writes": createdLinks.count,
        "completion_observed": false,
        "audio_uploaded": false,
        "full_natural_case_A_complete": false
    ]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("m3-real-close-summary.json"), options: .atomic)
    print(String(decoding: data, as: UTF8.self))
}

/// Restores only explicitly identified development-test reminders to the
/// normal open state. This command is separate from formal material handling.
func runM3RestoreOpen(_ args: [String]) async throws {
    guard args.count >= 4 else { throw VoiceOSError("m3-restore-open requires runtime root, calendar ID and one or more external IDs") }
    let root = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
    let allowed = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("runtime").standardizedFileURL.resolvingSymlinksInPath()
    guard root.path.hasPrefix(allowed.path + "/") else { throw VoiceOSError("只接受 runtime 内独立资料库") }
    let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector()); try await store.recover()
    let port = await MainActor.run { NativeReminders() }
    guard let access = try await store.reminderAccess(), access.enabled, access.calendarID == args[2] else { throw VoiceOSError("资料库的提醒事项清单授权与参数不一致") }
    var restored: [[String: Any]] = []
    for externalID in args.dropFirst(3) {
        guard let link = try await store.reminderLinks().first(where: { $0.externalID == externalID && $0.calendarID == access.calendarID }) else { throw VoiceOSError("外部身份不属于该资料库") }
        try await port.markIncomplete(calendarID: access.calendarID, externalID: externalID)
        if let action = try await store.actions(includeHistory: true).first(where: { $0.id == link.actionID }), action.state == "completed" {
            _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: .open,
                                               note: "撤销开发验证中的完成状态；正式任务默认保持未完成",
                                               commandID: "m3-restore-open-" + action.id)
        }
        try await store.readReminder(linkID: link.id, calendarID: access.calendarID, using: port, expectedAccessVersion: access.version)
        let current = try await store.reminderLinks().first(where: { $0.id == link.id })
        restored.append(["action_id": link.actionID, "link_id": link.id, "external_id": externalID,
                         "reminder_state": current?.state ?? "missing", "completed": current?.remoteCompleted ?? true])
    }
    let output: [String: Any] = ["restored": restored, "integrity": try await store.integrityCheck(), "completion_history_retained": true]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("m3-restore-open-summary.json"), options: .atomic)
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
