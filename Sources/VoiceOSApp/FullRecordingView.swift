import SwiftUI
import VoiceOSPlatform

struct FullRecordingInput: Identifiable {
    let id = UUID()
    let url: URL
    let media: RecordingMediaInfo
}

struct FullRecordingView: View {
    @ObservedObject var model: ControlCenter
    let input: FullRecordingInput
    let showTasks: () -> Void
    @State private var track = 0
    @State private var ownVoice = false
    private var duration: String {
        let seconds = Int(input.media.duration)
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("完整整理我的录音").font(.title2)
            Text(input.url.lastPathComponent).font(.headline).textSelection(.enabled)
            Text("完整时长 \(duration) · \(input.media.tracks.count) 条音轨").foregroundStyle(.secondary)
            Picker("本人音轨", selection: $track) {
                ForEach(input.media.tracks) { audio in Text(audio.title).tag(audio.id) }
            }.disabled(model.fullRecordingBusy || model.fullRecordingCount != nil)
            Text("OBS 通常将本人麦克风保存在音轨 2。请按这份素材的实际设置选择，避免把嘉宾或系统声音当成自己的意图。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("所选音轨是我的声音", isOn: $ownVoice).disabled(model.fullRecordingBusy || model.fullRecordingCount != nil)
            Text("Qwen 在本机转写所选音轨的全部内容；逐字稿发送到已配置文本模型，逐段提取后全文复查漏项。明确待办同步到已连接的 VoiceOS 清单，原始音视频保存在本机。")
                .font(.callout)
            if model.fullRecordingBusy { ProgressView().controlSize(.small) }
            Text(model.fullRecordingStatus).font(.callout).textSelection(.enabled).frame(minHeight: 48, alignment: .topLeading)
            HStack {
                if model.fullRecordingBusy { Button("停止处理") { model.cancelFullRecording() } }
                else { Button("关闭") { model.fullRecordingInput = nil }.keyboardShortcut(.cancelAction) }
                Spacer()
                if model.fullRecordingCount != nil {
                    Button("打开完整清单") { model.openFullRecordingOutput() }
                    Button("查看任务与后续", action: showTasks).buttonStyle(.borderedProminent)
                }
                else {
                    Button("完整转写并整理") { model.organizeRecording(input, track: track) }
                        .buttonStyle(.borderedProminent).disabled(!ownVoice || model.fullRecordingBusy || !model.modelConfigured)
                }
            }
        }.padding(24).frame(width: 600)
            .onAppear { track = input.media.tracks.count > 1 ? 1 : 0 }
            .interactiveDismissDisabled(model.fullRecordingBusy)
    }
}
