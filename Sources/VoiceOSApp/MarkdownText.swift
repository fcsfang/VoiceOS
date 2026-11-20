import SwiftUI
import VoiceOSCore

/// Renders a material's original text by Markdown tier. Structure comes from
/// `MarkdownDocument`; inline emphasis is parsed here.
struct MarkdownText: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var scale
    @StateObject private var store = MarkdownStore()
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    private var bodySize: CGFloat { WorkspaceText.body.size * scale }
    /// Paragraph gap is 0.75 of the 1.5x body line height.
    private var paragraphGap: CGFloat { bodySize * 1.125 }

    var body: some View {
        let elements = store.elements(for: raw)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(elements.indices, id: \.self) { index in
                view(elements[index], first: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(_ element: MarkdownElement, first: Bool) -> some View {
        switch element {
        case .heading(let level, let text):
            let style = headingStyle(level)
            Text(text)
                .vosFont(style)
                .foregroundStyle(palette.text)
                .lineSpacing(style.size * scale * 0.3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, first ? 0 : 16)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text)
                .vosFont(WorkspaceText.body)
                .foregroundStyle(palette.text)
                .lineSpacing(bodySize * 0.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, paragraphGap)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .vosFont(WorkspaceText.body)
                            .foregroundStyle(palette.secondaryText)
                            .frame(minWidth: ordered ? 22 * vosLayoutScale(scale) : 10, alignment: .trailing)
                        Text(items[index].text)
                            .vosFont(WorkspaceText.body)
                            .foregroundStyle(palette.text)
                            .lineSpacing(bodySize * 0.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(items[index].depth) * 18)
                }
            }
            .padding(.bottom, paragraphGap)
        case .quote(let text):
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(palette.border).frame(width: 2)
                Text(text)
                    .vosFont(WorkspaceText.body)
                    .foregroundStyle(palette.secondaryText)
                    .lineSpacing(bodySize * 0.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
            .padding(.bottom, paragraphGap)
        case .rule:
            Rectangle().fill(palette.border).frame(height: 1)
                .padding(.vertical, 8)
        }
    }

    private func headingStyle(_ level: Int) -> WorkspaceTextStyle {
        level <= 2 ? WorkspaceText.sectionTitle : WorkspaceText.rowTitle
    }
}

private enum MarkdownElement {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, items: [MarkdownElementItem])
    case quote(AttributedString)
    case rule
}

private struct MarkdownElementItem {
    let depth: Int
    let text: AttributedString
}

private final class MarkdownStore: ObservableObject {
    private var raw: String?
    private var built: [MarkdownElement] = []

    func elements(for raw: String) -> [MarkdownElement] {
        if self.raw == raw { return built }
        built = MarkdownDocument.blocks(from: raw).map { block -> MarkdownElement in
            switch block {
            case .heading(let level, let text): return .heading(level: level, text: inline(text))
            case .paragraph(let text): return .paragraph(inline(text))
            case .list(let ordered, let items):
                return .list(ordered: ordered, items: items.map { MarkdownElementItem(depth: $0.depth, text: inline($0.text)) })
            case .quote(let text): return .quote(inline(text))
            case .rule: return .rule
            }
        }
        self.raw = raw
        return built
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
