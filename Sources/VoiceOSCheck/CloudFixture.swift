import Foundation
import VoiceOSCore
import VoiceOSPlatform

private struct SyntheticSpeech: SpeechPort {
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        SpeechText(text: "合成测试资料：一位外部嘉宾说，记录想法可能有帮助，但不必把每个想法立刻变成任务。这不是用户的观点或任务指令。")
    }
}
extension Check {
    static func runCloudFixture(_ args: [String]) async throws {
        guard args.count == 3 else { throw VoiceOSError("cloud-fixture requires a NEW isolated root and local .env path") }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw VoiceOSError("此合成云端试验已有目录，禁止重复发送；保留原结果") }
        let port = try LocalTextModel.load(from: URL(fileURLWithPath: args[2]))
        // A generated silent WAV anchors a synthetic transcript in the normal data path.
        // No original recording or actual ASR is used by this fixture.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = root.appendingPathComponent("synthetic-silence.wav")
        var data = Data()
        func chars(_ s: String) { data.append(Data(s.utf8)) }
        func le<T: FixedWidthInteger>(_ v: T) { var n = v.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        chars("RIFF"); le(UInt32(32036)); chars("WAVEfmt "); le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(16000)); le(UInt32(32000)); le(UInt16(2)); le(UInt16(16)); chars("data"); le(UInt32(32000)); data.append(Data(repeating: 0, count: 32000))
        try data.write(to: wav, options: .withoutOverwriting)
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        let source = try await store.importFile(wav, commandID: "synthetic-cloud-import")
        try await store.processTranscriptions(using: SyntheticSpeech())
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false, commandID: "synthetic-text-grant")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let id = try await store.persistLocalContext(context, commandID: "synthetic-cloud-context", destination: .cloud)
        let start = Date(); var success = false
        do { _ = try await store.generateClaims(contextID: id, using: port); success = true }
        catch { /* Persisted attempts are the diagnostic authority; do not print raw errors. */ }
        let attempts = try await store.modelAttempts()
        let result: [String: Any] = ["date": "2026-10-10", "synthetic_only": true, "network_generation_attempts": attempts.count,
            "elapsed_seconds": Date().timeIntervalSince(start), "accepted": success, "claim_count": try await store.candidateClaims().count,
            "integrity": try await store.integrityCheck(), "audio_uploaded": false, "personal_text_sent": false,
            "attempts": attempts.map { ["state": $0.state, "provider": $0.provider, "model": $0.model, "usage": $0.usage as Any? ?? NSNull(), "billing_state": $0.billingState] as [String: Any] }]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: root.appendingPathComponent("summary.json"), options: .withoutOverwriting)
        print(String(decoding: encoded, as: UTF8.self))
        guard success else { throw VoiceOSError("单次合成文本试验未接纳结果，已保留记录且不重试") }
    }
}
