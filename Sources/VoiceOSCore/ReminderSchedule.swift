import Foundation

/// nil at the snapshot boundary means unknown. `.none` means a confirmed absence.
/// Date-only values are calendar dates, never midnight instants.
public enum ReminderDueDate: Equatable, Sendable, Codable {
    case none
    case dateOnly(localDate: String, timeZone: String?)
    case instant(utc: String, timeZone: String)

    public func validate() throws {
        switch self {
        case .none: return
        case let .dateOnly(date, zone):
            guard Self.calendarDate(date) != nil, zone == nil || TimeZone(identifier: zone!) != nil else {
                throw VoiceOSError("提醒事项日期或时区无效")
            }
        case let .instant(utc, zone):
            guard let date = Self.instantFormatter.date(from: utc), date.timeIntervalSince1970.isFinite,
                  Self.instantFormatter.string(from: date) == utc, TimeZone(identifier: zone) != nil else {
                throw VoiceOSError("提醒事项时刻必须是规范 UTC 与有效时区")
            }
        }
    }
    private static var instantFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
    private static func calendarDate(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let year = Int(parts[0]), (1...9999).contains(year), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let value = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: value) == components else { return nil }
        return components
    }
    /// Unsupported, floating timed, invalid, or ambiguous wall times stay unknown.
    /// Do not infer a timezone from the device's current settings on a retry.
    public static func reading(_ components: DateComponents?) -> ReminderDueDate? {
        guard let components else { return .some(.none) }
        guard components.era == nil || components.era == 1,
              components.calendar == nil || components.calendar?.identifier == .gregorian || components.calendar?.identifier == .iso8601,
              components.isLeapMonth != true,
              let year = components.year, (1...9999).contains(year),
              let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day) else { return nil }
        let dateText = String(format: "%04d-%02d-%02d", year, month, day)
        guard calendarDate(dateText) != nil else { return nil }
        if components.hour == nil, components.minute == nil, components.second == nil, components.nanosecond == nil {
            return .dateOnly(localDate: dateText, timeZone: components.timeZone?.identifier)
        }
        guard let zone = components.timeZone, let hour = components.hour, let minute = components.minute,
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(components.second ?? 0),
              components.nanosecond == nil || components.nanosecond == 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let match = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: components.second ?? 0)
        guard let candidate = calendar.date(from: match), calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: candidate) == match else { return nil }
        let before = calendar.startOfDay(for: candidate).addingTimeInterval(-1)
        guard let first = calendar.nextDate(after: before, matching: match, matchingPolicy: .strict, repeatedTimePolicy: .first),
              let last = calendar.nextDate(after: before, matching: match, matchingPolicy: .strict, repeatedTimePolicy: .last), first == last else { return nil }
        return .instant(utc: instantFormatter.string(from: first), timeZone: zone.identifier)
    }
    /// Only write values that the same connector can read back losslessly.
    public func writableComponents() throws -> DateComponents? {
        try validate()
        switch self {
        case .none: return nil
        case let .dateOnly(text, zone):
            var result = Self.calendarDate(text)!
            result.calendar = Calendar(identifier: .gregorian)
            result.timeZone = zone.flatMap(TimeZone.init(identifier:))
            guard Self.reading(result) == self else { throw VoiceOSError("期限不能无损写入提醒事项") }
            return result
        case let .instant(utc, zone):
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
            var result = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: Self.instantFormatter.date(from: utc)!)
            result.calendar = calendar; result.timeZone = calendar.timeZone
            guard Self.reading(result) == self else { throw VoiceOSError("重复墙上时刻或亚秒期限不能无损核对，停止写入") }
            return result
        }
    }
    public var summary: String {
        switch self {
        case .none: return "未设置期限"
        case let .dateOnly(date, _): return date + " · 仅日期"
        case let .instant(utc, zone):
            guard let date = Self.instantFormatter.date(from: utc), let timeZone = TimeZone(identifier: zone) else { return "期限未能核对" }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date) + " · " + zone
        }
    }
}

public enum ScheduleAuthority: String, Codable, Sendable {
    case aiFlexible = "ai_flexible", userCommitment = "user_commitment", externalManual = "external_manual", unknown
}
/// A resolved proposal keeps its original expression anchor. This type never
/// interprets "tomorrow" using the current clock or converts AI intent to a pledge.
public struct ReminderScheduleProposal: Sendable {
    public let due: ReminderDueDate
    public let authority: ScheduleAuthority
    public let rawExpression: String
    public let anchorEventTime: Date
    public init(due: ReminderDueDate, authority: ScheduleAuthority, rawExpression: String, anchorEventTime: Date) throws {
        try due.validate()
        guard !rawExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rawExpression.unicodeScalars.count <= 2000, anchorEventTime.timeIntervalSince1970.isFinite,
              authority == .aiFlexible || authority == .userCommitment else { throw VoiceOSError("排期提案缺少表达、锚点或归属") }
        self.due = due; self.authority = authority; self.rawExpression = rawExpression; self.anchorEventTime = anchorEventTime
    }
}
public enum ScheduleMergeDisposition: String, Sendable {
    case blocked, unavailable, captureRemote, unchanged, observeRemote, converged, writeFlexible, replanKeepingRemote, requiresConfirmation
}
public struct ReminderScheduleDecision: Sendable {
    public let disposition: ScheduleMergeDisposition
    public let remote: ReminderDueDate?
    public let proposed: ReminderDueDate?
    public let reason: String
}
public enum ReminderScheduleMerge {
    /// Pure field-level policy; `.writeFlexible` is a plan, never a write receipt.
    /// Callers still need durable intent, fresh preflight, authorization and readback.
    public static func decide(base: ReminderDueDate?, baseAuthority: ScheduleAuthority,
                              remote: ReminderDueDate?, desired: ReminderScheduleProposal?,
                              authorized: Bool, actionCurrent: Bool, uniqueIdentity: Bool) throws -> ReminderScheduleDecision {
        try base?.validate(); try remote?.validate(); try desired?.due.validate()
        func result(_ kind: ScheduleMergeDisposition, _ reason: String) -> ReminderScheduleDecision {
            .init(disposition: kind, remote: remote, proposed: desired?.due, reason: reason)
        }
        guard authorized, actionCurrent else { return result(.blocked, "授权或行动依据已失效") }
        guard uniqueIdentity, let remote else { return result(.unavailable, "身份或期限尚未唯一核对；不得当作无期限") }
        guard let base else { return result(.captureRemote, "首次核对只建立外部字段基线") }
        guard let desired else {
            return result(remote == base ? .unchanged : .observeRemote, "没有本地排期意图；保留外部字段及其变化")
        }
        if desired.due == remote { return result(remote == base ? .unchanged : .converged, "双方值一致，无需外写") }
        if desired.due == base { return result(.observeRemote, "仅外部字段变化；不回写旧值，不改变用户原始承诺") }
        let ordinary = baseAuthority == .aiFlexible && desired.authority == .aiFlexible
        guard ordinary else { return result(.requiresConfirmation, "明确承诺、人工字段或归属不明的期限变更须单独确认") }
        if remote == base { return result(.writeFlexible, "仅本地弹性安排变化；执行仍须持久意图与写前后核对") }
        return result(.replanKeepingRemote, "双方变化不同；保留外部人工字段并重新规划弹性安排")
    }
}
