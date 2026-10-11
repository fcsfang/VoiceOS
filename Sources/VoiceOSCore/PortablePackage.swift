import Foundation

private struct PackageFile: Codable {
    let path: String
    let bytes: Int64
    let sha256: String
}
private struct PackageManifest: Codable {
    let format: String
    let version: Int
    let databaseSchema: Int
    let createdAt: String
    let mediaIncluded: Bool
    let counts: [String: Int]
    let files: [PackageFile]
    let omittedAssetIDs: [String]
}
private enum PackageLayout {
    static let legacyTables = ["sources", "assets", "jobs", "transcripts"]
    static let version2Tables = legacyTables + ["transcript_versions", "transcript_revisions"]
    static let version3Tables = version2Tables + ["contexts", "context_inputs", "model_attempts", "claims"]
    static let version4Tables = version3Tables + ["source_policy_revisions"]
    static let version5Tables = version4Tables + ["claim_reviews"]
    static let version6Tables = version5Tables + ["actions", "action_revisions"]
    static let version9Tables = version6Tables + ["reminder_links", "reminder_observations"]
    static let version10Tables = version9Tables + ["action_feedback"]
    static let version11Tables = version10Tables + ["relevance_attempts", "relevance_inputs"]
    static let version13Tables = version11Tables + ["cognitive_feedback_ignores", "cognitive_feedback_preferences"]
    static let version14Tables = version13Tables + ["conversations", "conversation_user_turns"]
    static let tables = version14Tables + ["discussion_attempts"]
    static func tables(for version: Int) -> [String] {
        switch version {
        case 1: return legacyTables
        case 2: return version2Tables
        case 3: return version3Tables
        case 4: return version4Tables
        case 5: return version5Tables
        case 6: return version6Tables
        case 7...9: return version9Tables
        case 10: return version10Tables
        case 11: return version11Tables
        case 12...13: return version13Tables
        case 14: return version14Tables
        default: return tables
        }
    }
    static let integerFields: Set<String> = ["auto_send", "sequence", "action_version", "completed", "marker_valid", "claim_review_version", "review_version", "policy_version", "from_version", "to_version", "from_local_only", "to_local_only", "ordinal", "version", "version_no", "expected_bytes", "local_only", "bytes", "attempts"]
    static func json(_ row: [String: String]) -> [String: Any] {
        row.reduce(into: [String: Any]()) { out, pair in
            if integerFields.contains(pair.key), let number = Int64(pair.value) { out[pair.key] = number }
            else if pair.key == "duration", let number = Double(pair.value) { out[pair.key] = number }
            else { out[pair.key] = pair.value }
        }
    }
    static func digest(_ url: URL, path: String) throws -> PackageFile {
        let (bytes, hash) = try DurableFiles.hash(url)
        return PackageFile(path: path, bytes: bytes, sha256: hash)
    }
    static func safeFile(_ base: URL, _ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw VoiceOSError("迁移包含非法路径") }
        let canonicalBase = base.standardizedFileURL.resolvingSymlinksInPath()
        let file = canonicalBase.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(canonicalBase.path + "/"), file.resolvingSymlinksInPath() == file else { throw VoiceOSError("迁移包不能包含符号链接或目录逃逸") }
        return file
    }
}
public struct PackageSummary: Sendable {
    public let version: Int
    public let createdAt: String
    public let sourceCount: Int
    public let omittedAssetCount: Int
    public let mediaIncluded: Bool
}
extension VoiceOSStore {
    /// Metadata preview only; restore still verifies every file and record.
    public static func packageSummary(at package: URL) throws -> PackageSummary {
        let file = try PackageLayout.safeFile(package, "manifest.json")
        guard let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize, size > 0, size <= 1048576 else { throw VoiceOSError("迁移清单过大或为空") }
        let manifest = try JSONDecoder().decode(PackageManifest.self,from:Data(contentsOf:file))
        guard manifest.format == "VoiceOS-local-package", (1...15).contains(manifest.version), manifest.databaseSchema == manifest.version + 1,
              let count = manifest.counts["sources"], count >= 0, manifest.counts.values.allSatisfy({ $0 >= 0 && $0 <= 1000000 }) else { throw VoiceOSError("不支持此迁移包格式或记录数量") }
        return PackageSummary(version:manifest.version,createdAt:manifest.createdAt,sourceCount:count,omittedAssetCount:manifest.omittedAssetIDs.count,mediaIncluded:manifest.mediaIncluded)
    }
    /// A synchronous actor turn snapshots rows and immutable media together.
    /// Includes external mapping/history, never credentials or live authorization.
    public func exportPackage(to destination: URL, includeMedia: Bool = false) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw VoiceOSError("导出目录已存在，请选择新目录") }
        guard try db.query("SELECT id FROM sources WHERE input_fingerprint LIKE 'microphone-v1:%' AND state='receiving' AND expected_bytes=0").isEmpty else { throw VoiceOSError("请先停止并封存录制，再导出资料") }
        var rows: [String: [[String: String]]] = [:]
        try db.transaction {
            for table in PackageLayout.tables { rows[table] = try db.query("SELECT * FROM \(table) ORDER BY id") }
        }
        if includeMedia {
            for source in rows["sources"]! where source["input_fingerprint"] == "microphone-v1:"+source["id"]! && source["expected_bytes"] == "0" {
                let draft = root.appendingPathComponent("staging/"+source["asset_id"]!+".part.caf")
                guard !FileManager.default.fileExists(atPath:draft.path) else { throw VoiceOSError("存在未封存录制片段，请先核对；原件打包不会静默遗漏这些片段") }
            }
        }
        let sourceStates = Dictionary(uniqueKeysWithValues: rows["sources"]!.map { ($0["id"]!, $0["state"]!) })
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".voiceos-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var files: [PackageFile] = []; var omissions: [String] = []; var counts: [String: Int] = [:]
            for table in PackageLayout.tables {
                let name = "\(table).jsonl"
                let file = temporary.appendingPathComponent(name)
                var data = Data()
                for row in rows[table]! {
                    data.append(try JSONSerialization.data(withJSONObject: PackageLayout.json(row), options: [.sortedKeys]))
                    data.append(0x0A)
                }
                try data.write(to: file, options: .withoutOverwriting)
                try syncFile(file)
                files.append(try PackageLayout.digest(file, path: name)); counts[table] = rows[table]!.count
            }
            if includeMedia { try FileManager.default.createDirectory(at: temporary.appendingPathComponent("assets"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            for asset in rows["assets"]! {
                guard includeMedia, sourceStates[asset["source_id"]!] == "saved" else { omissions.append(asset["id"]!); continue }
                let sourceFile = try PackageLayout.safeFile(root, asset["relative_path"]!)
                let actual = try DurableFiles.hash(sourceFile)
                guard actual.0 == Int64(asset["bytes"]!), actual.1 == asset["sha256"] else { throw VoiceOSError("原件校验失败，未完成导出") }
                let output = try PackageLayout.safeFile(temporary, asset["relative_path"]!)
                try DurableFiles.copy(sourceFile, to: output, checkpoint: { _ in })
                let verified = try PackageLayout.digest(output, path: asset["relative_path"]!)
                guard verified.sha256 == actual.1, verified.bytes == actual.0 else { throw VoiceOSError("导出副本校验失败") }
                files.append(verified)
            }
            if includeMedia { try DurableFiles.syncDirectory(temporary.appendingPathComponent("assets")) }
            let manifest = PackageManifest(format: "VoiceOS-local-package", version: 15, databaseSchema: 16, createdAt: ISO8601DateFormatter().string(from: Date()), mediaIncluded: includeMedia, counts: counts, files: files, omittedAssetIDs: omissions.sorted())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestFile = temporary.appendingPathComponent("manifest.json")
            try encoder.encode(manifest).write(to: manifestFile, options: .withoutOverwriting)
            try syncFile(manifestFile)
            try DurableFiles.syncDirectory(temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try DurableFiles.syncDirectory(destination.deletingLastPathComponent())
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    /// Restore into a new empty directory only. Validate in a sibling scratch root before atomic placement.
    /// Pending jobs are paused; no restored data can trigger external writes.
    public static func restorePackage(from package: URL, to destination: URL, inspector: any MediaInspector) async throws {
        let package = package.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw VoiceOSError("恢复目标必须是新的空目录；现有资料库不会被覆盖") }
        let manifestURL = try PackageLayout.safeFile(package, "manifest.json")
        let manifest = try JSONDecoder().decode(PackageManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.format == "VoiceOS-local-package", (1...15).contains(manifest.version), manifest.databaseSchema == manifest.version + 1 else { throw VoiceOSError("不支持此迁移包格式") }
        let tables = PackageLayout.tables(for: manifest.version)
        guard Set(manifest.files.map(\.path)).count == manifest.files.count,
              Set(manifest.counts.keys) == Set(tables),
              Set(manifest.omittedAssetIDs).count == manifest.omittedAssetIDs.count else { throw VoiceOSError("迁移清单重复或缺少记录") }
        var verifiedFiles: [String: URL] = [:]
        for entry in manifest.files {
            let file = try PackageLayout.safeFile(package, entry.path)
            let actual = try DurableFiles.hash(file)
            guard actual.0 == entry.bytes, actual.1 == entry.sha256 else { throw VoiceOSError("迁移包文件损坏：\(entry.path)") }
            verifiedFiles[entry.path] = file
        }
        var rows: [String: [[String: String]]] = [:]
        for table in tables {
            guard let file = verifiedFiles["\(table).jsonl"] else { throw VoiceOSError("迁移包缺少结构化记录") }
            let text = try String(contentsOf: file, encoding: .utf8)
            var records: [[String: String]] = []
            for line in text.split(separator: "\n") {
                guard let raw = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw VoiceOSError("结构化记录格式错误") }
                var record: [String: String] = [:]
                for (key, value) in raw {
                    if let string = value as? String { record[key] = string }
                    else if let number = value as? NSNumber { record[key] = number.stringValue }
                    else { throw VoiceOSError("结构化记录字段格式错误") }
                }
                records.append(record)
            }
            guard records.count == manifest.counts[table], Set(records.compactMap { $0["id"] }).count == records.count else { throw VoiceOSError("迁移包记录数量或身份重复") }
            rows[table] = records
        }
        for table in tables {
            for row in rows[table]! {
                guard let id = row["id"], UUID(uuidString: id) != nil else { throw VoiceOSError("迁移包对象身份格式错误") }
            }
        }
        for source in rows["sources"]! {
            guard let asset = source["asset_id"], UUID(uuidString: asset) != nil,
                  let versionID = source["version_id"], UUID(uuidString: versionID) != nil,
                  let version = source["version"].flatMap(Int.init), version >= 1,
                  let bytes = source["expected_bytes"].flatMap(Int64.init), (bytes > 0 || (manifest.version >= 13 && bytes == 0 && source["state"] == "interrupted" && source["input_fingerprint"] == "microphone-v1:" + source["id"]!)),
                  let hash = source["expected_hash"], hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                  ((source["origin"] == "external" && source["speaker"] == "unknown") ||
                   (manifest.version >= 13 && source["origin"] == "user" && source["speaker"] == "user" && source["kind"] == "audio" && source["input_fingerprint"] == "microphone-v1:" + source["id"]!) ||
                   (manifest.version >= 9 && source["origin"] == "user" && source["speaker"] == "user" && source["kind"] == "user_text" && (source["input_fingerprint"] == "user-text-v1:" + hash || (manifest.version >= 10 && source["feedback_json"] != nil)))),
                  (source["local_only"] == "1" || (manifest.version >= 4 && source["local_only"] == "0")) else {
                throw VoiceOSError("迁移包来源字段与当前支持范围不符")
            }
        }
        let assetIDs = Set(rows["assets"]!.compactMap { $0["id"] })
        guard Set(manifest.omittedAssetIDs).isSubset(of: assetIDs) else { throw VoiceOSError("迁移包省略清单引用不存在的原件") }
        let sources = Dictionary(uniqueKeysWithValues: rows["sources"]!.map { ($0["id"]!, $0) })
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".voiceos-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent("assets"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var omittedSources: Set<String> = []
            var expectedPaths = Set(tables.map { "\($0).jsonl" })
            for asset in rows["assets"]! {
                guard let id = asset["id"], let sourceID = asset["source_id"], let source = sources[sourceID],
                      source["asset_id"] == id, source["relative_path"] == asset["relative_path"],
                      source["expected_hash"] == asset["sha256"], source["expected_bytes"] == asset["bytes"],
                      let relative = asset["relative_path"], relative.hasPrefix("assets/"), relative.split(separator: "/").count == 2 else { throw VoiceOSError("迁移包原件关联不一致") }
                let output = try PackageLayout.safeFile(temporary, relative)
                if manifest.omittedAssetIDs.contains(id) { omittedSources.insert(sourceID); continue }
                guard manifest.mediaIncluded, let input = verifiedFiles[relative] else { throw VoiceOSError("迁移包缺少声明已打包的原件") }
                expectedPaths.insert(relative)
                let actual = try DurableFiles.hash(input)
                guard String(actual.0) == asset["bytes"], actual.1 == asset["sha256"] else { throw VoiceOSError("迁移包原件与记录不一致") }
                let info = source["kind"] == "user_text" ? try VoiceOSStore.inspectUserText(input) : try await inspector.inspect(input)
                guard let durationText = source["duration"], let duration = Double(durationText), abs(duration - info.duration) < 0.1, source["kind"] == info.kind else { throw VoiceOSError("恢复媒体与时长、类型记录不一致") }
                try DurableFiles.copy(input, to: output, checkpoint: { _ in })
                let copied = try DurableFiles.hash(output)
                guard copied.0 == actual.0, copied.1 == actual.1 else { throw VoiceOSError("恢复副本完整性校验失败") }
            }
            guard Set(verifiedFiles.keys) == expectedPaths else { throw VoiceOSError("迁移清单包含不受支持的文件") }
            try populateRestore(temporary, rows: rows, omittedSources: omittedSources, tables: tables)
            try DurableFiles.syncDirectory(temporary.appendingPathComponent("assets"))
            try DurableFiles.syncDirectory(temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try DurableFiles.syncDirectory(destination.deletingLastPathComponent())
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    private static func populateRestore(_ directory: URL, rows: [String: [[String: String]]], omittedSources: Set<String>, tables: [String]) throws {
        let database = try Database(directory.appendingPathComponent("voiceos.sqlite"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("voiceos.sqlite").path)
        try database.transaction {
            for table in tables {
                let columns = Set(try database.query("PRAGMA table_info(\(table))").compactMap { $0["name"] })
                for var row in rows[table]! {
                    guard Set(row.keys).isSubset(of: columns), row["id"] != nil else { throw VoiceOSError("迁移包有未知字段或缺少身份") }
                    if table == "sources", omittedSources.contains(row["id"]!) { row["state"] = "reference_only"; row["error"] = "原件未随迁移包附带" }
                    if table == "sources", row["input_fingerprint"] == "microphone-v1:"+row["id"]!, row["expected_bytes"] == "0" {
                        row["error"] = "未封存录制；暂存片段未随包迁移，请保留原资料库核对"
                    }
                    if table == "model_attempts", row["state"] == "reserved" { row["state"] = "unknown"; row["error"] = "迁移前结果未登记；不会自动重发" }
                    if table == "relevance_attempts" {
                        row["validity"] = "frozen"
                        if row["state"] == "reserved" { row["state"] = "unknown"; row["error"] = "迁移前相关性结果未登记；不会自动重发" }
                    }
                    if table == "conversations" { row["validity"] = "frozen" }
                    if table == "discussion_attempts" {
                        row["validity"] = "frozen"
                        if row["state"] == "reserved" { row["state"] = "unknown"; row["error"] = "迁移前讨论结果未登记；不自动重发" }
                    }
                    if table == "jobs", ["queued", "running"].contains(row["state"] ?? "") { row["state"] = "blocked"; row["error"] = "迁移后暂停，请明确重试"; row.removeValue(forKey: "lease_token") }
                    let keys = row.keys.sorted()
                    try database.execute("INSERT INTO \(table)(\(keys.joined(separator: ","))) VALUES(\(keys.map { _ in "?" }.joined(separator: ",")))", keys.map { row[$0] })
                }
            }
            if tables == PackageLayout.legacyTables { try database.backfillTranscriptVersions() }
            guard try database.query("""
            SELECT t.id FROM transcripts t LEFT JOIN transcript_versions v ON v.id=t.current_version_id
            WHERE v.id IS NULL OR v.transcript_id!=t.id OR v.version_no!=t.version
            UNION ALL
            SELECT t.id FROM transcripts t LEFT JOIN transcript_versions v ON v.transcript_id=t.id AND v.version_no=1
            WHERE v.id IS NULL OR v.text!=t.text OR v.reason!='original' OR v.actor!='system'
            UNION ALL
            SELECT t.id FROM transcripts t JOIN transcript_versions v ON v.transcript_id=t.id GROUP BY t.id HAVING COUNT(v.id)!=t.version
            UNION ALL
            SELECT v.id FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id
            LEFT JOIN transcript_revisions r ON r.to_version_id=v.id
            WHERE v.version_no<1 OR v.version_no>t.version OR (v.version_no>1 AND
            (r.id IS NULL OR v.reason!='transcription_error' OR v.actor!='user'))
            UNION ALL
            SELECT r.id FROM transcript_revisions r JOIN transcript_versions f ON f.id=r.from_version_id
            JOIN transcript_versions n ON n.id=r.to_version_id
            WHERE f.transcript_id!=r.transcript_id OR n.transcript_id!=r.transcript_id OR n.version_no!=f.version_no+1
            """).isEmpty else { throw VoiceOSError("恢复的逐字稿版本链不一致") }
            for version in try database.query("SELECT v.*,s.duration FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id") {
                let spans = try JSONDecoder().decode([TranscriptSpan].self, from: Data(version["spans_json"]!.utf8))
                try SpeechText(text: version["text"]!, spans: spans).validate(duration: version["duration"].flatMap(Double.init))
            }
            guard try database.query("""
            SELECT s.id FROM sources s LEFT JOIN assets a ON a.id=s.asset_id
            WHERE s.state IN ('saved','reference_only') AND
            (a.id IS NULL OR a.source_id!=s.id OR a.relative_path!=s.relative_path OR a.sha256!=s.expected_hash OR a.bytes!=s.expected_bytes)
            """).isEmpty else { throw VoiceOSError("恢复的已保存来源缺少一致原件记录") }
            try VoiceOSStore.validateStoredCognition(database)
            try VoiceOSStore.validateStoredRelevance(database)
            try VoiceOSStore.validateStoredCognitiveFeedback(database)
            try VoiceOSStore.validateStoredRecordings(database)
            try VoiceOSStore.validateStoredConversations(database)
            try VoiceOSStore.validateStoredDiscussionAttempts(database)
            guard try database.query("PRAGMA foreign_key_check").isEmpty else { throw VoiceOSError("恢复记录存在悬空引用") }
            guard try database.query("""
            SELECT j.id FROM jobs j JOIN sources s ON s.id=j.source_id WHERE j.input_version_id!=s.version_id
            UNION ALL
            SELECT t.id FROM transcripts t JOIN sources s ON s.id=t.source_id JOIN jobs j ON j.id=t.job_id
            WHERE t.input_version_id!=s.version_id OR j.source_id!=t.source_id OR s.asset_id!=t.input_asset_id OR j.state NOT IN ('completed','blocked')
            """).isEmpty else { throw VoiceOSError("恢复记录版本或逐字稿来源不一致") }
        }
        guard try database.query("PRAGMA integrity_check").first?["integrity_check"] == "ok" else { throw VoiceOSError("恢复数据库校验失败") }
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    private func syncFile(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
