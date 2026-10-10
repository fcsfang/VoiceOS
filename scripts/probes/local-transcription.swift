// Transcribes a supplied synthetic test file using an already-installed model.
// No microphone, model download, legacy speech API, or cloud API.
import Foundation
import AVFoundation
import Speech

@main
struct LocalTranscription {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "VoiceOSProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "provide synthetic audio file and locale"])
        }
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            throw NSError(domain: "VoiceOSProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber unavailable"])
        }
        let locale = Locale(identifier: CommandLine.arguments[2])
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier == locale.identifier }) else {
            throw NSError(domain: "VoiceOSProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "locale not installed; probe does not download models"])
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let reader = Task {
            var segments: [String] = []
            for try await result in transcriber.results {
                segments.append(String(result.text.characters))
            }
            return segments
        }
        let began = Date()
        do {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let segments = try await reader.value
            let result: [String: Any] = [
                "probe": "local-synthetic-transcription-v1",
                "locale": locale.identifier,
                "audio_seconds": Double(file.length) / file.processingFormat.sampleRate,
                "elapsed_seconds": Date().timeIntervalSince(began),
                "segments": segments,
                "text": segments.joined(),
                "engine": "Apple SpeechAnalyzer / SpeechTranscriber",
                "model_download_requested": false,
                "microphone_used": false,
                "synthetic_fixture_only": true
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            reader.cancel()
            throw error
        }
    }
}
