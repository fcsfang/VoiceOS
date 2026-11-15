import Foundation

/// Opt-in startup timeline. Set VOICEOS_STARTUP_TRACE to a file path to append
/// one line per mark: elapsed milliseconds since first touch, tab, label.
public enum StartupTrace {
    private static let started: ContinuousClock.Instant = .now
    private static let writer: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["VOICEOS_STARTUP_TRACE"], !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    public static var isEnabled: Bool { writer != nil }
    public static func mark(_ label: String) {
        guard let writer else { return }
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        writer.write(Data(String(format: "%.1f\t%@\n", ms, label).utf8))
    }
    @discardableResult
    public static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let begin = ContinuousClock.now
        let value = try body()
        write(label, begin)
        return value
    }
    @discardableResult
    public static func measureAsync<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        guard isEnabled else { return try await body() }
        let begin = ContinuousClock.now
        let value = try await body()
        write(label, begin)
        return value
    }
    private static func write(_ label: String, _ begin: ContinuousClock.Instant) {
        let elapsed = begin.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        writer!.write(Data(String(format: "%.1f\t%@\n", ms, label).utf8))
    }
    public struct Token {
        let label: String
        let begin: ContinuousClock.Instant
    }
    public static func begin(_ label: String) -> Token? {
        isEnabled ? Token(label: label, begin: .now) : nil
    }
    public static func end(_ token: Token?) {
        guard let token else { return }
        write(token.label, token.begin)
    }
}
