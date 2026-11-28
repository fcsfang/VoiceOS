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
    /// A wall-clock timestamp carrying the given zone's offset (for example
    /// +08:00) instead of Z. Prompt context that states the user's local time
    /// uses this variant; stored identities keep the UTC forms above.
    public static func local(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
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
