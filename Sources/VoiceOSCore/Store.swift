import Foundation

public actor VoiceOSStore {
    public let root: URL
    private static let verificationFailureMessage = "原件核对失败，可在处理情况页重试"
    private let lock: StoreLock
    let db: Database
    private let inspector: any MediaInspector
    var ready = false
    var knowledgeReviewPreparations = 0
    var topicOrganizationCache: (fingerprint: String, input: TopicOrganizationInput?)?
    var recordingFollowupDecodeCache: [String: (digest: String, receipts: [RecordingFollowupReceipt])] = [:]
    private(set) var knowledgeReviewScanFastPathEnabled = true
    func setKnowledgeReviewScanFastPathEnabled(_ enabled: Bool) { knowledgeReviewScanFastPathEnabled = enabled }
    private var activeImports: Set<String> = []
    private var verifiedFiles: [URL: (stamp: DurableFiles.Fingerprint, bytes: Int64, hash: String)] = [:]
    var activeCaptures: Set<String> = []
    func inspectRecording(_ file:URL) async throws -> MediaInfo { try await inspector.inspect(file) }
    private var processing = false
    var activeProcessingIntents: Set<String> = []
    var segmentExtractionActive = false
    var segmentAggregationActive = false
    var activeReminderLinks: Set<String> = []
    var activeEnglishAttempts: Set<String> = []
    var contextValidationSuspended = false
    var frozenContextCount = 0
    /// A context revalidates only after a row change; its digest, the database
    /// write generation, and its originals' file fingerprints prove no input
    /// changed since the last pass.
    var contextValidationStamps: [String: ContextValidationStamp] = [:]
    var contextSnapshotDecodeBytes = 0
    var contextValidationPasses = 0
    struct ContextValidationStamp: Equatable {
        let digest: String
        let generation: Int64
        let files: [String: DurableFiles.Fingerprint]
    }
    /// Tests re-create the uncached path by dropping the stamps.
    func resetContextValidationMemo() { contextValidationStamps.removeAll() }
    func withoutContextValidation<T>(_ body: () throws -> T) rethrows -> T {
        guard !contextValidationSuspended else { return try body() }
        contextValidationSuspended = true
        defer { contextValidationSuspended = false }
        return try body()
    }
    var assistantExecutionActive = false
    var assistantDiscoveryActive = false
    var activeAssistantRequests: [String: @Sendable () -> Void] = [:]
    let checkpoint: @Sendable (SaveCheckpoint) throws -> Void

    public init(root: URL, inspector: any MediaInspector,
                checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = { _ in }) throws {
        self.root = root.standardizedFileURL; self.inspector = inspector; self.checkpoint = checkpoint
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lock = try StoreLock(self.root.appendingPathComponent("store.lock"))
        for folder in ["assets", "staging"] {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent(folder), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let databaseFile = LibraryLayout.database(in: self.root)
        db = try Database(databaseFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseFile.path)
    }
    public func recover() async throws {
        guard !ready, activeImports.isEmpty else { return }
        StartupTrace.mark("recover.start")
        try db.execute("UPDATE reminder_links SET state='unknown' WHERE state='reserved'")
        try db.execute("UPDATE reminder_schedule_operations SET state='blocked',reason='写前进程退出；未派发，不自动继续' WHERE state='reserved'")
        try db.execute("UPDATE reminder_compensation_operations SET state='blocked',reason='补偿写前进程退出，未派发且不自动续写' WHERE state='reserved'")
        // Startup only: the process lock proves the previous worker no longer owns a lease.
        try db.execute("UPDATE jobs SET state='queued', lease_token=NULL WHERE state='running'")
        try db.execute("UPDATE model_attempts SET state='unknown',error='进程退出前结果未登记；不会自动重发' WHERE state='reserved'")
        try db.execute("UPDATE relevance_attempts SET state='unknown',error='进程退出前相关性结果未登记；不会自动重发' WHERE state='reserved'")
        try db.execute("UPDATE discussion_attempts SET state='unknown',error='进程退出前讨论结果未登记；不自动重发' WHERE state='reserved'")
        try db.execute("UPDATE english_feedback_attempts SET state='unknown',error='进程退出前英文反馈未登记；不自动重发' WHERE state='reserved'")
        try db.execute("UPDATE expression_association_attempts SET state='unknown',error='进程退出前关联结果未登记；不自动重发' WHERE state='reserved'")
        try db.execute("UPDATE assistant_executions SET state='failed',error='执行因应用退出中断，可手动重试' WHERE state='running'")
        try db.execute("UPDATE assistant_assessments SET state='failed',error='评估因应用退出中断' WHERE state='running'")
        try StartupTrace.measure("recover.knowledgeReviews") { try recoverKnowledgeReviews() }
        let sourcesToken = StartupTrace.begin("recover.sources")
        // Saved sources need metadata only. Selecting * here read every
        // follow-up archive, which reaches tens of megabytes on a large library.
        for slim in try db.query("SELECT id,input_fingerprint,expected_bytes,state,relative_path FROM sources ORDER BY created_at") {
            let id = slim["id"]!
            if slim["input_fingerprint"] == "microphone-v1:"+id, slim["expected_bytes"] == "0" {
                try interruptDictation(sourceID:id); continue
            }
            let state = slim["state"]!
            if ["interrupted", "quarantined", "reference_only", "trashed"].contains(state) { continue }
            let final = try assetURL(relativePath: slim["relative_path"]!)
            if state == "saved" {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: final.path),
                      let size = attributes[.size] as? NSNumber else {
                    try quarantine(id, "受管原件缺失"); continue
                }
                if size.int64Value != Int64(slim["expected_bytes"]!) {
                    try db.execute("UPDATE sources SET error=? WHERE id=?", [Self.verificationFailureMessage, id])
                }
                continue
            }
            guard let row = try db.query("SELECT * FROM sources WHERE id=?", [id]).first else { continue }
            let staging = root.appendingPathComponent("staging/\(row["asset_id"]!).part.\(final.pathExtension)")
            let file = FileManager.default.fileExists(atPath: final.path) ? final : staging
            guard FileManager.default.fileExists(atPath: file.path) else {
                if state == "receiving" { try interrupt(id, "保存被中断，尚无完整副本") }
                else { try quarantine(id, "受管原件缺失") }
                continue
            }
            do {
                let (bytes, hash) = try verifiedHash(file)
                guard String(bytes) == row["expected_bytes"], hash == row["expected_hash"] else {
                    if state == "receiving" { try interrupt(id, "保存被中断，副本不完整") }
                    else { try quarantine(id, "原件完整性核对失败") }
                    continue
                }
                let info = try await inspectSource(file, kind: row["kind"]!)
                try db.execute("UPDATE sources SET state='sealed', duration=?, kind=? WHERE id=?", [String(info.duration), info.kind, id])
                if file != final { try place(staging, final) }
                try sealAndQueue(row, info: info)
            } catch {
                if state == "receiving" { try interrupt(id, "保存被中断，无法验证媒体原件") }
                else { try quarantine(id, "无法验证媒体原件，请保留副本并检查文件") }
            }
        }
        StartupTrace.end(sourcesToken)
        try StartupTrace.measure("recover.validators") {
        try db.execute("UPDATE claims SET validity='frozen' WHERE attempt_id IN (SELECT a.id FROM model_attempts a JOIN contexts x ON x.id=a.context_id WHERE x.state='stale')")
        try Self.validateStoredRelevance(db)
        try Self.validateStoredCognitiveFeedback(db)
        try Self.validateStoredRecordings(db)
        try Self.validateStoredExpressionActionReviews(db)
        try Self.validateStoredActionReviewResolutions(db)
        try Self.validateStoredConversations(db)
        try Self.validateStoredDiscussionAttempts(db)
        try freezeDiscussionDerivations()
        try Self.validateStoredDiscussionDerivations(db)
        try freezeConversationOutcomes()
        try Self.validateStoredConversationOutcomes(db)
        try Self.validateStoredEnglishFeedback(db)
        try Self.validateStoredExpressionAssociations(db)
        try Self.validateStoredExpressionAssociationIgnores(db)
        try Self.validateStoredQuestions(db)
        try Self.validateStoredReflectionQuestions(db)
        try Self.validateStoredTopicFeedback(db)
        try Self.validateStoredExternalTexts(db)
        try Self.validateStoredAssistantExecutions(db)
        try Self.validateStoredTaskInitiations(db)
        try Self.validateStoredKnowledgeReviews(db)
        try Self.validateStoredProcessingIntents(db)
        try Self.validateStoredRecordingProcessingRequests(db)
        try Self.validateStoredRecordingSegmentPlans(db)
        try Self.validateStoredSegmentedProcessingBatches(db)
        try recoverSegmentExtractionAttempts()
        try recoverSegmentAggregationAttempts()
        try Self.validateStoredSegmentCognitiveCommits(db)
        try recoverSegmentedProcessingBatches()
        try recoverExpressionProcessingIntents()
        try Self.validateStoredActionSchedules(db)
        try Self.validateReminderScheduleBases(db)
        try Self.validateReminderScheduleGrants(db)
        try Self.validateReminderScheduleOperations(db)
        try Self.validateReminderCompensations(db)
        }
        ready = true
        StartupTrace.mark("recover.end")
    }
    @discardableResult
    public func importFile(_ input: URL, commandID: String = UUID().uuidString) async throws -> String {
        try await importMedia(input, commandID: commandID, personalAudio: false)
    }
    /// Caller explicitly asserts this file contains only their own voice. This grants
    /// attribution, never cloud processing permission, and is not a microphone capture.
    @discardableResult
    public func importPersonalAudio(_ input: URL, commandID: String = UUID().uuidString) async throws -> String {
        try await importMedia(input, commandID: commandID, personalAudio: true)
    }
    public func importedSourceID(commandID: String) throws -> String? {
        try db.query("SELECT id FROM sources WHERE command_id=? AND state IN ('saved','reference_only')", [commandID]).first?["id"]
    }
    public func personalAudioSourceID(sha256: String) throws -> String? {
        try db.query("SELECT id FROM sources WHERE expected_hash=? AND origin='user' AND speaker='user' AND state='saved' ORDER BY created_at LIMIT 1", [sha256]).first?["id"]
    }
    private func importMedia(_ input: URL, commandID: String, personalAudio: Bool) async throws -> String {
        guard ready, !commandID.isEmpty else { throw VoiceOSError("资料库尚未完成恢复或导入命令为空") }
        let extensionName = input.pathExtension.lowercased()
        if personalAudio {
            guard ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac"].contains(extensionName) else {
                throw VoiceOSError("个人录音入口只接受明确归属本人的音频文件")
            }
        }
        guard ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac"].contains(extensionName) else { throw VoiceOSError("请选择音频或视频文件") }
        let (bytes, hash) = try DurableFiles.hash(input)
        guard bytes > 0 else { throw VoiceOSError("文件为空") }
        let fingerprint = (personalAudio ? "personal-audio-v1:" : "") + "\(hash):\(bytes):\(extensionName):\(input.lastPathComponent)"
        let id: String; let asset: String; let relative: String
        if let old = try db.query("SELECT * FROM sources WHERE command_id=?", [commandID]).first {
            guard old["input_fingerprint"] == fingerprint else { throw VoiceOSError("同一导入命令不能更换文件内容") }
            id = old["id"]!; asset = old["asset_id"]!; relative = old["relative_path"]!
            if ["saved", "reference_only"].contains(old["state"] ?? "") { return id }
            guard !activeImports.contains(id) else { throw VoiceOSError("同一导入命令正在执行") }
            if old["state"] == "sealed" { return try await finishSealedImport(old) }
            try db.execute("UPDATE sources SET state='receiving',error=NULL WHERE id=?", [id])
        } else {
            id = UUID().uuidString; asset = UUID().uuidString; let version = UUID().uuidString
            relative = "assets/\(asset).\(extensionName)"
            try db.execute("""
            INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,origin,speaker,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
            VALUES(?,?,?,?,?,?,?,?,?,'receiving',?,?,?,?,?)
            """, [id,commandID,fingerprint,asset,version,input.lastPathComponent,"unknown",personalAudio ? "user" : "external",personalAudio ? "user" : "unknown",Self.now(),TimeZone.current.identifier,String(bytes),hash,relative])
        }
        let staging = root.appendingPathComponent("staging/\(asset).part.\(extensionName)")
        let final = try assetURL(relativePath: relative)
        activeImports.insert(id)
        defer { activeImports.remove(id) }
        do {
            try checkpoint(.intent)
            try? FileManager.default.removeItem(at: staging)
            try DurableFiles.copy(input, to: staging, checkpoint: checkpoint)
            try checkpoint(.copyComplete)
            let actual = try DurableFiles.hash(staging)
            guard actual.0 == bytes, actual.1 == hash else { throw VoiceOSError("复制期间输入发生变化，无法确认完整保存") }
            let info = try await inspector.inspect(staging)
            guard !personalAudio || info.kind == "audio" else { throw VoiceOSError("个人录音文件必须经核对为音频") }
            try db.execute("UPDATE sources SET state='sealed', duration=?, kind=? WHERE id=?", [String(info.duration),info.kind,id])
            try checkpoint(.sealed)
            try place(staging, final)
            try checkpoint(.renamed)
            let row = try db.query("SELECT * FROM sources WHERE id=?", [id]).first!
            try sealAndQueue(row, info: info)
            try checkpoint(.savedCommitted)
            return id
        } catch {
            // Keep sealed intent recoverable. Never erase evidence to hide an incomplete import.
            if try db.query("SELECT state FROM sources WHERE id=?", [id]).first?["state"] == "receiving" {
                try interrupt(id, "导入未完成，可重新选择原文件")
            }
            throw error
        }
    }
    private static let sourceTranscriptJoin = """
        FROM sources s LEFT JOIN jobs j
          ON j.source_id=s.id AND j.stage='transcription' AND j.input_version_id=s.version_id
        LEFT JOIN transcripts t ON t.job_id=j.id
        """

    private static let sourceSelect = """
        SELECT s.id,s.asset_id,s.name,s.state,s.kind,s.created_at,s.expected_bytes,s.duration,s.error,s.relative_path,
               s.local_only,s.policy_version,s.origin,s.speaker,s.feedback_json,s.timezone,s.presentation_json,
               j.state AS job_state,j.error AS job_error,v.text AS transcript,t.current_version_id AS transcript_version_id,t.backend AS transcription_backend,v.spans_json,v.reason AS transcript_version_reason
        \(sourceTranscriptJoin) LEFT JOIN transcript_versions v ON v.id=t.current_version_id
        """
    /// Row-change counter for this connection; stable means no writes happened,
    /// so a periodic full reload can skip re-reading the whole library.
    public var dataGeneration: Int64 { db.writeGeneration }
    public func sources() throws -> [SourceRecord] {
        try db.query(Self.sourceSelect + " ORDER BY s.created_at DESC,s.id").map(Self.sourceRecord)
    }
    func sourceCatalog() throws -> [String: SourceRecord] {
        Dictionary(try sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    /// Targeted read for callers that hold ids; the full-table variant decodes
    /// every transcript and is far too heavy to run once per checked id.
    public func sourceRecords(ids: [String]) throws -> [SourceRecord] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try db.query(Self.sourceSelect + " WHERE s.id IN (\(marks))", ids).map(Self.sourceRecord)
    }

    func sourceTranscriptRevisions(ids: [String]) throws -> [String: (versionID: String?, policyVersion: Int, localOnly: Bool)] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try db.query("""
            SELECT s.id,t.current_version_id,s.policy_version,s.local_only
            \(Self.sourceTranscriptJoin) WHERE s.id IN (\(marks))
            """, ids)
        return Dictionary(rows.map { row in
            (row["id"]!, (row["current_version_id"], Int(row["policy_version"]!)!, row["local_only"] != "0"))
        }, uniquingKeysWith: { first, _ in first })
    }
    private static func sourceRecord(_ row: [String: String]) throws -> SourceRecord {
        let feedback = try feedbackIntent(row["feedback_json"])
        return SourceRecord(id: row["id"]!, assetID: row["asset_id"]!, name: row["name"]!, state: row["state"]!, kind: row["kind"]!, createdAt: row["created_at"]!, bytes: Int64(row["expected_bytes"]!)!, duration: row["duration"].flatMap(Double.init), jobState: row["job_state"], transcript: ["saved", "reference_only"].contains(row["state"] ?? "") ? row["transcript"] : nil, error: row["error"] ?? row["job_error"], relativePath: row["relative_path"]!, transcriptVersionID: row["transcript_version_id"], transcriptionBackend: row["transcription_backend"], spans: try row["spans_json"].map { try JSONDecoder().decode([TranscriptSpan].self, from: Data($0.utf8)) } ?? [], localOnly: row["local_only"] != "0", policyVersion: Int(row["policy_version"]!)!, origin: row["origin"]!, speaker: row["speaker"]!, feedbackActionID: feedback?.actionID, feedbackActionVersion: feedback?.actionVersion, feedbackKind: feedback?.kind.rawValue, feedbackRelation: feedback?.relation, timeZone: row["timezone"]!, presentation: try row["presentation_json"].map { try JSONDecoder().decode(RecordingPresentation.self, from: Data($0.utf8)) }, transcriptVersionReason: row["transcript_version_reason"])
    }
    public func playableURL(sourceID: String) throws -> URL {
        guard let row = try db.query("SELECT * FROM sources WHERE id=? AND state='saved'", [sourceID]).first else { throw VoiceOSError("此原件尚未可靠保存") }
        let url = try assetURL(relativePath: row["relative_path"]!)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try quarantine(sourceID, "原件缺失或无法完整核对")
            throw VoiceOSError("原件缺失或无法完整核对，已暂停后续处理")
        }
        let actual: (Int64, String)
        do { actual = try verifiedHash(url) }
        catch {
            try db.execute("UPDATE sources SET error=? WHERE id=?", [Self.verificationFailureMessage, sourceID])
            throw VoiceOSError(Self.verificationFailureMessage)
        }
        guard actual.0 == Int64(row["expected_bytes"]!), actual.1 == row["expected_hash"]! else {
            try db.execute("UPDATE sources SET error=? WHERE id=?", [Self.verificationFailureMessage, sourceID])
            throw VoiceOSError(Self.verificationFailureMessage)
        }
        return url
    }
    public func reverifySource(id: String) async throws -> Bool {
        guard let row = try db.query("SELECT * FROM sources WHERE id=? AND state IN ('saved','quarantined')", [id]).first,
              let expectedBytes = Int64(row["expected_bytes"]!) else { return false }
        do {
            let file = try assetURL(relativePath: row["relative_path"]!)
            guard FileManager.default.fileExists(atPath: file.path) else { throw VoiceOSError("原件缺失") }
            let actual = try DurableFiles.hash(file)
            guard actual.0 == expectedBytes, actual.1 == row["expected_hash"] else { throw VoiceOSError("原件完整性核对失败") }
            let info = try await inspectSource(file, kind: row["kind"]!)
            return try restoreVerifiedOriginal(row, info: info)
        } catch {
            try db.execute("UPDATE sources SET error=? WHERE id=?", [Self.verificationFailureMessage, id])
            return false
        }
    }
    private func restoreVerifiedOriginal(_ row: [String: String], info: MediaInfo) throws -> Bool {
        let id = row["id"]!
        var restored = false
        try db.transaction {
            guard let state = try db.query("SELECT state FROM sources WHERE id=?", [id]).first?["state"], ["saved", "quarantined"].contains(state) else { return }
            restored = true
            try db.execute("UPDATE sources SET state='saved',duration=?,kind=?,error=NULL WHERE id=?", [String(info.duration), info.kind, id])
            try db.execute("INSERT OR IGNORE INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,?,?,'original')", [row["asset_id"], id, row["relative_path"], row["expected_bytes"], row["expected_hash"]])
            let transcripts = try db.query("SELECT 1 FROM transcripts WHERE source_id=? LIMIT 1", [id])
            let activeJobs = try db.query("SELECT 1 FROM jobs WHERE source_id=? AND stage='transcription' AND state IN ('queued','running') LIMIT 1", [id])
            if transcripts.isEmpty, activeJobs.isEmpty, ["audio", "video"].contains(info.kind) {
                try db.execute("INSERT OR IGNORE INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','pending-local-speech-v1','queued')", [UUID().uuidString, id, row["version_id"]])
                try db.execute("UPDATE jobs SET state='queued',lease_token=NULL,error=NULL WHERE source_id=? AND input_version_id=? AND stage='transcription' AND config='pending-local-speech-v1' AND state NOT IN ('queued','running')", [id, row["version_id"]])
            }
        }
        return restored
    }
    private func verifiedHash(_ url: URL) throws -> (Int64, String) {
        // Session-only reuse. ctime also changes if equal-size contents are edited
        // and mtime is restored; inode detects replacement. DB/policy checks stay live.
        let before = try DurableFiles.fingerprint(url)
        if let cached = verifiedFiles[url], cached.stamp == before { return (cached.bytes, cached.hash) }
        verifiedFiles[url] = nil
        let result = try DurableFiles.hash(url)
        guard try DurableFiles.fingerprint(url) == before else { throw VoiceOSError("原件在核对期间发生变化") }
        verifiedFiles[url] = (before, result.0, result.1)
        return result
    }
    func hasCurrentVerifiedFile(_ url: URL) -> Bool {
        guard let cached = verifiedFiles[url] else { return false }
        return (try? DurableFiles.fingerprint(url)) == cached.stamp
    }
    public func retryTranscription(sourceID: String) throws {
        try db.execute("""
        UPDATE jobs SET state='queued',error=NULL WHERE source_id=? AND EXISTS(SELECT 1 FROM sources WHERE id=? AND state='saved')
          AND (state IN ('failed','blocked') OR (state='completed' AND EXISTS(
            SELECT 1 FROM transcripts t JOIN transcript_versions v ON v.id=t.current_version_id
            WHERE t.job_id=jobs.id AND length(trim(v.text, ' ' || char(9) || char(10) || char(13)))=0)))
        """, [sourceID,sourceID])
    }

    private static let queuedTranscriptionJobs = """
        FROM jobs j JOIN sources s ON s.id=j.source_id
        WHERE j.state='queued' AND s.state='saved' AND j.input_version_id=s.version_id
        """

    public func queuedTranscriptionSourceIDs() throws -> [String] {
        try db.query("""
            SELECT DISTINCT s.id,s.created_at \(Self.queuedTranscriptionJobs)
            ORDER BY s.created_at DESC,s.id
            """).map { $0["id"]! }
    }

    public func processTranscriptions(using speech: any SpeechPort, sourceIDs: [String]? = nil) async throws {
        guard ready, !processing else { return }
        let backend = speech.backendIdentity
        guard !backend.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, backend.utf8.count <= 160, !backend.contains("\n"), !backend.contains("\r") else { throw VoiceOSError("转写端口身份无效") }
        guard sourceIDs?.isEmpty != true else { return }
        let scope = sourceIDs == nil ? "" : " AND j.source_id IN (SELECT value FROM json_each(?))"
        let bindings = try sourceIDs.map { [try Self.relevanceJSON($0)] } ?? []
        processing = true
        defer { processing = false }
        while let row = try db.query("""
        SELECT j.id,j.source_id,j.input_version_id,s.asset_id \(Self.queuedTranscriptionJobs)\(scope)
        ORDER BY s.created_at,j.rowid LIMIT 1
        """, bindings).first {
            let job = row["id"]!; let source = row["source_id"]!; let lease = UUID().uuidString
            try db.execute("UPDATE jobs SET state='running',config=?,lease_token=?,attempts=attempts+1 WHERE id=?", [backend,lease,job])
            do {
                try checkpoint(.jobClaimed)
                let url = try playableURL(sourceID: source)
                let result = try await speech.transcribe(url, locale: "zh_CN")
                let duration = try db.query("SELECT duration FROM sources WHERE id=?", [source]).first?["duration"].flatMap(Double.init)
                try result.validate(duration: duration)
                let text = result.text
                _ = try playableURL(sourceID: source)
                let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                try db.transaction {
                    guard !(try db.query("""
                    SELECT j.id FROM jobs j JOIN sources s ON s.id=j.source_id
                    WHERE j.id=? AND j.lease_token=? AND j.state='running' AND s.state='saved' AND s.version_id=j.input_version_id
                    """, [job,lease])).isEmpty else { return }
                    guard !empty else {
                        try db.execute("UPDATE jobs SET state='blocked',lease_token=NULL,error=? WHERE id=?", [SourceRecord.emptyTranscriptJobError,job])
                        return
                    }
                    if let existingID = try db.query("SELECT id FROM transcripts WHERE job_id=?", [job]).first?["id"] {
                        _ = try db.appendTranscriptVersion(transcriptID: existingID,
                                                           speech: result, reason: .original, createdAt: Self.now())
                    } else {
                        try db.createTranscript(sourceID: source, assetID: row["asset_id"]!, inputVersionID: row["input_version_id"]!,
                                                jobID: job, speech: result, backend: backend, createdAt: Self.now())
                    }
                    try db.execute("UPDATE jobs SET state='completed' ,lease_token=NULL,error=NULL WHERE id=?", [job])
                    try checkpoint(.transcriptUncommitted)
                }
                try checkpoint(.transcriptCommitted)
            } catch {
                try db.execute("UPDATE jobs SET state='failed',lease_token=NULL,error=? WHERE id=? AND lease_token=? AND state='running'", [error.localizedDescription,job,lease])
            }
        }
    }
    public func integrityCheck() throws -> Bool {
        try db.query("PRAGMA integrity_check").first?["integrity_check"] == "ok" && db.query("PRAGMA foreign_key_check").isEmpty
    }
    func sealAndQueue(_ row: [String: String], info: MediaInfo) throws {
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,?,?,'original')", [row["asset_id"],row["id"],row["relative_path"],row["expected_bytes"],row["expected_hash"]])
            try db.execute("UPDATE sources SET state='saved',duration=?,kind=?,error=NULL WHERE id=?", [String(info.duration),info.kind,row["id"]])
            if info.kind == "user_text" { try commitUserText(row) }
            else if info.kind == "external_text" { try commitExternalText(row) }
            else {
            try db.execute("INSERT OR IGNORE INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','pending-local-speech-v1','queued')", [UUID().uuidString,row["id"],row["version_id"]])
            }
            try checkpoint(.savedUncommitted)
        }
    }
    private func inspectSource(_ file: URL, kind: String) async throws -> MediaInfo {
        if kind == "ai_text" { return try Self.inspectAssistantText(file) }
        if kind == "user_text" { return try Self.inspectUserText(file) }
        if kind == "external_text" { return try Self.inspectExternalText(file) }
        return try await inspector.inspect(file)
    }
    private func finishSealedImport(_ row: [String: String]) async throws -> String {
        let id = row["id"]!, asset = row["asset_id"]!
        guard !activeImports.contains(id) else { throw VoiceOSError("同一导入命令正在执行") }
        let final = try assetURL(relativePath: row["relative_path"]!)
        let staging = root.appendingPathComponent("staging/\(asset).part.\(final.pathExtension)")
        let file = FileManager.default.fileExists(atPath: final.path) ? final : staging
        guard FileManager.default.fileExists(atPath: file.path) else {
            try interrupt(id, "导入未完成，尚无完整副本")
            throw VoiceOSError("导入未完成，尚无完整副本")
        }
        activeImports.insert(id); defer { activeImports.remove(id) }
        let actual: (Int64, String)
        do { actual = try DurableFiles.hash(file) }
        catch {
            try interrupt(id, "导入未完成，无法核对副本")
            throw error
        }
        guard String(actual.0) == row["expected_bytes"], actual.1 == row["expected_hash"] else {
            try interrupt(id, "导入未完成，副本不完整")
            throw VoiceOSError("导入未完成，副本不完整")
        }
        let info: MediaInfo
        if let duration = row["duration"].flatMap(Double.init), ["audio", "video"].contains(row["kind"] ?? "") {
            info = MediaInfo(duration: duration, kind: row["kind"]!)
        } else {
            info = try await inspectSource(file, kind: row["kind"] ?? "unknown")
        }
        if file == staging { try place(staging, final) }
        try checkpoint(.renamed)
        let sealed = try db.query("SELECT * FROM sources WHERE id=?", [id]).first!
        try sealAndQueue(sealed, info: info)
        try checkpoint(.savedCommitted)
        return id
    }
    private func interrupt(_ id: String, _ reason: String) throws { try db.execute("UPDATE sources SET state='interrupted',error=? WHERE id=?", [reason,id]) }
    private func quarantine(_ id: String, _ reason: String) throws {
        try db.transaction {
            try db.execute("UPDATE sources SET state='quarantined',error=? WHERE id=?", [reason,id])
            try db.execute("UPDATE jobs SET state='blocked',lease_token=NULL,error=? WHERE source_id=?", [reason,id])
            try invalidateCognition(sourceID: id)
        }
    }
    func place(_ staging: URL, _ final: URL) throws {
        try FileManager.default.moveItem(at: staging, to: final)
        try DurableFiles.syncDirectory(final.deletingLastPathComponent())
        try DurableFiles.syncDirectory(staging.deletingLastPathComponent())
    }
    func assetURL(relativePath: String) throws -> URL {
        let path = root.appendingPathComponent(relativePath).standardizedFileURL
        guard relativePath.hasPrefix("assets/"), path.deletingLastPathComponent() == root.appendingPathComponent("assets") else { throw VoiceOSError("非法资产路径") }
        return path
    }
    static func now() -> String { TimestampFormatting.iso.string(from: Date()) }
}
