import SwiftUI
import VoiceOSCore

struct DiscussionHistoryView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let close: () -> Void
    @State private var previews: [ConversationPreview] = []
    @State private var loading = true
    @State private var loadError = ""
    @State private var error = ""
    @State private var showSlowLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("历史讨论", systemImage: "clock.arrow.circlepath").vosFont(WorkspaceText.rowTitle)
                    Text("按最近更新排列；打开后沿用当时的依据与许可。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
                Spacer()
                WorkspaceIconButton(systemImage: "xmark", label: "关闭历史讨论") { close() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            WorkspaceListDivider()
            Group {
                if loading {
                    if showSlowLoad { ProgressView("正在读取讨论历史…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                } else if !loadError.isEmpty {
                    WorkspaceEmptyState(title: InlineFailurePresentation.message(operation: "读取讨论历史", reason: loadError),
                                        systemImage: "exclamationmark.triangle",
                                        description: "请检查资料库后重试。") {
                        Button("重试") { Task { await load() } }.buttonStyle(.workspaceSecondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if previews.isEmpty {
                    WorkspaceEmptyState(title: "还没有讨论历史", systemImage: "bubble.left.and.bubble.right",
                                        description: "在资料页选中一条材料，点「讨论」建立新的讨论；建立后会按最近更新显示在这里。") {
                        Button("关闭", action: close).buttonStyle(.workspaceSecondary)
                    }
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
                WorkspaceListDivider()
                WorkspaceNoticeText(message: error, severity: .danger).padding(12)
            }
        }
        .frame(width: 560, height: 520)
        .background(palette.sidebar)
        .workspaceSlowLoading(loading, into: $showSlowLoad)
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
                error = InlineFailurePresentation.message(operation: "打开讨论", reason: model.discussionStatus)
            }
        }
    }

    private func load() async {
        loading = true
        loadError = ""
        defer { loading = false }
        guard let store = model.store else {
            loadError = "资料库尚未打开"
            return
        }
        do {
            previews = try await store.conversationPreviews()
        } catch {
            self.loadError = error.localizedDescription
        }
    }
}
