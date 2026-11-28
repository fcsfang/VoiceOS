import AppKit
import Darwin
import Foundation
import VoiceOSCore

private let appBundleID = "local.voiceos.app"

private let usageText = """
usage: voiceos-cli <command> [options]

commands:
  actions list [--state open|completed|dismissed|someday] [--validity current|frozen]
               [--kind task|opportunity|ai_suggestion] [--limit 1...1000] [--offset n]
  actions show <id> [--include-feedback] [--include-feedback-text] [--include-note] [--topics]
  action feedback <id> --text <text> [--kind outcome|reflection] [--command <uuid>]
  action complete <id>
  status

options:
  --root <dir>   资料库目录；默认 $VOICEOS_ROOT，否则 ~/Library/Application Support/VoiceOS
                 写回时须与运行中 VoiceOS 打开的资料库一致
  --json         兼容参数；stdout 始终输出 JSON
  --pretty       缩进 JSON

写回经运行中的 VoiceOS app 完成：先交付 voiceos:// 链接，再轮询资料库确认效果。
正文与参数不会写入任何日志。
stdout 只输出 JSON，错误 JSON 写到 stderr。
exit codes: 0 成功, 1 参数或内部错误, 2 未找到, 3 资料库不可用, 4 等待 app 写回超时, 5 app 未运行
"""

private enum CLIError: Error {
    case usage(String)
    case notFound(String)
}

private struct ParsedOptions {
    var positionals: [String] = []
    var root: URL
    var pretty = false
    var limit = 100
    var offset = 0
    var state: String?
    var validity: String?
    var kind: String?
    var text: String?
    var commandID: String?
    var includeFeedback = false
    var includeFeedbackText = false
    var includeNote = false
    var topics = false
}

private struct ListOutput: Encodable {
    let actions: [ReadOnlyActionRow]
    let count: Int
}

private struct FeedbackResult: Encodable {
    let action: String
    let command: String
    let kind: String
    let observed: Bool
    let feedbackCount: Int?
}

private struct CompleteResult: Encodable {
    let action: String
    let observed: Bool
    let state: String
}

private func defaultRoot() -> URL {
    if let raw = ProcessInfo.processInfo.environment["VOICEOS_ROOT"], !raw.isEmpty {
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }
    return LibraryLayout.defaultRoot
}

private func parse(_ arguments: [String]) throws -> ParsedOptions {
    var options = ParsedOptions(root: defaultRoot())
    var index = 0
    func next(_ flag: String) throws -> String {
        guard index < arguments.count else { throw CLIError.usage("\(flag) 需要取值") }
        defer { index += 1 }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        switch argument {
        case "--root":
            options.root = URL(fileURLWithPath: (try next(argument) as NSString).expandingTildeInPath)
        case "--json":
            break
        case "--pretty":
            options.pretty = true
        case "--limit":
            guard let limit = Int(try next(argument)), (1...1000).contains(limit) else {
                throw CLIError.usage("--limit 需要 1...1000 的整数")
            }
            options.limit = limit
        case "--offset":
            guard let offset = Int(try next(argument)), offset >= 0 else {
                throw CLIError.usage("--offset 需要非负整数")
            }
            options.offset = offset
        case "--state":
            let state = try next(argument)
            guard ["open", "completed", "dismissed", "someday"].contains(state) else {
                throw CLIError.usage("--state 需要 open|completed|dismissed|someday")
            }
            options.state = state
        case "--validity":
            let validity = try next(argument)
            guard ["current", "frozen"].contains(validity) else {
                throw CLIError.usage("--validity 需要 current|frozen")
            }
            options.validity = validity
        case "--kind":
            options.kind = try next(argument)
        case "--text":
            options.text = try next(argument)
        case "--command":
            options.commandID = try next(argument)
        case "--include-feedback":
            options.includeFeedback = true
        case "--include-feedback-text":
            options.includeFeedbackText = true
        case "--include-note":
            options.includeNote = true
        case "--topics":
            options.topics = true
        default:
            guard !argument.hasPrefix("-") else { throw CLIError.usage("未知参数：\(argument)") }
            options.positionals.append(argument)
        }
    }
    return options
}

