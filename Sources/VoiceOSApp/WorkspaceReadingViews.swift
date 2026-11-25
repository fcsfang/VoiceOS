import SwiftUI

// Navigation, section headings, content and provenance each have a distinct weight.
struct WorkspaceTabs: View {
    enum Style { case chips, filters }
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: String
    let titles: [String]
    var style: Style = .chips

    var body: some View {
        if style == .filters {
            filterRow
        } else {
            chipRow
        }
    }

    private var chipRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(titles, id: \.self) { chip($0) }
            }.fixedSize(horizontal: true, vertical: false)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 8)], spacing: 8) {
                ForEach(titles, id: \.self) { chip($0, fill: true) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filterRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                ForEach(titles, id: \.self) { filterTab($0) }
            }.fixedSize(horizontal: true, vertical: false)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 14)], alignment: .leading, spacing: 10) {
                ForEach(titles, id: \.self) { filterTab($0, fill: true) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ title: String, fill: Bool = false) -> some View {
        Button { selection = title } label: {
            Text(title).vosFont(WorkspaceText.rowTitle).lineLimit(1)
                .foregroundStyle(selection == title ? palette.canvas : palette.text)
                .frame(maxWidth: fill ? .infinity : nil)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selection == title ? palette.accent : palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(selection == title ? .clear : palette.border, lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selection == title ? [.isSelected] : [])
            .accessibilityIdentifier("workspace.tab." + title)
            .animation(reduceMotion ? nil : WorkspaceMotion.selection, value: selection)
    }

    private func filterTab(_ title: String, fill: Bool = false) -> some View {
        let selected = selection == title
        return Button { selection = title } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).vosFont(WorkspaceText.meta.size, weight: selected ? .semibold : .regular).lineLimit(1)
                    .foregroundStyle(selected ? palette.text : palette.secondaryText)
                Rectangle().fill(selected ? palette.accent : Color.clear).frame(height: 2)
            }
            .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("workspace.tab." + title)
            .animation(reduceMotion ? nil : WorkspaceMotion.selection, value: selection)
    }
}

/// Page-level secondary actions folded behind the header ellipsis.
struct WorkspaceHeaderMenu<Content: View>: View {
    @Environment(\.workspacePalette) private var palette
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu { content() } label: {
            Image(systemName: "ellipsis").vosFont(WorkspaceText.meta.size, weight: .semibold)
                .foregroundStyle(palette.secondaryText)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("更多操作").help("更多操作")
    }
}

/// 1px rule for list rows and section headers; replaces bare `Divider`.
struct WorkspaceListDivider: View {
    @Environment(\.workspacePalette) private var palette
    var body: some View {
        Rectangle().fill(palette.border).frame(height: 1).accessibilityHidden(true)
    }
}

/// Date anchor inside a long list; one step quieter than a section header.
struct WorkspaceListGroupHeader: View {
    @Environment(\.workspacePalette) private var palette
    let title: String

    var body: some View {
        Text(title).vosFont(WorkspaceText.meta.size, weight: .semibold, monospacedDigit: true)
            .foregroundStyle(palette.secondaryText)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 18).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A list-class section: header on the canvas, hairline rule, no card shell.
/// Collapsible sections start folded unless `initiallyExpanded` says otherwise.
struct WorkspaceListSection<Content: View>: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    var subtitle: String = ""
    var count: Int? = nil
    var badge: String? = nil
    var collapsible = false
    var initiallyExpanded = false
    @ViewBuilder let content: () -> Content
    @State private var userExpanded: Bool?
    private var expanded: Bool { userExpanded ?? initiallyExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if collapsible {
                Button { withAnimation(reduceMotion ? nil : WorkspaceMotion.expand) { userExpanded = !expanded } } label: { header }
                    .buttonStyle(.plain)
                    .workspaceHoverHighlight()
                    .accessibilityValue(expanded ? "已展开" : "已收起")
            } else {
                header
            }
            WorkspaceListDivider()
            if !collapsible || expanded {
                LazyVStack(alignment: .leading, spacing: 0, content: content)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            if collapsible {
                Image(systemName: "chevron.right").vosFont(WorkspaceText.caption.size, weight: .semibold)
                    .foregroundStyle(palette.tertiaryText)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            Text(title).vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.text)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let badge {
                WorkspaceBadge(text: badge, tone: .warning)
            } else if let count {
                Text(String(count)).vosFont(WorkspaceText.meta.size, weight: WorkspaceText.meta.weight, monospacedDigit: true)
                    .foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A titled group on the canvas: heading, optional quiet action, hairline,
/// then rows. Same plane as `WorkspaceListSection`; the old card shell and
/// accent icon made secondary pages read as boxes inside boxes.
struct WorkspaceSection<Content: View>: View {
    @Environment(\.workspacePalette) private var palette
    let title: String
    var subtitle: String = ""
    var count: Int? = nil
    var actionTitle: String = ""
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.text)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).lineLimit(2)
                }
                Spacer(minLength: 8)
                if let action {
                    Button(actionTitle, action: action).buttonStyle(.workspaceQuietCompact)
                } else if let count {
                    Text(String(count)).vosFont(WorkspaceText.meta.size, weight: WorkspaceText.meta.weight, monospacedDigit: true)
                        .foregroundStyle(palette.tertiaryText)
                }
            }
            .padding(.vertical, 10)
            WorkspaceListDivider()
            LazyVStack(alignment: .leading, spacing: 0, content: content).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkspaceExpandableText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    var label = "完整内容"
    var lines = 4
    var size: CGFloat = WorkspaceText.body.size
    @State private var expanded = false
    private var canCollapse: Bool { text.count > 160 || text.components(separatedBy: .newlines).count > lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).vosFont(size).lineSpacing(6).textSelection(.enabled)
                .lineLimit(canCollapse && !expanded ? lines : nil).fixedSize(horizontal: false, vertical: true)
            if canCollapse {
                Button(expanded ? "收起" + label : "展开" + label, systemImage: expanded ? "chevron.up" : "chevron.down") {
                    withAnimation(reduceMotion ? nil : WorkspaceMotion.expand) { expanded.toggle() }
                }
                    .vosFont(WorkspaceText.meta.size, weight: .medium).buttonStyle(.borderless)
                    .accessibilityValue(expanded ? "已展开" : "已收起")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
