import SwiftUI

// Shared design vocabulary. Views pick from these tokens instead of restating
// sizes, widths and container shapes, so a page cannot drift from its siblings.
enum WorkspaceMetrics {
    static let pageWidth: CGFloat = 860
    static let readerWidth: CGFloat = 720
    static let pagePadding: CGFloat = 32
    // Spacing rhythm asks the eye to group before it reads: rows inside one
    // group stay tight, groups breathe, sections start a new plane.
    static let rowGap: CGFloat = 8
    static let groupGap: CGFloat = 18
    static let sectionGap: CGFloat = 28
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

// Motion is defined once, here, and taken by interaction category instead of
// being restated per view. Call sites still gate it with
// `reduceMotion ? nil : ...` so the system setting wins.
enum WorkspaceMotion {
    /// Pointer hover and press: responds at once without flicker.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Selection and active-state changes.
    static let selection = Animation.easeOut(duration: 0.12)
    /// Expand and collapse.
    static let expand = Animation.easeOut(duration: 0.16)
    /// Transient overlays entering and leaving: toasts, undo bars.
    static let transient = Animation.easeOut(duration: 0.2)
    /// Section jumps and viewport restoration.
    static let scroll = Animation.easeOut(duration: 0.18)
}

// The editorial surfaces (capture, assistant, reflection) keep their serif
// motif; the rest of the app reads in the system face.
struct WorkspaceHero: View {
    let eyebrow: String
    let title: String
    var subtitle: String = ""
    var body: some View {
        WorkspacePageHeading(eyebrow: eyebrow, title: title, subtitle: subtitle)
            .textSelection(.enabled)
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
            Image(systemName: "magnifyingglass").vosFont(WorkspaceText.meta.size, weight: .medium).foregroundStyle(palette.secondaryText)
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                    focus?.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill").vosFont(WorkspaceText.meta.size).foregroundStyle(palette.tertiaryText)
                        .frame(width: WorkspaceMetrics.rowActionMinHeight, height: WorkspaceMetrics.rowActionMinHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, WorkspaceMetrics.controlPadding).frame(minHeight: 36)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(palette.border, lineWidth: 1) }
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(placeholder, text: $text).textFieldStyle(.plain).vosFont(WorkspaceText.body).focused(focus)
                .onSubmit { submit?() }
        } else {
            TextField(placeholder, text: $text).textFieldStyle(.plain).vosFont(WorkspaceText.body)
                .onSubmit { submit?() }
        }
    }
}

struct WorkspaceEmptyState<Actions: View>: View {
    @Environment(\.workspacePalette) private var palette
    let title: String
    var systemImage: String = "leaf"
    var description: String = ""
    /// A failed read keeps the danger tone and lets the reader copy the detail.
    var severity: WorkspaceNoticeText.Severity? = nil
    var selectableMessage: Bool = false
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if !description.isEmpty {
                if selectableMessage {
                    descriptionText.textSelection(.enabled)
                } else {
                    descriptionText
                }
            }
        } actions: {
            actions()
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var descriptionText: some View {
        if let severity {
            Text(description).foregroundStyle(tint(severity))
        } else {
            Text(description)
        }
    }

    private func tint(_ severity: WorkspaceNoticeText.Severity) -> Color {
        switch severity {
        case .danger: palette.danger
        case .warning: palette.warning
        case .info: palette.accent
        case .success: palette.success
        }
    }
}

extension WorkspaceEmptyState where Actions == EmptyView {
    init(title: String, systemImage: String = "leaf", description: String = "",
         severity: WorkspaceNoticeText.Severity? = nil, selectableMessage: Bool = false) {
        self.init(title: title, systemImage: systemImage, description: description,
                  severity: severity, selectableMessage: selectableMessage) { EmptyView() }
    }
}

