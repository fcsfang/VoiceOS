import AppKit
import SwiftUI

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

    private static func image(dark: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: dark ? darkName : lightName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
