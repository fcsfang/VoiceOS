import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceOSCore
import VoiceOSPlatform

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
    @State private var linkImporting = false
    @State private var showingLinkPrompt = false
    @State private var linkText = ""
    @FocusState private var focus: CaptureField?
    private enum CaptureField: Hashable { case title, text }
    private var validationIssue: String? {
        if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "填写完整原文后即可保存。" }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty && (title.count > 100 || title.contains(where: \.isNewline)) { return "标题需为一行、不超过 100 字；留空则取正文首行。" }
        return nil
    }
    private var valid: Bool { validationIssue == nil }
    private var saveExplanation: String {
        if draft.allowCloud && model.canUnderstandCapturedText { return "保存后同时整理观点与任务。" }
        if draft.allowCloud { return "保存后先留在本机；稍后可在资料页允许云端整理。" }
        return "保存后只留在本机，不发送云端。"
    }
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
                if importing { ProgressView("正在读取文字、PDF 或识别图片…").controlSize(.small) }
                if linkImporting { ProgressView("正在抓取网页正文…").controlSize(.small) }
                Text(saveExplanation).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("稍后继续", action: dismiss).disabled(draft.saving)
                    Spacer()
                    if draft.saving { ProgressView().controlSize(.small) }
                    Button("保存") { save() }.buttonStyle(.borderedProminent).tint(palette.accent)
                        .disabled(draft.saving || !valid)
                }
            }.padding(20).background(palette.canvas)
        }.foregroundStyle(palette.text).background(palette.canvas).interactiveDismissDisabled(draft.saving).disabled(!model.initialized || importing || linkImporting)
            .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).stroke(dropTargeted ? palette.accent : .clear, lineWidth: 2).allowsHitTesting(false) }
            .dropDestination(for: URL.self) { urls, _ in
                guard model.initialized, !draft.saving, !importing, !linkImporting, !confirmingReplacement else { return false }
                guard urls.count == 1, let url = urls.first else {
                    draft.error = "请一次拖入一份 .txt、.md、.pdf 或图片文件；当前草稿已保留。"
                    return false
                }
                readDroppedFile(url)
                return true
            } isTargeted: { dropTargeted = $0 }
            .task {
                // A focus write before the field attaches to its window is dropped.
                guard model.initialized, !model.dictationActive, !model.dictationBusy, !draft.saving, !importing, !linkImporting,
                      focus == nil, !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled, focus == nil, !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                focus = .text
            }
            .onDisappear { importWorker?.cancel(); importing = false; linkImporting = false; showingLinkPrompt = false; model.flushTextCaptureDraft(); focus = nil }
            .alert("替换当前文字草稿？", isPresented: $confirmingReplacement) {
                Button("保留当前草稿", role: .cancel) { pendingImport = nil }
                Button("用文件替换", role: .destructive) { applyImport() }
            } message: {
                Text("导入将替换当前标题和完整原文。若要保留两份内容，请先取消并保存当前草稿，再导入文件。")
            }
            .sheet(isPresented: $showingLinkPrompt) { linkImportSheet }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 12) {
                WorkspaceHero(eyebrow: "", title: "记录想法")
                Button("导入文字文件") { chooseFile() }.disabled(draft.saving)
                Button("从链接导入正文") { linkText = ""; showingLinkPrompt = true }.disabled(draft.saving)
            }
            Text("⌘⇧R 开始或停止口述").font(.caption).foregroundStyle(.secondary)
            TextField(draft.ownership == .personal ? "表达标题 · 可留空，默认取正文首行" : "资料标题 · 可留空，默认取正文首行", text: $draft.title).textFieldStyle(.roundedBorder).focused($focus, equals: .title).disabled(draft.saving)
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
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("原文归属", selection: $draft.ownership) {
                        Text("我的表达").tag(TextCaptureOwnership.personal)
                        Text("外部资料").tag(TextCaptureOwnership.external)
                    }.pickerStyle(.segmented).disabled(draft.saving)
                    Toggle("允许云端理解全文", isOn: $draft.allowCloud).disabled(draft.saving)
                    Text("手打默认我的表达；导入文字或图片默认外部资料并仅本地。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            } label: {
                Text("保存选项 · \(draft.ownership == .personal ? "我的表达" : "外部资料") · \(draft.allowCloud ? "允许云端" : "仅本地")")
                    .font(.callout)
            }
        }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "导入文字或 PDF"
        panel.prompt = "读取全文"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .text, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            readFile(url)
        }
    }
    private func readFile(_ url: URL) {
        guard url.isFileURL, ["txt", "md", "pdf"].contains(url.pathExtension.lowercased()) else {
            draft.error = "请选择 .txt、.md 或 .pdf 本地文件；当前草稿已保留。"
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
                    if url.pathExtension.lowercased() == "pdf" { return try PDFText.extract(fileURL: url).text }
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
    private func readDroppedFile(_ url: URL) {
        guard url.isFileURL else {
            draft.error = "请拖入 .txt、.md、.pdf 或图片文件；当前草稿已保留。"
            return
        }
        let ext = url.pathExtension.lowercased()
        if ext == "txt" || ext == "md" || ext == "pdf" { readFile(url) }
        else if SourceAttachment.mime(forFileExtension: ext) != nil { recognizeImage(url) }
        else { draft.error = "请拖入 .txt、.md、.pdf 或图片文件；当前草稿已保留。" }
    }
    private func recognizeImage(_ url: URL) {
        importing = true
        draft.error = ""
        importWorker = Task {
            defer { importing = false; importWorker = nil }
            let result = await model.ocrImage(url)
            guard !Task.isCancelled else { return }
            guard let result else {
                draft.error = model.status.isEmpty ? "图片里没有识别到文字" : model.status
                return
            }
            pendingImport = (result.text, result.title, url.lastPathComponent)
            if !draft.text.isEmpty || !draft.title.isEmpty { confirmingReplacement = true }
            else { applyImport() }
        }
    }
    private var linkImportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("从链接导入正文").font(.title2)
            Text("只支持 http 或 https 链接。抓取成功后填入当前草稿；当前草稿不为空时会先确认替换。").font(.callout).foregroundStyle(.secondary)
            TextField("https://…", text: $linkText).textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { showingLinkPrompt = false }
                Spacer()
                Button("抓取正文") { importLink() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 480)
    }
    private func importLink() {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            draft.error = "请输入 http 或 https 链接；当前草稿已保留。"
            return
        }
        showingLinkPrompt = false
        linkImporting = true
        draft.error = ""
        importWorker = Task {
            defer { linkImporting = false; importWorker = nil }
            do {
                let article = try await WebArticle.fetch(url: url)
                try Task.checkCancellation()
                pendingImport = (article.text, article.title, url.host ?? url.absoluteString)
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
    private func save() {
        guard valid else { return }
        draft.saving = true; draft.error = ""
        let input = draft
        let process = input.allowCloud && model.canUnderstandCapturedText
        Task {
            if let id = await model.saveCapturedText(input.text, title: input.title, ownership: input.ownership, allowCloud: process, commandID: input.commandID) {
                draft = TextCaptureDraft()
                onSaved(id)
            }
            else { draft.error = model.status }
            draft.saving = false
        }
    }
}
