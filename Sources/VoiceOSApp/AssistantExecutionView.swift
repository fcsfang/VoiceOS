import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VoiceOSCore

func assistantExecutionLabel(_ execution: AssistantExecutionRecord) -> String {
    if execution.validity != "current" { return "依据已变化 · 暂停使用" }
    let analysis = execution.mode == .analysis
    switch execution.state {
    case "queued": return analysis ? "等待分析" : "已排队"
    case "running": return analysis ? "正在分析" : "正在执行"
    case "completed": return analysis ? "分析已就绪" : "成果已就绪"
    case "failed": return analysis ? "分析未完成" : "需要重试"
    case "cancelled": return "已取消"
    default: return execution.state
    }
}

struct AssistantReportView: View {
    @Environment(\.workspacePalette) private var palette
    let report: String
    private struct Block {
        let text: String
        let heading: Int
        let literal: Bool
    }
    private var blocks: [Block] {
        var result: [Block] = [], paragraph: [String] = []
        var fenced = false
        func flush() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            let table = paragraph.filter { $0.contains("|") }.count >= 2
            result.append(Block(text: text, heading: 0, literal: fenced || table))
            paragraph = []
        }
        for line in report.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                fenced.toggle()
                continue
            }
            if fenced { paragraph.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if (1...3).contains(level), trimmed.dropFirst(level).first == " " {
                flush()
                result.append(Block(text: String(trimmed.dropFirst(level + 1)), heading: level, literal: false))
            } else { paragraph.append(line) }
        }
        flush()
        return result
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.literal {
                    ScrollView(.horizontal) {
                        Text(verbatim: block.text).vosFont(WorkspaceText.body.size, design: .monospaced).lineSpacing(5).textSelection(.enabled)
                            .padding(16)
                    }.background(palette.canvas, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border,lineWidth:1) }
                } else {
                    Text(inline(block.text))
                        .vosFont(block.heading == 1 ? WorkspaceText.pageTitle : block.heading > 0 ? WorkspaceText.sectionTitle : WorkspaceText.body)
                        .lineSpacing(block.heading > 0 ? 3 : 6)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, block.heading > 0 ? 18 : 0)
                        .accessibilityAddTraits(block.heading > 0 ? [.isHeader] : [])
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}