import Foundation
import Darwin
import CSQLite

public enum DatabaseBackup {
    public struct Summary: Sendable, Equatable {
        public let date: Date
        public let count: Int
    }

    private static let metaFileName = ".backup-meta"

    public static func successText(at date: Date, count: Int) -> String {
        "最近备份 " + date.formatted(date: .abbreviated, time: .shortened) + " · 共 \(count) 份"
    }

    public static func failureText(_ error: Error) -> String {
        "备份失败：" + error.localizedDescription
    }

    public static func summary(directory: URL) -> Summary? {
        let files = backupFiles(directory: directory)
        guard !files.isEmpty else { return nil }
        let latest = files.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max() ?? .distantPast
        return Summary(date: latest, count: files.count)
    }

    public static func lastBackupDate(directory: URL) -> Date? {
        summary(directory: directory)?.date
    }

    public static func backupCount(directory: URL) -> Int {
        summary(directory: directory)?.count ?? 0
    }

    /// Creates at most one backup per local day. The day marker lives next to
    /// the backups so it survives restarts; existing files cover the case where
    /// the marker is missing.
    @discardableResult
    public static func createDailyIfNeeded(database: URL, directory: URL, retain: Int = 7, now: Date = Date(), calendar: Calendar = .current) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let today = dayKey(now, calendar: calendar)
        if lastBackupDay(directory: directory, calendar: calendar) == today { return nil }
        let created = try create(database: database, directory: directory, retain: retain, now: now)
        if let data = (today + "\n").data(using: .utf8) {
            try? data.write(to: directory.appendingPathComponent(metaFileName), options: .atomic)
        }
        return created
    }

    @discardableResult
    public static func create(database: URL, directory: URL, retain: Int = 7, now: Date = Date()) throws -> URL {
        guard retain >= 1 else { throw VoiceOSError("备份保留数量至少为 1") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = uniqueDestination(directory: directory, now: now)
        if cloneCopy(database: database, destination: destination) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: now], ofItemAtPath: destination.path)
            try prune(directory: directory, retain: retain)
            return destination
        }
        discard(destination)
        var source: OpaquePointer?
        guard sqlite3_open_v2(database.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(source)
            throw VoiceOSError("无法只读打开资料库")
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 5000)
        var target: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(target)
            discard(destination)
            throw VoiceOSError("无法建立备份文件")
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else {
            discard(destination)
            throw VoiceOSError("无法开始资料库备份")
        }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE,
              sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK,
              integrityOK(target) else {
            discard(destination)
            throw VoiceOSError("备份完整性校验失败")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try prune(directory: directory, retain: retain)
        return destination
    }

    public static func integrityCheck(at url: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        return integrityOK(handle)
    }

    /// APFS clone of the main database file. A WAL-mode database is consistent
    /// at its last checkpoint, so the clone is a point-in-time snapshot. The
    /// integrity check rejects a copy taken during a checkpoint; the caller
    /// then falls back to the SQLite backup API.
    private static func cloneCopy(database: URL, destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: database.path),
              clonefile(database.path, destination.path, 0) == 0 else { return false }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        guard sqlite3_exec(handle, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK,
              integrityOK(handle) else { return false }
        return true
    }

    private static func backupFiles(directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("voiceos-") && $0.pathExtension == "sqlite" } ?? []
    }

    private static func lastBackupDay(directory: URL, calendar: Calendar) -> String? {
        let meta = directory.appendingPathComponent(metaFileName)
        if let stored = try? String(contentsOf: meta, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        return summary(directory: directory).map { dayKey($0.date, calendar: calendar) }
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func uniqueDestination(directory: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        var destination = directory.appendingPathComponent("voiceos-\(stamp).sqlite")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("voiceos-\(stamp)-\(suffix).sqlite")
            suffix += 1
        }
        return destination
    }

    private static func integrityOK(_ handle: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: value) == "ok"
    }

    private static func discard(_ destination: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: destination.path + suffix)
        }
    }

    private static func prune(directory: URL, retain: Int) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("voiceos-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count > retain else { return }
        for file in files.prefix(files.count - retain) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
