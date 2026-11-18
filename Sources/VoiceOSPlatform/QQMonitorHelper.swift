import Foundation
import VoiceOSCore

/// macOS TCC blocks QQ container reads until VoiceOS has Full Disk Access.
/// The stderr signatures stand in for the code so an older bundled script
/// that still calls this `key_invalid` is classified correctly.
public enum QQMonitorPermissionGuidance {
    public static let text = "需要完全磁盘访问权限：请打开 系统设置 → 隐私与安全性 → 完全磁盘访问权限，勾选 VoiceOS，然后完全退出并重新打开 VoiceOS；若刚更新过应用，可能需要重新授权"
    public static func matches(_ text: String) -> Bool {
        text.contains("Operation not permitted") || text.contains("PermissionError") || text.contains("permission_denied")
    }
}

public struct QQMonitorConversation: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let latestAt: Date?
    public let messageCount: Int
    public init(id: String, name: String, latestAt: Date?, messageCount: Int) {
        self.id = id
        self.name = name
        self.latestAt = latestAt
        self.messageCount = messageCount
    }
}

public struct QQMonitorConversationList: Sendable, Equatable {
    public let conversations: [QQMonitorConversation]
    public let account: String?
    public init(conversations: [QQMonitorConversation], account: String?) {
        self.conversations = conversations
        self.account = account
    }
}

public struct QQMonitorDiagnosisItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let ok: Bool
    public let detail: String
    public let needsFullDiskAccess: Bool
    public init(id: String, title: String, ok: Bool, detail: String, needsFullDiskAccess: Bool = false) {
        self.id = id
        self.title = title
        self.ok = ok
        self.detail = detail
        self.needsFullDiskAccess = needsFullDiskAccess
    }
}

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

public enum QQMonitorPythonProbe: Sendable, Equatable {
    case available
    case missingPackage
    case cannotRun

    public var label: String {
        switch self {
        case .available: return "可用"
        case .missingPackage: return "缺少 qqnt_export_macos"
        case .cannotRun: return "无法执行"
        }
    }
}

/// Runs the repository's short-lived read-only QQ script with JSON over
/// stdin/stdout. Paths, account and group ids come from the caller; nothing
/// is hardcoded and no QQ state is modified.
public struct QQMonitorHelper: QQMonitorCollecting, Sendable {
    static let messageReadOperation = "QQ 消息读取"

    public init() {}

    public func checkPython(_ pythonPath: String) async -> QQMonitorPythonProbe {
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else { return .cannotRun }
        do {
            let result = try await Self.run(pythonPath: pythonPath,
                                            arguments: ["-c", "import qqnt_export_macos"],
                                            stdin: nil, timeout: 10, operation: "QQ Python 自检")
            return Self.classifyPythonProbe(exitCode: result.exitCode,
                                            stderr: String(decoding: result.stderr, as: UTF8.self))
        } catch {
            return .cannotRun
        }
    }

