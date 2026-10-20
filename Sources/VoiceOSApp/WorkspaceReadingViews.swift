import SwiftUI

// Navigation, section headings, content and provenance each have a distinct weight.
struct WorkspaceTabs: View {
    @Environment(\.workspacePalette) private var palette
    @Binding var selection: String
    let titles: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 8)], spacing: 8) {
                ForEach(titles, id: \.self) { tab($0, fill: true) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(titles, id: \.self) { tab($0) }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func tab(_ title: String, fill: Bool = false) -> some View {
        Button { selection = title } label: {
            Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                .foregroundStyle(selection == title ? palette.canvas : palette.text)
                .frame(maxWidth: fill ? .infinity : nil)
                .padding(.horizontal, 20).padding(.vertical, 13)
                .background(selection == title ? palette.accent : palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selection == title ? .clear : palette.border, lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selection == title ? [.isSelected] : [])
            .accessibilityIdentifier("workspace.tab." + title)
    }
}

struct WorkspaceSection<Content: View>: View {
    @Environment(\.workspacePalette) private var palette
    let title: String
    var subtitle: String = ""
    var icon: String = ""
    var count: Int? = nil
    var actionTitle: String = ""
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 19, weight: .medium)).frame(width: 26, height: 28)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Text(title).font(.system(size: 21, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        if let count {
                            Text(String(count)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(palette.selection, in: Capsule()).foregroundStyle(.secondary)
                        }
                    }
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3) }
                }
                Spacer(minLength: 0)
                if let action { Button(actionTitle, action: action).font(.system(size: 13, weight: .medium)).buttonStyle(.borderless).padding(.top, 4) }
            }.padding(.bottom, 18)
            Rectangle().fill(palette.border).frame(height: 1)
            LazyVStack(alignment: .leading, spacing: 0, content: content).padding(.top, 8)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(palette.border.opacity(0.8), lineWidth: 1) }
    }
}

struct WorkspaceExpandableText: View {
    let text: String
    var label = "完整内容"
    var lines = 4
    var size: CGFloat = 17
    @State private var expanded = false
    private var canCollapse: Bool { text.count > 160 || text.components(separatedBy: .newlines).count > lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.system(size: size)).lineSpacing(6).textSelection(.enabled)
                .lineLimit(canCollapse && !expanded ? lines : nil).fixedSize(horizontal: false, vertical: true)
            if canCollapse {
                Button(expanded ? "收起" + label : "展开" + label, systemImage: expanded ? "chevron.up" : "chevron.down") { expanded.toggle() }
                    .font(.system(size: 13, weight: .medium)).buttonStyle(.borderless)
                    .accessibilityValue(expanded ? "已展开" : "已收起")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
