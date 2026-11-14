import SwiftUI
import VoiceOSCore

extension ControlCenter {
    func claimNoteMap() async throws -> [String:ClaimNote] {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        return try await store.claimNotes()
    }
    @discardableResult
    func saveClaimNote(claimID:String,body:String) async throws -> ClaimNote {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        return try await store.saveClaimNote(claimID:claimID,body:body)
    }
    func deleteClaimNote(claimID:String) async throws {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        try await store.deleteClaimNote(claimID:claimID)
    }
    func sourceCaptureMetadata(sourceID:String) async throws -> CaptureMetadata? {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        return try await store.captureMetadata()[sourceID]
    }
}

struct ClaimNoteRow:View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model:ControlCenter
    let claimID:String
    @Binding var notes:[String:ClaimNote]
    @State private var editing=false
    @State private var draft=""
    @State private var saving=false
    @State private var errorText=""
    private var note:ClaimNote? { notes[claimID] }
    private var trimmed:String { draft.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var tooLong:Bool { trimmed.count > 1000 }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if editing {
                TextEditor(text:$draft).frame(minHeight:64).workspaceEditorSurface()
                HStack {
                    Text("\(trimmed.count) / 1000").font(.caption).foregroundStyle(tooLong ? palette.warning : Color.secondary)
                    Spacer()
                    if note != nil { Button("删除旁注", role:.destructive) { Task { await remove() } }.disabled(saving) }
                    Button("取消") { editing=false;errorText="" }.disabled(saving)
                    Button("保存") { Task { await save() } }.disabled(saving || trimmed.isEmpty || tooLong)
                }.font(.caption)
                if !errorText.isEmpty { Text(errorText).font(.caption).foregroundStyle(palette.danger) }
            } else if let note {
                HStack(alignment:.top,spacing:10) {
                    Text("旁注").vosFont(12, weight:.medium).foregroundStyle(.secondary)
                    Text(note.body).vosFont(13).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
                    Spacer(minLength:8)
                    Button("编辑",systemImage:"pencil") { draft=note.body;editing=true;errorText="" }.font(.caption)
                }
                .padding(10)
                .frame(maxWidth:.infinity,alignment:.leading)
                .background(palette.selection.opacity(0.35),in:RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
            } else {
                Button("添加旁注",systemImage:"square.and.pencil") { draft="";editing=true;errorText="" }.font(.caption)
            }
        }
    }
    private func save() async {
        saving=true
        defer { saving=false }
        do {
            let saved=try await model.saveClaimNote(claimID:claimID,body:trimmed)
            notes[claimID]=saved
            editing=false
            errorText=""
        } catch { errorText=error.localizedDescription }
    }
    private func remove() async {
        saving=true
        defer { saving=false }
        do {
            try await model.deleteClaimNote(claimID:claimID)
            notes[claimID]=nil
            draft=""
            editing=false
            errorText=""
        } catch { errorText=error.localizedDescription }
    }
}
