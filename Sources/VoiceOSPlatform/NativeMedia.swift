import Foundation
import AVFoundation
import Speech
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
public struct NativeSpeechPort: SpeechPort {
    public init() {}
    public func transcribe(_ url: URL, locale identifier: String) async throws -> SpeechText {
        guard SpeechTranscriber.isAvailable else { throw VoiceOSError("此设备暂不支持本地转写") }
        let locale = Locale(identifier: identifier)
        guard await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) else { throw VoiceOSError("本地中文语音模型尚未安装；未下载模型或上传音频") }
        // Video and some containers cannot be opened by AVAudioFile. Extract only into a temporary local derivative.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-\(UUID().uuidString).m4a")
        let file: AVAudioFile
        if let direct = try? AVAudioFile(forReading: url) { file = direct }
        else {
            let asset = AVURLAsset(url: url)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw VoiceOSError("无法准备本地转写音轨") }
            do { try await export.export(to: temporary, as: .m4a); file = try AVAudioFile(forReading: temporary) }
            catch { try? FileManager.default.removeItem(at: temporary); throw VoiceOSError("无法提取可转写音轨") }
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let sourceDuration = try await AVURLAsset(url: url).load(.duration).seconds
        let reader = Task {
            var text = ""; var spans: [TranscriptSpan] = []; var offset = 0
            for try await result in transcriber.results {
                let part = String(result.text.characters)
                guard !part.isEmpty else { continue }
                let endOffset = offset + part.unicodeScalars.count
                let start = result.range.start.seconds * 1000
                let end = CMTimeRangeGetEnd(result.range).seconds * 1000
                let known = start.isFinite && end.isFinite && start >= 0 && end >= start && end <= sourceDuration * 1000 + 0.5
                spans.append(TranscriptSpan(textStart: offset, textEnd: endOffset, startMS: known ? Int(start.rounded()) : nil, endMS: known ? Int(end.rounded()) : nil))
                text += part; offset = endOffset
            }
            return SpeechText(text: text, spans: spans)
        }
        do {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            return try await reader.value
        } catch { reader.cancel(); throw VoiceOSError("本地转写未完成，可稍后重试") }
    }
}
