import Foundation

/// Extraction stores its leading bracket marker inside the statement text.
/// Display code splits it off once, here, instead of patching strings per view.
public enum StatementTag: String, CaseIterable, Sendable {
    case insight = "观点"
    case question = "问题"
    case idea = "想法"
    case goal = "长期目标"
    case recordingActivity = "录音中活动"
    case review = "待核对"
}

public struct StatementTagged: Equatable, Sendable {
    public let tag: StatementTag?
    public let text: String
    public init(tag: StatementTag?, text: String) { self.tag = tag; self.text = text }
}

public enum StatementTagParser {
    public static func split(_ raw: String) -> StatementTagged {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var tag: StatementTag?
        if text.hasPrefix("【"), let close = text.firstIndex(of: "】") {
            let name = String(text[text.index(after: text.startIndex)..<close])
            if let parsed = StatementTag(rawValue: name) {
                tag = parsed
                text = String(text[text.index(after: close)...])
            }
        }
        for suffix in ["（待核对）", "(待核对)"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            if tag == nil { tag = .review }
        }
        return StatementTagged(tag: tag, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
