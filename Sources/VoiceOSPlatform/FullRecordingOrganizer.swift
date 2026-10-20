import Foundation
import VoiceOSCore

public struct RecordingAudioTrack: Identifiable, Sendable {
    public let id: Int
    public let title: String
    public var startMS: Int = 0
}
public struct RecordingMediaInfo: Sendable {
    public let duration: Double
    public let tracks: [RecordingAudioTrack]
    public var recordedAt: String? = nil
    /// Saved recording convention: audio 0 = mix, 1 = microphone, 2 = system.
    public var usesPersonalRecordingLayout: Bool { tracks.count == 3 }
    public var personalTrack: Int { tracks.count > 1 ? 1 : 0 }
    public var contextTrack: Int? { usesPersonalRecordingLayout ? 2 : nil }
    public func contextOffsetMS(personalTrack: Int) -> Int {
        guard let contextTrack,let external=tracks.first(where: { $0.id == contextTrack }),let personal=tracks.first(where: { $0.id == personalTrack }) else { return 0 }
        return external.startMS-personal.startMS
    }
    public static let personalRecordingLayout = "固定录制格式（从 0 编号）：音轨 0 混音 · 音轨 1 我的声音 · 音轨 2 系统内录。本人和节目分别完整转写，按时间与语义关联；节目内容保留外部归属。"
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
        try await run(executable: executable("ffprobe"), arguments: ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index,start_time:stream_tags=title:format=duration:format_tags=creation_time", "-of", "json", input.path], log: result)
        struct Probe: Decodable {
            struct Stream: Decodable { let tags: [String: String]?; let start_time: String? }
            struct Format: Decodable { let duration: String; let tags: [String:String]? }
            let streams: [Stream]; let format: Format
        }
        let probe = try JSONDecoder().decode(Probe.self, from: Data(contentsOf: result))
        guard let duration = Double(probe.format.duration), duration.isFinite, duration > 0, !probe.streams.isEmpty else { throw VoiceOSError("素材没有可用的完整音轨") }
        var info = RecordingMediaInfo(duration: duration, tracks: probe.streams.enumerated().map { index, track in
            let role = probe.streams.count == 3 ? ["混音", "我的声音", "系统内录"][index] : nil
            var audio=RecordingAudioTrack(id: index, title: "音轨 \(index)" + (role.map { " · " + $0 } ?? "") + (track.tags?["title"].map { " · " + $0 } ?? ""))
            if let raw=track.start_time,let seconds=Double(raw),seconds.isFinite,abs(seconds) < Double(Int.max/1000) { audio.startMS=Int((seconds*1000).rounded()) }
            return audio
        })
        if let value=probe.format.tags?["creation_time"] {
            let fractional=ISO8601DateFormatter();fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            if let date=ISO8601DateFormatter().date(from:value) ?? fractional.date(from:value) { info.recordedAt=date.ISO8601Format() }
        }
        return info
    }
    public static func extract(_ input: URL, track: Int, to output: URL, log: URL) async throws {
        guard track >= 0, !FileManager.default.fileExists(atPath: output.path) else { throw VoiceOSError("音轨选择或输出路径无效") }
        try await run(executable: executable("ffmpeg"), arguments: ["-v", "error", "-nostdin", "-i", input.path, "-map", "0:a:\(track)", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path], log: log)
    }
    public static func organize(folder: URL, script: URL, python: URL, configuration: URL, log: URL, reviewTranscriptOnly: Bool = false) async throws {
        try await organize(folders:[folder],script:script,python:python,configuration:configuration,log:log,reviewTranscriptOnly:reviewTranscriptOnly)
    }
    public static func organize(folders: [URL], script: URL, python: URL, configuration: URL, log: URL, reviewTranscriptOnly: Bool = false) async throws {
        guard !folders.isEmpty else { throw VoiceOSError("连续表达没有录音") }
        let arguments = [script.path] + folders.map(\.path) + [reviewTranscriptOnly ? "--review-transcript-only" : "--include-knowledge"]
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
        do { try await LocalProcessWait(process, failure: "完整整理未完成").run() }
        catch is CancellationError { throw CancellationError() }
        catch {
            let content = try? String(contentsOf: log, encoding: .utf8)
            let detail = content?.split(separator: "\n").last.map(String.init)
            throw VoiceOSError((detail ?? "完整整理未完成") + "；原件及已完成转写、核对结果保留")
        }
    }
}
