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
    static let version15Tables = version14Tables + ["discussion_attempts"]
    static let version16Tables = version15Tables + ["discussion_claim_derivations"]
    static let currentTables = version16Tables + ["conversation_outcome_attempts"]
    static let version19Tables = currentTables + ["english_feedback_attempts"]
    static let version20Tables = version19Tables + ["expression_association_attempts"]
    static let version21Tables = version20Tables + ["expression_association_ignores"]
    static let version23Tables = version21Tables + ["questions", "question_revisions"]
    static let tables = version23Tables + ["processing_intents"]
    static let version26Tables = tables + ["recording_processing_requests"]
    static let version27Tables = version26Tables + ["segmented_processing_batches"]
    static let version28Tables = version27Tables + ["segmented_extraction_attempts"]
    static let version29Tables = version28Tables + ["segmented_aggregation_attempts"]
    static let version30Tables = version29Tables + ["segmented_cognitive_commits"]
    static let version31Tables = version30Tables + ["recording_segment_plans"]
    static let version32Tables = version31Tables + ["reminder_status_resolutions"]
    static let version33Tables = version32Tables + ["reminder_time_observations"]
    static let version34Tables = version33Tables + ["action_schedule_intents"]
    static let version35Tables = version34Tables + ["reminder_schedule_operations"]
    static let version36Tables = version34Tables + ["reminder_schedule_grants", "reminder_schedule_grant_revocations", "reminder_schedule_operations"]
    static let version37Tables = version36Tables + ["reminder_schedule_bases"]
    static let version38Tables = version37Tables + ["reminder_compensation_plans", "reminder_compensation_grants", "reminder_compensation_revocations", "reminder_compensation_operations"]
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
        case 15: return version15Tables
        case 16: return version16Tables
        case 17: return currentTables
        case 18: return currentTables
        case 19: return version19Tables
        case 20: return version20Tables
        case 21...22: return version21Tables
        case 23: return version23Tables
        case 24, 25: return tables
        case 26: return version26Tables
        case 27: return version27Tables
        case 28: return version28Tables
        case 29: return version29Tables
        case 30: return version30Tables
        case 31: return version31Tables
        case 32: return version32Tables
        case 33: return version33Tables
        case 34: return version34Tables
        case 35: return version35Tables
        case 36: return version36Tables
        case 37: return version37Tables
        case 38, 39, 40, 41: return version38Tables
        default: return tables
        }
    }
    static let integerFields: Set<String> = ["attempted", "save_acknowledged", "schedule_version", "base_action_version", "access_version", "producer_sequence", "part_index", "conversation_version", "auto_send", "sequence", "action_version", "completed", "marker_valid", "claim_review_version", "review_version", "policy_version", "from_version", "to_version", "from_local_only", "to_local_only", "ordinal", "version", "version_no", "expected_bytes", "local_only", "bytes", "attempts"]
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
        guard manifest.format == "VoiceOS-local-package", (1...41).contains(manifest.version), manifest.databaseSchema == (manifest.version >= 25 ? manifest.version : manifest.version + 1),
              let count = manifest.counts["sources"], count >= 0, manifest.counts.values.allSatisfy({ $0 >= 0 && $0 <= 1000000 }) else { throw VoiceOSError("不支持此迁移包格式或记录数量") }
        return PackageSummary(version:manifest.version,createdAt:manifest.createdAt,sourceCount:count,omittedAssetCount:manifest.omittedAssetIDs.count,mediaIncluded:manifest.mediaIncluded)
    }
    /// A synchronous actor turn snapshots rows and immutable media together.
    /// Includes external mapping/history, never credentials or live authorization.
    public func exportPackage(to destination: URL, includeMedia: Bool = false) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw VoiceOSError("导出目录已存在，请选择新目录") }
        guard try db.query("SELECT id FROM sources WHERE input_fingerprint LIKE 'microphone-v1:%' AND state='receiving' AND expected_bytes=0").isEmpty else { throw VoiceOSError("请先停止并封存录制，再导出资料") }
        let exportTables = PackageLayout.version38Tables
        var rows: [String: [[String: String]]] = [:]
        try db.transaction {
            for table in exportTables { rows[table] = try db.query("SELECT * FROM \(table) ORDER BY id") }
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
            for table in exportTables {
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
            let manifest = PackageManifest(format: "VoiceOS-local-package", version: 41, databaseSchema: 41, createdAt: ISO8601DateFormatter().string(from: Date()), mediaIncluded: includeMedia, counts: counts, files: files, omittedAssetIDs: omissions.sorted())
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
        guard manifest.format == "VoiceOS-local-package", (1...41).contains(manifest.version), manifest.databaseSchema == (manifest.version >= 25 ? manifest.version : manifest.version + 1) else { throw VoiceOSError("不支持此迁移包格式") }
        guard manifest.version >= 26 || !manifest.files.contains(where: { $0.path == "recording_processing_requests.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带录制处理请求") }
        guard manifest.version >= 27 || !manifest.files.contains(where: { $0.path == "segmented_processing_batches.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带分段批次") }
        guard manifest.version >= 28 || !manifest.files.contains(where: { $0.path == "segmented_extraction_attempts.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带片段尝试") }
        guard manifest.version >= 29 || !manifest.files.contains(where: { $0.path == "segmented_aggregation_attempts.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带聚合尝试") }
        guard manifest.version >= 30 || !manifest.files.contains(where: { $0.path == "segmented_cognitive_commits.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带整篇认知提交") }
        guard manifest.version >= 31 || !manifest.files.contains(where: { $0.path == "recording_segment_plans.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带录制分段范围") }
        guard manifest.version >= 32 || !manifest.files.contains(where: { $0.path == "reminder_status_resolutions.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带提醒事项状态恢复") }
        guard manifest.version >= 33 || !manifest.files.contains(where: { $0.path == "reminder_time_observations.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带提醒事项时间观测") }
        guard manifest.version >= 34 || !manifest.files.contains(where: { $0.path == "action_schedule_intents.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带排期意图") }
        guard manifest.version >= 35 || !manifest.files.contains(where: { $0.path == "reminder_schedule_operations.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带改期操作") }
        guard manifest.version >= 36 || !manifest.files.contains(where: { ["reminder_schedule_grants.jsonl","reminder_schedule_grant_revocations.jsonl"].contains($0.path) }) else { throw VoiceOSError("旧迁移格式不能携带具体效果确认") }
        guard manifest.version >= 37 || !manifest.files.contains(where: { $0.path == "reminder_schedule_bases.jsonl" }) else { throw VoiceOSError("旧迁移格式不能携带字段归属证据") }
        guard manifest.version >= 38 || !manifest.files.contains(where: { $0.path.hasPrefix("reminder_compensation_") }) else { throw VoiceOSError("旧迁移格式不能携带补偿计划、许可或尝试") }
        var tables = PackageLayout.tables(for: manifest.version)
        // A newer package can be relabeled as an older compatibility fixture. The
        // additive queue table is safe to carry through that validation path.
        if manifest.version < 24, manifest.files.contains(where: { $0.path == "processing_intents.jsonl" }), !tables.contains("processing_intents") {
            tables.append("processing_intents")
        }
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
                   (manifest.version >= 25 && source["origin"] == "user" && source["speaker"] == "user" && (source["kind"] == "audio" || (source["kind"] == "unknown" && source["state"] == "interrupted")) && VoiceOSStore.isPersonalAudioImport(source)) ||
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
            try populateRestore(temporary, rows: rows, omittedSources: omittedSources, tables: tables, packageVersion: manifest.version)
            try DurableFiles.syncDirectory(temporary.appendingPathComponent("assets"))
            try DurableFiles.syncDirectory(temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try DurableFiles.syncDirectory(destination.deletingLastPathComponent())
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    private static func populateRestore(_ directory: URL, rows: [String: [[String: String]]], omittedSources: Set<String>, tables: [String], packageVersion:Int) throws {
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
                    if table == "english_feedback_attempts", row["state"] == "reserved" { row["state"] = "unknown"; row["error"] = "迁移前英文反馈未登记；不自动重发" }
                    if table == "questions" { row["validity"] = "frozen" }
                    if table == "action_schedule_intents" { row["validity"] = "frozen" }
                    if table == "reminder_schedule_operations" { row["validity"] = "frozen" }
                    if table == "reminder_schedule_operations", packageVersion < 36, row["grant_id"] != nil { throw VoiceOSError("旧迁移格式不能携带具体效果确认绑定") }
                    if table == "reminder_schedule_grants" { row["validity"] = "frozen" }
                    if ["reminder_compensation_plans", "reminder_compensation_grants", "reminder_compensation_operations"].contains(table) { row["validity"] = "frozen" }
                    if packageVersion<30 {
                        if table == "model_attempts", row["execution_kind"] == "segmented_derivation" { throw VoiceOSError("旧格式不能携带整篇认知生产者") }
                        if table == "segmented_aggregation_attempts", try VoiceOSStore.aggregationAttempt(row).response?.finalClaims != nil { throw VoiceOSError("旧格式不能携带最终认知提案") }
                    }
                    if table == "segmented_extraction_attempts" || table == "segmented_aggregation_attempts" {
                        guard SegmentExtractionState(rawValue:row["state"] ?? "") != nil, ["current","frozen"].contains(row["validity"] ?? "") else { throw VoiceOSError("迁移分段调用状态无效") }
                        row["validity"] = "frozen"
                        if row["state"] == "reserved" { row["state"] = "unknown"; row["error"] = "迁移前分段调用结果未登记；不自动重发" }
                    }
                    if table == "segmented_processing_batches" {
                        guard packageVersion >= 28 || !["unknown","rejected"].contains(row["state"] ?? "") else { throw VoiceOSError("旧包不支持片段终态") }
                        guard SegmentedProcessingBatchState(rawValue:row["state"] ?? "") != nil else { throw VoiceOSError("迁移分段批次状态无效") }
                        row["state"] = "frozen"; row["error"] = "迁移后分段批次冻结，不自动派发"
                    }
                    if table == "recording_processing_requests" { row["state"] = "frozen"; row["error"] = "迁移后录制处理请求冻结，不自动派发" }
                    if table == "processing_intents" {
                        if ["queued", "running"].contains(row["state"] ?? "") { row["state"] = "frozen"; row["error"] = "迁移后暂停；不会自动派发处理意图" }
                        else if row["state"] != "frozen" { row["state"] = "frozen" }
                    }
                    if table == "expression_association_attempts" {
                        row["validity"] = "frozen"
                        if row["state"] == "reserved" { row["state"] = "unknown"; row["error"] = "迁移前关联结果未登记；不自动重发" }
                    }
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
            if packageVersion < 18 {
                for row in try database.query("SELECT snapshot_json FROM conversation_outcome_attempts") {
                    let snapshot=try JSONDecoder().decode(ConversationOutcomeSnapshot.self,from:Data(row["snapshot_json"]!.utf8))
                    guard snapshot.reusePlan == nil else { throw VoiceOSError("旧格式不能携带需要持久生产顺序的成果复用目录") }
                }
                try database.backfillModelProducerSequence()
            }
            try database.execute("UPDATE contexts SET state='stale' WHERE id IN (SELECT context_id FROM model_attempts WHERE execution_kind IN ('discussion_derivation','segmented_derivation'))")
            try database.execute("UPDATE claims SET validity='frozen' WHERE attempt_id IN (SELECT id FROM model_attempts WHERE execution_kind IN ('discussion_derivation','segmented_derivation'))")
            try database.execute("UPDATE actions SET validity='frozen' WHERE claim_id IN (SELECT id FROM claims WHERE attempt_id IN (SELECT id FROM model_attempts WHERE execution_kind IN ('discussion_derivation','segmented_derivation')))")
            try database.execute("UPDATE contexts SET state='stale' WHERE id IN (SELECT m.context_id FROM model_attempts m JOIN conversation_outcome_attempts o ON o.id=m.id)")
            try database.execute("UPDATE claims SET validity='frozen' WHERE attempt_id IN (SELECT id FROM conversation_outcome_attempts)")
            try database.execute("UPDATE actions SET validity='frozen' WHERE claim_id IN (SELECT id FROM claims WHERE attempt_id IN (SELECT id FROM conversation_outcome_attempts))")
            guard try database.query("""
            SELECT t.id FROM transcripts t LEFT JOIN transcript_versions v ON v.id=t.current_version_id
            WHERE v.id IS NULL OR v.transcript_id!=t.id OR v.version_no!=t.version
            UNION ALL
            SELECT t.id FROM transcripts t LEFT JOIN transcript_versions v ON v.transcript_id=t.id AND v.version_no=1
            WHERE v.id IS NULL OR v.text!=t.text OR v.reason NOT IN ('original','ai_corrected','ai_superseded') OR v.actor!='system'
            UNION ALL
            SELECT t.id FROM transcripts t JOIN transcript_versions v ON v.transcript_id=t.id GROUP BY t.id HAVING COUNT(v.id)!=t.version
            UNION ALL
            SELECT v.id FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id
            LEFT JOIN transcript_revisions r ON r.to_version_id=v.id
            WHERE v.version_no<1 OR v.version_no>t.version OR (v.version_no>1 AND
            (r.id IS NULL OR v.reason!='transcription_error' OR v.actor!='user') AND
            NOT (v.actor='system' AND (v.reason LIKE 'qwen_audio_review:%' OR v.reason LIKE 'qwen_context_review:%' OR v.reason IN ('ai_corrected','ai_superseded'))))
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
            try VoiceOSStore.validateStoredDiscussionDerivations(database)
            try VoiceOSStore.validateStoredConversationOutcomes(database)
            try VoiceOSStore.validateStoredEnglishFeedback(database)
            try VoiceOSStore.validateStoredExpressionAssociations(database)
            try VoiceOSStore.validateStoredExpressionAssociationIgnores(database)
            try VoiceOSStore.validateStoredQuestions(database)
            try VoiceOSStore.validateStoredProcessingIntents(database)
            try VoiceOSStore.validateStoredRecordingProcessingRequests(database)
            try VoiceOSStore.validateStoredRecordingSegmentPlans(database)
            try VoiceOSStore.validateStoredSegmentedProcessingBatches(database)
            try VoiceOSStore.validateStoredSegmentExtraction(database)
            try VoiceOSStore.validateStoredSegmentAggregation(database)
            try VoiceOSStore.validateStoredSegmentCognitiveCommits(database)
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
