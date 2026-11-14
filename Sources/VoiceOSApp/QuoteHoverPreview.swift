import SwiftUI

struct QuoteHoverPreview<Content: View>: View {
    @Environment(\.workspacePalette) private var palette
    let sourceTitle: String
    let snippet: String
    let open: () -> Void
    private let content: Content
    @State private var revealed = false
    @State private var showTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    init(sourceTitle: String, snippet: String, open: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.sourceTitle = sourceTitle
        self.snippet = snippet
        self.open = open
        self.content = content()
    }

    var body: some View {
        content
            .onHover { inside in
                showTask?.cancel(); showTask = nil
                hideTask?.cancel(); hideTask = nil
                if inside {
                    guard !revealed else { return }
                    showTask = Task {
                        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                        revealed = true
                    }
                } else {
                    hideTask = Task {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        revealed = false
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    if revealed { panel.offset(y: geo.size.height + 6) }
                }
            }
            .zIndex(revealed ? 1 : 0)
            .onDisappear {
                showTask?.cancel(); hideTask?.cancel()
            }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sourceTitle).vosFont(12, weight: .semibold).lineLimit(2)
            Text(snippet).vosFont(13).foregroundStyle(.secondary).lineLimit(6)
            Button("打开材料") { revealed = false; open() }.font(.caption)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border, lineWidth: 1) }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .onHover { inside in
            hideTask?.cancel(); hideTask = nil
            if !inside { revealed = false }
        }
    }
}
