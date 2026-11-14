import Foundation
import PDFKit
import VoiceOSCore

public struct PDFTextResult: Sendable {
    public let text: String
    public let pageCount: Int
    public init(text: String, pageCount: Int) {
        self.text = text
        self.pageCount = pageCount
    }
}

public enum PDFText {
    public static func extract(fileURL: URL) throws -> PDFTextResult {
        guard let document = PDFDocument(url: fileURL) else { throw VoiceOSError("无法读取 PDF 文件") }
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceOSError("PDF 里没有可提取的文字")
        }
        return PDFTextResult(text: text, pageCount: document.pageCount)
    }
}
