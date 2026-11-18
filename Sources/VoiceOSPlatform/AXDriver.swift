import Foundation
import ApplicationServices
import VoiceOSCore

public enum AXDriverError: Error, LocalizedError {
    case notFound(String)
    case ax(String)

    public var exitCode: Int32 {
        switch self {
        case .notFound: return 2
        case .ax: return 3
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notFound(let message), .ax(let message): return message
        }
    }
}

public struct AXFrame: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct AXElementRecord: Codable, Equatable {
    public let role: String
    public let identifier: String?
    public let title: String?
    public let description: String?
    public let value: String?
    public let frame: AXFrame?
    public let actions: [String]

    public init(role: String, identifier: String? = nil, title: String? = nil, description: String? = nil, value: String? = nil, frame: AXFrame? = nil, actions: [String] = []) {
        self.role = role; self.identifier = identifier; self.title = title; self.description = description; self.value = value; self.frame = frame; self.actions = actions
    }
}

public struct AXSnapshot: Codable, Equatable {
    public let elements: [AXElementRecord]
    public let truncated: Bool

    public init(elements: [AXElementRecord], truncated: Bool) {
        self.elements = elements; self.truncated = truncated
    }
}

public enum AXRecords {
    public static func filter(_ records: [AXElementRecord], identifierPrefix: String?) -> [AXElementRecord] {
        guard let identifierPrefix else { return records }
        return records.filter { $0.identifier?.hasPrefix(identifierPrefix) == true }
    }
}

public enum AXCommand: Equatable {
    case dump(pid: pid_t, identifierPrefix: String?, json: Bool)
    case click(pid: pid_t, identifier: String)
    case setValue(pid: pid_t, identifier: String, value: String)
    case wait(pid: pid_t, identifier: String, timeout: Double)
    case scrollTo(pid: pid_t, identifier: String, maxPages: Int)

    public static let usage = """
    usage: voiceos-check ax <dump|click|set-value|wait|scroll-to> ...
      ax dump --pid <pid> [--identifier <前缀>] [--json]
      ax click --pid <pid> --identifier <id>
      ax set-value --pid <pid> --identifier <id> --value <文本>
      ax wait --pid <pid> --identifier <id> [--timeout <秒>]
      ax scroll-to --pid <pid> --identifier <id> [--max-pages <页数>]
    """

    public static func parse(_ arguments: [String]) throws -> AXCommand {
        guard let name = arguments.first else { throw VoiceOSError(usage) }
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let token = arguments[index]
            guard token.hasPrefix("--"), token.count > 2 else { throw VoiceOSError("无法识别的参数：\(token)\n\(usage)") }
            let option = String(token.dropFirst(2))
            if option == "json" {
                flags.insert(option)
                index = arguments.index(after: index)
                continue
            }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { throw VoiceOSError("选项 \(token) 缺少取值") }
            options[option] = arguments[valueIndex]
            index = arguments.index(after: valueIndex)
        }
        let allowedOptions: Set<String>, allowedFlags: Set<String>
        switch name {
        case "dump": allowedOptions = ["pid", "identifier"]; allowedFlags = ["json"]
        case "click": allowedOptions = ["pid", "identifier"]; allowedFlags = []
        case "set-value": allowedOptions = ["pid", "identifier", "value"]; allowedFlags = []
        case "wait": allowedOptions = ["pid", "identifier", "timeout"]; allowedFlags = []
        case "scroll-to": allowedOptions = ["pid", "identifier", "max-pages"]; allowedFlags = []
        default: throw VoiceOSError("未知的 ax 子命令：\(name)\n\(usage)")
        }
        if let unknown = Set(options.keys).union(flags).subtracting(allowedOptions.union(allowedFlags)).sorted().first {
            throw VoiceOSError("未知选项：--\(unknown)\n\(usage)")
        }
        let pid = try pidValue(options)
        func required(_ key: String) throws -> String {
            guard let value = options[key], !value.isEmpty else { throw VoiceOSError("缺少选项 --\(key)\n\(usage)") }
            return value
        }
        switch name {
        case "dump":
            return .dump(pid: pid, identifierPrefix: options["identifier"], json: flags.contains("json"))
        case "click":
            return .click(pid: pid, identifier: try required("identifier"))
        case "set-value":
            return .setValue(pid: pid, identifier: try required("identifier"), value: try required("value"))
        case "wait":
            return .wait(pid: pid, identifier: try required("identifier"), timeout: try positiveDouble(options["timeout"], name: "--timeout", fallback: 5))
        case "scroll-to":
            return .scrollTo(pid: pid, identifier: try required("identifier"), maxPages: try positiveInt(options["max-pages"], name: "--max-pages", fallback: 10))
        default:
            throw VoiceOSError("未知的 ax 子命令：\(name)\n\(usage)")
        }
    }

    private static func pidValue(_ options: [String: String]) throws -> pid_t {
        guard let raw = options["pid"], let pid = Int32(raw), pid > 0 else {
            throw VoiceOSError("缺少或无效的选项 --pid（需要正整数进程号）\n\(usage)")
        }
        return pid
    }

    private static func positiveDouble(_ raw: String?, name: String, fallback: Double) throws -> Double {
        guard let raw else { return fallback }
        guard let value = Double(raw), value > 0 else { throw VoiceOSError("选项 \(name) 需要正数") }
        return value
    }

    private static func positiveInt(_ raw: String?, name: String, fallback: Int) throws -> Int {
        guard let raw else { return fallback }
        guard let value = Int(raw), value > 0 else { throw VoiceOSError("选项 \(name) 需要正整数") }
        return value
    }
}

