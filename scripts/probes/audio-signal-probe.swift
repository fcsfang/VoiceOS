// Reads an authorized local audio file completely. No playback or network.
import Foundation
import AVFoundation

@main
struct AudioSignalProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "VoiceOSProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "provide local audio file"])
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw NSError(domain: "VoiceOSProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "PCM buffer unavailable"])
        }
        var frames: Int64 = 0
        var samples: Int64 = 0
        var sum: Double = 0
        var peak: Double = 0
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition))
            try file.read(into: buffer, frameCount: remaining)
            if buffer.frameLength == 0 { break }
            guard let channels = buffer.floatChannelData else {
                throw NSError(domain: "VoiceOSProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "float PCM unavailable"])
            }
            frames += Int64(buffer.frameLength)
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(channels[channel][frame])
                    samples += 1
                    sum += value * value
                    peak = max(peak, abs(value))
                }
            }
        }
        let result: [String: Any] = [
            "probe": "local-audio-signal-v1",
            "decoded_frames": frames,
            "declared_frames": file.length,
            "decode_complete": frames == file.length && samples > 0,
            "sample_count": samples,
            "peak_absolute": peak,
            "rms": samples > 0 ? sqrt(sum / Double(samples)) : 0,
            "all_decoded_samples_zero": samples > 0 && peak == 0
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
