import Foundation
import Darwin
import CSQLite

public struct LibraryStorageUsage: Sendable, Equatable {
    public let databaseBytes: Int64
    /// nil means the category exists but its directory could not be enumerated;
    /// zero means the directory is absent. The two must stay distinguishable so
    /// the settings page can say "无法读取" instead of showing a fake zero.
    public let assetsBytes: Int64?
    public let backupBytes: Int64?
    public let localSpeechBytes: Int64?
    public let mirrorBytes: Int64?
    public let backupCount: Int
    public var totalBytes: Int64? {
        guard let assetsBytes, let backupBytes, let localSpeechBytes, let mirrorBytes else { return nil }
        return databaseBytes + assetsBytes + backupBytes + localSpeechBytes + mirrorBytes
    }
    public init(databaseBytes: Int64, assetsBytes: Int64?, backupBytes: Int64?, localSpeechBytes: Int64?, mirrorBytes: Int64?, backupCount: Int) {
        self.databaseBytes = databaseBytes
        self.assetsBytes = assetsBytes
        self.backupBytes = backupBytes
        self.localSpeechBytes = localSpeechBytes
        self.mirrorBytes = mirrorBytes
        self.backupCount = backupCount
    }
}

public enum DatabaseBackup {
    public struct Summary: Sendable, Equatable {
        public let date: Date
        public let count: Int
    }

    /// Distinguishes "no backups yet" from "the directory exists but cannot be
    /// read"; both used to collapse to a nil summary and show "尚未生成备份".
    public enum BackupAvailability: Sendable, Equatable {
        case none
        case unreadable
        case summary(Summary)
    }

    private static let metaFileName = ".backup-meta"

    public static func successText(at date: Date, count: Int) -> String {
        "最近备份 " + date.formatted(date: .abbreviated, time: .shortened) + " · 共 \(count) 份"
    }

    public static func failureText(_ error: Error) -> String {
        "备份失败：" + error.localizedDescription
    }

    public static func summary(directory: URL) -> Summary? {
        if case .summary(let summary) = availability(directory: directory) { return summary }
        return nil
    }

