import Darwin
import Foundation
import VoiceOSCore

private let usageText = """
usage: voiceos-cli <command> [options]

commands:
  actions list [--state open|completed|dismissed|someday] [--validity current|frozen]
               [--kind task|opportunity|ai_suggestion] [--limit 1...1000] [--offset n]
  actions show <id> [--include-feedback] [--include-feedback-text] [--include-note] [--topics]
  status

options:
  --root <dir>   资料库目录；默认 $VOICEOS_ROOT，否则 ~/Library/Application Support/VoiceOS
  --json         兼容参数；stdout 始终输出 JSON
  --pretty       缩进 JSON

stdout 只输出 JSON，错误 JSON 写到 stderr。
exit codes: 0 成功, 1 参数或内部错误, 2 未找到, 3 资料库不可用
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
    var includeFeedback = false
    var includeFeedbackText = false
    var includeNote = false
    var topics = false
}

private struct ListOutput: Encodable {
    let actions: [ReadOnlyActionRow]
    let count: Int
}

private func defaultRoot() -> URL {
    if let raw = ProcessInfo.processInfo.environment["VOICEOS_ROOT"], !raw.isEmpty {
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceOS")
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
            let kind = try next(argument)
            guard ["task", "opportunity", "ai_suggestion"].contains(kind) else {
                throw CLIError.usage("--kind 需要 task|opportunity|ai_suggestion")
            }
            options.kind = kind
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
        let library = try ReadOnlyLibrary(root: options.root)
        try write(try library.status(), pretty: options.pretty)
    case ["actions", "list"]:
        guard !(options.includeFeedback || options.includeFeedbackText || options.includeNote || options.topics) else {
            throw CLIError.usage("--include-feedback/--include-feedback-text/--include-note/--topics 只用于 actions show")
        }
        let library = try ReadOnlyLibrary(root: options.root)
        let rows = try library.actions(state: options.state, validity: options.validity, kind: options.kind,
                                       limit: options.limit, offset: options.offset)
        try write(ListOutput(actions: rows, count: rows.count), pretty: options.pretty)
    case let positionals where positionals.count == 3 && positionals[0] == "actions" && positionals[1] == "show":
        let library = try ReadOnlyLibrary(root: options.root)
        guard let detail = try library.action(id: positionals[2],
                                              includeFeedback: options.includeFeedback || options.includeFeedbackText,
                                              includeFeedbackText: options.includeFeedbackText,
                                              includeNote: options.includeNote,
                                              includeTopics: options.topics) else {
            throw CLIError.notFound("未找到行动：\(positionals[2])")
        }
        try write(detail, pretty: options.pretty)
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