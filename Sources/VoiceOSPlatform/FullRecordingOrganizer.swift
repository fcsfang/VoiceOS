import Foundation
import VoiceOSCore

public struct RecordingAudioTrack: Identifiable, Sendable {
    public let id: Int
    public let title: String
}
public struct RecordingMediaInfo: Sendable {
    public let duration: Double
    public let tracks: [RecordingAudioTrack]
}

public enum FullRecordingOrganizer {
    private static func executable(_ name: String) throws -> URL {
        guard let path = ["/opt/homebrew/bin/", "/usr/local/bin/"].map({ $0 + name }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw VoiceOSError("请使用已配置的本地 \(name)；没有安装或下载工具")
        }
        return URL(fileURLWithPath: path)
    }
    public static func inspect(_ input: URL) async throws -> RecordingMediaInfo {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: result) }
        try await run(executable: executable("ffprobe"), arguments: ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index:stream_tags=title:format=duration", "-of", "json", input.path], log: result)
        struct Probe: Decodable {
            struct Stream: Decodable { let tags: [String: String]? }
            struct Format: Decodable { let duration: String }
            let streams: [Stream]; let format: Format
        }
        let probe = try JSONDecoder().decode(Probe.self, from: Data(contentsOf: result))
        guard let duration = Double(probe.format.duration), duration.isFinite, duration > 0, !probe.streams.isEmpty else { throw VoiceOSError("素材没有可用的完整音轨") }
        return RecordingMediaInfo(duration: duration, tracks: probe.streams.enumerated().map { index, track in
            RecordingAudioTrack(id: index, title: "音轨 \(index + 1)" + (track.tags?["title"].map { " · " + $0 } ?? ""))
        })
    }
    public static func extract(_ input: URL, track: Int, to output: URL, log: URL) async throws {
        guard track >= 0, !FileManager.default.fileExists(atPath: output.path) else { throw VoiceOSError("音轨选择或输出路径无效") }
        try await run(executable: executable("ffmpeg"), arguments: ["-v", "error", "-nostdin", "-i", input.path, "-map", "0:a:\(track)", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path], log: log)
    }
    public static func organize(folder: URL, script: URL, python: URL, configuration: URL, log: URL, qwen: LocalQwenSpeechPort? = nil) async throws {
        var arguments = [script.path, folder.path, "--include-knowledge"]
        if let qwen {
            let local = folder.deletingLastPathComponent().appendingPathComponent("本地Qwen配置.json")
            try qwen.configurationData().write(to: local, options: .atomic)
            arguments += ["--asr-config", local.path]
        }
        try await run(executable: python, arguments: arguments, log: log,
                      environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "VOICEOS_MODEL_CONFIG_FILE": configuration.path, "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"])
    }
    private static func run(executable: URL, arguments: [String], log: URL, environment: [String: String]? = nil) async throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.environment = environment ?? ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        process.standardOutput = handle; process.standardError = handle
        try await LocalProcessWait(process, failure: "完整整理未完成；原件和已保存结果保留，可查看处理日志后继续").run()
    }
}