public final class AXDriver {
    public let pid: pid_t
    private let application: AXUIElement
    private let messagingTimeout: Float = 1.5
    private let nodeLimit = 4000
    private static let permissionMessage = "辅助功能权限未授予：请在 系统设置 > 隐私与安全性 > 辅助功能 中允许运行 voiceos-check 的终端。"

    public init(pid: pid_t) throws {
        guard AXIsProcessTrusted() else { throw AXDriverError.ax(Self.permissionMessage) }
        self.pid = pid
        application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, messagingTimeout)
    }

    public func snapshot(identifierPrefix: String? = nil) throws -> AXSnapshot {
        var records: [AXElementRecord] = []
        var processed = 0
        var truncated = false
        var lastError: Error?
        var stack: [AXUIElement] = [application]
        while let element = stack.popLast() {
            guard processed < nodeLimit else { truncated = true; break }
            processed += 1
            do {
                records.append(try describe(element))
                stack.append(contentsOf: try children(of: element).reversed())
            } catch {
                lastError = error
            }
        }
        if records.isEmpty, let lastError { throw lastError }
        return AXSnapshot(elements: AXRecords.filter(records, identifierPrefix: identifierPrefix), truncated: truncated)
    }

    public func find(identifier: String) throws -> AXElementRecord? {
        try locate(identifier)?.record
    }

    public func press(identifier: String) throws -> AXElementRecord {
        guard let target = try locate(identifier) else { throw AXDriverError.notFound("未找到元素 \(identifier)") }
        guard target.record.actions.contains(kAXPressAction as String) else {
            let available = target.record.actions.isEmpty ? "无" : target.record.actions.joined(separator: ", ")
            throw AXDriverError.ax("元素 \(identifier) 不支持 AXPress；可用动作：\(available)")
        }
        try perform(kAXPressAction, on: target.element, identifier: identifier, context: "AXPress")
        return target.record
    }

    public func setValue(identifier: String, value: String) throws -> AXElementRecord {
        guard let target = try locate(identifier) else { throw AXDriverError.notFound("未找到元素 \(identifier)") }
        var element = target.element
        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settableError == .success, settable.boolValue else {
            throw AXDriverError.ax("元素 \(identifier) 的 AXValue 不可写（错误码 \(settableError.rawValue)）")
        }
        var error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        if error == .cannotComplete || error == .invalidUIElement, let refreshed = try locate(identifier) {
            element = refreshed.element
            error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        }
        guard error == .success else { throw AXDriverError.ax("写入 AXValue 失败（\(identifier)，错误码 \(error.rawValue)）") }
        let readBack = stringValue((try? copyAttribute(kAXValueAttribute as String, of: element)) ?? nil)
        guard readBack == value else {
            throw AXDriverError.ax("写入后回读不一致：期望「\(value)」，实际「\(readBack ?? "无值")」")
        }
        return target.record
    }

    public func wait(identifier: String, timeout: Double = 5) throws -> AXElementRecord {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let record = try find(identifier: identifier) { return record }
            guard Date() < deadline else { throw AXDriverError.notFound("等待 \(timeout) 秒后仍未找到元素 \(identifier)") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    public func scrollTo(identifier: String, maxPages: Int = 10) throws -> (record: AXElementRecord, pages: Int) {
        if let record = try find(identifier: identifier) { return (record, 0) }
        for page in 1...maxPages {
            guard let container = try largestScrollArea() else {
                throw AXDriverError.notFound("未找到可滚动的 AXScrollArea，无法滚动到元素 \(identifier)")
            }
            let available = actionNames(of: container)
            guard available.contains(scrollDownByPageAction) else {
                let list = available.isEmpty ? "无" : available.joined(separator: ", ")
                throw AXDriverError.ax("滚动容器不支持 AXScrollDownByPage；可用动作：\(list)")
            }
            var error = AXUIElementPerformAction(container, scrollDownByPageAction as CFString)
            if error == .cannotComplete || error == .invalidUIElement, let refreshed = try largestScrollArea() {
                error = AXUIElementPerformAction(refreshed, scrollDownByPageAction as CFString)
            }
            guard error == .success else { throw AXDriverError.ax("AXScrollDownByPage 失败（错误码 \(error.rawValue)）") }
            Thread.sleep(forTimeInterval: 0.25)
            if let record = try find(identifier: identifier) { return (record, page) }
        }
        throw AXDriverError.notFound("滚动 \(maxPages) 页后仍未找到元素 \(identifier)")
    }

    private let scrollDownByPageAction = "AXScrollDownByPage"

    private func locate(_ identifier: String) throws -> (element: AXUIElement, record: AXElementRecord)? {
        var processed = 0
        var described = 0
        var lastError: Error?
        var stack: [AXUIElement] = [application]
        while let element = stack.popLast() {
            guard processed < nodeLimit else { return nil }
            processed += 1
            do {
                let record = try describe(element)
                described += 1
                if record.identifier == identifier { return (element, record) }
                stack.append(contentsOf: try children(of: element).reversed())
            } catch {
                lastError = error
            }
        }
        if described == 0, let lastError { throw lastError }
        return nil
    }

    private func largestScrollArea() throws -> AXUIElement? {
        var best: (element: AXUIElement, area: Double)?
        var processed = 0
        var stack: [AXUIElement] = [application]
        while let element = stack.popLast() {
            guard processed < nodeLimit else { break }
            processed += 1
            do {
                let record = try describe(element)
                if record.role == kAXScrollAreaRole as String {
                    let area = (record.frame?.w ?? 0) * (record.frame?.h ?? 0)
                    if area > (best?.area ?? -1) { best = (element, area) }
                }
                stack.append(contentsOf: try children(of: element).reversed())
            } catch {
                continue
            }
        }
        return best?.element
    }

    private func perform(_ action: String, on element: AXUIElement, identifier: String, context: String) throws {
        var error = AXUIElementPerformAction(element, action as CFString)
        if error == .cannotComplete || error == .invalidUIElement, let refreshed = try locate(identifier) {
            error = AXUIElementPerformAction(refreshed.element, action as CFString)
        }
        guard error == .success else { throw AXDriverError.ax("\(context) 失败（\(identifier)，错误码 \(error.rawValue)）") }
    }

    private func describe(_ element: AXUIElement) throws -> AXElementRecord {
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXElementRecord(
            role: stringValue(try copyAttribute(kAXRoleAttribute as String, of: element)) ?? "",
            identifier: stringValue(try copyAttribute(kAXIdentifierAttribute as String, of: element)),
            title: stringValue(try copyAttribute(kAXTitleAttribute as String, of: element)),
            description: stringValue(try copyAttribute(kAXDescriptionAttribute as String, of: element)),
            value: stringValue(try copyAttribute(kAXValueAttribute as String, of: element)),
            frame: frame(of: element),
            actions: actionNames(of: element))
    }

    private func copyAttribute(_ attribute: String, of element: AXUIElement) throws -> CFTypeRef? {
        var raw: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        if error == .cannotComplete || error == .invalidUIElement {
            _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
            error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        }
        switch error {
        case .success: return raw
        case .noValue, .attributeUnsupported: return nil
        case .apiDisabled: throw AXDriverError.ax(Self.permissionMessage)
        default: throw AXDriverError.ax("读取 \(attribute) 失败（错误码 \(error.rawValue)）")
        }
    }

    private func children(of element: AXUIElement) throws -> [AXUIElement] {
        guard let raw = try copyAttribute(kAXChildrenAttribute as String, of: element) else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func frame(of element: AXUIElement) -> AXFrame? {
        guard let rawPosition = (try? copyAttribute(kAXPositionAttribute as String, of: element)) ?? nil,
              let rawSize = (try? copyAttribute(kAXSizeAttribute as String, of: element)) ?? nil,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point), AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return AXFrame(x: Double(point.x), y: Double(point.y), w: Double(size.width), h: Double(size.height))
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return [] }
        return names as? [String] ?? []
    }

    private func stringValue(_ raw: CFTypeRef?) -> String? {
        guard let raw else { return nil }
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }
}
