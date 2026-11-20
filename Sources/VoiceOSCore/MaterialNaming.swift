import Foundation

public enum MaterialNaming {
    /// 把存储名里的机器时间后缀转成本地可读时间；无法识别的名字原样返回。
    public static func displayName(_ storedName: String, timeZone: TimeZone = .current) -> String {
        let prefixes = ["行动反馈 · ", "我的表达 · "]
        guard let prefix = prefixes.first(where: { storedName.hasPrefix($0) }) else { return storedName }
        let stamp = String(storedName.dropFirst(prefix.count))
        // 保守解析：整串都必须是时间戳，后面多出任何字符都不转换。
        guard stamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression)
                .map({ $0 == stamp.startIndex..<stamp.endIndex }) == true,
              let date = iso8601Date(stamp) else { return storedName }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return prefix + formatter.string(from: date)
    }

    private static func iso8601Date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
