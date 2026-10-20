import Foundation
import VoiceOSCore

/// One native callback request. All terminal paths resolve once, on MainActor.
@MainActor
final class CallbackWait<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelNative: (() -> Void)?
    private var timer: Task<Void, Never>?
    private var started = false
    var isWaiting: Bool { continuation != nil }
    func wait(timeout: Duration, start: (@escaping @MainActor (Result<Value, Error>) -> Void) -> (() -> Void)) async throws -> Value {
        guard !started, timeout > .zero else { throw VoiceOSError("读取请求已结束或超时设置无效") }
        started = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                self.continuation = continuation
                guard !Task.isCancelled else { finish(.failure(CancellationError()), cancel: true); return }
                let cancel = start { [weak self] result in self?.finish(result, cancel: false) }
                // Supports a callback that completes synchronously in start().
                guard self.continuation != nil else { return }
                cancelNative = cancel
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.finish(.failure(VoiceOSError("提醒事项读取超时；保留历史，不自动重建")), cancel: true)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError()), cancel: true) }
        }
    }
    private func finish(_ result: Result<Value, Error>, cancel: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        let cancellation = cancelNative
        cancelNative = nil
        timer?.cancel(); timer = nil
        // Mark terminal first: cancellation may itself cause a late callback.
        if cancel { cancellation?() }
        continuation.resume(with: result)
    }
}
