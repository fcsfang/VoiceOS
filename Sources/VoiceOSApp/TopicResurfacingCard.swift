import SwiftUI
import VoiceOSCore

/// Quiet, optional resurfacing. The quoted thought belongs to the user;
/// the reason describes available records, never a judgment of progress.
struct TopicResurfacingCard: View {
    @Environment(\.workspacePalette) private var palette
    let item: ReflectionTopicResurfacing
    let busy: Bool
    let open: () -> Void
    let feedback: (CognitiveFeedbackMode, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("可以再看一眼", systemImage: "leaf").font(.caption).foregroundStyle(palette.accent)
            Text(item.title).font(.system(size: 15, weight: .medium, design: .serif)).lineLimit(3)
            Text(item.quote).font(.callout).lineLimit(4).textSelection(.enabled)
            Text(item.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("接着探索", action: open).buttonStyle(.borderedProminent).tint(palette.accent)
                Spacer(minLength: 0)
                Menu("稍后") {
                    Button("稍后 7 天") { feedback(.normal, true) }
                    Button("减少此主题提示") { feedback(.reduced, false) }
                    Button("暂停此主题提示") { feedback(.paused, false) }
                }
            }.font(.caption)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            .disabled(busy)
    }
}
