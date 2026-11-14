import XCTest
import AppKit
import VoiceOSCore
import VoiceOSPlatform

final class PDFTextChecks: XCTestCase {
    func testExtractReadsTextAndPageCount() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writePDF(pages: ["VoiceOS 第一页正文", "VoiceOS 第二页正文"], to: url)
        let result = try PDFText.extract(fileURL: url)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertTrue(result.text.contains("VoiceOS 第一页正文"), result.text)
        XCTAssertTrue(result.text.contains("VoiceOS 第二页正文"), result.text)
    }

    func testEmptyTextPDFThrowsVoiceOSError() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writePDF(pages: [nil], to: url)
        XCTAssertThrowsError(try PDFText.extract(fileURL: url)) { error in
            XCTAssertTrue(error is VoiceOSError)
        }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-pdf-" + UUID().uuidString + ".pdf")
    }

    private func writePDF(pages: [String?], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw VoiceOSError("测试 PDF 创建失败")
        }
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                (text as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 24),
                    .foregroundColor: NSColor.black,
                ])
                NSGraphicsContext.restoreGraphicsState()
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
