import Foundation
import Darwin
import VoiceOSCore
import VoiceOSPlatform

@main
struct Check {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2 else { throw VoiceOSError("usage: voiceos-check <import|read|transcribe> <isolated-root> [file] [command-id]") }
            if args[0] == "retrieval-fixture" { try await runRetrievalFixture(args); return }
            if args[0] == "relevance-fixture" { try await runRelevanceFixture(args); return }
            if args[0] == "relevance-cloud-fixture" { try await runRelevanceCloudFixture(args); return }
            if args[0] == "expression-eval-fixture" { try await runExpressionEvaluation(args); return }
            if args[0] == "expression-cloud-fixture" { try await runExpressionCloudFixture(args); return }
            if args[0] == "cloud-fixture" { try await runCloudFixture(args); return }
            if args[0] == "restore" {
                guard args.count == 3 else { throw VoiceOSError("restore requires package path") }
                try await VoiceOSStore.restorePackage(from: URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[1]), inspector: NativeMediaInspector())
                print("{\"restored\":true}")
                return
            }
            let crash = ProcessInfo.processInfo.environment["VOICEOS_TEST_CRASH_AT"]
            let store = try VoiceOSStore(root: URL(fileURLWithPath: args[1]), inspector: NativeMediaInspector(), checkpoint: { point in
                if point.rawValue == crash { kill(getpid(), SIGKILL) }
            })
            try await store.recover()
            if args[0] == "import" {
                guard args.count >= 3 else { throw VoiceOSError("missing file") }
                _ = try await store.importFile(URL(fileURLWithPath: args[2]), commandID: args.count > 3 ? args[3] : UUID().uuidString)
            } else if args[0] == "expression-fixture" {
                _ = try await store.recordUserExpression("我会整理开发验证素材。以后也许研究检索。我现在不打算学习摄影。", commandID: "synthetic-expression")
            } else if args[0] == "extracted-action-fixture" {
                guard let source = try await store.sources().first(where: { $0.origin == "user" }) else { throw VoiceOSError("fixture requires user text") }
                let snapshot = try await store.prepareLocalTranscriptContext(sourceIDs: [source.id])
                let context = try await store.persistLocalContext(snapshot, commandID: "synthetic-action-context")
                let attempt = try await store.reserveLocalModelAttempt(contextID: context, model: "fixture", promptVersion: "v2", schemaVersion: "v2")
                let input = snapshot.sources[0]
                let refs = [ClaimReference(sourceID: source.id, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)]
                _ = try await store.commitLocalClaims(attemptID: attempt, proposals: [ClaimProposal(statement: "我会整理开发验证素材", ownership: .userTentative, references: refs, action: ExtractedAction(title: "整理开发验证素材", kind: .task, quote: "我会整理开发验证素材", autoSend: true))])
            } else if args[0] == "feedback-fixture" {
                guard let action = try await store.actions(includeHistory: true).first(where: { $0.kind == "task" }) else { throw VoiceOSError("fixture requires task") }
                _ = try await store.recordActionFeedback(actionID: action.id, expectedVersion: action.version, kind: .outcome, text: "合成结果验证：素材已整理，仅测试反馈回流。", commandID: "synthetic-feedback")
            } else if args[0] == "export" {
                guard args.count >= 3 else { throw VoiceOSError("export requires new package directory") }
                try await store.exportPackage(to: URL(fileURLWithPath: args[2]), includeMedia: args.count == 4 && args[3] == "media")
            } else if args[0] == "cognition-fixture" {
                guard let source = try await store.sources().first(where: { !($0.transcript ?? "").isEmpty }) else { throw VoiceOSError("test fixture requires an existing transcript") }
                let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source.id])
                let contextID = try await store.persistLocalContext(context, commandID: "local-cognition-fixture")
                let attempt = try await store.reserveLocalModelAttempt(contextID: contextID, model: "development-fixture", promptVersion: "fixture-v1", schemaVersion: "claims-v1")
                let input = context.sources[0]
                _ = try await store.commitLocalClaims(attemptID: attempt, proposals: [ClaimProposal(statement: "开发测试候选，不代表模型理解结果或用户观点", ownership: .aiCandidate, references: [ClaimReference(sourceID: source.id, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)])])
            } else if args[0] == "reminder-fixture" {
                guard let action = try await store.actions().first(where: { $0.kind == "task" }) else { throw VoiceOSError("fixture requires a task") }
                let port = FileRemindersFixture(file: URL(fileURLWithPath: args[1]).appendingPathComponent("fixture-reminders.json"))
                try await store.sendTaskToReminders(actionID: action.id, expectedVersion: action.version, calendarID: "development-fixture-calendar", using: port)
            } else if args[0] == "reminder-read-fixture" {
                guard let link = try await store.reminderLinks().first else { throw VoiceOSError("fixture requires a reminder link") }
                let port = FileRemindersFixture(file: URL(fileURLWithPath: args[1]).appendingPathComponent("fixture-reminders.json"))
                try await store.readReminder(linkID: link.id, calendarID: "development-fixture-calendar", using: port)
            } else if args[0] == "action-fixture" {
                guard let claim = try await store.candidateClaims().first else { throw VoiceOSError("fixture requires a candidate") }
                _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: claim.reviewVersion, title: "开发验证任务，不代表真实用户任务", kind: .task, commandID: "fixture-action")
            } else if args[0] == "action-state-fixture" {
                guard let action = try await store.actions().first else { throw VoiceOSError("fixture requires an action") }
                _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: .completed, commandID: "fixture-action-state")
            } else if args[0] == "review-fixture" {
                guard let claim = try await store.candidateClaims().first else { throw VoiceOSError("test fixture requires a current candidate") }
                _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: claim.reviewVersion, action: .endorse, commandID: "fixture-review")
            } else if args[0] == "policy-fixture" {
                guard let source = try await store.sources().first else { throw VoiceOSError("test fixture requires a source") }
                _ = try await store.setSourceLocalOnly(sourceID: source.id, expectedVersion: source.policyVersion, localOnly: !source.localOnly, commandID: "fixture-policy")
            } else if args[0] == "correction-fixture" {
                guard let source = try await store.sources().first(where: { $0.transcript != nil }), let version = source.transcriptVersionID else { throw VoiceOSError("test fixture requires a transcript") }
                _ = try await store.correctTranscript(sourceID: source.id, expectedVersionID: version, text: source.transcript! + "（开发故障验证注记）", commandID: "fixture-correction")
            } else if args[0] == "transcribe" { try await store.processTranscriptions(using: NativeSpeechPort()) }
            else if args[0] != "read" { throw VoiceOSError("unknown command") }
            let records = try await store.sources()
            // Deliberately omit paths, names and transcript contents from public diagnostics.
            let output: [String: Any] = ["integrity": try await store.integrityCheck(), "records": records.map {
                ["id": $0.id, "state": $0.state, "kind": $0.kind, "bytes": $0.bytes, "job_state": $0.jobState ?? "none", "text_scalars": $0.transcript?.unicodeScalars.count ?? 0] as [String: Any]
            }]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}

// Development-only durable stand-in for an external service. Never uses EventKit.
private actor FileRemindersFixture: RemindersPort {
    let file: URL
    init(file: URL) { self.file = file }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([ReminderSnapshot].self, from: Data(contentsOf: file)).filter { $0.marker == marker || $0.id == externalID }
    }
    func create(calendarID: String, title: String, marker: String) async throws {
        guard !FileManager.default.fileExists(atPath: file.path) else { throw VoiceOSError("fixture must never duplicate a write") }
        let data = try JSONEncoder().encode([ReminderSnapshot(id: UUID().uuidString, title: title, completed: true, marker: marker)])
        try data.write(to: file, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
        let fd = open(file.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw VoiceOSError("fixture directory unavailable") }
        defer { close(fd) }; guard fsync(fd) == 0 else { throw VoiceOSError("fixture directory sync failed") }
    }
}
