import SwiftUI
import VoiceOSCore

struct MaterialNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var lead: String
    @State private var blocks: [NoteBlock]
    @State private var failure: String?
    @State private var saving = false
    let save: (MaterialNote) async throws -> Void

    init(base: StoredMaterialNote, save: @escaping (MaterialNote) async throws -> Void) {
        _title = State(initialValue: base.note.title)
        _lead = State(initialValue: base.note.lead ?? "")
        _blocks = State(initialValue: NoteBoardAdapting.blocks(for: base.note))
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑笔记").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("标题", text: $title)
                    TextField("导语", text: $lead, axis: .vertical)
                    ForEach($blocks) { $block in
                        if let heading = Binding($block.heading) {
                            TextField("小标题", text: heading)
                        }
                        if let paragraphs = Binding($block.paragraphs) {
                            ForEach(paragraphs.wrappedValue.indices, id: \.self) { index in
                                TextField("正文段落", text: paragraphs[index].text, axis: .vertical)
                            }
                        }
                        if let text = Binding($block.text) {
                            TextField("正文", text: text, axis: .vertical)
                        }
                    }
                    Button("添加段落", systemImage: "plus") {
                        blocks.append(NoteBlock(id: UUID().uuidString, kind: "text", paragraphs: [.init(text: "")]))
                    }
                }.textFieldStyle(.roundedBorder)
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    saving = true
                    Task {
                        do {
                            let cleaned = blocks.map { item in
                                var block = item
                                block.paragraphs?.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                return block
                            }
                            try await save(MaterialNote(title: title, lead: lead.isEmpty ? nil : lead, sections: [], blocks: cleaned))
                            dismiss()
                        } catch { failure = error.localizedDescription }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(minWidth: 480, minHeight: 420).disabled(saving)
    }
}
