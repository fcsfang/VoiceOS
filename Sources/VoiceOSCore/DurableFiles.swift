import Foundation
import CryptoKit
import Darwin

// Held for the store lifetime; separate instances/processes cannot process the same jobs.
final class StoreLock {
    let fd: Int32
    init(_ url: URL) throws {
        fd = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw VoiceOSError("无法建立资料库锁") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw VoiceOSError("此资料库已由另一个 VoiceOS 实例使用") }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
enum DurableFiles {
    static func hash(_ url: URL) throws -> (Int64, String) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256(); var bytes: Int64 = 0
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data); bytes += Int64(data.count) }
        return (bytes, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw VoiceOSError("无法打开保存目录") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw VoiceOSError("无法确认目录保存完成") }
    }
    static func copy(_ input: URL, to output: URL, checkpoint: (SaveCheckpoint) throws -> Void) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw VoiceOSError("无法建立新的媒体副本") }
        let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? writer.close() }
        var first = true
        while let chunk = try reader.read(upToCount: 65536), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
            if first { try writer.synchronize(); try checkpoint(.copyChunk); first = false }
        }
        try writer.synchronize()
        try syncDirectory(output.deletingLastPathComponent())
    }
}
