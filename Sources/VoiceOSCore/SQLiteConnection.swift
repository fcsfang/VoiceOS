import Foundation
import CSQLite

/// Owns one SQLite handle. Callers supply their concurrency and transaction policy.
final class SQLiteConnection {
    enum Access {
        case readOnly
        case readWriteCreate

        fileprivate var flags: Int32 {
            switch self {
            case .readOnly: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            case .readWriteCreate: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            }
        }
    }

    private let handle: OpaquePointer
    private let access: Access

    init(_ url: URL, access: Access, openError: @autoclosure () -> any Error) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, access.flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw openError()
        }
        self.handle = handle
        self.access = access
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    var totalChanges: Int64 { sqlite3_total_changes64(handle) }
    var lastChangeCount: Int { Int(sqlite3_changes(handle)) }
    var schemaVersion: Int {
        get throws { try query("PRAGMA user_version").first?["user_version"].flatMap(Int.init) ?? -1 }
    }

    @discardableResult
    func query(_ sql: String, _ arguments: [String?] = []) throws -> [[String: String]] {
        var rows: [[String: String]] = []
        try forEachRow(sql, arguments) { rows.append($0) }
        return rows
    }

    func forEachRow(_ sql: String, _ arguments: [String?] = [],
                    _ visit: ([String: String]) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error(sql) }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in arguments.enumerated() {
            let parameter = Int32(index + 1)
            let code: Int32
            if let value {
                guard value.utf8.count < Int(Int32.max) else { throw VoiceOSError("资料字段过大") }
                code = value.utf8CString.withUnsafeBufferPointer { bytes in
                    sqlite3_bind_text(statement, parameter, bytes.baseAddress, Int32(bytes.count - 1), transient)
                }
            } else {
                code = sqlite3_bind_null(statement, parameter)
            }
            guard code == SQLITE_OK else {
                throw access == .readOnly ? VoiceOSError("查询参数绑定失败") : error()
            }
        }

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw error(sql) }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, index) != SQLITE_NULL {
                let key = String(cString: sqlite3_column_name(statement, index))
                if let value = sqlite3_column_text(statement, index) {
                    let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index)))
                    row[key] = String(decoding: bytes, as: UTF8.self)
                }
            }
            visit(row)
        }
    }

    func copyPages(to destination: SQLiteConnection) throws {
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw VoiceOSError("无法开始资料库备份")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw VoiceOSError("备份完整性校验失败")
        }
    }

    private func error(_ sql: String? = nil) -> VoiceOSError {
        let message = String(cString: sqlite3_errmsg(handle))
        if access == .readOnly { return VoiceOSError("查询失败：\(message)") }
        guard let sql else { return VoiceOSError("资料库错误：\(message)") }
        let statement = sql.split(whereSeparator: \.isWhitespace).prefix(14).joined(separator: " ")
        return VoiceOSError("资料库错误：\(message)｜\(statement)")
    }
}
