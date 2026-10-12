import Foundation
import VoiceOSCore

/// Explicit local candidate. No fallback, download, shell, cloud, or old-graft overwrite.
public struct LocalQwenSpeechPort: SpeechPort {
    public let backendIdentity = "Qwen3-ASR-1.7B-8bit@a8379a2 MLXAudio0.5.8 chunk30-v1"
    private let python: URL
    private let runner: URL
    private let model: URL
    public static func load(from file: URL) throws -> LocalQwenSpeechPort {
        struct Configuration: Decodable { let format: String; let python: String; let runner: String; let model: String }
        let data=try Data(contentsOf:file)
        guard data.count<=16_384 else { throw VoiceOSError("本地转写配置过大") }
        let config=try JSONDecoder().decode(Configuration.self,from:data)
        guard config.format=="voiceos-local-qwen-v1",[config.python,config.runner,config.model].allSatisfy({ $0.hasPrefix("/") }) else {
            throw VoiceOSError("本地转写配置格式无效")
        }
        return try .init(python:URL(fileURLWithPath:config.python),runner:URL(fileURLWithPath:config.runner),model:URL(fileURLWithPath:config.model))
    }
    public init(python: URL, runner: URL, model: URL) throws {
        guard FileManager.default.isExecutableFile(atPath:python.path),
              FileManager.default.fileExists(atPath:runner.path),
              FileManager.default.fileExists(atPath:model.appendingPathComponent("model.safetensors").path) else {
            throw VoiceOSError("本地 Qwen 转写环境或权重不可用；不会下载或切换云端")
        }
        self.python=python; self.runner=runner; self.model=model
    }
    public func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        guard ["zh_CN","en_US"].contains(locale) else { throw VoiceOSError("本地 Qwen 候选尚未启用该语言") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-qwen-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let output=directory.appendingPathComponent("result.json")
        let process=Process()
        process.executableURL=python
        process.arguments=[runner.path,"--audio",url.path,"--model",model.path,"--output",output.path,"--locale",locale]
        // Do not inherit gateway/API credentials or Python path overrides.
        process.environment=["PATH":"/opt/homebrew/bin:/usr/bin:/bin","HF_HUB_OFFLINE":"1","HF_HUB_DISABLE_TELEMETRY":"1"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        let wait = LocalSpeechProcessWait(process)
        try await wait.run()
        struct Response: Decodable { let backend: String; let text: String; let spans: [TranscriptSpan]; let audio_uploaded: Bool }
        let data=try Data(contentsOf:output)
        guard data.count<=16_000_000 else { throw VoiceOSError("本地转写结果超过预算") }
        let result=try JSONDecoder().decode(Response.self,from:data)
        guard result.backend==backendIdentity,!result.audio_uploaded else { throw VoiceOSError("本地转写回执身份无效") }
        let media=try await NativeMediaInspector().inspect(url)
        let speech=SpeechText(text:result.text,spans:result.spans)
        try speech.validate(duration:media.duration)
        return speech
    }
}

/// Process lifetime is serialized under a lock; cancellation kills this child
/// and completion waits for termination before removing its private output.
private final class LocalSpeechProcessWait: @unchecked Sendable {
    private let process: Process
    private let lock=NSLock()
    private var cancelled=false
    init(_ process: Process) { self.process=process }
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                lock.lock()
                defer { lock.unlock() }
                guard !cancelled,!Task.isCancelled else { continuation.resume(throwing:CancellationError());return }
                process.terminationHandler = { [self] child in
                    lock.lock();let wasCancelled=cancelled;lock.unlock()
                    if wasCancelled { continuation.resume(throwing:CancellationError()) }
                    else if child.terminationStatus==0 { continuation.resume() }
                    else { continuation.resume(throwing:VoiceOSError("本地 Qwen 转写未完成；保留原件，不自动切换服务")) }
                }
                do { try process.run() }
                catch { process.terminationHandler=nil;continuation.resume(throwing:VoiceOSError("无法启动本地 Qwen 转写")) }
            }
        } onCancel: {
            self.lock.lock();self.cancelled=true
            if self.process.isRunning { self.process.terminate() }
            self.lock.unlock()
        }
    }
}
