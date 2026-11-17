import SwiftUI
import VoiceOSCore

struct DiscussionHistoryView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let close: () -> Void
    @State private var previews: [ConversationPreview] = []
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("历史讨论", systemImage: "clock.arrow.circlepath").vosFont(WorkspaceText.rowTitle)
                    Text("按最近更新排列；打开后沿用当时的依据与许可。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
                Spacer()
                WorkspaceIconButton(systemImage: "xmark", label: "关闭历史讨论") { close() }
            }.padding(18)
            Divider()
            Group {
                if loading {
                    ProgressView("正在读取讨论历史…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if previews.isEmpty {
                    WorkspaceEmptyState(title: "还没有讨论历史", systemImage: "bubble.left.and.bubble.right",
                                        description: "从材料详情点击“继续讨论”会建立新的讨论；建立后按最近更新显示在这里。")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(previews) { preview in
                                WorkspaceRow(title: preview.firstTurnExcerpt, subtitle: subtitle(preview),
                                             icon: "bubble.left.and.bubble.right",
                                             trailing: continues(preview) ? "继续" : "查看") { open(preview) }
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
            }
            if !error.isEmpty {
                Divider()
                Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger)
                    .textSelection(.enabled).padding(12)
            }
        }
        .frame(width: 560, height: 520)
        .background(palette.sidebar)
        .task { await load() }
    }

    private func continues(_ preview: ConversationPreview) -> Bool {
        preview.state == "active" && preview.validity == "current"
    }

    private func subtitle(_ preview: ConversationPreview) -> String {
        let date = ConversationReflectionFocus.date(preview.updatedAt)?.formatted(date: .abbreviated, time: .shortened) ?? preview.updatedAt
        let status: String
        if preview.validity == "frozen" {
            status = preview.state == "ended" ? "已结束 · 只读" : "依据已冻结 · 只读"
        } else {
            status = preview.state == "ended" ? "已结束" : "进行中"
        }
        return "\(date) · \(status) · \(preview.turnCount) 轮"
    }

    private func open(_ preview: ConversationPreview) {
        Task {
            if await model.openDiscussion(preview.id) {
                close()
            } else {
                error = model.discussionStatus
            }
        }
    }

    private func load() async {
        guard let store = model.store else {
            loading = false
            error = "资料库尚未打开"
            return
        }
        do {
            previews = try await store.conversationPreviews()
            loading = false
        } catch {
            loading = false
            self.error = error.localizedDescription
        }
    }
}
