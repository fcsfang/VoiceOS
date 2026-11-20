import AppKit
import Carbon
import SwiftUI
import VoiceOSPlatform

extension GlobalHotKey {
    static let quickNote = GlobalHotKey(identifier: 3, keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey))
}

@MainActor
final class QuickNoteController: NSObject, NSWindowDelegate {
    static let shared = QuickNoteController()
    private var panel: QuickNotePanel?
    private var previousApplication: NSRunningApplication?

    func show() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeKey()
            return
        }
        guard let model = ControlCenter.primary else { return }
        let context = FrontContextReader.current()
        previousApplication = NSWorkspace.shared.frontmostApplication
        let panel = QuickNotePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "速记"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickNoteView(model: model, context: context?.display) { [weak self] in
            self?.close()
        })
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
    }

    private func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        guard let previousApplication else { return }
        self.previousApplication = nil
        _ = previousApplication.activate(from: .current, options: [])
    }
}

private struct QuickNoteView: View {
    @ObservedObject var model: ControlCenter
    let context: String?
    let close: () -> Void
    /// The quick note panel is its own hosting root, outside WorkspaceView's
    /// palette injection, so resolve the stored theme directly.
    private var palette: WorkspacePalette {
        WorkspacePalette(theme: WorkspaceTheme(rawValue: UserDefaults.standard.string(forKey: "voiceos.workspaceTheme") ?? "") ?? .graphite)
    }
    @State private var title = ""
    @State private var text = ""
    @State private var saving = false
    @State private var error = ""
    @FocusState private var editing: Bool
    private var valid: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let context { Text("来自 " + context).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
            TextField("标题 · 可留空", text: $title).textFieldStyle(.roundedBorder).disabled(saving).accessibilityLabel("标题")
            TextEditor(text: $text).vosFont(WorkspaceText.body).frame(minHeight: 180).focused($editing).disabled(saving).accessibilityLabel("正文")
            if !error.isEmpty { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger) }
            HStack {
                Button("取消") { close() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("保存") { save() }.keyboardShortcut(.defaultAction).disabled(!valid || saving).accessibilityLabel("保存速记")
            }
        }
        .padding(20)
        .frame(width: 480, height: 340)
        .vosTextEnvironment(model.textSize)
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            editing = true
        }
    }

    private func save() {
        guard valid, !saving else { return }
        saving = true
        error = ""
        Task {
            let saved = await model.acceptCaptureRequest(text: text, title: title, url: nil, successURL: nil, context: context)
            saving = false
            if saved { close() } else { error = model.status.isEmpty ? "保存失败，请稍后重试" : model.status }
        }
    }
}

@MainActor
private final class QuickNotePanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