    public static func classifyPythonProbe(exitCode: Int32?, stderr: String) -> QQMonitorPythonProbe {
        if exitCode == 0 { return .available }
        if stderr.contains("ModuleNotFoundError") || stderr.contains("No module named") {
            return .missingPackage
        }
        return .cannotRun
    }

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
                                        stdin: input, timeout: settings.timeout, operation: Self.messageReadOperation)
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
                if QQMonitorPermissionGuidance.matches(stderr) {
                    return .failed(QQMonitorPermissionGuidance.text + "；QQ 数据未被修改")
                }
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

    public func conversations(settings: QQMonitorSettings) async throws -> [QQMonitorConversation] {
        try await conversationList(settings: settings).conversations
    }

    public func conversationList(settings: QQMonitorSettings) async throws -> QQMonitorConversationList {
        guard FileManager.default.isExecutableFile(atPath: settings.pythonPath) else {
            throw VoiceOSError("Python 解释器不可用：\(settings.pythonPath)；请在消息监测设置中指定已安装 qqnt-export-macos 的解释器")
        }
        guard FileManager.default.fileExists(atPath: settings.scriptPath) else {
            throw VoiceOSError("QQ 读取脚本缺失：\(settings.scriptPath)；请重新安装应用")
        }
        let request: [String: Any] = [
            "version": 1,
            "action": "conversations",
            "key_path": settings.keyPath,
            "cache_dir": settings.cacheDir,
            "account": settings.account ?? NSNull(),
            "minutes": 365 * 24 * 60,
            "limit": 100,
        ]
        let input = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let result = try await Self.run(pythonPath: settings.pythonPath, arguments: [settings.scriptPath],
                                        stdin: input, timeout: settings.timeout, operation: "QQ 群列表读取")
        guard result.exitCode == 0 else { throw Self.contractError(stderr: result.stderr) }
        return try Self.decodeConversationList(result.stdout)
    }

    /// Only group conversations are returned, newest first, capped at 100.
    /// Private chats never surface in the source picker. The account is
    /// carried only when the script reports one.
    static func decodeConversationList(_ data: Data) throws -> QQMonitorConversationList {
        guard data.count <= 8_000_000 else { throw VoiceOSError("QQ 群列表超过 8 MB 预算") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceOSError("QQ 群列表不是有效 JSON；请更新 qqmonitor 脚本")
        }
        guard (root["version"] as? Int) == 1 else { throw VoiceOSError("QQ 群列表版本不受支持") }
        guard let raw = root["conversations"] as? [[String: Any]] else {
            throw VoiceOSError("QQ 群列表缺少 conversations")
        }
        let account = (root["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var rows: [QQMonitorConversation] = []
        for item in raw {
            guard let id = item["conversation_id"] as? String, id.hasPrefix("group:") else { continue }
            guard seen.insert(id).inserted else { continue }
            let name = (item["conversation_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "群 " + id.replacingOccurrences(of: "group:", with: "")
            let millis = (item["latest_timestamp"] as? NSNumber)?.int64Value ?? 0
            let latest = millis > 0 ? Date(timeIntervalSince1970: TimeInterval(millis) / 1000) : nil
            let count = (item["message_count"] as? NSNumber)?.intValue ?? 0
            rows.append(QQMonitorConversation(id: id, name: (name?.isEmpty == false ? name! : fallback),
                                              latestAt: latest, messageCount: count))
        }
        rows.sort { lhs, rhs in
            switch (lhs.latestAt, rhs.latestAt) {
            case let (left?, right?) where left != right: return left > right
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.name < rhs.name
            }
        }
        return QQMonitorConversationList(conversations: Array(rows.prefix(100)),
                                         account: (account?.isEmpty == false) ? account : nil)
    }

    static func decodeConversations(_ data: Data) throws -> [QQMonitorConversation] {
        try decodeConversationList(data).conversations
    }

    /// The library's account discovery turns a TCC denial into an empty glob,
    /// so a failed discovery rechecks the root listing; a permission failure
    /// there is reported as missing Full Disk Access instead of missing data.
    static let directoryProbeScript = """
    import os
    import sys
    from qqnt_export_macos.live import discover_active_nt_db
    from qqnt_export_macos.snapshot import DEFAULT_QQ_ROOT
    try:
        print(discover_active_nt_db(DEFAULT_QQ_ROOT, sys.argv[1] or None))
    except FileNotFoundError:
        try:
            os.listdir(os.path.expanduser(str(DEFAULT_QQ_ROOT)))
        except PermissionError as exc:
            sys.stderr.write("PermissionError: " + str(exc) + "\\n")
            sys.exit(1)
        raise
    """

    /// Opening the mirror runs mirror refresh, key selection and SQLCipher
    /// decryption, so it surfaces key rotation and a missing SQLCipher that a
    /// plain import check cannot see.
    static let mirrorProbeScript = """
    import json
    import sys
    from pathlib import Path
    from qqnt_export_macos.recent import QQRecentReader
    reader = QQRecentReader(Path(sys.argv[1]).expanduser(), account=sys.argv[2] or None,
                            cache_dir=Path(sys.argv[3]).expanduser())
    print(json.dumps(reader.status()))
    """

    static func directoryProbeItem(exitCode: Int32, stdout: String, stderr: String,
                                   account: String?) -> QQMonitorDiagnosisItem {
        let title = "QQ 账号数据目录"
        let accountText = account.map { "（\($0)）" } ?? ""
        if QQMonitorPermissionGuidance.matches(stderr) {
            return .init(id: "qqdata", title: title, ok: false,
                         detail: QQMonitorPermissionGuidance.text, needsFullDiskAccess: true)
        }
        if exitCode != 0 {
            if stderr.contains("no QQNT account message databases found")
                || stderr.contains("account database not found") || stderr.contains("FileNotFoundError") {
                return .init(id: "qqdata", title: title, ok: false,
                             detail: "未找到该账号的 QQ 数据目录；请确认 QQ 已安装并登录过该账号" + accountText)
            }
            if stderr.contains("ModuleNotFoundError") || stderr.contains("No module named") {
                return .init(id: "qqdata", title: title, ok: false,
                             detail: "该 Python 无法导入 qqnt-export-macos，无法检查数据目录；请先修复依赖")
            }
            let tail = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "原因未知"
            return .init(id: "qqdata", title: title, ok: false,
                         detail: "数据目录检查失败：" + String(tail.prefix(200)) + "；QQ 数据未被修改")
        }
        let path = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        return .init(id: "qqdata", title: title, ok: ok,
                     detail: ok ? path : "未找到该账号的 QQ 数据目录；请确认 QQ 已安装并登录过该账号" + accountText)
    }

    static func mirrorProbeItem(exitCode: Int32, stderr: String) -> QQMonitorDiagnosisItem {
        let title = "镜像库与密钥"
        if exitCode == 0 {
            return .init(id: "mirror", title: title, ok: true, detail: "可打开 QQ 镜像库并验证密钥")
        }
        if QQMonitorPermissionGuidance.matches(stderr) {
            return .init(id: "mirror", title: title, ok: false,
                         detail: QQMonitorPermissionGuidance.text, needsFullDiskAccess: true)
        }
        if stderr.contains("valid key candidate") {
            return .init(id: "mirror", title: title, ok: false,
                         detail: "QQ 可能已升级导致密钥失效，请重新导出密钥；应用不会修改 QQ")
        }
        if stderr.contains("SQLCipher support is missing") || stderr.contains("sqlcipher3") {
            return .init(id: "mirror", title: title, ok: false,
                         detail: "缺少 SQLCipher 支持：请在读取用的 Python 中安装 qqnt-export-macos[decrypt]；应用不会自动下载")
        }
        if stderr.contains("ModuleNotFoundError") || stderr.contains("No module named") {
            return .init(id: "mirror", title: title, ok: false,
                         detail: "该 Python 无法导入 qqnt-export-macos，无法验证密钥；请安装 0.4.0 或更新版本")
        }
        if stderr.contains("no QQNT account message databases found") || stderr.contains("account database not found") {
            return .init(id: "mirror", title: title, ok: false,
                         detail: "未找到该账号的 QQ 数据目录；请确认 QQ 已安装并登录过该账号")
        }
        let tail = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "原因未知"
        return .init(id: "mirror", title: title, ok: false,
                     detail: "镜像库读取失败：" + String(tail.prefix(200)) + "；QQ 数据未被修改")
    }

    /// Itemized dependency checks for the settings page. Nothing is modified;
    /// every failure carries a Chinese next step.
    public func diagnoseItems(settings: QQMonitorSettings) async -> [QQMonitorDiagnosisItem] {
        let fileManager = FileManager.default
        var items: [QQMonitorDiagnosisItem] = []
        let pythonOK = fileManager.isExecutableFile(atPath: settings.pythonPath)
        items.append(.init(id: "python", title: "Python 解释器", ok: pythonOK,
                           detail: pythonOK ? settings.pythonPath
                           : "找不到可执行的 Python：\(settings.pythonPath)；请在设置中选择已安装 qqnt-export-macos 的解释器"))
        let scriptOK = fileManager.fileExists(atPath: settings.scriptPath)
        items.append(.init(id: "script", title: "读取脚本", ok: scriptOK,
                           detail: scriptOK ? settings.scriptPath : "脚本缺失：\(settings.scriptPath)；请重新构建或重新安装应用"))
        let keyReadable = Self.keyIsReadable(settings.keyPath)
        items.append(.init(id: "key", title: "密钥文件", ok: keyReadable,
                           detail: keyReadable ? "可读取：\(settings.keyPath)"
                           : "密钥缺失、为空或不可读：\(settings.keyPath)；请按已验证方式重新导出密钥，应用不会修改 QQ 或安全设置"))
        guard pythonOK else {
            items.append(.init(id: "package", title: "qqnt-export-macos 导入", ok: false,
                               detail: "Python 不可用，无法检查依赖"))
            items.append(.init(id: "qqdata", title: "QQ 账号数据目录", ok: false,
                               detail: "Python 不可用，无法检查数据目录"))
            return items
        }
        do {
            let probe = "import qqnt_export_macos as m; print(getattr(m, '__version__', 'unknown'))"
            let result = try await Self.run(pythonPath: settings.pythonPath, arguments: ["-c", probe],
                                            stdin: nil, timeout: 30, operation: "QQ 依赖检查")
            if result.exitCode == 0 {
                let version = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(.init(id: "package", title: "qqnt-export-macos 导入", ok: true,
                                   detail: "可导入，版本 " + (version.isEmpty ? "未知" : version)))
            } else {
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                let missing = stderr.contains("ModuleNotFoundError") || stderr.contains("No module named")
                let detail = missing
                    ? "该 Python 无法导入 qqnt-export-macos；请安装 0.4.0 或更新版本，应用不会自动下载或修改 QQ"
                    : "导入失败：" + (stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "原因未知")
                items.append(.init(id: "package", title: "qqnt-export-macos 导入", ok: false, detail: detail))
            }
        } catch {
            items.append(.init(id: "package", title: "qqnt-export-macos 导入", ok: false, detail: error.localizedDescription))
        }
        do {
            let result = try await Self.run(pythonPath: settings.pythonPath,
                                            arguments: ["-c", Self.directoryProbeScript, settings.account ?? ""],
                                            stdin: nil, timeout: 30, operation: "QQ 数据目录检查")
            items.append(Self.directoryProbeItem(exitCode: result.exitCode,
                                                 stdout: String(decoding: result.stdout, as: UTF8.self),
                                                 stderr: String(decoding: result.stderr, as: UTF8.self),
                                                 account: settings.account))
        } catch {
            items.append(.init(id: "qqdata", title: "QQ 账号数据目录", ok: false, detail: error.localizedDescription))
        }
        do {
            let result = try await Self.run(pythonPath: settings.pythonPath,
                                            arguments: ["-c", Self.mirrorProbeScript, settings.keyPath,
                                                        settings.account ?? "", settings.cacheDir],
                                            stdin: nil, timeout: 60, operation: "QQ 镜像库与密钥检查")
            items.append(Self.mirrorProbeItem(exitCode: result.exitCode,
                                              stderr: String(decoding: result.stderr, as: UTF8.self)))
        } catch {
            items.append(.init(id: "mirror", title: "镜像库与密钥", ok: false, detail: error.localizedDescription))
        }
        return items
    }

    public static func keyIsReadable(_ path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1))?.isEmpty == false
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

    static func contractError(stderr: Data) -> VoiceOSError {
        let text = String(decoding: stderr, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            if QQMonitorPermissionGuidance.matches(text) {
                return VoiceOSError("QQ 读取失败（permission_denied）：" + QQMonitorPermissionGuidance.text
                                    + "（" + String(text.prefix(200)) + "）；QQ 数据未被修改")
            }
            let detail = line.isEmpty ? "脚本没有返回诊断信息" : String(line.prefix(200))
            return VoiceOSError("QQ 读取失败：" + detail + "；QQ 数据未被修改")
        }
        let code = error["code"] as? String ?? "unknown"
        let zh = error["zh"] as? String ?? "原因未知"
        let en = error["en"] as? String ?? ""
        if code == "permission_denied" || QQMonitorPermissionGuidance.matches(en) || QQMonitorPermissionGuidance.matches(zh) {
            let detail = en.isEmpty ? "" : "。技术细节：" + String(en.prefix(200))
            return VoiceOSError("QQ 读取失败（permission_denied）：" + QQMonitorPermissionGuidance.text + detail + "；QQ 数据未被修改")
        }
        let hint: String
        switch code {
        case "import_failed":
            hint = "请在该 Python 解释器中安装 qqnt-export-macos（pip install qqnt-export-macos），应用不会自动下载"
        case "key_invalid":
            hint = "密钥缺失、失效或无法读取；QQ 升级后请重新导出密钥，应用不会修改 QQ 或安全设置"
        case "group_missing":
            hint = "群不存在或已退出；请重新选择目标群，应用不会修改 QQ"
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
        guard data.count <= 32_000_000 else { throw VoiceOSError("QQ 读取结果超过 32 MB 预算；请把起始时间调近后重试") }
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
        let retry = operation == QQMonitorHelper.messageReadOperation ? "可把起始时间调近后重试" : "可稍后重试"
        child?.terminate()
        continuation?.resume(throwing: VoiceOSError("\(operation)超过 \(Int(timeout.rounded())) 秒未完成，已停止；QQ 数据未被修改，\(retry)"))
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
