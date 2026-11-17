import Foundation
import VoiceOSCore

public enum QQMonitorDiagnosis: Sendable, Equatable {
    case ready(String)
    case pythonMissing(String)
    case scriptMissing(String)
    case packageMissing(String)
    case keyMissing(String)
    case qqDataMissing(String)
    case failed(String)
    public var message: String {
        switch self {
        case .ready(let message), .pythonMissing(let message), .scriptMissing(let message),
             .packageMissing(let message), .keyMissing(let message), .qqDataMissing(let message), .failed(let message):
            return message
        }
    }
}

/// Runs the repository's short-lived read-only QQ script with JSON over
/// stdin/stdout. Paths, account and group ids come from the caller; nothing
/// is hardcoded and no QQ state is modified.
public struct QQMonitorHelper: QQMonitorCollecting, Sendable {
    public init() {}

    public func collect(conversationID: String, start: Date, end: Date, settings: QQMonitorSettings) async throws -> QQMonitorReadResult {
        guard FileManager.default.isExecutableFile(atPath: settings.pythonPath) else {
            throw VoiceOSError("Python 解释器不可用：\(settings.pythonPath)；请在消息监测设置中指定已安装 qqnt-export-macos 的解释器")
        }
        guard FileManager.default.fileExists(atPath: settings.scriptPath) else {
            throw VoiceOSError("QQ 读取脚本缺失：\(settings.scriptPath)；请重新安装应用")
        }
        let request: [String: Any] = [
            "version": 1,
            "key_path": settings.keyPath,
            "cache_dir": settings.cacheDir,
            "account": settings.account ?? NSNull(),
            "conversation_id": conversationID,
            "start_iso8601": ISO8601DateFormatter().string(from: start),
            "end_iso8601": ISO8601DateFormatter().string(from: end),
        ]
        let input = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let result = try await Self.run(pythonPath: settings.pythonPath, arguments: [settings.scriptPath],
                                        stdin: input, timeout: settings.timeout, operation: "QQ 消息读取")
        guard result.exitCode == 0 else { throw Self.contractError(stderr: result.stderr) }
        return try Self.decodeResult(result.stdout)
    }