struct WorkspaceIconButton: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let systemImage: String
    let label: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).vosFont(WorkspaceText.rowTitle.size, weight: .medium)
                .frame(width: WorkspaceMetrics.iconButtonSize, height: WorkspaceMetrics.iconButtonSize)
                .background(hovered && isEnabled ? palette.hover : .clear, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.chipRadius))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 && isEnabled }
            .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
            .help(label).accessibilityLabel(label)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct WorkspaceNoticeText: View {
    enum Severity { case danger, warning, info, success }
    @Environment(\.workspacePalette) private var palette
    let message: String
    var severity: Severity = .warning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon).vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message).vosFont(WorkspaceText.meta).foregroundStyle(palette.text)
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
            Image(systemName: "checkmark.circle.fill").vosFont(WorkspaceText.meta.size, weight: .semibold)
                .foregroundStyle(palette.success).accessibilityHidden(true)
            Text(message).vosFont(WorkspaceText.meta).foregroundStyle(palette.text).lineLimit(2)
                .accessibilityHidden(true)
            Button(action: close) {
                Image(systemName: "xmark").vosFont(WorkspaceText.caption.size, weight: .semibold)
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: WorkspaceMetrics.rowActionMinHeight, height: WorkspaceMetrics.rowActionMinHeight)
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
    private static let visibleFor: TimeInterval = 3.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var message: String?
    @State private var hovered = false
    @State private var remaining = WorkspaceToastModifier.visibleFor
    @State private var deadline: Date?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let text = message {
                    WorkspaceToast(message: text) {
                        withAnimation(reduceMotion ? nil : WorkspaceMotion.transient) { message = nil }
                    }
                    .padding(.bottom, 18)
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                    .onHover { setHovered($0) }
                }
            }
            .animation(reduceMotion ? nil : WorkspaceMotion.transient, value: message)
            .onChange(of: message) { _, text in
                guard let text else { deadline = nil; return }
                remaining = Self.visibleFor
                deadline = hovered ? nil : Date().addingTimeInterval(remaining)
                // The toast is transient, so VoiceOver hears it once instead of
                // chasing an element that disappears.
                AccessibilityNotification.Announcement(text).post()
            }
            .task(id: dismissKey) { await dismissWhenDue() }
    }

    private var dismissKey: String {
        (message ?? "") + "|" + (deadline.map { String($0.timeIntervalSinceReferenceDate) } ?? "paused")
    }

    private func setHovered(_ value: Bool) {
        guard value != hovered else { return }
        if value, let deadline {
            remaining = max(0, deadline.timeIntervalSinceNow)
            self.deadline = nil
            hovered = true
        } else if !value, message != nil {
            deadline = Date().addingTimeInterval(remaining)
            hovered = false
        } else {
            hovered = value
        }
    }

    private func dismissWhenDue() async {
        guard message != nil, !hovered, let deadline else { return }
        let wait = deadline.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard message != nil, !hovered, self.deadline == deadline else { return }
        withAnimation(reduceMotion ? nil : WorkspaceMotion.transient) { message = nil }
        self.deadline = nil
    }
}

struct WorkspaceRowChevron: View {
    @Environment(\.workspacePalette) private var palette

    var body: some View {
        Image(systemName: "chevron.right").vosFont(WorkspaceText.caption.size, weight: .semibold)
            .foregroundStyle(palette.disabledText).accessibilityHidden(true)
    }
}

struct WorkspaceListRow<Trailing: View>: View {
    enum Density { case comfortable, compact }
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vosTextScale) private var textScale
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
                Image(systemName: icon).vosFont(WorkspaceText.rowTitle.size, weight: .medium)
                    .foregroundStyle(action == nil ? palette.disabledText : palette.accent)
                    .frame(width: 34, height: 34)
                    .background(iconBackground, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).vosFont(WorkspaceText.rowTitle)
                    .foregroundStyle(action == nil ? palette.disabledText : palette.text)
                    .lineLimit(textLineLimit)
                if !subtitle.isEmpty {
                    Text(subtitle).vosFont(WorkspaceText.meta)
                        .foregroundStyle(action == nil ? palette.disabledText : palette.secondaryText)
                        .lineLimit(textLineLimit)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, density == .comfortable ? 12 : 10)
        .padding(.vertical, density == .comfortable ? 9 : 8)
        .frame(minHeight: density == .comfortable ? 52 : 44, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
        .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
    }

    private var iconBackground: Color {
        if action == nil { return palette.selection.opacity(0.35) }
        return highlighted ? palette.surface : palette.selection.opacity(0.6)
    }

    private var rowBackground: Color {
        if highlighted { return palette.selection }
        if hovered && action != nil { return palette.hover }
        return .clear
    }

    // Only 特大 (1.45) crosses 1.3; 大 (1.28) keeps the single-line row.
    private var textLineLimit: Int {
        textScale >= 1.3 ? 2 : 1
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cornerRadius: CGFloat
    @State private var hovered = false

    func body(content: Content) -> some View {
        content.background(hovered ? palette.hover : .clear, in: RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
    }
}

/// Sheet roots are separate windows; without a palette fill they fall back to the system near-white.
private struct WorkspaceModalSurface: ViewModifier {
    @Environment(\.workspacePalette) private var palette

    func body(content: Content) -> some View {
        content.background(palette.canvas)
    }
}

struct WorkspaceFieldSurface: ViewModifier {
    @Environment(\.workspacePalette) private var palette

    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(minHeight: WorkspaceMetrics.fieldHeight)
            .background(palette.selection, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(palette.border, lineWidth: 1) }
    }
}

