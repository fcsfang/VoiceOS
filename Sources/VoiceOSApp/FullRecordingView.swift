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
    var embedded = false
    let showTasks: () -> Void
    @State private var track = 0
    @State private var ownVoice = false
    private var duration: String {
        let seconds = Int(input.media.duration)
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private var trackDecision: RecordingTrackDecision {
        FullRecordingOrganizer.decide(track: track, ownVoice: ownVoice, in: input.media)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("完整整理我的录音").font(.title2)
            Text(input.url.lastPathComponent).font(.headline).textSelection(.enabled)
            Text("完整时长 \(duration) · \(input.media.tracks.count) 条音轨").foregroundStyle(.secondary)
            Picker("本人音轨", selection: $track) {
                ForEach(input.media.tracks) { audio in Text(audio.title).tag(audio.id) }
            }.disabled(model.fullRecordingBusy || model.fullRecordingCount != nil)
            Text(RecordingMediaInfo.personalRecordingLayout)
                .font(.callout).foregroundStyle(.secondary)
            Toggle("所选音轨是我的声音", isOn: $ownVoice)
                .disabled(model.fullRecordingBusy || model.fullRecordingCount != nil || !trackDecision.allowsOwnVoice)
            Text(input.media.contextTrack != nil && track == input.media.personalTrack ? "Qwen 在本机分别完整转写你的声音和节目声音，AI 校正后结合双轨全文理解，保留双方原话与时间。节目观点、你的复述与看法分开，只有你明确要做的事进入待办。双轨文字使用已配置模型，原始音视频留在本机。" : "Qwen 在本机完整转写本人音轨，AI 依据全文校正识别错误，保留原意与修订历史。随后整理观点与明确待办；原始音视频保留在本机。")
                .font(.callout)
            if let issue = model.recordingModelIssue {
                Text(issue).font(.callout).foregroundStyle(.orange)
                HStack {
                    if !model.speechConfigured { Button("配置本地 Qwen 转写…") { model.chooseLocalSpeech() } }
                    if !model.textModelConfigured { Button("配置文本模型…") { model.chooseTextModel() } }
                }
            }
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
                    if input.media.tracks.count == 1 && !trackDecision.importsAsPersonal {
                        Button("作为外部资料导入") { model.importFullRecordingAsExternal(input) }
                            .disabled(model.fullRecordingBusy || model.importing)
                    }
                    Button("完整转写并整理") { model.organizeRecording(input, track: track) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!trackDecision.importsAsPersonal || model.fullRecordingBusy || model.recordingModelIssue != nil)
                }
            }
        }.padding(24).frame(width: embedded ? nil : 600).frame(maxWidth: embedded ? 780 : nil)
            .onAppear {
                track = input.media.personalTrack
                ownVoice = input.media.usesPersonalRecordingLayout
            }
            .onChange(of: track) { _, selected in
                if input.media.usesPersonalRecordingLayout { ownVoice = selected == input.media.personalTrack }
            }
            .interactiveDismissDisabled(model.fullRecordingBusy)
    }
}
