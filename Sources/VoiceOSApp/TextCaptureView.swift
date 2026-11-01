import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceOSCore

struct TextCaptureView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @Binding var draft: TextCaptureDraft
    let onSaved: (String) -> Void
    let dismiss: () -> Void
    @State private var importing = false
    @State private var importWorker: Task<Void, Never>?
    @State private var pendingImport: (text: String, title: String, fileName: String)?
    @State private var confirmingReplacement = false
    @State private var dropTargeted = false
    @FocusState private var focus: CaptureField?
    private enum CaptureField: Hashable { case title, text }
    private var validationIssue: String? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "填写标题和完整原文后即可保存。" }
        if title.count > 100 || title.contains(where: \.isNewline) { return "标题需为一行、不超过 100 字；完整原文无需缩短。" }
        if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "填写完整原文后即可保存。" }
        return nil
    }
    private var valid: Bool { validationIssue == nil }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .padding(WorkspaceMetrics.pagePadding)
                    .frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !model.initialized { ProgressView("正在恢复资料库与草稿…").controlSize(.small) }
                if !draft.error.isEmpty { WorkspaceNoticeText(message: draft.error, severity: .danger) }
                if !model.textCaptureDraftIssue.isEmpty { WorkspaceNoticeText(message: model.textCaptureDraftIssue) }
                Text("草稿自动保存在本机，切页或重开应用可继续；保存成功后清空。").font(.caption).foregroundStyle(.secondary)
                if let validationIssue { Text(validationIssue).font(.caption).foregroundStyle(.secondary) }
                if importing { ProgressView("正在读取完整文件…").controlSize(.small) }
                if model.modelConfigured && !model.canUnderstandCapturedText {
                    Text("其他内容正在整理，可先仅本地保存。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("稍后继续", action: dismiss).disabled(draft.saving)
                    Spacer()
                    if draft.saving { ProgressView().controlSize(.small) }
                    Button("仅本地保存") { save(process: false) }.disabled(draft.saving || !valid)
                    Button("保存并理解全文") { save(process: true) }.buttonStyle(.borderedProminent).tint(palette.accent)
                        .disabled(draft.saving || !valid || !draft.allowCloud || !model.canUnderstandCapturedText)
                }
            }.padding(20).background(palette.canvas)
        }.foregroundStyle(palette.text).background(palette.canvas).interactiveDismissDisabled(draft.saving).disabled(!model.initialized || importing)
            .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).stroke(dropTargeted ? palette.accent : .clear, lineWidth: 2).allowsHitTesting(false) }
            .dropDestination(for: URL.self) { urls, _ in
                guard model.initialized, !draft.saving, !importing, !confirmingReplacement else { return false }
                guard urls.count == 1, let url = urls.first else {
                    draft.error = "请一次拖入一份 .txt 或 .md 文件；当前草稿已保留。"
                    return false
                }
                readFile(url)
                return true
            } isTargeted: { dropTargeted = $0 }
            .task {
                // A focus write before the field attaches to its window is dropped.
                guard model.initialized, !model.dictationActive, !model.dictationBusy, !draft.saving, !importing,
                      focus == nil, !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled, focus == nil, !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                focus = .text
            }
            .onDisappear { importWorker?.cancel(); importing = false; model.flushTextCaptureDraft(); focus = nil }
            .alert("替换当前文字草稿？", isPresented: $confirmingReplacement) {
                Button("保留当前草稿", role: .cancel) { pendingImport = nil }
                Button("用文件替换", role: .destructive) { applyImport() }
            } message: {
                Text("导入将替换当前标题和完整原文。若要保留两份内容，请先取消并仅本地保存当前草稿，再导入文件。")
            }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 12) {
                WorkspaceHero(eyebrow: "CAPTURE YOUR CONTEXT", title: "把文字，带进思考",
                              subtitle: "可粘贴原文，或拖入一份 txt / md 文件；分别保留自己的表达与外部资料的真实归属。")
                Button("导入文字文件") { chooseFile() }.disabled(draft.saving)
            }
            Text("⌘⇧R 开始或停止口述").font(.caption).foregroundStyle(.secondary)
            Picker("原文归属", selection: $draft.ownership) {
                Text("我的表达").tag(TextCaptureOwnership.personal)
                Text("外部资料").tag(TextCaptureOwnership.external)
            }.pickerStyle(.segmented).disabled(draft.saving)
            Text(draft.ownership == .personal ? "仅选择你亲自表达的判断、想法或行动。摘录、文章和其他人的笔记请选外部资料。" : "文章、摘录和他人笔记作为外部资料；作者的观点与行动不会归为你的个人认识或待办。")
                .font(.callout).foregroundStyle(.secondary)
            TextField(draft.ownership == .personal ? "表达标题" : "资料标题 · 可填写作者与出处", text: $draft.title).textFieldStyle(.roundedBorder).focused($focus, equals: .title).disabled(draft.saving)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("完整原文").font(.headline)
                    Spacer()
                    if let fileName = draft.fileName { Text(fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text("\(draft.text.unicodeScalars.count) 字").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                TextEditor(text: $draft.text).font(.body).scrollContentBackground(.hidden).frame(minHeight:240)
                    .workspaceEditorSurface().focused($focus, equals: .text).disabled(draft.saving)
                    .accessibilityLabel("完整原文")
            }.frame(maxHeight: .infinity)
            Toggle("允许这份完整原文用于云端理解", isOn: $draft.allowCloud).disabled(draft.saving)
            Text(draft.allowCloud ? "点击“保存并理解全文”才会发送全文并整理观点与意图；点击“仅本地保存”不会发送，归属仍以以上选择为准。" : "这次只在本机保存。以后可在资料详情中允许云端理解。")
                .font(.caption).foregroundStyle(.secondary)
            if draft.allowCloud && !model.modelConfigured { Text("尚未配置模型连接，仍可先保存完整原文。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "导入完整文字原文"
        panel.prompt = "读取全文"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            readFile(url)
        }
    }
    private func readFile(_ url: URL) {
        guard url.isFileURL, ["txt", "md"].contains(url.pathExtension.lowercased()) else {
            draft.error = "请选择 .txt 或 .md 本地文字文件；当前草稿已保留。"
            return
        }
        importing = true
        draft.error = ""
        importWorker = Task {
            defer { importing = false; importWorker = nil }
            do {
                let content = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceOSError("文件需为非空 UTF-8 文字；未保存或截断内容") }
                    return text
                }.value
                try Task.checkCancellation()
                pendingImport = (content, String(url.deletingPathExtension().lastPathComponent.prefix(100)), url.lastPathComponent)
                if !draft.text.isEmpty || !draft.title.isEmpty { confirmingReplacement = true }
                else { applyImport() }
            } catch is CancellationError {} catch { draft.error = error.localizedDescription }
        }
    }
    private func applyImport() {
        guard let input = pendingImport else { return }
        draft.text = input.text; draft.title = input.title; draft.fileName = input.fileName
        // A file's author is unknown until the user explicitly chooses personal ownership.
        draft.ownership = .external; draft.allowCloud = false; draft.error = ""; draft.commandID = UUID().uuidString
        pendingImport = nil
    }
    private func save(process: Bool) {
        draft.saving = true; draft.error = ""
        let input = draft
        Task {
            if let id = await model.saveCapturedText(input.text, title: input.title, ownership: input.ownership, allowCloud: process && input.allowCloud, commandID: input.commandID) {
                draft = TextCaptureDraft()
                onSaved(id)
            }
            else { draft.error = model.status }
            draft.saving = false
        }
    }
}
