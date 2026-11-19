import XCTest
import Foundation
@testable import VoiceOSCore

final class StorageUsageChecks: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("voiceos-storage-" + UUID().uuidString)
        outside = base.appendingPathComponent("voiceos-storage-outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    private func write(_ relative: String, bytes: Int, root base: URL? = nil) throws {
        let url = try XCTUnwrap(base ?? root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    func testStorageUsageCountsCategoriesAndSkipsSymlinks() throws {
        try write("voiceos.sqlite", bytes: 100)
        try write("voiceos.sqlite-wal", bytes: 20)
        try write("voiceos.sqlite-shm", bytes: 5)
        try write("assets/a.bin", bytes: 200)
        try write("assets/nested/b.bin", bytes: 30)
        try write("Backups/voiceos-20260101-000000.sqlite", bytes: 40)
        try write("Backups/voiceos-20260102-000000.sqlite", bytes: 60)
        try write("Backups/voiceos-20260101-000000.sqlite-wal", bytes: 4)
        try write("LocalSpeech/model.safetensors", bytes: 300)
        try write("Mirror/materials/x.md", bytes: 7)
        try write("target.bin", bytes: 999, root: outside)
        try write("target/big.bin", bytes: 500, root: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("assets/linked.bin"),
                                                   withDestinationURL: outside.appendingPathComponent("target.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("assets/linked-directory"),
                                                   withDestinationURL: outside.appendingPathComponent("target"))

        let usage = DatabaseBackup.storageUsage(root: root)
        XCTAssertEqual(usage.databaseBytes, 125)
        XCTAssertEqual(usage.assetsBytes, 230)
        XCTAssertEqual(usage.backupBytes, 104)
        XCTAssertEqual(usage.localSpeechBytes, 300)
        XCTAssertEqual(usage.mirrorBytes, 7)
        XCTAssertEqual(usage.backupCount, 2)
        XCTAssertEqual(usage.totalBytes, 766)
    }

    func testDirectoryBytesReturnsZeroForMissingDirectory() {
        XCTAssertEqual(DatabaseBackup.directoryBytes(at: root.appendingPathComponent("absent")), 0)
    }

    func testPruneRemovesSidecarsWithExpiredBackups() throws {
        let directory = root.appendingPathComponent("Backups")
        for index in 1...5 {
            try write(String(format: "Backups/voiceos-%02d.sqlite", index), bytes: 10)
        }
        for index in 1...2 {
            try write(String(format: "Backups/voiceos-%02d.sqlite-wal", index), bytes: 2)
            try write(String(format: "Backups/voiceos-%02d.sqlite-shm", index), bytes: 2)
        }

        let removed = try DatabaseBackup.prune(directory: directory, retain: 3)
        XCTAssertEqual(removed, 2)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertFalse(names.contains("voiceos-01.sqlite"))
        XCTAssertFalse(names.contains("voiceos-01.sqlite-wal"))
        XCTAssertFalse(names.contains("voiceos-01.sqlite-shm"))
        XCTAssertFalse(names.contains("voiceos-02.sqlite"))
        XCTAssertFalse(names.contains("voiceos-02.sqlite-wal"))
        XCTAssertFalse(names.contains("voiceos-02.sqlite-shm"))
        XCTAssertTrue(names.contains("voiceos-03.sqlite"))
        XCTAssertTrue(names.contains("voiceos-05.sqlite"))
        XCTAssertEqual(try DatabaseBackup.prune(directory: directory, retain: 3), 0)
    }

    func testOrphanSidecarSweepLeavesPairedAndForeignFiles() throws {
        let directory = root.appendingPathComponent("Backups")
        try write("Backups/voiceos-01.sqlite", bytes: 10)
        try write("Backups/voiceos-01.sqlite-wal", bytes: 2)
        try write("Backups/voiceos-01.sqlite-shm", bytes: 2)
        try write("Backups/voiceos-02.sqlite-wal", bytes: 2)
        try write("Backups/voiceos-02.sqlite-shm", bytes: 2)
        try write("Backups/other.sqlite-wal", bytes: 2)

        XCTAssertEqual(DatabaseBackup.removeOrphanSidecars(directory: directory), 2)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertTrue(names.contains("voiceos-01.sqlite-wal"))
        XCTAssertTrue(names.contains("voiceos-01.sqlite-shm"))
        XCTAssertFalse(names.contains("voiceos-02.sqlite-wal"))
        XCTAssertFalse(names.contains("voiceos-02.sqlite-shm"))
        XCTAssertTrue(names.contains("other.sqlite-wal"))
    }

    func testOrphanSidecarSweepSkipsMissingDirectory() {
        XCTAssertEqual(DatabaseBackup.removeOrphanSidecars(directory: root.appendingPathComponent("absent")), 0)
    }

    func testUnreadableDirectoryReportsNilBytesAndUsage() throws {
        try write("assets/a.bin", bytes: 12)
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: assets.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: assets.path) }
        guard DatabaseBackup.directoryBytes(at: assets) == nil else {
            throw XCTSkip("当前环境无法模拟不可读目录（可能以 root 运行）")
        }
        let usage = DatabaseBackup.storageUsage(root: root)
        XCTAssertNil(usage.assetsBytes, "读不到的原件目录应报告失败而不是 0")
        XCTAssertNil(usage.totalBytes, "任一分类不可读时合计不能当作完整数字")
        XCTAssertEqual(usage.mirrorBytes, 0, "不存在的目录仍按 0 计算")
    }

    func testBackupAvailabilityDistinguishesMissingFromUnreadable() throws {
        let backups = root.appendingPathComponent("Backups")
        XCTAssertEqual(DatabaseBackup.availability(directory: backups), .none)

        try write("Backups/voiceos-20260101-000000.sqlite", bytes: 10)
        guard case .summary(let summary) = DatabaseBackup.availability(directory: backups) else {
            return XCTFail("有备份文件时应返回摘要")
        }
        XCTAssertEqual(summary.count, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: backups.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backups.path) }
        guard DatabaseBackup.availability(directory: backups) == .unreadable else {
            throw XCTSkip("当前环境无法模拟不可读目录（可能以 root 运行）")
        }
    }
}
