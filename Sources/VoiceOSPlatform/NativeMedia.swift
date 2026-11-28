import Foundation
import AVFoundation
import VoiceOSCore

public struct NativeMediaInspector: MediaInspector {
    public init() {}
    public func inspect(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, let track = audio.first else { throw VoiceOSError("媒体没有可处理的音轨") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        guard reader.canAdd(output) else { throw VoiceOSError("无法解码媒体音轨") }
        reader.add(output)
        guard reader.startReading() else { throw VoiceOSError("无法读取媒体音轨") }
        var samples = 0
        while let buffer = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(buffer) }
        guard reader.status == .completed, samples > 0 else { throw VoiceOSError("媒体音轨未能完整解码") }
        return MediaInfo(duration: duration, kind: video.isEmpty ? "audio" : "video")
    }
}
