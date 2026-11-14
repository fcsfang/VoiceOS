import SwiftUI
import VoiceOSCore

extension ControlCenter {
    func reverifySource(_ record: SourceRecord) async -> Bool {
        guard let store else { status = "资料库尚未打开"; return false }
        do {
            let verified = try await store.reverifySource(id: record.id)
            await refresh()
            if verified { status = "已重新核对「\(record.displayTitle)」的原件" }
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
    private var sources: [SourceRecord] {
        model.records.filter { $0.state == "quarantined" || ($0.state == "saved" && ($0.error ?? "").contains("核对失败")) }
    }
    var body: some View {
        let rows = sources
        if !rows.isEmpty {
            WorkspaceSection(title:"需要重新核对的原件",subtitle:"核对通过后恢复原件状态；已有理解不自动解冻。",icon:"checkmark.shield",count:rows.count) {
                ForEach(rows) { source in
                    VStack(alignment:.leading,spacing:8) {
                        HStack(alignment:.firstTextBaseline,spacing:10) {
                            VStack(alignment:.leading,spacing:5) {
                                Text(source.displayTitle).vosFont(15, weight:.medium).lineLimit(2)
                                Text(workspaceStateLabel(source.state)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength:8)
                            Button(runningID == source.id ? "正在核对…" : "重新核对") { reverify(source) }
                                .disabled(runningID != nil)
                        }
                        if let failure = failures[source.id] {
                            Text(failure).font(.caption).foregroundStyle(palette.danger).textSelection(.enabled)
                        } else if let error = source.error {
                            Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.padding(.vertical,10)
                    if source.id != rows.last?.id { Divider() }
                }
            }
        }
    }
    private func reverify(_ source: SourceRecord) {
        guard runningID == nil else { return }
        runningID = source.id
        failures[source.id] = nil
        Task {
            let verified = await model.reverifySource(source)
            if !verified {
                failures[source.id] = model.records.first(where: { $0.id == source.id })?.error ?? (model.status.isEmpty ? "原件核对失败，可在处理情况页重试" : model.status)
            }
            runningID = nil
        }
    }
}
