import Foundation

/// Write-back commands an external agent may hand to the running app. Parsing
/// is the boundary: the view only ever receives these typed cases.
public enum ExternalActionCommand: Equatable, Sendable {
    case feedback(actionID: String, text: String, kind: ActionFeedbackKind, commandID: String)
    case complete(actionID: String)
}

public extension ExternalActionCommand {
    static let maximumTextLength = 4000

    /// Returns nil for every `voiceos://action/<id>` URL that is not a
    /// write-back route, so navigation links keep flowing to the old branch.
    static func parse(_ url: URL) throws -> ExternalActionCommand? {
        guard url.scheme?.lowercased() == "voiceos",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "action" else { return nil }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 2 else { return nil }
        let actionID = segments[0]
        guard UUID(uuidString: actionID) != nil else { throw VoiceOSError("行动链接身份不是有效 UUID") }
        let items = components.queryItems ?? []
        switch segments[1].lowercased() {
        case "complete":
            guard items.isEmpty else { throw VoiceOSError("完成链接不接受查询参数") }
            return .complete(actionID: actionID)
        case "feedback":
            var values: [String: String] = [:]
            for item in items {
                guard ["text", "kind", "command"].contains(item.name) else {
                    throw VoiceOSError("反馈链接包含未知参数：\(item.name)")
                }
                guard values[item.name] == nil else { throw VoiceOSError("反馈链接的参数重复：\(item.name)") }
                values[item.name] = item.value ?? ""
            }
            guard let text = values["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceOSError("反馈链接缺少正文")
            }
            guard text.count <= Self.maximumTextLength else {
                throw VoiceOSError("反馈正文最多 \(Self.maximumTextLength) 个字符")
            }
            let rawKind = values["kind"] ?? ActionFeedbackKind.outcome.rawValue
            guard let kind = ActionFeedbackKind(rawValue: rawKind) else {
                throw VoiceOSError("反馈类型只能是 outcome 或 reflection")
            }
            let commandID: String
            if let raw = values["command"] {
                guard UUID(uuidString: raw) != nil else { throw VoiceOSError("反馈命令不是有效 UUID") }
                commandID = raw
            } else {
                commandID = UUID().uuidString
            }
            return .feedback(actionID: actionID, text: text, kind: kind, commandID: commandID)
        default:
            return nil
        }
    }
}