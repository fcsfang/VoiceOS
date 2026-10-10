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

extension Check {
    static func runExpressionCloudFixture(_ args: [String]) async throws {
        guard args.count == 3 else { throw VoiceOSError("expression-cloud-fixture requires a NEW isolated root and local config") }
        let root = URL(fileURLWithPath: args[1])
        guard !FileManager.default.fileExists(atPath: root.path) else { throw VoiceOSError("合成表达试验目录已有记录，不重复发送") }
        let port = try LocalTextModel.load(from: URL(fileURLWithPath: args[2]))
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector()); try await store.recover()
        // Synthetic first-person role; never entered into the user's personal data root.
        let id = try await store.recordUserExpression("我会整理开发验证素材。以后也许研究检索。我现在不打算学习摄影。", commandID: "synthetic-expression")
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        let ids = try await store.understandSource(sourceID: id, using: port)
        let claims = try await store.candidateClaims(), actions = try await store.actions(), attempts = try await store.modelAttempts()
        let result: [String: Any] = ["synthetic": true, "claims": ids.count, "actions": actions.map { ["kind": $0.kind, "title": $0.title, "autoSend": $0.autoSend] as [String:Any] }, "ownerships": claims.map(\.ownership), "usage": attempts.first?.usage ?? [:], "billing_state": "unknown", "model": port.configuration.model, "external_writes": 0]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
        try data.write(to:root.appendingPathComponent("expression-cloud-summary.json"),options:.withoutOverwriting)
        print(String(decoding: data,as:UTF8.self))
    }
}

extension Check {
    static func runExpressionEvaluation(_ args: [String]) async throws {
        guard args.count == 3 else { throw VoiceOSError("expression-eval-fixture requires new root and config") }
        let root = URL(fileURLWithPath: args[1]); guard !FileManager.default.fileExists(atPath: root.path) else { throw VoiceOSError("评估已有目录，禁止重发") }
        let port = try LocalTextModel.load(from: URL(fileURLWithPath: args[2]))
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector()); try await store.recover()
        let cases = [
            "嘉宾说：我会跑步。这只是转述，不是我的计划。",
            "如果将来换电脑，也许可以学习剪辑；现在不打算报名课程。",
            "周五之前我必须交开发测试报告。这有明确期限，请保留期限，不要替我安排弹性提醒。"]
        var sourceIDs: [String] = []
        for text in cases { let id = try await store.recordUserExpression(text); _ = try await store.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false); sourceIDs.append(id) }
        let snapshot = try await store.prepareLocalTranscriptContext(sourceIDs:sourceIDs)
        let context = try await store.persistLocalContext(snapshot,commandID:"synthetic-boundary-evaluation",destination:.cloud)
        _ = try await store.generateClaims(contextID:context,using:port)
        let claims = try await store.candidateClaims(), actions = try await store.actions(), attempts = try await store.modelAttempts()
        var results: [[String:Any]] = []
        for (index,id) in sourceIDs.enumerated() {
            let relevant = claims.filter { $0.references.contains { $0.sourceID == id } }; let ids = Set(relevant.map(\.id)); let proposed = actions.filter { ids.contains($0.claimID) }
            let noAuto = proposed.allSatisfy { !$0.autoSend }
            let pass = noAuto && (index != 0 || proposed.isEmpty) && (index != 2 || proposed.contains { $0.kind == "task" })
            results.append(["case": index + 1,"passed":pass,"claims":relevant.map { ["statement":$0.statement,"ownership":$0.ownership] },"actions":proposed.map { ["kind":$0.kind,"autoSend":$0.autoSend,"title":$0.title,"quote":$0.note] as [String:Any] }])
        }
        let report: [String:Any] = ["synthetic":true,"passed":results.allSatisfy { $0["passed"] as? Bool == true },"cases":results,"usage":attempts.first?.usage ?? [:],"external_writes":0,"billing_state":"unknown"]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:root.appendingPathComponent("boundary-evaluation.json"),options:.withoutOverwriting)
        print(String(decoding:data,as:UTF8.self))
    }
}
