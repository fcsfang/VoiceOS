import AppKit
import SwiftUI

enum WorkspaceTheme: String, CaseIterable, Identifiable {
    case graphite, sage

    var id: String { rawValue }
    var title: String { self == .graphite ? "石墨" : "鼠尾草" }
    var subtitle: String { self == .graphite ? "中性灰阶，专注内容" : "柔和绿调，轻盈自然" }
}

struct WorkspacePalette {
    let theme: WorkspaceTheme
    private let increasesContrast: Bool

    init(theme: WorkspaceTheme) {
        self.theme = theme
        increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    var canvas: Color { theme == .graphite ? adaptive(0xF2F2F3, 0x1E1E1E) : adaptive(0xF1F3EE, 0x1B1F1D) }
    var surface: Color { theme == .graphite ? adaptive(0xFCFCFD, 0x272727) : adaptive(0xFFFFFF, 0x242925) }
    var sidebar: Color { theme == .graphite ? adaptive(0xECECEE, 0x161616) : adaptive(0xE9EDE6, 0x171C18) }
    var text: Color { theme == .graphite ? adaptive(0x202020, 0xECECEC) : adaptive(0x26352D, 0xE5EBE4) }
    /// Secondary toolbar and metadata copy; one step quieter than `text`.
    var secondaryText: Color { text.opacity(increasesContrast ? 0.85 : 0.72) }
    /// Counts, footers and third-level facts. One step quieter than `secondaryText`.
    var tertiaryText: Color { text.opacity(increasesContrast ? 0.66 : 0.53) }
    var accent: Color { theme == .graphite ? adaptive(0x3A4A5C, 0xAEC3D6) : adaptive(0x315F49, 0xB8D9BF) }
    var selection: Color { theme == .graphite ? adaptive(0xE7E7E7, 0x333333) : adaptive(0xE6EEE5, 0x303F33) }
    var border: Color {
        theme == .graphite
            ? (increasesContrast ? adaptive(0xB0B0B6, 0x6C6C6C) : adaptive(0xD5D5D8, 0x4A4A4A))
            : (increasesContrast ? adaptive(0xA7B5A5, 0x6C7F72) : adaptive(0xCCD6CA, 0x4A5A4E))
    }
    var hover: Color { selection.opacity(0.55) }
    var pressed: Color { selection.opacity(0.9) }
    var disabledText: Color { text.opacity(increasesContrast ? 0.6 : 0.35) }
    var focusRing: Color { accent.opacity(0.5) }
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
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double(value >> 16 & 255) / 255,
                green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
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
                Text(theme.subtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
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