private struct WorkspaceEditorSurface: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.padding(10)
            .scrollContentBackground(.hidden)
            .background(palette.selection, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(palette.border, lineWidth: 1) }
    }
}

private struct WorkspaceFocusRing: ViewModifier {
    @Environment(\.workspacePalette) private var palette
    let isFocused: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: radius).strokeBorder(palette.focusRing, lineWidth: 1)
            }
        }
    }
}

extension View {
    func workspaceHoverHighlight(cornerRadius: CGFloat = WorkspaceMetrics.controlRadius) -> some View {
        modifier(WorkspaceHoverHighlight(cornerRadius: cornerRadius))
    }

    func workspaceModalSurface() -> some View {
        modifier(WorkspaceModalSurface())
    }

    func workspaceFieldSurface() -> some View {
        modifier(WorkspaceFieldSurface())
    }

    func workspaceEditorSurface(radius: CGFloat = WorkspaceMetrics.controlRadius) -> some View {
        modifier(WorkspaceEditorSurface(radius: radius))
    }

    func workspaceFocusRing(_ isFocused: Bool, radius: CGFloat) -> some View {
        modifier(WorkspaceFocusRing(isFocused: isFocused, radius: radius))
    }

    /// Shows the caller's slow-load placeholder only after 150ms, so fast loads never flash one.
    func workspaceSlowLoading(_ isLoading: Bool, into visible: Binding<Bool>) -> some View {
        self.task(id: isLoading) {
            guard isLoading else { visible.wrappedValue = false; return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            if isLoading { visible.wrappedValue = true }
        }
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

/// The content paints itself with the palette canvas, so the NSWindow must
/// do the same; otherwise the titlebar keeps the system near-white and reads
/// as a separate strip above the warm canvas.
private struct WindowCanvasTint: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window, window.backgroundColor != NSColor(color) else { return }
        window.backgroundColor = NSColor(color)
        window.titlebarAppearsTransparent = true
    }
}

extension View {
    func windowCanvasTint(_ color: Color) -> some View {
        background(WindowCanvasTint(color: color))
    }
}

// MARK: - Action buttons

/// One button vocabulary for the whole app. Primary fills with the ink color
/// and appears at most once per view; secondary carries a hairline border for
/// every other action; quiet is accent text with no chrome.
struct WorkspaceButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary, quiet, destructive }
    var emphasis: Emphasis = .secondary
    var compact = false
    var monospacedDigit = false

    func makeBody(configuration: Configuration) -> some View {
        WorkspaceButtonBody(configuration: configuration, emphasis: emphasis, compact: compact, monospacedDigit: monospacedDigit)
    }
}

