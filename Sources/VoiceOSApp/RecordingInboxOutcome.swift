import Foundation
import VoiceOSCore

enum RecordingInboxOutcome {
    case completed
    case retryableFailure(String)
    /// 条件尚未就绪（等待配置、另一段整理占用、应用退出中断）：不计入三次自动重试预算。
    case deferred(String)
    case needsAttention(String)

    enum FailureMode { case automatic, manual }

    static func failure(_ error: Error, mode: FailureMode) -> Self {
        if error is CancellationError {
            return mode == .automatic
                ? .deferred("处理被中断，将从已保存的转写与分组继续")
                : .needsAttention("你已停止处理，点击重试后继续")
        }
        let message = error.localizedDescription
        if let typed = error as? RecordingServiceFailure {
            if case .connection = typed.cause { return .retryableFailure(message) }
        }
        if mode == .automatic, let status = httpStatus(in: error) {
            if status == 401 || status == 403 {
                return .needsAttention("文本服务拒绝访问（HTTP \(status)）；请检查模型密钥与权限，重新保存后重试")
            }
            return status == 408 || status == 429 || (500...599).contains(status)
                ? .retryableFailure(message) : .needsAttention(message)
        }
        if mode == .manual, let typed = error as? RecordingServiceFailure, case .http(let status) = typed.cause {
            return [429, 502, 503, 504].contains(status) ? .retryableFailure(message) : .needsAttention(message)
        }
        let common = ["网络", "timed out", "connection", "response.completed", "素材仍在更新"]
        let additional = mode == .automatic
            ? ["本批录音", "尚未完成", "没有完成回执"]
            : ["HTTP 429", "HTTP 502", "HTTP 503", "HTTP 504", "Incomplete text response", "temporarily unavailable", "server_error", "overloaded"]
        return (common + additional).contains { message.localizedCaseInsensitiveContains($0) }
            ? .retryableFailure(message) : .needsAttention(message)
    }

    /// Some saved failures and older adapters provide only a diagnostic string.
    static func httpStatus(in error: Error) -> Int? {
        if let typed = error as? RecordingServiceFailure {
            if case .http(let status) = typed.cause { return status }
            return nil
        }
        let message = error.localizedDescription
        guard let range = message.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(message[range].dropFirst(5))
    }

    static func aggregateUnderstandingFailures(_ failures: [(title: String, error: Error)]) -> Error {
        let message = failures.map { $0.title + "：" + $0.error.localizedDescription }.joined(separator: "\n")
        if let status = failures.lazy.compactMap({ httpStatus(in: $0.error) }).first {
            return RecordingServiceFailure(.http(status), message: message)
        }
        if failures.contains(where: {
            guard let service = $0.error as? RecordingServiceFailure, case .connection = service.cause else { return false }
            return true
        }) {
            return RecordingServiceFailure(.connection, message: message)
        }
        return VoiceOSError(message)
    }
}
