import Foundation

/// The one place ISO 8601 formatters are configured. A fractional formatter
/// does not parse plain timestamps, so parsing tries fractional first and
/// falls back to the plain form.
public enum TimestampFormatting {
    public static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    public static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    public static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    public static func parse(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? iso.date(from: text)
    }
}
