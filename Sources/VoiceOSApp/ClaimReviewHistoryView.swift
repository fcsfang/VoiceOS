import SwiftUI
import VoiceOSCore

struct ClaimReviewHistoryView: View {
    let revisions: [ClaimReviewVersion]
    let dismiss: () -> Void

    private func reason(_ value: String) -> String {
        switch value {
        case "explicit_endorsement": return "明确认可"
        case "explicit_rejection": return "停止使用"
        case "correction": return "认知更正"
        case "discussion_ai_original": return "讨论 AI 段落原文"
        default: return "模型原始结果"
        }
    }
    private func owner(_ value: String) -> String {
        switch value {
        case "user_tentative": return "我的暂定表达"
        case "external": return "外部主张"
        case "ai_candidate": return "AI 建议"
        default: return "归属待核对"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("认知审阅历史").font(.title2)
            Text("认可不等于已验证；更正不代表真实观点变化。").foregroundStyle(.secondary)
            ScrollView {
                ForEach(revisions) { revision in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("第 \(revision.version) 版 · " + reason(revision.reason)).font(.headline)
                        Text(revision.statement).textSelection(.enabled)
                        Text(owner(revision.ownership) + " · " + (revision.decision == "endorsed" ? "已认可" : revision.decision == "rejected" ? "已停止使用" : "待核对")).font(.caption).foregroundStyle(.secondary)
                        if !revision.note.isEmpty { Text("原因：" + revision.note).font(.callout) }
                        Divider()
                    }
                }
            }
            HStack { Spacer(); Button("完成", action: dismiss).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 660, height: 440)
    }
}
