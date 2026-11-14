import Foundation
import Vision
import VoiceOSCore

public enum ImageOCR {
    public static func recognize(fileURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(url: fileURL).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw VoiceOSError("图片里没有识别到文字") }
            return text
        }.value
    }
}
