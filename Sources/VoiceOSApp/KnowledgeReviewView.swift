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
    @State private var showsSettled = false
    private var sources: [SourceRecord] { model.records.filter { sourceIDs.contains($0.id) && $0.origin == "user" && $0.speaker == "user" } }

    var body: some View {
        if !sources.isEmpty {
        WorkspaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                WorkspaceSectionHeading(title: "知识核查") {
                    if model.knowledgeReviewBusy { ProgressView().controlSize(.small) }
                }
                Text("对照原话检查事实、推断与适用条件。以下是有依据的 AI 核查建议，是否采纳由你决定；可标为已读、认可或驳回，已认可与已驳回的建议默认折叠。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                ForEach(sources) { source in
                    sourceReview(source)
                }
                if !model.knowledgeReviewStatus.isEmpty {
                    Text(model.knowledgeReviewStatus).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
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
            if sources.count > 1 { Text(source.displayTitle).vosFont(WorkspaceText.rowTitle).textSelection(.enabled) }
            if let record = review(source.id) {
                switch record.state {
                case "queued", "running":
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(record.state == "queued" ? "知识核查已排队" : "正在查证原话中的知识判断…").vosFont(WorkspaceText.meta)
                    }
                case "failed":
                    Label("本次核查未完成", systemImage: "exclamationmark.circle").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    if let error = record.error { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("重试知识核查") { Task { await model.reviewKnowledge(sourceID: source.id, retry: true) } }.buttonStyle(.workspaceSecondary)
                        .disabled(!canReview(source))
                case "frozen":
                    Label("历史核查 · 原话或授权已变化", systemImage: "pause.circle").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    Text("这份核查保留供追溯，当前不能据此判断这条认识。可以针对现有原文重新核查。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    let issues = record.issues.filter { matches($0, source: source) }
                    if !issues.isEmpty {
                        DisclosureGroup("查看历史核查建议") {
                            issueList(record, issues: issues)
                        }
                    }
                    Button("核查当前原文") { Task { await model.reviewKnowledge(sourceID: source.id) } }.buttonStyle(.workspaceSecondary).disabled(!canReview(source))
                case "completed":
                    let issues = record.issues.filter { matches($0, source: source) }
                    if record.issues.isEmpty {
                        Text("本次未提出需要纠偏的知识判断。").vosFont(WorkspaceText.body)
                        Text("这不代表全文全部正确；当前核查可能仍有遗漏。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    } else if issues.isEmpty {
                        Text("本条思考暂无可按连续原话定位的核查建议。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                        Text("来源中其他判断的核查可在资料详情查看，未关联到这里。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    } else {
                        issueList(record, issues: issues)
                    }
                default:
                    Text("核查状态：" + record.state).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
            } else {
                Text("检查这份资料中可能的事实错误、缺失条件或推断跳跃，并保留查证来源。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                Button("核查知识理解") { Task { await model.reviewKnowledge(sourceID: source.id) } }.buttonStyle(.workspacePrimary).disabled(!canReview(source))
            }
            if source.localOnly {
                Text("这份原文仅本地。先在资料详情允许云端处理，再发起核查。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            } else if !model.modelConfigured {
                Text("配置模型连接后可发起核查。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            } else if (model.currentClaimsBySource[source.id] ?? []).isEmpty {
                Text("先完成这份原话的理解，再核查其中的知识判断。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            }
        }
    }
    private func canReview(_ source: SourceRecord) -> Bool {
        !model.knowledgeReviewBusy && model.modelConfigured && !source.localOnly &&
        ["saved", "reference_only"].contains(source.state) && !(source.transcript ?? "").isEmpty &&
        !(model.currentClaimsBySource[source.id] ?? []).isEmpty
    }
    @ViewBuilder private func issueList(_ record: KnowledgeReviewRecord, issues: [KnowledgeReviewIssue]) -> some View {
        let counts = record.issueCounts(of: issues)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                WorkspaceBadge(text: "待核查 \(counts.pending)", tone: .warning)
                WorkspaceBadge(text: "已读 \(counts.seen)", tone: .neutral)
                WorkspaceBadge(text: "已认可 \(counts.accepted)", tone: .success)
                WorkspaceBadge(text: "已驳回 \(counts.rejected)", tone: .neutral)
            }
                .accessibilityLabel("待核查 \(counts.pending) 条，已读 \(counts.seen) 条，已认可 \(counts.accepted) 条，已驳回 \(counts.rejected) 条")
            ForEach(record.openIssues(from: issues)) { issue in issueCard(issue, record: record) }
            let settled = record.settledIssues(from: issues)
            if !settled.isEmpty {
                Button(showsSettled ? "仅看待核查" : "显示全部（含已处理 \(settled.count) 条）") { showsSettled.toggle() }
                    .vosFont(WorkspaceText.meta.size, weight: .medium).buttonStyle(.borderless)
                if showsSettled { ForEach(settled) { issue in issueCard(issue, record: record) } }
            }
        }
    }
    private func issueCard(_ issue: KnowledgeReviewIssue, record: KnowledgeReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(kindLabel(issue.kind.rawValue)).vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text("原话").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                Text(issue.quote).vosFont(WorkspaceText.body).textSelection(.enabled)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
            field("为什么值得核对", issue.explanation)
            field("更准确的理解建议", issue.betterUnderstanding)
            field("适用条件与边界", issue.boundary)
            field("反例", issue.counterexample)
            if !issue.references.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("核查来源").vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(.secondary)
                    ForEach(Array(issue.references.enumerated()), id: \.offset) { _, reference in
                        if let url = URL(string: reference.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                            Link(reference.title.isEmpty ? reference.url : reference.title, destination: url).vosFont(WorkspaceText.body).tint(palette.accent)
                            Text(reference.url).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            KnowledgeReviewIssueStatusControls(model: model, record: record, issue: issue)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border, lineWidth: 1) }
    }
    @ViewBuilder private func field(_ title: String, _ text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(.secondary)
                Text(text).vosFont(WorkspaceText.body).textSelection(.enabled)
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

/// Shared by the full issue card and the source summary, so both lists offer
/// the same reading record without duplicating the state rules.
struct KnowledgeReviewIssueStatusControls: View {
    @ObservedObject var model: ControlCenter
    let record: KnowledgeReviewRecord
    let issue: KnowledgeReviewIssue

    var body: some View {
        HStack(spacing: 8) {
            Text("状态：" + stateLabel(record.issueState(issue.id))).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ForEach(KnowledgeReviewIssueState.allCases, id: \.self) { state in
                Button(actionLabel(state)) {
                    Task { await model.setKnowledgeReviewIssueState(state, reviewID: record.id, issueID: issue.id) }
                }
                .buttonStyle(state == .rejected ? WorkspaceButtonStyle.workspaceQuietCompact : WorkspaceButtonStyle.workspaceSecondaryCompact)
                .disabled(record.issueState(issue.id) == state)
                .accessibilityLabel(actionLabel(state) + "：" + issue.quote)
            }
        }
    }
    private func stateLabel(_ state: KnowledgeReviewIssueState?) -> String {
        switch state {
        case .seen: return "已读"
        case .accepted: return "已认可"
        case .rejected: return "已驳回"
        case nil: return "待核查"
        }
    }
    private func actionLabel(_ state: KnowledgeReviewIssueState) -> String {
        switch state {
        case .seen: return "标为已读"
        case .accepted: return "认可"
        case .rejected: return "驳回"
        }
    }
}