private func validateActionKind(_ kind: String?) throws {
    guard let kind else { return }
    guard ["task", "opportunity", "ai_suggestion"].contains(kind) else {
        throw CLIError.usage("--kind 需要 task|opportunity|ai_suggestion")
    }
}

private func rejectWriteOptions(_ options: ParsedOptions) throws {
    guard options.text == nil, options.commandID == nil else {
        throw CLIError.usage("--text/--command 只用于 action feedback")
    }
}

private func appIsRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
}

private func writeBackURL(actionID: String, route: String, query: [URLQueryItem] = []) throws -> URL {
    var components = URLComponents()
    components.scheme = "voiceos"
    components.host = "action"
    components.path = "/\(actionID)/\(route)"
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw CLIError.usage("无法构造写回链接") }
    return url
}

private func pollLibrary(root: URL, timeout: TimeInterval = 10, interval: TimeInterval = 0.3,
                         until done: (ReadOnlyLibrary) -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let library = try? ReadOnlyLibrary(root: root), done(library) { return true }
        Thread.sleep(forTimeInterval: interval)
    } while Date() < deadline
    return false
}

private func feedbackCount(root: URL, actionID: String) -> Int? {
    guard let library = try? ReadOnlyLibrary(root: root) else { return nil }
    guard let detail = try? library.action(id: actionID) else { return nil }
    return detail.feedbackCount
}

private func runFeedback(actionID: String, options: ParsedOptions) throws {
    guard UUID(uuidString: actionID) != nil else { throw CLIError.usage("行动 ID 需要 UUID") }
    guard let text = options.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError.usage("action feedback 需要 --text")
    }
    guard text.count <= ExternalActionCommand.maximumTextLength else {
        throw CLIError.usage("--text 最多 \(ExternalActionCommand.maximumTextLength) 个字符")
    }
    let kind = options.kind ?? ActionFeedbackKind.outcome.rawValue
    guard ActionFeedbackKind(rawValue: kind) != nil else {
        throw CLIError.usage("--kind 需要 outcome|reflection")
    }
    if let command = options.commandID, UUID(uuidString: command) == nil {
        throw CLIError.usage("--command 需要 UUID")
    }
    let commandID = options.commandID ?? UUID().uuidString
    guard appIsRunning() else {
        fail(code: "app_not_running", message: "VoiceOS 未运行；先启动应用再写回", status: 5)
    }
    guard let before = try ReadOnlyLibrary(root: options.root).action(id: actionID) else {
        throw CLIError.notFound("未找到行动：\(actionID)")
    }
    let url = try writeBackURL(actionID: actionID, route: "feedback", query: [
        URLQueryItem(name: "text", value: text),
        URLQueryItem(name: "kind", value: kind),
        URLQueryItem(name: "command", value: commandID),
    ])
    guard NSWorkspace.shared.open(url) else {
        fail(code: "open_failed", message: "无法把写回链接交给 VoiceOS", status: 1)
    }
    let observed = pollLibrary(root: options.root) { library in
        do {
            guard let detail = try library.action(id: actionID) else { return false }
            return detail.feedbackCount > before.feedbackCount
        } catch { return false }
    }
    guard observed else {
        fail(code: "timeout", message: "等待 VoiceOS 写回反馈超时", status: 4)
    }
    try write(FeedbackResult(action: actionID, command: commandID, kind: kind, observed: true,
                             feedbackCount: feedbackCount(root: options.root, actionID: actionID)),
              pretty: options.pretty)
}

