import Foundation

/// The pool an opportunity belongs to. Extraction proposes one from typed
/// content or the title tag; the user reclassifies through the revision ledger.
public enum ActionNature: String, Codable, Sendable, CaseIterable {
    case question, goal, narration, unknown

    public var label: String {
        switch self {
        case .question: return "问题"
        case .goal: return "目标"
        case .narration: return "旁白"
        case .unknown: return "未归类"
        }
    }
    public init?(label: String) {
        guard let match = Self.allCases.first(where: { $0.label == label }) else { return nil }
        self = match
    }
    /// Typed content wins over the title tag; tags are the fallback for
    /// producers that never carried a content kind.
    public static func derive(title: String, contentKind: CognitiveContentKind?) -> ActionNature {
        if contentKind == .question { return .question }
        switch StatementTagParser.split(title).tag {
        case .question?: return .question
        case .goal?: return .goal
        case .recordingActivity?: return .narration
        default: return .unknown
        }
    }
}
