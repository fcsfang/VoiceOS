import Foundation
import AVFoundation
import VoiceOSCore

@MainActor
public final class NativeDictation: NSObject, AVAudioRecorderDelegate {
    private static weak var owner: NativeDictation?
    private var recorder: AVAudioRecorder?
    private var finish: (@MainActor (Bool) -> Void)?
    private var watchdog: Task<Void,Never>?
    public func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for:.audio) }
    public func start(at file:URL, maximumDuration: TimeInterval? = nil, finished:@escaping @MainActor (Bool) -> Void) throws {
        if let maximumDuration {
            guard maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 60 else { throw VoiceOSError("限时采集须为大于0且不超过60秒") }
        }
        guard recorder == nil, Self.owner == nil, AVCaptureDevice.authorizationStatus(for:.audio) == .authorized,
              !FileManager.default.fileExists(atPath:file.path) else { throw VoiceOSError("麦克风尚未授权、已有录制或暂存文件已存在") }
        let value = try AVAudioRecorder(url:file,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:24000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
        recorder = value; finish = finished; value.delegate = self; Self.owner = self
        let started = value.prepareToRecord() && (maximumDuration.map { value.record(forDuration:$0) } ?? value.record())
        guard started else {
            value.delegate = nil; recorder = nil; finish = nil; Self.owner = nil
            throw VoiceOSError("麦克风未开始录制，未报告保存成功")
        }
    }
    public func stop() {
        guard let recorder else { return }
        recorder.stop()
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for:.seconds(5))
            guard !Task.isCancelled else { return }
            self?.complete(false)
        }
    }
    private func complete(_ success:Bool) {
        guard let callback = finish else { return }
        watchdog?.cancel(); watchdog = nil
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; finish = nil
        if Self.owner === self { Self.owner = nil }
        callback(success)
    }
    nonisolated public func audioRecorderDidFinishRecording(_ recorder:AVAudioRecorder,successfully flag:Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            self.complete(flag)
        }
    }
    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder:AVAudioRecorder,error:Error?) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            self.complete(false)
        }
    }
}
