import XCTest
import Foundation
import AppKit
import VoiceOSCore
import VoiceOSPlatform

final class ImageOCRChecks: XCTestCase {
    func testRecognizeReadsRenderedEnglishText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-ocr-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeImage("VoiceOS", to: url)
        let text = try await ImageOCR.recognize(fileURL: url)
        XCTAssertTrue(text.contains("VoiceOS"), text)
    }

    private func writeImage(_ text: String, to url: URL) throws {
        let size = NSSize(width: 900, height: 240)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 96, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            (text as NSString).draw(at: NSPoint(x: 40, y: 70), withAttributes: attributes)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            throw VoiceOSError("测试图片生成失败")
        }
        try png.write(to: url)
    }
}
