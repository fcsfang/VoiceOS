import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// Offline synthetic records for native history inspection. Never loads credentials.
private struct EnglishUIFixturePort: EnglishPracticeModelPort {
    let configuration = ModelConfiguration(provider: "offline_english_ui_fixture", model: "synthetic", promptVersion: "english-practice-v1", schemaVersion: "english-feedback-v1", destination: .cloud)
    let index: Int
    func generate(_ request: EnglishPracticeRequest) async throws -> EnglishPracticeResponse {
        if index == 11 { throw VoiceOSError("synthetic unknown result") }
        let current = request.snapshot.context.sources[0], prior = request.snapshot.context.sources[1]
        func evidence(_ source: ContextTranscript) -> OutcomeSourceEvidence {
            OutcomeSourceEvidence(reference: ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id), quote: source.text)
        }
        return EnglishPracticeResponse(suggestions: [.init(kind: .grammar, original: evidence(current), suggestedText: "Synthetic practice \(index): the model has two layers.", explanation: "Synthetic fixture: singular subject takes has.", possibleTranscriptIssue: index == 3)], comparisons: [.init(kind: .similarIssue, currentSuggestionIndex: 0, current: evidence(current), prior: evidence(prior), explanation: "Synthetic comparison \(index): both texts use have with a singular subject; no mastery claim.")], inputTokens: 17, outputTokens: 23)
    }
}

func runEnglishUISeed(_ args: [String]) async throws {
    guard args.count == 2 else { throw VoiceOSError("english-ui-seed requires a new isolated root") }
    let root = URL(fileURLWithPath: args[1])
    guard !FileManager.default.fileExists(atPath: root.path) else { throw VoiceOSError("English UI seed refuses an existing root") }
    let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
    try await store.recover()
    for index in 0..<12 {
        let prior = try await store.recordUserExpression("Synthetic prior practice \(index): the model have one layer.")
        let current = try await store.recordUserExpression("Synthetic current practice \(index): the model have two layers.")
        for id in [prior, current] { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false) }
        let snapshot = try await store.prepareEnglishPractice(currentSourceID: current, priorSourceIDs: [prior], destination: .cloud)
        do { _ = try await store.performEnglishFeedback(snapshot, using: EnglishUIFixturePort(index: index)) }
        catch { if index != 11 { throw error } }
        if index == 0 { _ = try await store.setSourceLocalOnly(sourceID: current, expectedVersion: 2, localOnly: true) }
    }
    let records = try await store.englishFeedbackAttempts()
    guard records.count == 12, records.filter({ $0.state == "completed" }).count == 11,
          records.filter({ $0.state == "unknown" }).count == 1,
          records.filter({ $0.validity == "frozen" }).count == 1,
          try await store.actions().isEmpty, try await store.candidateClaims().isEmpty,
          try await store.integrityCheck() else { throw VoiceOSError("synthetic English UI seed invariant failed") }
    print("{\"synthetic_only\":true,\"feedback_records\":12,\"completed\":11,\"unknown\":1,\"frozen\":1,\"network_calls\":0,\"microphone_calls\":0,\"reminder_writes\":0}")
}