    public func diagnose(settings: QQMonitorSettings) async -> QQMonitorDiagnosis {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: settings.pythonPath) else {
            return .pythonMissing("Python 解释器不可用：\(settings.pythonPath)；请在消息监测设置中指定已安装 qqnt-export-macos 的解释器")
        }
        guard fileManager.fileExists(atPath: settings.scriptPath) else {
            return .scriptMissing("QQ 读取脚本缺失：\(settings.scriptPath)；请重新安装应用")
        }
        let attributes = try? fileManager.attributesOfItem(atPath: settings.keyPath)
        guard ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
            return .keyMissing("QQ 密钥不可用：\(settings.keyPath)；请按已验证方式重新导出密钥，应用不会修改 QQ 或安全设置")
        }
        let probe = """
        import qqnt_export_macos
        from qqnt_export_macos.live import discover_active_nt_db
        from qqnt_export_macos.snapshot import DEFAULT_QQ_ROOT
        print(discover_active_nt_db(DEFAULT_QQ_ROOT, None))
        """
        do {
            let result = try await Self.run(pythonPath: settings.pythonPath, arguments: ["-c", probe],
                                            stdin: nil, timeout: 30, operation: "QQ 环境探测")
            guard result.exitCode == 0 else {
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                if stderr.contains("ModuleNotFoundError") || stderr.contains("No module named") {
                    return .packageMissing("缺少 qqnt-export-macos：该 Python（\(settings.pythonPath)）无法导入该库；请安装 0.4.0 或更新版本，应用不会自动下载或修改 QQ")
                }
                let tail = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "原因未知"
                return .failed("QQ 环境探测失败：" + String(tail.prefix(200)) + "；QQ 数据未被修改")
            }
            let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, fileManager.fileExists(atPath: path) else {
                return .qqDataMissing("未找到该账号的 QQ 数据目录；请确认 QQ 已安装并登录过该账号")
            }
            return .ready("QQ 读取环境可用")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private struct RunOutput {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    private static func run(pythonPath: String, arguments: [String], stdin: Data?, timeout: TimeInterval, operation: String) async throws -> RunOutput {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-monitor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdinURL = directory.appendingPathComponent("stdin.json")
        let stdoutURL = directory.appendingPathComponent("stdout.json")
        let stderrURL = directory.appendingPathComponent("stderr.log")
        try (stdin ?? Data()).write(to: stdinURL)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let input = try FileHandle(forReadingFrom: stdinURL)
        let output = try FileHandle(forWritingTo: stdoutURL)
        let errors = try FileHandle(forWritingTo: stderrURL)
        defer { try? input.close(); try? output.close(); try? errors.close() }
        let process = MonitorChildProcess()
        let exitCode = try await process.run(operation: operation, timeout: timeout) { child in
            child.executableURL = URL(fileURLWithPath: pythonPath)
            child.arguments = arguments
            child.standardInput = input
            child.standardOutput = output
            child.standardError = errors
            child.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                                 "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                                 "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1"]
        }
        return RunOutput(exitCode: exitCode,
                         stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
                         stderr: (try? Data(contentsOf: stderrURL)) ?? Data())
    }

    private static func contractError(stderr: Data) -> VoiceOSError {
        let text = String(decoding: stderr, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            let detail = line.isEmpty ? "脚本没有返回诊断信息" : String(line.prefix(200))
            return VoiceOSError("QQ 读取失败：" + detail + "；QQ 数据未被修改")
        }
        let code = error["code"] as? String ?? "unknown"
        let zh = error["zh"] as? String ?? "原因未知"
        let en = error["en"] as? String ?? ""
        let hint: String
        switch code {
        case "import_failed":
            hint = "请在该 Python 解释器中安装 qqnt-export-macos（pip install qqnt-export-macos），应用不会自动下载"
        case "key_invalid":
            hint = "密钥缺失或无法读取；请按已验证方式重新导出密钥，应用不会修改 QQ 或安全设置"
        case "qq_data_missing":
            hint = "未找到该账号的 QQ 数据目录；请确认 QQ 已安装并登录过该账号"
        case "invalid_input", "range_invalid":
            hint = "读取参数无效；请检查来源配置中的群号和账号"
        default:
            hint = "可稍后重试；已采集内容不受影响"
        }
        return VoiceOSError("QQ 读取失败（\(code)）：\(zh)" + (en.isEmpty ? "" : "（\(en)）") + "；\(hint)")
    }

    static func decodeResult(_ data: Data) throws -> QQMonitorReadResult {
        guard data.count <= 32_000_000 else { throw VoiceOSError("QQ 读取结果超过 32 MB 预算") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceOSError("QQ 读取结果不是有效 JSON；请更新 qqmonitor 脚本")
        }
        guard (root["version"] as? Int) == 1 else { throw VoiceOSError("QQ 读取结果版本不受支持") }
        guard let conversationID = root["conversation_id"] as? String, !conversationID.isEmpty else {
            throw VoiceOSError("QQ 读取结果缺少会话标识")
        }
        let name = root["conversation_name"] as? String
        guard let rawMessages = root["messages"] as? [[String: Any]],
              let count = root["message_count"] as? Int, count == rawMessages.count else {
            throw VoiceOSError("QQ 读取结果的消息数量与内容不一致")
        }
        let truncated = (root["truncated"] as? Bool) ?? false
        let messages = try rawMessages.map { raw -> QQMonitorReadMessage in
            guard let id = raw["message_id"] as? String, !id.isEmpty,
                  let timestamp = raw["timestamp_ms"] as? NSNumber,
                  let text = raw["text"] as? String else {
                throw VoiceOSError("QQ 读取结果包含无效消息")
            }
            let kind = (raw["type"] as? String).flatMap(MonitorMessageKind.init(rawValue:)) ?? .other
            let millis = timestamp.int64Value
            let sentAt = millis > 0 ? Date(timeIntervalSince1970: TimeInterval(millis) / 1000) : nil
            var metaJSON: String?
            if let meta = raw["meta"], !(meta is NSNull),
               let metaData = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
                metaJSON = String(decoding: metaData, as: UTF8.self)
            }
            return QQMonitorReadMessage(externalID: id, kind: kind, senderName: raw["sender_name"] as? String,
                                        sentAt: sentAt, content: text, metaJSON: metaJSON)
        }
        return QQMonitorReadResult(conversationID: conversationID, conversationName: name,
                                   messages: messages, truncated: truncated)
    }
}

/// Waits for one child process with a wall-clock timeout; cancellation and
/// timeout both terminate it so a hung reader cannot outlive the check.
private final class MonitorChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<Int32, Error>?
    private var timer: Task<Void, Never>?
    private var finished = false
    private var cancelled = false

    func run(operation: String, timeout: TimeInterval, configure: (Process) -> Void) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let child = Process()
                configure(child)
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                process = child
                self.continuation = continuation
                child.terminationHandler = { [weak self] finishedChild in
                    self?.finish(exitCode: finishedChild.terminationStatus)
                }
                do { try child.run() } catch {
                    process = nil
                    self.continuation = nil
                    lock.unlock()
                    continuation.resume(throwing: VoiceOSError(operation + "无法启动：\(error.localizedDescription)"))
                    return
                }
                timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.expire(operation: operation, timeout: timeout)
                }
                lock.unlock()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func finish(exitCode: Int32) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        timer?.cancel(); timer = nil
        lock.unlock()
        continuation?.resume(returning: exitCode)
    }

    private func expire(operation: String, timeout: TimeInterval) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let child = process
        process = nil
        timer = nil
        lock.unlock()
        child?.terminate()
        continuation?.resume(throwing: VoiceOSError("\(operation)超过 \(Int(timeout.rounded())) 秒未完成，已停止；QQ 数据未被修改，可稍后重试"))
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let child = process
        process = nil
        timer?.cancel(); timer = nil
        lock.unlock()
        child?.terminate()
        continuation?.resume(throwing: CancellationError())
    }
}
