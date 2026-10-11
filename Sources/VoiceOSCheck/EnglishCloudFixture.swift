import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// One bounded real text-only English feedback request. It creates synthetic local sources and never records audio.
func runEnglishCloudFixture(_ args: [String]) async throws {
    guard args.count == 3 else { throw VoiceOSError("english-cloud-fixture requires isolated root and local config") }
    let root = URL(fileURLWithPath: args[1]); let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector()); try await store.recover()
    guard try await store.sources().isEmpty else { throw VoiceOSError("English cloud fixture requires an empty isolated root") }
    let old = try await store.recordUserExpression("Earlier practice: the model have one layer.", commandID: "english-cloud-old")
    let current = try await store.recordUserExpression("The model have two layers. The encoder process the input.", commandID: "english-cloud-current")
    for id in [old, current] { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false, commandID: "english-cloud-grant-" + id) }
    let snapshot = try await store.prepareEnglishPractice(currentSourceID: current, priorSourceIDs: [old], destination: .cloud)
    let port = try LocalTextModel.loadEnglish(from: URL(fileURLWithPath: args[2]))
    let attempt = try await store.performEnglishFeedback(snapshot, using: port)
    guard let result = attempt.result else { throw VoiceOSError("English fixture has no accepted feedback; attempt remains durable") }
    let output: [String: Any] = ["synthetic_only": true, "audio_uploaded": false, "microphone_calls": 0, "suggestions": result.suggestions.count, "comparisons": result.comparisons.count, "input_tokens": result.inputTokens as Any, "output_tokens": result.outputTokens as Any, "provider": port.configuration.provider, "prompt_version": port.configuration.promptVersion]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
}
