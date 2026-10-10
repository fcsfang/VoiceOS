// Authorized existing media only. Copies and extracts locally; no recording,
// playback, model downloads, network calls, or modifications to the input.
import Foundation
import AVFoundation
import CryptoKit

func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

@main
struct MediaImportProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 5,
              let start = Double(CommandLine.arguments[3]), start.isFinite, start >= 0,
              let maximum = Double(CommandLine.arguments[4]), maximum.isFinite, maximum > 0 else {
            throw NSError(domain: "VoiceOSProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "provide input file, new scratch directory, start seconds, maximum seconds"])
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NSError(domain: "VoiceOSProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "scratch directory exists; use a new directory"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copied = directory.appendingPathComponent("original").appendingPathExtension(source.pathExtension)
        let beforeHash = try digest(source)
        try FileManager.default.copyItem(at: source, to: copied)
        let copiedHash = try digest(copied)
        guard beforeHash == copiedHash else {
            throw NSError(domain: "VoiceOSProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "copied file digest mismatch"])
        }
        let asset = AVURLAsset(url: copied)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, start < duration, !audioTracks.isEmpty else {
            throw NSError(domain: "VoiceOSProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "no usable duration/audio track at selected offset"])
        }
        let selected = min(maximum, duration - start)
        let clip = directory.appendingPathComponent("clip.m4a")
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "VoiceOSProbe", code: 5, userInfo: [NSLocalizedDescriptionKey: "audio exporter unavailable"])
        }
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: selected, preferredTimescale: 600))
        try await exporter.export(to: clip, as: .m4a)
        let decoded = try AVAudioFile(forReading: clip)
        guard decoded.length > 0 else {
            throw NSError(domain: "VoiceOSProbe", code: 6, userInfo: [NSLocalizedDescriptionKey: "exported clip has no decoded frames"])
        }
        let result: [String: Any] = [
            "probe": "existing-media-import-v1",
            "source_bytes": try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!,
            "source_sha256_before": beforeHash,
            "source_sha256_after": try digest(source),
            "copied_sha256": copiedHash,
            "original_duration_seconds": duration,
            "audio_tracks": audioTracks.count,
            "video_tracks": videoTracks.count,
            "clip_start_seconds": start,
            "clip_requested_seconds": selected,
            "clip_decoded_seconds": Double(decoded.length) / decoded.processingFormat.sampleRate,
            "clip_sample_rate": decoded.processingFormat.sampleRate,
            "clip_channels": decoded.processingFormat.channelCount,
            "clip_sha256": try digest(clip),
            "clip_bytes": try clip.resourceValues(forKeys: [.fileSizeKey]).fileSize!,
            "microphone_used": false,
            "cloud_upload_executed": false,
            "video_frames_analyzed": false
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
