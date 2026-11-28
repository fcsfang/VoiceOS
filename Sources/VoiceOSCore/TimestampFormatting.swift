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
    public static let dayKey: DateFormatter = dayFormatter(timeZone: .current, calendar: Calendar(identifier: .gregorian))
    private static let dayFormatters = NSCache<NSString, DateFormatter>()
    /// Day-key strings ("yyyy-MM-dd") for a given zone and calendar. One
    /// implementation serves scheduling, monitoring and reminder dates; the
    /// formatter is cached per zone and calendar identifier.
    public static func dayString(_ date: Date, timeZone: TimeZone = .current,
                                 calendar: Calendar = .current) -> String {
        dayFormatter(timeZone: timeZone, calendar: calendar).string(from: date)
    }
    public static func dayDate(_ text: String, timeZone: TimeZone = .current,
                               calendar: Calendar = .current) -> Date? {
        dayFormatter(timeZone: timeZone, calendar: calendar).date(from: text)
    }
    private static func dayFormatter(timeZone: TimeZone, calendar: Calendar) -> DateFormatter {
        let key = "\(calendar.identifier)|\(timeZone.identifier)" as NSString
        if let cached = dayFormatters.object(forKey: key) { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        dayFormatters.setObject(formatter, forKey: key)
        return formatter
    }
    public static func parse(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? iso.date(from: text)
    }
}
