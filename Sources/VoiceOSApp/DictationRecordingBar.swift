import SwiftUI

struct DictationRecordingBar: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Label(model.dictationBusy ? "正在保存" : model.dictationPaused ? "录音已暂停" : "正在录音",
                      systemImage: model.dictationPaused ? "pause.circle" : "record.circle")
                    .foregroundStyle(model.dictationPaused ? palette.secondaryText : palette.danger)
                    .vosFont(WorkspaceText.meta)
                TimelineView(.periodic(from: .now, by: model.dictationBusy || model.dictationPaused ? 1 : 0.1)) { _ in
                    HStack(spacing: 8) {
                        Text(model.dictationElapsedText).monospacedDigit()
                            .vosFont(WorkspaceText.meta)
                            .accessibilityIdentifier("capture.record.elapsed")
                        GeometryReader { geometry in
                            Capsule().fill(palette.border)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(palette.accent)
                                        .frame(width: geometry.size.width * model.dictationInputLevel)
                                }
                        }
                        .frame(width: 64, height: 4)
                        .accessibilityHidden(true)
                    }
                }
                Spacer()
                Button(model.dictationPaused ? "继续" : "暂停",
                       systemImage: model.dictationPaused ? "play" : "pause",
                       action: model.toggleDictationPause)
                    .buttonStyle(.workspaceSecondary)
                    .accessibilityIdentifier("capture.record.pause")
                Button("停止", systemImage: "stop.fill") { model.stopDictation() }
                    .buttonStyle(.workspacePrimary)
                    .accessibilityIdentifier("capture.record.stop")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(palette.canvas)
            .disabled(model.dictationBusy)
        }
    }
}
