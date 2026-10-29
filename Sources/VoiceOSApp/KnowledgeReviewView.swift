import SwiftUI
import VoiceOSCore

/// Source details show all issues. A knowledge card can supply exact, continuously
/// quoted matches so a nearby judgment from the same recording is never attached.
struct KnowledgeReviewSection: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let sourceIDs: [String]
    var quoteFilter: String? = nil
    var matchingQuotesBySource: [String: [String]]? = nil
    private var green: Color { palette.accent }
    private var sources: [SourceRecord] { model.records.filter { sourceIDs.contains($0.id) && $0.origin == "user" && $0.speaker == "user" } }

    var body: some View {
        if !sources.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("知识理解核查", systemImage: "text.magnifyingglass").font(.headline)
                Spacer()
                if model.knowledgeReviewBusy { ProgressView().controlSize(.small) }
            }
            Text("对照原话检查事实、推断与适用条件。以下是有依据的 AI 核查建议，是否采纳由你决定。").font(.caption).foregroundStyle(.secondary)
            ForEach(sources) { source in
                sourceReview(source)
            }
            if !model.knowledgeReviewStatus.isEmpty {
                Text(model.knowledgeReviewStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(14)
            .background(green.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(green.opacity(0.15)) }
        }
    }

    private func review(_ sourceID: String) -> KnowledgeReviewRecord? {
        let records = model.knowledgeReviews.filter { $0.sourceID == sourceID }.sorted { $0.createdAt > $1.createdAt }
        return records.first { $0.state != "frozen" } ?? records.first
    }
    private func matches(_ issue: KnowledgeReviewIssue, source: SourceRecord) -> Bool {
        guard source.transcript?.contains(issue.quote) == true else { return false }
        if let quoteFilter, !quoteFilter.contains(issue.quote) { return false }
        if let matchingQuotesBySource, !(matchingQuotesBySource[source.id] ?? []).contains(issue.quote) { return false }
        return true
    }
    @ViewBuilder private func sourceReview(_ source: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if sources.count > 1 { Text(source.displayTitle).font(.callout.bold()).textSelection(.enabled) }
            if let record = review(source.id) {
                switch record.state {
                case "queued", "running":
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(record.state == "queued" ? "知识核查已排队" : "正在查证原话中的知识判断…").font(.callout)
                    }
                case "failed":
                    Label("本次核查未完成", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    if let error = record.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("重试知识核查") { Task { await model.reviewKnowledge(sourceID: source.id, retry: true) } }
                        .disabled(!canReview(source))
                case "frozen":
                    Label("历史核查 · 原话或授权已变化", systemImage: "pause.circle").font(.callout).foregroundStyle(.orange)
                    Text("这份核查保留供追溯，当前不能据此判断这条认识。可以针对现有原文重新核查。").font(.caption).foregroundStyle(.secondary)
                    let issues = record.issues.filter { matches($0, source: source) }
                    if !issues.isEmpty {
                        DisclosureGroup("查看历史核查建议") {
                            ForEach(issues) { issue in issueCard(issue) }
                        }
                    }
                    Button("核查当前原文") { Task { await model.reviewKnowledge(sourceID: source.id) } }.disabled(!canReview(source))
                case "completed":
                    let issues = record.issues.filter { matches($0, source: source) }
                    if record.issues.isEmpty {
                        Text("本次未提出需要纠偏的知识判断。").font(.callout)
                        Text("这不代表全文全部正确；当前核查可能仍有遗漏。").font(.caption).foregroundStyle(.secondary)
                    } else if issues.isEmpty {
                        Text("本条思考暂无可按连续原话定位的核查建议。").font(.callout).foregroundStyle(.secondary)
                        Text("来源中其他判断的核查可在资料详情查看，未关联到这里。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(issues) { issue in issueCard(issue) }
                    }
                default:
                    Text("核查状态：" + record.state).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("检查这份资料中可能的事实错误、缺失条件或推断跳跃，并保留查证来源。").font(.callout).foregroundStyle(.secondary)
                Button("核查知识理解") { Task { await model.reviewKnowledge(sourceID: source.id) } }.disabled(!canReview(source))
            }
            if source.localOnly {
                Text("这份原文仅本地。先在资料详情允许云端处理，再发起核查。").font(.caption).foregroundStyle(.secondary)
            } else if !model.modelConfigured {
                Text("配置模型连接后可发起核查。").font(.caption).foregroundStyle(.secondary)
            } else if (model.currentClaimsBySource[source.id] ?? []).isEmpty {
                Text("先完成这份原话的理解，再核查其中的知识判断。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func canReview(_ source: SourceRecord) -> Bool {
        !model.knowledgeReviewBusy && model.modelConfigured && !source.localOnly &&
        ["saved", "reference_only"].contains(source.state) && !(source.transcript ?? "").isEmpty &&
        !(model.currentClaimsBySource[source.id] ?? []).isEmpty
    }
    private func issueCard(_ issue: KnowledgeReviewIssue) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(kindLabel(issue.kind.rawValue)).font(.caption.bold()).foregroundStyle(green)
            VStack(alignment: .leading, spacing: 5) {
                Text("原话").font(.caption).foregroundStyle(.secondary)
                Text(issue.quote).font(.callout).textSelection(.enabled)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(green.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            field("为什么值得核对", issue.explanation)
            field("更准确的理解建议", issue.betterUnderstanding)
            field("适用条件与边界", issue.boundary)
            field("反例", issue.counterexample)
            if !issue.references.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("核查来源").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(issue.references.enumerated()), id: \.offset) { _, reference in
                        if let url = URL(string: reference.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                            Link(reference.title.isEmpty ? reference.url : reference.title, destination: url).font(.callout).tint(green)
                            Text(reference.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            Text("AI 核查建议 · 尚不代表你接受了修正").font(.caption).foregroundStyle(.secondary)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
    }
    @ViewBuilder private func field(_ title: String, _ text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                Text(text).font(.callout).textSelection(.enabled)
            }
        }
    }
    private func kindLabel(_ value: String) -> String {
        switch value {
        case "factualError": return "事实可能有误"
        case "missingCondition": return "缺少成立条件"
        case "unsupportedInference": return "推断依据不足"
        case "disputed": return "存在争议"
        case "transcriptionUncertain": return "转写含义待核对"
        default: return value
        }
    }
}
