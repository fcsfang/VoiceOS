import SwiftUI
import AVFoundation

struct DictationRecordingBar: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @State private var levels: [Double] = []

    private var sampling: Bool { model.dictationActive && !model.dictationBusy && !model.dictationPaused }
    private var caption: String {
        if model.dictationBusy { return "正在保存" }
        return model.dictationPaused ? "已暂停" : "录音中"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(sampling ? palette.danger : palette.tertiaryText)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.dictationElapsedText.isEmpty ? "–:––" : model.dictationElapsedText)
                            .vosFont(WorkspaceText.rowTitle.size, weight: .semibold, monospacedDigit: true)
                            .foregroundStyle(palette.text)
                            .accessibilityLabel("已录时长")
                            .accessibilityValue(model.dictationElapsedText)
                            .accessibilityIdentifier("capture.record.elapsed")
                        Text(caption).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                    }
                }
                .frame(minWidth: 78, alignment: .leading)
                waveform
                Button(model.dictationPaused ? "继续" : "暂停",
                       systemImage: model.dictationPaused ? "play" : "pause",
                       action: model.toggleDictationPause)
                    .buttonStyle(.workspaceSecondary)
                    .accessibilityIdentifier("capture.record.pause")
                Button { model.stopDictation() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.danger)
                        .frame(width: 34, height: 34)
                        .background(palette.danger.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("停止并保存")
                .accessibilityLabel("停止并保存")
                .accessibilityIdentifier("capture.record.stop")
            }
            .frame(maxWidth: WorkspaceMetrics.pageWidth)
            .padding(.horizontal, WorkspaceMetrics.toolbarPadding)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(palette.surface)
            .disabled(model.dictationBusy)
        }
        .task(id: sampling) {
            guard sampling else { return }
            while !Task.isCancelled {
                if levels.count == 128 { levels.removeFirst() }
                levels.append(model.dictationInputLevel)
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            }
        }
    }

    private var waveform: some View {
        Canvas { context, size in
            let step: CGFloat = 4
            let count = max(1, Int(size.width / step))
            let samples = levels.suffix(count)
            let start = count - samples.count
            for slot in 0..<count {
                let level = slot < start ? 0 : samples[samples.startIndex + slot - start]
                let height = max(2, CGFloat(level) * (size.height - 9))
                let bar = CGRect(x: size.width - CGFloat(count - slot) * step,
                                 y: (size.height - height) / 2, width: 2, height: height)
                let ink = slot < start ? palette.border : (sampling ? palette.danger : palette.tertiaryText)
                context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(ink))
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 7)
        .background(palette.canvas, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        .accessibilityHidden(true)
    }
}

struct DictationPlaybackTimeline: View {
    @Environment(\.workspacePalette) private var palette
    let player: AVPlayer
    let duration: TimeInterval
    @State private var scrubPosition: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { _ in
            let seconds = player.currentTime().seconds
            let position = scrubPosition ?? (seconds.isFinite ? min(max(0, seconds), duration) : 0)
            let playing = player.timeControlStatus != .paused
            HStack(spacing: 10) {
                Button {
                    if playing { player.pause() }
                    else {
                        if position >= duration { player.seek(to: .zero) }
                        player.play()
                    }
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .frame(width: 30, height: 28)
                        .background(palette.hover, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.chipRadius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "暂停回听" : "继续回听")
                Text(ControlCenter.clockText(position)).monospacedDigit()
                Slider(value: Binding(get: { position }, set: { value in
                    if scrubPosition != nil { scrubPosition = value }
                    else { seek(value) }
                }), in: 0...duration) { started in
                    if started { scrubPosition = position }
                    else if let target = scrubPosition {
                        seek(target)
                        scrubPosition = nil
                    }
                }
                .accessibilityLabel("回听进度")
                .accessibilityIdentifier("capture.record.timeline")
                Text(ControlCenter.clockText(duration)).monospacedDigit()
            }
            .vosFont(WorkspaceText.meta)
            .foregroundStyle(palette.secondaryText)
            .tint(palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(palette.canvas, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
        }
    }

    private func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