private func runComplete(actionID: String, options: ParsedOptions) throws {
    guard UUID(uuidString: actionID) != nil else { throw CLIError.usage("行动 ID 需要 UUID") }
    guard appIsRunning() else {
        fail(code: "app_not_running", message: "VoiceOS 未运行；先启动应用再写回", status: 5)
    }
    guard let before = try ReadOnlyLibrary(root: options.root).action(id: actionID) else {
        throw CLIError.notFound("未找到行动：\(actionID)")
    }
    if before.state == "completed" {
        try write(CompleteResult(action: actionID, observed: true, state: "completed"), pretty: options.pretty)
        return
    }
    let url = try writeBackURL(actionID: actionID, route: "complete")
    guard NSWorkspace.shared.open(url) else {
        fail(code: "open_failed", message: "无法把写回链接交给 VoiceOS", status: 1)
    }
    let observed = pollLibrary(root: options.root) { library in
        do {
            guard let detail = try library.action(id: actionID) else { return false }
            return detail.state == "completed"
        } catch { return false }
    }
    guard observed else {
        fail(code: "timeout", message: "等待 VoiceOS 标记完成超时", status: 4)
    }
    try write(CompleteResult(action: actionID, observed: true, state: "completed"), pretty: options.pretty)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty { throw CLIError.usage(usageText) }
    if arguments.contains("--help") || arguments.contains("-h") {
        print(usageText)
        return
    }
    let options = try parse(arguments)
    switch options.positionals {
    case ["status"]:
        try rejectWriteOptions(options)
        try validateActionKind(options.kind)
        let library = try ReadOnlyLibrary(root: options.root)
        try write(try library.status(), pretty: options.pretty)
    case ["actions", "list"]:
        try rejectWriteOptions(options)
        try validateActionKind(options.kind)
        guard !(options.includeFeedback || options.includeFeedbackText || options.includeNote || options.topics) else {
            throw CLIError.usage("--include-feedback/--include-feedback-text/--include-note/--topics 只用于 actions show")
        }
        let library = try ReadOnlyLibrary(root: options.root)
        let rows = try library.actions(state: options.state, validity: options.validity, kind: options.kind,
                                       limit: options.limit, offset: options.offset)
        try write(ListOutput(actions: rows, count: rows.count), pretty: options.pretty)
    case let positionals where positionals.count == 3 && positionals[0] == "actions" && positionals[1] == "show":
        try rejectWriteOptions(options)
        try validateActionKind(options.kind)
        let library = try ReadOnlyLibrary(root: options.root)
        guard let detail = try library.action(id: positionals[2],
                                              includeFeedback: options.includeFeedback || options.includeFeedbackText,
                                              includeFeedbackText: options.includeFeedbackText,
                                              includeNote: options.includeNote,
                                              includeTopics: options.topics) else {
            throw CLIError.notFound("未找到行动：\(positionals[2])")
        }
        try write(detail, pretty: options.pretty)
    case let positionals where positionals.count == 3 && positionals[0] == "action" && positionals[1] == "feedback":
        try runFeedback(actionID: positionals[2], options: options)
    case let positionals where positionals.count == 3 && positionals[0] == "action" && positionals[1] == "complete":
        try rejectWriteOptions(options)
        try runComplete(actionID: positionals[2], options: options)
    default:
        throw CLIError.usage(usageText)
    }
}

private func encoder(pretty: Bool) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty
        ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        : [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

private func write<T: Encodable>(_ value: T, pretty: Bool) throws {
    var data = try encoder(pretty: pretty).encode(value)
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

private func fail(code: String, message: String, status: Int32) -> Never {
    struct Detail: Encodable { let code: String; let message: String }
    struct Body: Encodable { let error: Detail }
    if let data = try? encoder(pretty: false).encode(Body(error: Detail(code: code, message: message))) {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data([0x0A]))
    }
    exit(status)
}

@main
struct VoiceOSCLI {
    static func main() {
        do {
            try run()
        } catch let error as CLIError {
            switch error {
            case let .usage(message): fail(code: "usage", message: message, status: 1)
            case let .notFound(message): fail(code: "not_found", message: message, status: 2)
            }
        } catch let error as ReadOnlyLibraryError {
            fail(code: "unavailable", message: error.localizedDescription, status: 3)
        } catch {
            fail(code: "internal", message: error.localizedDescription, status: 1)
        }
    }
}