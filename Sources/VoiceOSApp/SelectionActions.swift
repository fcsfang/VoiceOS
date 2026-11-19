import SwiftUI

struct SelectionActions: View {
    @Environment(\.workspacePalette) private var palette
    let selection: String
    let canPlay: Bool
    let onSave: () -> Void
    let onCopy: () -> Void
    let onPlay: () -> Void

    private var isVisible: Bool {
        !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Button("存为问题", systemImage: "questionmark.bubble", action: onSave)
                .buttonStyle(.workspaceSecondary)
            Button("复制", systemImage: "doc.on.doc", action: onCopy)
                .buttonStyle(.workspaceQuiet)
                .accessibilityLabel("复制选中文字")
            Button("回听选中段", systemImage: "play.circle", action: onPlay)
                .buttonStyle(.workspaceQuiet)
                .disabled(!canPlay)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border, lineWidth: 1) }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .disabled(!isVisible)
    }
}
