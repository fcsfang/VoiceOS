// Synthetic file I/O only: no microphone, speakers, personal files, or network.
import Foundation
import AVFoundation

@main
struct AudioFileCapabilities {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "VoiceOSProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "provide an empty scratch directory"])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("synthetic.wav")
        let encoded = directory.appendingPathComponent("synthetic.m4a")
        guard !FileManager.default.fileExists(atPath: input.path), !FileManager.default.fileExists(atPath: encoded.path) else {
            throw NSError(domain: "VoiceOSProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "scratch outputs already exist; use a new directory"])
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for frame in 0..<16000 {
            buffer.floatChannelData![0][frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / 16000) * 0.1)
        }
        do {
            let file = try AVAudioFile(forWriting: input, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            try file.write(from: buffer)
        }
        let readback = try AVAudioFile(forReading: input)
        let asset = AVURLAsset(url: input)
        let sourceDuration = try await asset.load(.duration)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "VoiceOSProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "M4A exporter unavailable"])
        }
        try await exporter.export(to: encoded, as: .m4a)
        let encodedAsset = AVURLAsset(url: encoded)
        let encodedDuration = try await encodedAsset.load(.duration)
        let encodedTracks = try await encodedAsset.loadTracks(withMediaType: .audio)
        let result: [String: Any] = [
            "probe": "synthetic-audio-file-v1",
            "source": "generated 440Hz sine; no speech",
            "wav_frames": readback.length,
            "wav_sample_rate": readback.processingFormat.sampleRate,
            "wav_channels": readback.processingFormat.channelCount,
            "wav_duration_seconds": sourceDuration.seconds,
            "m4a_duration_seconds": encodedDuration.seconds,
            "m4a_audio_tracks": encodedTracks.count,
            "wav_bytes": try input.resourceValues(forKeys: [.fileSizeKey]).fileSize!,
            "m4a_bytes": try encoded.resourceValues(forKeys: [.fileSizeKey]).fileSize!,
            "microphone_used": false,
            "transcription_executed": false,
            "video_import_tested": false
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