private struct WorkspaceButtonBody: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyle.Configuration
    let emphasis: WorkspaceButtonStyle.Emphasis
    let compact: Bool
    let monospacedDigit: Bool
    @State private var hovered = false

    private var radius: CGFloat { 7 }

    var body: some View {
        configuration.label
            .vosFont(WorkspaceText.meta.size + 0.5, weight: .medium, monospacedDigit: monospacedDigit)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(minHeight: compact ? 25 : 29)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                if emphasis == .secondary {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(palette.border, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .opacity(opacity)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovered = false }
            }
    }

    private var foreground: Color {
        switch emphasis {
        case .primary: palette.canvas
        case .secondary: palette.text
        case .quiet: palette.accent
        case .destructive: palette.danger
        }
    }

    private var background: Color {
        switch emphasis {
        case .primary: palette.text
        case .secondary: hovered && isEnabled ? palette.hover : palette.surface
        case .quiet, .destructive: hovered && isEnabled ? palette.hover : .clear
        }
    }

    private var opacity: Double {
        if !isEnabled { return 0.4 }
        return configuration.isPressed ? 0.72 : 1
    }
}

extension ButtonStyle where Self == WorkspaceButtonStyle {
    /// The single committed action on a surface.
    static var workspacePrimary: WorkspaceButtonStyle { .init(emphasis: .primary) }
    /// Every other action: visible, bordered, never reading as disabled.
    static var workspaceSecondary: WorkspaceButtonStyle { .init(emphasis: .secondary) }
    /// Accent text actions embedded in copy or headers.
    static var workspaceQuiet: WorkspaceButtonStyle { .init(emphasis: .quiet) }
    static var workspaceDestructive: WorkspaceButtonStyle { .init(emphasis: .destructive) }
    /// Smaller secondary for dense rows.
    static var workspaceSecondaryCompact: WorkspaceButtonStyle { .init(emphasis: .secondary, compact: true) }
    static var workspaceQuietCompact: WorkspaceButtonStyle { .init(emphasis: .quiet, compact: true) }
}

// MARK: - Badges

/// Counts and states share one capsule. Neutral carries counts, accent an
/// active outcome, warning an unresolved conflict.
struct WorkspaceBadge: View {
    enum Tone { case neutral, accent, warning, danger, success }
    @Environment(\.workspacePalette) private var palette
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .vosFont(WorkspaceText.caption.size, weight: .semibold, monospacedDigit: true)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(tint.opacity(0.13), in: Capsule())
            .accessibilityLabel(text)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: palette.secondaryText
        case .accent: palette.accent
        case .warning: palette.warning
        case .danger: palette.danger
        case .success: palette.success
        }
    }

    private var tint: Color {
        switch tone {
        case .neutral: palette.text
        default: foreground
        }
    }
}

// MARK: - Page and section headers

/// Every page opens with the same block: optional eyebrow, a page title, an
/// optional one-line explanation, and actions pinned to the right.
struct WorkspacePageHeading<Trailing: View>: View {
    @Environment(\.workspacePalette) private var palette
    var eyebrow: String = ""
    let title: String
    var subtitle: String = ""
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                titleBlock
                Spacer(minLength: 12)
                trailing()
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                trailing()
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !eyebrow.isEmpty {
                Text(eyebrow)
                    .vosFont(WorkspaceText.caption.size, weight: .semibold, design: .monospaced)
                    .tracking(1.4).textCase(.uppercase).foregroundStyle(palette.accent)
            }
            Text(title).vosFont(WorkspaceText.pageTitle).accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension WorkspacePageHeading where Trailing == EmptyView {
    init(eyebrow: String = "", title: String, subtitle: String = "") {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A section inside a page: title, optional count, trailing actions.
struct WorkspaceSectionHeading<Trailing: View>: View {
    @Environment(\.workspacePalette) private var palette
    let title: String
    var count: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            if let count {
                Text(count).vosFont(WorkspaceText.meta, monospacedDigit: true).foregroundStyle(palette.tertiaryText)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension WorkspaceSectionHeading where Trailing == EmptyView {
    init(_ title: String, count: String? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

// MARK: - Cards

/// Raised content surface. All cards share the same radius, padding rhythm and
/// hairline, so a page never drifts into a different container style.
struct WorkspaceCard<Content: View>: View {
    @Environment(\.workspacePalette) private var palette
    var padding: CGFloat = 20
    var radius: CGFloat = WorkspaceMetrics.sectionRadius
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius).strokeBorder(palette.border, lineWidth: 1)
            }
    }
}
