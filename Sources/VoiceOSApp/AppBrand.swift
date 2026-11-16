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

    static func applyApplicationIcon() {
        guard let appearance = NSApp?.effectiveAppearance, let image = image(for: appearance) else { return }
        NSApplication.shared.applicationIconImage = dockTile(image)
    }

    /// The supplied tiles are full-bleed. Drawing them inside Apple's icon grid
    /// keeps the Dock size in line with system apps; scripts/app/pad_icon.swift
    /// applies the same fraction to the bundle icon.
    static let iconContentFraction: CGFloat = 0.91

    static func dockTile(_ source: NSImage) -> NSImage {
        let side = source.size.width
        let canvas = NSImage(size: source.size)
        canvas.lockFocus()
        let inset = side * iconContentFraction
        source.draw(in: NSRect(x: (side - inset) / 2, y: (side - inset) / 2, width: inset, height: inset))
        canvas.unlockFocus()
        return canvas
    }

    /// The menu bar shows only the V mark. The mask comes from the light tile's
    /// ink, and the template rendering lets the system tint it for the menu bar.
    /// Recording fills the same mark with the system red and opts out of template
    /// tinting, so the active state reads at a glance without a second asset.
    static func menuBarImage(recording: Bool = false) -> NSImage? {
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
        let fallback = recording ? NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let tint = (recording ? NSColor.systemRed : NSColor.black).usingColorSpace(.deviceRGB) ?? fallback
        let red = Int((tint.redComponent * 255).rounded())
        let green = Int((tint.greenComponent * 255).rounded())
        let blue = Int((tint.blueComponent * 255).rounded())
        for index in 0..<mask.alpha.count {
            let alpha = Int(mask.alpha[index])
            buffer[index * 4] = UInt8(red * alpha / 255)
            buffer[index * 4 + 1] = UInt8(green * alpha / 255)
            buffer[index * 4 + 2] = UInt8(blue * alpha / 255)
            buffer[index * 4 + 3] = UInt8(alpha)
        }
        buffer.withUnsafeBufferPointer { maskPixels.update(from: $0.baseAddress!, count: buffer.count) }
        let height: CGFloat = 12
        let image = NSImage(size: NSSize(width: height * CGFloat(mask.width) / CGFloat(mask.height), height: height))
        image.addRepresentation(maskRep)
        image.isTemplate = !recording
        return image
    }

    private static func image(dark: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: dark ? darkName : lightName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
