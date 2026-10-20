import SwiftUI
import VoiceOSCore

struct OutcomeFollowupView: View {
    let actions: [ActionRecord]
    let onRecord: (ActionRecord) -> Void
    let onOpen: (ActionRecord) -> Void
    let onSkip: (ActionRecord) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("完成后的结果与收获").font(.title2)
                    Text("愿意时留下一句实际结果或反思，也可以跳过。").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(actions.count) 项").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if actions.isEmpty {
                        ContentUnavailableView("暂无待记录的结果", systemImage: "checkmark.circle",
                                               description: Text("记录过结果或选择跳过的事项会从这里收起。"))
                    }
                    ForEach(actions) { action in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(action.title).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Button("记录结果") { onRecord(action) }.buttonStyle(.borderedProminent)
                                Button("这次跳过") { onSkip(action) }.buttonStyle(.borderless)
                            }
                            DisclosureGroup("查看事项与依据") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if !action.note.isEmpty { Text(action.note).textSelection(.enabled) }
                                    Button("查看待办与原话") { onOpen(action) }.buttonStyle(.link)
                                }.padding(.top, 6)
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.vertical, 4)
            }
            HStack {
                Text("完成状态会保留；这里不会替你生成结果。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成", action: onDone).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 820, height: 540)
    }
}
