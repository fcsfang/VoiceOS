import AppKit
import SwiftUI

enum WorkspaceTheme: String, CaseIterable, Identifiable {
    case graphite, snow, sage

    var id: String { rawValue }
    var title: String {
        switch self {
        case .graphite: "石墨"
        case .snow: "雪白"
        case .sage: "鼠尾草"
        }
    }
    var subtitle: String {
        switch self {
        case .graphite: "纸白暖调，柔和专注"
        case .snow: "纯中性白，更亮更冷"
        case .sage: "柔和绿调，轻盈自然"
        }
    }
}

struct WorkspacePalette {
    let theme: WorkspaceTheme
    private let increasesContrast: Bool

    init(theme: WorkspaceTheme) {
        self.theme = theme
        increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    var canvas: Color {
        switch theme {
        case .graphite: adaptive(0xFAFAF9, 0x1E1E1E)
        case .snow: adaptive(0xFFFFFF, 0x1D1D1F)
        case .sage: adaptive(0xF9FAF5, 0x1B1F1D)
        }
    }
    /// Cards sit two steps above the canvas. The border carries the grouping, so
    /// nothing reads as a white slab dropped onto a gray page.
    var surface: Color {
        switch theme {
        case .graphite: adaptive(0xFFFFFF, 0x272727)
        case .snow: adaptive(0xFFFFFF, 0x262628)
        case .sage: adaptive(0xFFFFFF, 0x242925)
        }
    }
    /// The sidebar is a half step below the canvas, not a separate slab.
    var sidebar: Color {
        switch theme {
        case .graphite: adaptive(0xF4F4F2, 0x161616)
        case .snow: adaptive(0xF3F3F5, 0x151517)
        case .sage: adaptive(0xF2F4ED, 0x171C18)
        }
    }
    var text: Color { adaptive(textValues.light, textValues.dark) }
    /// The AppKit text view behind `SelectableText` cannot take a SwiftUI
    /// `Color`, so the dynamic text color is exposed as its NSColor twin.
    var textNSColor: NSColor { dynamicColor(textValues.light, textValues.dark) }
    private var textValues: (light: UInt32, dark: UInt32) {
        switch theme {
        case .graphite: (0x1F1F1D, 0xECECEC)
        case .snow: (0x1A1A1C, 0xEDEDEF)
        case .sage: (0x242F26, 0xE5EBE4)
        }
    }
    /// Secondary toolbar and metadata copy; one step quieter than `text`.
    var secondaryText: Color { text.opacity(increasesContrast ? 0.90 : 0.80) }
    /// Counts, footers and third-level facts. One step quieter than `secondaryText`.
    var tertiaryText: Color { text.opacity(increasesContrast ? 0.80 : 0.68) }
    var accent: Color {
        switch theme {
        case .graphite: adaptive(0x3A4A5C, 0xAEC3D6)
        case .snow: adaptive(0x3B4654, 0xB6C2D2)
        case .sage: adaptive(0x315F49, 0xB8D9BF)
        }
    }
    var selection: Color {
        switch theme {
        case .graphite: adaptive(0xEFEFEC, 0x333333)
        case .snow: adaptive(0xECECEF, 0x323234)
        case .sage: adaptive(0xEDF1E6, 0x303F33)
        }
    }
    var border: Color {
        switch theme {
        case .graphite:
            increasesContrast ? adaptive(0xAFAFB0, 0x6C6C6C) : adaptive(0xE4E4DF, 0x4A4A4A)
        case .snow:
            increasesContrast ? adaptive(0xAEAEB2, 0x6C6C70) : adaptive(0xE2E2E6, 0x47474A)
        case .sage:
            increasesContrast ? adaptive(0xA5B2A2, 0x6C7F72) : adaptive(0xE1E6D8, 0x4A5A4E)
        }
    }
    var hover: Color { text.opacity(increasesContrast ? 0.16 : 0.075) }
    var pressed: Color { selection.opacity(0.9) }
    var disabledText: Color { text.opacity(increasesContrast ? 0.6 : 0.35) }
    var focusRing: Color { accent }
    // Graph colors distinguish kinds of evidence without tinting the workspace.
    var action: Color { adaptive(0x526B82, 0xA9BED1) }
    var outcome: Color { adaptive(0x826B52, 0xCDB99E) }
    // Status roles. Warnings are recoverable; danger marks failed writes or
    // destructive results. Success is a fixed green so completion reads the same
    // in either theme.
    var warning: Color { adaptive(0x9A5B13, 0xE8B15D) }
    var danger: Color { adaptive(0xB42318, 0xF97066) }
    var success: Color { adaptive(0x2E7D52, 0x6FC08A) }

    func graphColor(_ lane: Int) -> Color { [text, accent, action, outcome][lane] }

    private func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: dynamicColor(light, dark))
    }

    private func dynamicColor(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double(value >> 16 & 255) / 255,
                green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        }
    }
}

private struct WorkspacePaletteKey: EnvironmentKey {
    static let defaultValue = WorkspacePalette(theme: .graphite)
}

extension EnvironmentValues {
    var workspacePalette: WorkspacePalette {
        get { self[WorkspacePaletteKey.self] }
        set { self[WorkspacePaletteKey.self] = newValue }
    }
}

struct WorkspaceThemeOption: View {
    let theme: WorkspaceTheme
    let selected: Bool
    let choose: () -> Void
    @Environment(\.workspacePalette) private var palette
    private var preview: WorkspacePalette { WorkspacePalette(theme: theme) }

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 0) {
                    VStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(preview.text.opacity(0.55)).frame(width: 14, height: 3)
                        RoundedRectangle(cornerRadius: 2).fill(preview.selection).frame(width: 20, height: 9)
                        Spacer(minLength: 0)
                    }.padding(10).frame(width: 44).background(preview.sidebar)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(preview.text.opacity(0.65)).frame(width: 64, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(preview.text.opacity(0.16)).frame(width: 96, height: 3)
                        RoundedRectangle(cornerRadius: 4).fill(preview.surface).frame(height: 20)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(preview.canvas)
                }.frame(height: 72).clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(preview.border, lineWidth: 1) }
                HStack {
                    Text(theme.title).vosFont(WorkspaceText.rowTitle)
                    if theme == .graphite { Text("默认").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText) }
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent) }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.canvas, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? palette.accent : palette.border, lineWidth: selected ? 1.5 : 1) }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
            .accessibilityLabel(theme.title + "，" + theme.subtitle)
            .accessibilityValue(selected ? "已选择" : "未选择")
            .accessibilityIdentifier("workspace.theme." + theme.rawValue)
    }
}