    public static func availability(directory: URL, fileManager: FileManager = .default) -> BackupAvailability {
        guard fileManager.fileExists(atPath: directory.path) else { return .none }
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("voiceos-") && $0.pathExtension == "sqlite" }
        } catch {
            return .unreadable
        }
        guard !files.isEmpty else { return .none }
        let latest = files.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max() ?? .distantPast
        return .summary(Summary(date: latest, count: files.count))
    }

    public static func lastBackupDate(directory: URL) -> Date? {
        summary(directory: directory)?.date
    }

    public static func backupCount(directory: URL) -> Int {
        summary(directory: directory)?.count ?? 0
    }

    public static func storageUsage(root: URL, fileManager: FileManager = .default) -> LibraryStorageUsage {
        let database = root.appendingPathComponent("voiceos.sqlite")
        let databaseBytes = ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let attributes = try? fileManager.attributesOfItem(atPath: database.path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        return LibraryStorageUsage(
            databaseBytes: databaseBytes,
            assetsBytes: directoryBytes(at: root.appendingPathComponent("assets", isDirectory: true), fileManager: fileManager),
            backupBytes: directoryBytes(at: backups, fileManager: fileManager),
            localSpeechBytes: directoryBytes(at: root.appendingPathComponent("LocalSpeech", isDirectory: true), fileManager: fileManager),
            mirrorBytes: directoryBytes(at: root.appendingPathComponent("Mirror", isDirectory: true), fileManager: fileManager),
            backupCount: backupFiles(directory: backups).count)
    }

    /// Absent directory is zero bytes; a directory that exists but cannot be
    /// enumerated returns nil so the caller can show "无法读取" instead of 0.
    public static func directoryBytes(at url: URL, fileManager: FileManager = .default) -> Int64? {
        // Foundation 的 enumerator 在遇到指向目录的符号链接并 skipDescendants 时
        // 会连带跳过后续兄弟目录的子项，这里改用手写递归。
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey],
            options: []
        ) else { return nil }
        var total: Int64 = 0
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            } else if values.isDirectory == true {
                guard let nested = directoryBytes(at: entry, fileManager: fileManager) else { return nil }
                total += nested
            }
        }
        return total
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

    public struct SourceAssetScan: Sendable {
        public let sourceCount: Int
        public let missing: [String]
        public init(sourceCount: Int, missing: [String]) {
            self.sourceCount = sourceCount
            self.missing = missing
        }
    }

    public struct BackupVerification: Sendable {
        public let file: URL?
        public let date: Date?
        public let count: Int
        public let ok: Bool
        public init(file: URL?, date: Date?, count: Int, ok: Bool) {
            self.file = file
            self.date = date
            self.count = count
            self.ok = ok
        }
    }

    /// Walks the backup's b-tree pages without a full integrity pass. Used by
    /// the library check so a 270 MB backup stays cheap to verify repeatedly.
    public static func quickCheck(at url: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: value) == "ok"
    }

    public static func latestBackupFile(directory: URL) -> URL? {
        backupFiles(directory: directory).max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    public static func verifyLatestBackup(directory: URL) -> BackupVerification {
        let count = backupCount(directory: directory)
        guard let latest = latestBackupFile(directory: directory) else {
            return BackupVerification(file: nil, date: nil, count: count, ok: false)
        }
        let date = try? latest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return BackupVerification(file: latest, date: date, count: count, ok: quickCheck(at: latest))
    }

    /// Read-only enumeration of the originals recorded in `assets`. Missing
    /// files are returned as relative paths so the caller can name key items.
    public static func scanSourceAssets(database: URL, root: URL) throws -> SourceAssetScan {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw VoiceOSError("无法只读打开资料库：" + database.path)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT relative_path FROM assets", -1, &statement, nil) == SQLITE_OK else {
            throw VoiceOSError("无法读取原件清单：" + database.path)
        }
        defer { sqlite3_finalize(statement) }
        var count = 0
        var missing: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            count += 1
            let relative = String(cString: raw)
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) {
                missing.append(relative)
            }
        }
        return SourceAssetScan(sourceCount: count, missing: missing)
    }

    /// Builds a new library root from the newest backup database plus clones of
    /// the current library's originals. The current library is only read.
    public static func createLibraryFromLatestBackup(currentRoot: URL, destination: URL) throws -> URL {
        let backupDirectory = currentRoot.appendingPathComponent("Backups", isDirectory: true)
        guard let backup = latestBackupFile(directory: backupDirectory) else {
            throw VoiceOSError("还没有可用于恢复的备份（\(backupDirectory.path)）")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw VoiceOSError("新资料库位置已存在，请换一个名称（\(destination.path)）")
        }
        let currentPath = currentRoot.standardizedFileURL.path
        let targetPath = destination.standardizedFileURL.path
        guard targetPath != currentPath, !targetPath.hasPrefix(currentPath + "/") else {
            throw VoiceOSError("新资料库不能放在当前资料库目录内（\(destination.path)）")
        }
        guard quickCheck(at: backup) else {
            throw VoiceOSError("最近备份未通过完整性抽查，不能用来新建资料库（\(backup.path)）")
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let database = destination.appendingPathComponent("voiceos.sqlite")
            guard cloneOrCopy(backup, to: database), quickCheck(at: database) else {
                throw VoiceOSError("无法复制备份数据库")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
            let assets = destination.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let sourceAssets = currentRoot.appendingPathComponent("assets", isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(at: sourceAssets, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            for file in files {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard cloneOrCopy(file, to: assets.appendingPathComponent(file.lastPathComponent)) else {
                    throw VoiceOSError("无法复制原件：" + file.lastPathComponent)
                }
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw VoiceOSError("无法从最近备份建立新资料库：\(error.localizedDescription)（位置：\(destination.path)）")
        }
    }

    private static func cloneOrCopy(_ source: URL, to destination: URL) -> Bool {
        if clonefile(source.path, destination.path, 0) == 0 { return true }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch { return false }
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

    @discardableResult
    public static func prune(directory: URL, retain: Int) throws -> Int {
        guard retain >= 1 else { throw VoiceOSError("备份保留数量至少为 1") }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("voiceos-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count > retain else { return 0 }
        let expired = files.prefix(files.count - retain)
        for file in expired {
            try FileManager.default.removeItem(at: file)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: file.path + suffix)
            }
        }
        return expired.count
    }

    @discardableResult
    public static func removeOrphanSidecars(directory: URL) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        let names = Set(entries.map(\.lastPathComponent))
        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            let base: String
            if name.hasSuffix(".sqlite-wal") {
                base = String(name.dropLast(".sqlite-wal".count)) + ".sqlite"
            } else if name.hasSuffix(".sqlite-shm") {
                base = String(name.dropLast(".sqlite-shm".count)) + ".sqlite"
            } else {
                continue
            }
            guard name.hasPrefix("voiceos-"), !names.contains(base) else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
                removed += 1
            } catch {}
        }
        return removed
    }
}
