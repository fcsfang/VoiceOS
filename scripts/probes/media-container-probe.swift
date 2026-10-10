// Validates authorized local containers and decodes their first audio track.
// No playback, transcription, recording, downloads, or network.
import Foundation
import AVFoundation

@main
struct MediaContainerProbe {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw NSError(domain: "VoiceOSProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "provide local media file"])
            }
            let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            let duration = try await asset.load(.duration).seconds
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            guard duration.isFinite, duration > 0, let first = audio.first else {
                throw NSError(domain: "VoiceOSProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "no valid duration/audio track"])
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: first, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            guard reader.canAdd(output) else {
                throw NSError(domain: "VoiceOSProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "audio reader output unavailable"])
            }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? NSError(domain: "VoiceOSProbe", code: 4)
            }
            var frames: Int64 = 0
            var buffers = 0
            while let sample = output.copyNextSampleBuffer() {
                frames += Int64(CMSampleBufferGetNumSamples(sample))
                buffers += 1
            }
            guard reader.status == .completed, frames > 0 else {
                throw reader.error ?? NSError(domain: "VoiceOSProbe", code: 5, userInfo: [NSLocalizedDescriptionKey: "incomplete audio decode"])
            }
            let result: [String: Any] = [
                "probe": "local-media-container-v1", "valid": true,
                "duration_seconds": duration, "audio_tracks": audio.count,
                "video_tracks": video.count, "decoded_audio_frames": frames,
                "decoded_audio_buffers": buffers, "reader_completed": true,
                "video_frames_decoded": false, "microphone_used": false,
                "cloud_upload_executed": false
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            // Do not emit supplied paths, personal content, or uncaught crash logs.
            let result: [String: Any] = ["probe": "local-media-container-v1", "valid": false, "error_domain": (error as NSError).domain, "error_code": (error as NSError).code]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(1)
        }
    }
}
