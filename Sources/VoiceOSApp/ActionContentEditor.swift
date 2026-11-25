import SwiftUI
import VoiceOSCore

struct ActionContentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspacePalette) private var palette
    @State private var title: String
    @State private var note: String
    @State private var saving = false
    @State private var failure: String?
    let save: (String, String) async throws -> Void

    init(action: ActionRecord, save: @escaping (String, String) async throws -> Void) {
        _title = State(initialValue: action.title)
        _note = State(initialValue: action.note)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑行动").vosFont(WorkspaceText.sectionTitle)
            LabeledContent("标题") { TextField("标题", text: $title, axis: .vertical).labelsHidden() }
            LabeledContent("说明") { TextField("说明", text: $note, axis: .vertical).labelsHidden() }
            if let failure { Text(failure).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Button("保存") {
                    saving = true
                    Task {
                        do { try await save(title, note); dismiss() }
                        catch { failure = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(minWidth: 460).workspaceModalSurface().disabled(saving)
    }
}
