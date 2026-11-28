import Foundation
import AVFoundation
import CoreAudio
import VoiceOSCore

public enum MicrophoneAuthorization: Sendable, Equatable {
    case granted, denied, notDetermined
}

@MainActor
public final class NativeDictation: NSObject, AVAudioRecorderDelegate {
    private static weak var owner: NativeDictation?
    private var recorder: AVAudioRecorder?
    private var finish: (@MainActor (Bool) -> Void)?
    private var watchdog: Task<Void,Never>?
    private var pausedTime: TimeInterval?
    private var durationLimit: TimeInterval?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    public var elapsed: TimeInterval { pausedTime ?? recorder?.currentTime ?? 0 }
    public var inputLevel: Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        return max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 55) / 55))
    }
    public func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for:.audio) }
    /// Read-only view of the system microphone permission. Requesting stays in `requestPermission`.
    public nonisolated static func authorizationStatus() -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    public func start(at file: URL, maximumDuration: TimeInterval? = nil,
                      inputChanged: (@MainActor () -> Void)? = nil,
                      finished: @escaping @MainActor (Bool) -> Void) throws {
        if let maximumDuration {
            guard maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 60 else { throw VoiceOSError("限时采集须为大于0且不超过60秒") }
        }
        guard recorder == nil, Self.owner == nil, AVCaptureDevice.authorizationStatus(for:.audio) == .authorized,
              !FileManager.default.fileExists(atPath:file.path) else { throw VoiceOSError("麦克风尚未授权、已有录制或暂存文件已存在") }
        let value = try AVAudioRecorder(url:file,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:24000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
        recorder = value; finish = finished; value.delegate = self; Self.owner = self
        value.isMeteringEnabled = true
        let started = value.prepareToRecord() && (maximumDuration.map { value.record(forDuration:$0) } ?? value.record())
        guard started else {
            value.delegate = nil; recorder = nil; finish = nil; Self.owner = nil
            throw VoiceOSError("麦克风未开始录制，未报告保存成功")
        }
        durationLimit = maximumDuration
        if let inputChanged { observeInputChange(inputChanged) }
    }
    public func pause() -> Bool {
        guard let recorder, recorder.isRecording else { return false }
        pausedTime = recorder.currentTime
        recorder.pause()
        return true
    }
    public func resume() -> Bool {
        guard let recorder, let elapsedBeforePause = pausedTime else { return false }
        let resumed = durationLimit.map { recorder.record(forDuration: max(0.001, $0 - elapsedBeforePause)) } ?? recorder.record()
        guard resumed else { return false }
        pausedTime = nil
        return true
    }
    public func stop() {
        guard let recorder else { return }
        stopObservingInput()
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
        stopObservingInput()
        watchdog?.cancel(); watchdog = nil
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; finish = nil
        pausedTime = nil
        durationLimit = nil
        if Self.owner === self { Self.owner = nil }
        callback(success)
    }

    private func defaultInputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &inputAddress, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private func observeInputChange(_ changed: @escaping @MainActor () -> Void) {
        guard let device = defaultInputDevice() else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.inputListener != nil, self.defaultInputDevice() != device else { return }
                changed()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &inputAddress, .main, listener) == noErr {
            inputListener = listener
        }
    }

    private func stopObservingInput() {
        guard let inputListener else { return }
        self.inputListener = nil
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &inputAddress, .main, inputListener)
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
