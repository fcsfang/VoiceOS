import SwiftUI
import VoiceOSCore

extension ControlCenter {
    func reverifySource(_ record: SourceRecord) async -> Bool {
        guard let store else { status = "资料库尚未打开"; return false }
        do {
            let verified = try await store.reverifySource(id: record.id)
            await refresh()
            if verified { status = "原件已恢复。已有理解仍暂停，在材料页重新识别观点和任务后更新" }
            return verified
        } catch {
            status = error.localizedDescription
            await refresh()
            return false
        }
    }
}

struct ReverifyControls: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @State private var runningID: String?
    @State private var failures: [String: String] = [:]
    @State private var restored: Set<String> = []
    private var pending: [SourceRecord] {
        model.records.filter { ($0.state == "quarantined" || ($0.state == "saved" && ($0.error ?? "").contains("核对失败"))) && !restored.contains($0.id) }
    }
    private var restoredSources: [SourceRecord] { model.records.filter { restored.contains($0.id) } }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if !pending.isEmpty {
                WorkspaceSection(title:"需要重新核对的原件",subtitle:"核对通过后恢复原件状态；已有理解不自动解冻，在材料页重新识别观点和任务后更新。",icon:"checkmark.shield",count:pending.count) {
                    ForEach(pending) { source in
                        VStack(alignment:.leading,spacing:8) {
                            HStack(alignment:.firstTextBaseline,spacing:10) {
                                VStack(alignment:.leading,spacing:5) {
                                    Text(source.displayTitle).vosFont(WorkspaceText.rowTitle).lineLimit(2)
                                    Text(workspaceStateLabel(source.state)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                }
                                Spacer(minLength:8)
                                Button(runningID == source.id ? "正在核对…" : "重新核对") { reverify(source) }
                                    .disabled(runningID != nil)
                            }
                            if let failure = failures[source.id] {
                                Text(failure).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger).textSelection(.enabled)
                            } else if let error = source.error {
                                Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                            }
                        }.padding(.vertical,10)
                        if source.id != pending.last?.id { WorkspaceListDivider() }
                    }
                }
            }
            if !restoredSources.isEmpty {
                DisclosureGroup("本次已恢复（\(restoredSources.count)）") {
                    VStack(alignment:.leading,spacing:0) {
                        ForEach(restoredSources) { source in
                            HStack(alignment:.firstTextBaseline,spacing:10) {
                                VStack(alignment:.leading,spacing:4) {
                                    Text(source.displayTitle).vosFont(WorkspaceText.rowTitle).lineLimit(2)
                                    Text("原件已恢复；已有理解仍暂停，在材料页重新识别观点和任务后更新。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                }
                                Spacer(minLength:8)
                                Button("打开材料") { model.requestWorkspaceSource(source.id) }
                            }.padding(.vertical,8)
                            if source.id != restoredSources.last?.id { WorkspaceListDivider() }
                        }
                    }.padding(.top,8)
                }.vosFont(WorkspaceText.body)
            }
        }
    }
    private func reverify(_ source: SourceRecord) {
        guard runningID == nil else { return }
        runningID = source.id
        failures[source.id] = nil
        Task {
            let verified = await model.reverifySource(source)
            if verified { restored.insert(source.id) }
            else {
                failures[source.id] = model.records.first(where: { $0.id == source.id })?.error ?? (model.status.isEmpty ? "原件核对失败，可在处理情况页重试" : model.status)
            }
            runningID = nil
        }
    }
}
