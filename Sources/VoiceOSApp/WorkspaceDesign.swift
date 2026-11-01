import SwiftUI

// Shared design vocabulary. Views pick from these tokens instead of restating
// sizes, widths and container shapes, so a page cannot drift from its siblings.
enum WorkspaceMetrics {
    static let pageWidth: CGFloat = 860
    static let pagePadding: CGFloat = 30
    static let sectionRadius: CGFloat = 14
    static let panelRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let tabRadius: CGFloat = 10
    static let iconButtonSize: CGFloat = 32
    static let modalSmall: CGFloat = 620
    static let modalMedium: CGFloat = 720
    static let modalLarge: CGFloat = 1020
}

// The editorial surfaces (capture, assistant, reflection) keep their serif
// motif; the rest of the app reads in the system face.
struct WorkspaceHero: View {
    @Environment(\.workspacePalette) private var palette
    let eyebrow: String
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2)
                .textCase(.uppercase).foregroundStyle(palette.accent)
            Text(title).font(.system(size: 27, weight: .medium, design: .serif)).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkspaceSearchField: View {
    @Environment(\.workspacePalette) private var palette
    @Binding var text: String
    var placeholder: String
    var focus: FocusState<Bool>.Binding? = nil
    var submit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                    focus?.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.tertiary)
                }.buttonStyle(.plain).accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(palette.border, lineWidth: 1) }
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 15)).focused(focus)
                .onSubmit { submit?() }
        } else {
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 15))
                .onSubmit { submit?() }
        }
    }
}

struct WorkspaceEmptyState<Actions: View>: View {
    let title: String
    var systemImage: String = "leaf"
    var description: String = ""
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if !description.isEmpty { Text(description) }
        } actions: {
            actions()
        }.frame(maxWidth: .infinity)
    }
}

extension WorkspaceEmptyState where Actions == EmptyView {
    init(title: String, systemImage: String = "leaf", description: String = "") {
        self.init(title: title, systemImage: systemImage, description: description) { EmptyView() }
    }
}

struct WorkspaceIconButton: View {
    @Environment(\.workspacePalette) private var palette
    let systemImage: String
    let label: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
                .frame(width: WorkspaceMetrics.iconButtonSize, height: WorkspaceMetrics.iconButtonSize)
                .background(hovered ? palette.selection.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .help(label).accessibilityLabel(label)
    }
}

struct WorkspaceNoticeText: View {
    enum Severity { case danger, warning }
    @Environment(\.workspacePalette) private var palette
    let message: String
    var severity: Severity = .warning

    var body: some View {
        Text(message).font(.callout)
            .foregroundStyle(severity == .danger ? palette.danger : palette.warning)
            .textSelection(.enabled)
    }
}

private struct WorkspaceHoverHighlight: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let cornerRadius: CGFloat
    @State private var hovered = false

    func body(content: Content) -> some View {
        content.background(hovered ? palette.selection.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovered = $0 }
    }
}

private struct WorkspaceEditorSurface: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.padding(10)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(palette.border, lineWidth: 1) }
    }
}

extension View {
    func workspaceHoverHighlight(cornerRadius: CGFloat = WorkspaceMetrics.controlRadius) -> some View {
        modifier(WorkspaceHoverHighlight(cornerRadius: cornerRadius))
    }

    func workspaceEditorSurface(radius: CGFloat = WorkspaceMetrics.controlRadius) -> some View {
        modifier(WorkspaceEditorSurface(radius: radius))
    }
}
