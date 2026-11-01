import AppKit
import SwiftUI

enum WorkspaceTheme: String, CaseIterable, Identifiable {
    case graphite, sage

    var id: String { rawValue }
    var title: String { self == .graphite ? "石墨" : "鼠尾草" }
    var subtitle: String { self == .graphite ? "中性灰阶，专注内容" : "柔和绿调，轻盈自然" }
}

enum WorkspaceAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct WorkspacePalette {
    let theme: WorkspaceTheme

    var canvas: Color { theme == .graphite ? adaptive(0xFFFFFF, 0x202020) : adaptive(0xFAFAF7, 0x1D211F) }
    var surface: Color { theme == .graphite ? adaptive(0xF7F7F8, 0x292929) : adaptive(0xFFFFFF, 0x242925) }
    var sidebar: Color { theme == .graphite ? adaptive(0xF3F3F3, 0x181818) : adaptive(0xF0F2ED, 0x181D19) }
    var text: Color { theme == .graphite ? adaptive(0x202020, 0xECECEC) : adaptive(0x26352D, 0xE5EBE4) }
    var accent: Color { theme == .graphite ? adaptive(0x282828, 0xE5E5E5) : adaptive(0x315F49, 0xB8D9BF) }
    var selection: Color { theme == .graphite ? adaptive(0xE7E7E7, 0x333333) : adaptive(0xE6EEE5, 0x303F33) }
    var border: Color { theme == .graphite ? adaptive(0xDEDEDE, 0x424242) : adaptive(0xD8E1D7, 0x405044) }
    // Graph colors distinguish kinds of evidence without tinting the workspace.
    var action: Color { adaptive(0x526B82, 0xA9BED1) }
    var outcome: Color { adaptive(0x826B52, 0xCDB99E) }
    // Status roles. Warnings are recoverable; danger marks failed writes or
    // destructive results. Success follows the theme accent so completion never
    // introduces an off-hue green.
    var warning: Color { adaptive(0x9A5B13, 0xE8B15D) }
    var danger: Color { adaptive(0xB42318, 0xF97066) }
    var success: Color { accent }

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
                    Text(theme.title).font(.callout.weight(.medium))
                    if theme == .graphite { Text("默认").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent) }
                }
                Text(theme.subtitle).font(.caption).foregroundStyle(.secondary)
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
