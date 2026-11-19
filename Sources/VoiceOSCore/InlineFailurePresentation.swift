import Foundation

/// Inline failure copy names the failed operation before a one-line reason, so
/// the notice fits beside the control instead of at the bottom of a long page.
public enum InlineFailurePresentation {
    public static func message(operation: String, reason: String?) -> String {
        let firstLine = (reason ?? "")
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let short: String
        if firstLine.isEmpty {
            short = "请重试。"
        } else if firstLine.count > 60 {
            short = String(firstLine.prefix(60)) + "…"
        } else {
            short = firstLine
        }
        return operation + "失败：" + short
    }
}
