import SwiftUI

// Shared design vocabulary. Views pick from these tokens instead of restating
// sizes, widths and container shapes, so a page cannot drift from its siblings.
enum WorkspaceMetrics {
    static let pageWidth: CGFloat = 860
    static let readerWidth: CGFloat = 720
    static let pagePadding: CGFloat = 32
    static let sectionGap: CGFloat = 24
    static let controlPadding: CGFloat = 12
    static let toolbarPadding: CGFloat = 16
    static let sectionRadius: CGFloat = 16
    static let panelRadius: CGFloat = 12
    static let chipRadius: CGFloat = 6
    static let controlRadius: CGFloat = 8
    static let tabRadius: CGFloat = 10
    static let iconButtonSize: CGFloat = 28
    static let rowActionMinHeight: CGFloat = 24
    static let fieldHeight: CGFloat = 28
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
            if !eyebrow.isEmpty {
                Text(eyebrow).vosFont(10, weight: .semibold, design: .monospaced).tracking(2)
                    .textCase(.uppercase).foregroundStyle(palette.accent)
            }
            Text(title).vosFont(27, weight: .medium, design: .serif).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).vosFont(14).foregroundStyle(.secondary).lineSpacing(4)
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
            Image(systemName: "magnifyingglass").vosFont(13, weight: .medium).foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                    focus?.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill").vosFont(13).foregroundStyle(.tertiary)
                }.buttonStyle(.plain).accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, WorkspaceMetrics.controlPadding).frame(minHeight: 36)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(palette.border, lineWidth: 1) }
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(placeholder, text: $text).textFieldStyle(.plain).vosFont(15).focused(focus)
                .onSubmit { submit?() }
        } else {
            TextField(placeholder, text: $text).textFieldStyle(.plain).vosFont(15)
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
            Image(systemName: systemImage).vosFont(14, weight: .medium)
                .frame(width: WorkspaceMetrics.iconButtonSize, height: WorkspaceMetrics.iconButtonSize)
                .background(hovered ? palette.hover : .clear, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.chipRadius))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .help(label).accessibilityLabel(label)
    }
}

struct WorkspaceNoticeText: View {
    enum Severity { case danger, warning, info, success }
    @Environment(\.workspacePalette) private var palette
    let message: String
    var severity: Severity = .warning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon).vosFont(12, weight: .semibold).foregroundStyle(tint)
            Text(message).vosFont(WorkspaceText.meta.size).foregroundStyle(palette.text)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(tint.opacity(0.3), lineWidth: 1) }
    }

    private var tint: Color {
        switch severity {
        case .danger: palette.danger
        case .warning: palette.warning
        case .info: palette.accent
        case .success: palette.success
        }
    }

    private var icon: String {
        switch severity {
        case .danger: "exclamationmark.triangle"
        case .warning: "exclamationmark.circle"
        case .info: "info.circle"
        case .success: "checkmark.circle"
        }
    }
}

struct WorkspaceToast: View {
    @Environment(\.workspacePalette) private var palette
    let message: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").vosFont(13, weight: .semibold)
                .foregroundStyle(palette.success)
            Text(message).vosFont(WorkspaceText.meta.size).foregroundStyle(palette.text).lineLimit(2)
            Button(action: close) {
                Image(systemName: "xmark").vosFont(10, weight: .semibold)
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(palette.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.border, lineWidth: 1) }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

private struct WorkspaceToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let text = message {
                    WorkspaceToast(message: text) {
                        withAnimation(.easeOut(duration: 0.2)) { message = nil }
                    }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.26), value: message)
    }
}

struct WorkspaceRowChevron: View {
    @Environment(\.workspacePalette) private var palette

    var body: some View {
        Image(systemName: "chevron.right").vosFont(11, weight: .semibold)
            .foregroundStyle(palette.disabledText).accessibilityHidden(true)
    }
}

struct WorkspaceListRow<Trailing: View>: View {
    enum Density { case comfortable, compact }
    @Environment(\.workspacePalette) private var palette
    var density: Density = .comfortable
    let title: String
    var subtitle: String = ""
    var icon: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var highlighted: Bool = false
    var action: (() -> Void)? = nil
    @State private var hovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { row }
            } else {
                row
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 && action != nil }
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private var row: some View {
        HStack(spacing: density == .comfortable ? 11 : 9) {
            if let icon {
                Image(systemName: icon).vosFont(15, weight: .medium)
                    .foregroundStyle(action == nil ? palette.disabledText : palette.accent)
                    .frame(width: 34, height: 34)
                    .background(iconBackground, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).vosFont(titleSize, weight: .semibold)
                    .foregroundStyle(action == nil ? palette.disabledText : palette.text)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).vosFont(WorkspaceText.meta.size)
                        .foregroundStyle(action == nil ? palette.disabledText : palette.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, density == .comfortable ? 12 : 10)
        .padding(.vertical, density == .comfortable ? 9 : 6)
        .frame(minHeight: density == .comfortable ? 52 : 44, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var titleSize: CGFloat { density == .comfortable ? WorkspaceText.rowTitle.size : 15 }

    private var iconBackground: Color {
        if action == nil { return palette.selection.opacity(0.35) }
        return highlighted ? palette.surface : palette.selection.opacity(0.6)
    }

    private var rowBackground: Color {
        if highlighted { return palette.selection }
        if hovered && action != nil { return palette.hover }
        return .clear
    }
}

extension WorkspaceListRow where Trailing == WorkspaceRowChevron {
    init(density: Density = .comfortable, title: String, subtitle: String = "", icon: String? = nil,
         highlighted: Bool = false, action: (() -> Void)? = nil) {
        self.init(density: density, title: title, subtitle: subtitle, icon: icon,
                  trailing: { WorkspaceRowChevron() }, highlighted: highlighted, action: action)
    }
}

private struct WorkspaceHoverHighlight: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let cornerRadius: CGFloat
    @State private var hovered = false

    func body(content: Content) -> some View {
        content.background(hovered ? palette.hover : .clear, in: RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovered = $0 }
    }
}

private struct WorkspaceEditorSurface: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.padding(10)
            .scrollContentBackground(.hidden)
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

    func workspaceToast(_ message: Binding<String?>) -> some View {
        modifier(WorkspaceToastModifier(message: message))
    }
}

/// SwiftUI presents `.sheet` as a fixed-size window on macOS. The HIG asks
/// sheets with long content to support resizing, which only a resizable
/// NSWindow offers, so the sheet's hosting window flips its style mask once
/// it is on screen.
private struct WorkspaceResizableSheet: NSViewRepresentable {
    let minimumSize: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window, !window.styleMask.contains(.resizable) else { return }
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumSize
    }
}

extension View {
    func workspaceResizableSheet(minimumSize: CGSize = CGSize(width: 680, height: 540)) -> some View {
        background(WorkspaceResizableSheet(minimumSize: minimumSize))
    }
}
