import AppKit
import SwiftUI
import VoiceOSCore

/// The supplied marks are full app tiles. The sidebar and the Dock icon load
/// the same asset so the brand is identical inside and outside the window.
enum AppBrand {
    private static let lightName = "VoiceOSLogoLight"
    private static let darkName = "VoiceOSLogoDark"

    static func image(for colorScheme: ColorScheme) -> NSImage? {
        image(dark: colorScheme == .dark)
    }

    static func image(for appearance: NSAppearance) -> NSImage? {
        image(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    static func applyApplicationIcon(preferred: WorkspaceAppearance = .system) {
        let appearance: NSAppearance?
        switch preferred {
        case .system: appearance = NSApp?.effectiveAppearance
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        guard let appearance, let image = image(for: appearance) else { return }
        NSApplication.shared.applicationIconImage = image
    }

    /// The menu bar shows only the V mark. The mask comes from the light tile's
    /// ink, and the template rendering lets the system tint it for the menu bar.
    static func menuBarImage() -> NSImage? {
        guard let source = image(dark: false) else { return nil }
        let side = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep),
              let pixels = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Transparent tile margins composite to white, the ink-to-alpha step's background.
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let samples = Array(UnsafeBufferPointer(start: pixels, count: side * rep.bytesPerRow))
        guard let mask = MenuBarMark.derive(rgba: samples, width: side, height: side),
              let maskRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: mask.width, pixelsHigh: mask.height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: mask.width * 4, bitsPerPixel: 32),
              let maskPixels = maskRep.bitmapData else { return nil }
        var buffer = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for index in 0..<mask.alpha.count {
            buffer[index * 4 + 3] = mask.alpha[index]
        }
        buffer.withUnsafeBufferPointer { maskPixels.update(from: $0.baseAddress!, count: buffer.count) }
        let height: CGFloat = 12
        let image = NSImage(size: NSSize(width: height * CGFloat(mask.width) / CGFloat(mask.height), height: height))
        image.addRepresentation(maskRep)
        image.isTemplate = true
        return image
    }

    private static func image(dark: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: dark ? darkName : lightName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
