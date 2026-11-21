import SwiftUI
import VoiceOSCore

struct OutcomeFollowupView: View {
    @Environment(\.workspacePalette) private var palette
    let actions: [ActionRecord]
    let onRecord: (ActionRecord) -> Void
    let onOpen: (ActionRecord) -> Void
    let onSkip: (ActionRecord) -> Void
    let onOpenActions: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("完成后的结果与收获").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                }
                Spacer()
                Text("\(actions.count) 项").vosFont(WorkspaceText.caption.size, monospacedDigit: true).foregroundStyle(palette.secondaryText)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if actions.isEmpty {
                        WorkspaceEmptyState(title: "还没有待记录的结果", systemImage: "checkmark.circle",
                                            description: "在行动页完成事项后，会在这里请你记录结果或跳过；记录或跳过的事项会从这里收起。") {
                            Button("去行动页") {
                                onOpenActions()
                                onDone()
                            }.buttonStyle(.workspaceSecondary)
                        }
                    }
                    ForEach(actions) { action in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
                                Text(action.title).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Button("记录结果") { onRecord(action) }.buttonStyle(.workspacePrimary)
                                Button("这次跳过") { onSkip(action) }.buttonStyle(.borderless)
                            }
                            DisclosureGroup("查看事项与依据") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if !action.note.isEmpty { Text(action.note).textSelection(.enabled) }
                                    Button("查看待办与原话") { onOpen(action) }.buttonStyle(.link)
                                }.padding(.top, 6)
                            }.vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                    }
                }.padding(.vertical, 4)
            }
            HStack {
                Text("完成状态会保留；这里不会替你生成结果。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                Spacer()
                Button("完成", action: onDone).keyboardShortcut(.cancelAction).buttonStyle(.workspaceSecondary)
            }
        }.padding(24).frame(minWidth: 680, idealWidth: 820, minHeight: 540, maxHeight: .infinity)
            .workspaceResizableSheet()
            .workspaceModalSurface()
    }
}
