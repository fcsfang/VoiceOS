import Foundation

public enum MaterialNaming {
    /// 把存储名里的机器时间后缀转成本地可读时间；无法识别的名字原样返回。
    public static func displayName(_ storedName: String, timeZone: TimeZone = .current) -> String {
        guard let prefix = prefixes.first(where: { storedName.hasPrefix($0) }) else { return storedName }
        let stamp = String(storedName.dropFirst(prefix.count))
        // 保守解析：整串都必须是时间戳，后面多出任何字符都不转换。
        let range = NSRange(stamp.startIndex..<stamp.endIndex, in: stamp)
        guard stampPattern.firstMatch(in: stamp, range: range).map({ $0.range == range }) == true,
              let date = iso8601Date(stamp) else { return storedName }
        return prefix + formatter(for: timeZone).string(from: date)
    }

    private static let prefixes = ["行动反馈 · ", "我的表达 · ", "我的口述 · "]
    private static let stampPattern = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#)
    // NSCache 线程安全；按 ID 缓存，测试里的显式时区也走同一份缓存。
    private static let formatters = NSCache<NSString, DateFormatter>()

    private static func formatter(for timeZone: TimeZone) -> DateFormatter {
        let key = timeZone.identifier as NSString
        if let cached = formatters.object(forKey: key) { return cached }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        formatters.setObject(formatter, forKey: key)
        return formatter
    }

    private static func iso8601Date(_ text: String) -> Date? { TimestampFormatting.parse(text) }
}