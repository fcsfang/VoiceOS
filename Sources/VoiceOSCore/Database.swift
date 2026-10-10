import Foundation
import CSQLite

// Confined to the Store actor. No SQLite transaction spans an await.
final class Database {
    private var handle: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw VoiceOSError("无法打开资料库")
        }
        do { try configure() }
        catch { sqlite3_close(handle); handle = nil; throw error }
    }
    private func configure() throws {
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        let version = try query("PRAGMA user_version").first?["user_version"] ?? "0"
        guard ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"].contains(version) else { throw VoiceOSError("资料库格式比此应用更新，请使用兼容版本") }
        if version == "1" {
            // Add reference-only state without silently rewriting a newer schema.
            guard let original = try query("SELECT sql FROM sqlite_master WHERE name='sources'").first?["sql"] else { throw VoiceOSError("旧资料库缺少来源表，无法升级") }
            let revised = original.replacingOccurrences(of: "CREATE TABLE sources", with: "CREATE TABLE sources_next").replacingOccurrences(of: "'quarantined'))", with: "'quarantined','reference_only'))")
            try execute("PRAGMA foreign_keys=OFF")
            do {
                try transaction {
                    try execute(revised)
                    try execute("INSERT INTO sources_next SELECT * FROM sources")
                    try execute("DROP TABLE sources")
                    try execute("ALTER TABLE sources_next RENAME TO sources")
                    guard try query("PRAGMA foreign_key_check").isEmpty else { throw VoiceOSError("资料库升级引用校验失败") }
                    try execute("PRAGMA user_version=2")
                }
            } catch { try? execute("PRAGMA foreign_keys=ON"); throw error }
            try execute("PRAGMA foreign_keys=ON")
        }
        if version == "0" {
            try transaction {
                try execute("""
                CREATE TABLE sources (
                  id TEXT PRIMARY KEY, command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL,
                  asset_id TEXT NOT NULL UNIQUE, version_id TEXT NOT NULL UNIQUE, version INTEGER NOT NULL DEFAULT 1,
                  name TEXT NOT NULL, kind TEXT NOT NULL, speaker TEXT NOT NULL DEFAULT 'unknown', origin TEXT NOT NULL DEFAULT 'external',
                  state TEXT NOT NULL CHECK(state IN ('receiving','sealed','saved','interrupted','quarantined','reference_only')),
                  created_at TEXT NOT NULL, timezone TEXT NOT NULL, expected_bytes INTEGER NOT NULL,
                  expected_hash TEXT NOT NULL, relative_path TEXT NOT NULL UNIQUE, duration REAL,
                  local_only INTEGER NOT NULL DEFAULT 1, error TEXT
                )
                """)
                try execute("""
                CREATE TABLE assets (
                  id TEXT PRIMARY KEY, source_id TEXT NOT NULL UNIQUE REFERENCES sources(id),
                  relative_path TEXT NOT NULL UNIQUE, bytes INTEGER NOT NULL, sha256 TEXT NOT NULL,
                  role TEXT NOT NULL CHECK(role='original')
                )
                """)
                try execute("""
                CREATE TABLE jobs (
                  id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id), input_version_id TEXT NOT NULL,
                  stage TEXT NOT NULL, config TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('queued','running','completed','blocked','failed')),
                  attempts INTEGER NOT NULL DEFAULT 0, lease_token TEXT, error TEXT,
                  UNIQUE(source_id,input_version_id,stage,config)
                )
                """)
                try execute("""
                CREATE TABLE transcripts (
                  id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id), input_asset_id TEXT NOT NULL REFERENCES assets(id),
                  input_version_id TEXT NOT NULL, job_id TEXT NOT NULL UNIQUE REFERENCES jobs(id),
                  kind TEXT NOT NULL CHECK(kind='verbatim'), text TEXT NOT NULL, locale TEXT NOT NULL, backend TEXT NOT NULL,
                  created_at TEXT NOT NULL
                )
                """)
                try execute("PRAGMA user_version=2")
            }
        }
        if try query("PRAGMA user_version").first?["user_version"] == "2" {
            try transaction {
                try execute("ALTER TABLE transcripts ADD COLUMN current_version_id TEXT")
                try execute("ALTER TABLE transcripts ADD COLUMN version INTEGER NOT NULL DEFAULT 1")
                try execute("""
                CREATE TABLE transcript_versions (
                    id TEXT PRIMARY KEY, transcript_id TEXT NOT NULL REFERENCES transcripts(id),
                    version_no INTEGER NOT NULL, text TEXT NOT NULL, spans_json TEXT NOT NULL,
                    reason TEXT NOT NULL, actor TEXT NOT NULL, created_at TEXT NOT NULL,
                    UNIQUE(transcript_id,version_no)
                )
                """)
                try execute("""
                CREATE TABLE transcript_revisions (
                    id TEXT PRIMARY KEY, transcript_id TEXT NOT NULL REFERENCES transcripts(id),
                    from_version_id TEXT NOT NULL REFERENCES transcript_versions(id),
                    to_version_id TEXT NOT NULL UNIQUE REFERENCES transcript_versions(id),
                    command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL,
                    reason TEXT NOT NULL CHECK(reason='transcription_error'), actor TEXT NOT NULL CHECK(actor='user'), created_at TEXT NOT NULL
                )
                """)
                try backfillTranscriptVersions()
                try execute("PRAGMA user_version=3")
            }
        }
        if try query("PRAGMA user_version").first?["user_version"] == "3" {
            try transaction {
                try execute("""
                CREATE TABLE contexts (
                  id TEXT PRIMARY KEY, command_id TEXT NOT NULL UNIQUE, snapshot_json TEXT NOT NULL,
                  digest TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('current','stale')), created_at TEXT NOT NULL
                )
                """)
                try execute("""
                CREATE TABLE context_inputs (
                  id TEXT PRIMARY KEY, context_id TEXT NOT NULL REFERENCES contexts(id),
                  source_id TEXT NOT NULL REFERENCES sources(id), transcript_version_id TEXT NOT NULL REFERENCES transcript_versions(id),
                  UNIQUE(context_id,source_id)
                )
                """)
                try execute("""
                CREATE TABLE model_attempts (
                  id TEXT PRIMARY KEY, context_id TEXT NOT NULL REFERENCES contexts(id), provider TEXT NOT NULL CHECK(provider='local_fixture'),
                  model TEXT NOT NULL, prompt_version TEXT NOT NULL, schema_version TEXT NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('reserved','completed','unknown','rejected')),
                  result_digest TEXT, usage_json TEXT, error TEXT, created_at TEXT NOT NULL
                )
                """)
                try execute("""
                CREATE TABLE claims (
                  id TEXT PRIMARY KEY, attempt_id TEXT NOT NULL REFERENCES model_attempts(id), ordinal INTEGER NOT NULL CHECK(ordinal>=0), statement TEXT NOT NULL,
                  ownership TEXT NOT NULL CHECK(ownership IN ('external','ai_candidate','unresolved')),
                  evidence_state TEXT NOT NULL CHECK(evidence_state='unverified'),
                  validity TEXT NOT NULL CHECK(validity IN ('current','frozen')), refs_json TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(attempt_id,ordinal)
                )
                """)
                try execute("PRAGMA user_version=4")
            }
        }
        if try query("PRAGMA user_version").first?["user_version"] == "4" {
            try transaction {
                try execute("ALTER TABLE sources ADD COLUMN policy_version INTEGER NOT NULL DEFAULT 1")
                try execute("ALTER TABLE context_inputs ADD COLUMN policy_version INTEGER NOT NULL DEFAULT 1")
                try execute("ALTER TABLE contexts ADD COLUMN destination TEXT NOT NULL DEFAULT 'local' CHECK(destination IN ('local','cloud'))")
                try execute("""
                CREATE TABLE source_policy_revisions (
                  id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id), from_version INTEGER NOT NULL,
                  to_version INTEGER NOT NULL, from_local_only INTEGER NOT NULL, to_local_only INTEGER NOT NULL,
                  command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL, actor TEXT NOT NULL CHECK(actor='user'),
                  created_at TEXT NOT NULL, UNIQUE(source_id,to_version)
                )
                """)
                // Provider names are metadata; only an injected port can perform work.
                try execute("ALTER TABLE model_attempts RENAME TO old_model_attempts")
                try execute("""
                CREATE TABLE model_attempts (
                  id TEXT PRIMARY KEY, context_id TEXT NOT NULL REFERENCES contexts(id), provider TEXT NOT NULL,
                  model TEXT NOT NULL, prompt_version TEXT NOT NULL, schema_version TEXT NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('reserved','completed','unknown','rejected')),
                  result_digest TEXT, usage_json TEXT, error TEXT, created_at TEXT NOT NULL
                )
                """)
                try execute("INSERT INTO model_attempts SELECT * FROM old_model_attempts")
                // Rebuild dependent table so its FK points at the new attempt table.
                try execute("ALTER TABLE claims RENAME TO old_claims")
                try execute("""
                CREATE TABLE claims (
                  id TEXT PRIMARY KEY, attempt_id TEXT NOT NULL REFERENCES model_attempts(id), ordinal INTEGER NOT NULL CHECK(ordinal>=0), statement TEXT NOT NULL,
                  ownership TEXT NOT NULL CHECK(ownership IN ('external','ai_candidate','unresolved')),
                  evidence_state TEXT NOT NULL CHECK(evidence_state='unverified'),
                  validity TEXT NOT NULL CHECK(validity IN ('current','frozen')), refs_json TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(attempt_id,ordinal)
                )
                """)
                try execute("INSERT INTO claims SELECT * FROM old_claims")
                try execute("DROP TABLE old_claims")
                try execute("DROP TABLE old_model_attempts")
                try execute("PRAGMA user_version=5")
            }
        }
        if try query("PRAGMA user_version").first?["user_version"] == "5" {
            try transaction {
                try execute("ALTER TABLE claims ADD COLUMN review_version INTEGER NOT NULL DEFAULT 0 CHECK(review_version>=0)")
                try execute("""
                CREATE TABLE claim_reviews (
                  id TEXT PRIMARY KEY, claim_id TEXT NOT NULL REFERENCES claims(id), version INTEGER NOT NULL CHECK(version>0),
                  from_version INTEGER NOT NULL CHECK(from_version>=0), decision TEXT NOT NULL CHECK(decision IN ('pending','endorsed','rejected')),
                  statement TEXT NOT NULL, ownership TEXT NOT NULL CHECK(ownership IN ('external','ai_candidate','unresolved')),
                  reason TEXT NOT NULL CHECK(reason IN ('explicit_endorsement','explicit_rejection','correction')), note TEXT NOT NULL,
                  actor TEXT NOT NULL CHECK(actor='user'), command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL, created_at TEXT NOT NULL,
                  UNIQUE(claim_id,version)
                )
                """)
                try execute("PRAGMA user_version=6")
            }
        }
        if try query("PRAGMA user_version").first?["user_version"] == "6" {
            try transaction {
                try execute("""
                CREATE TABLE actions (
                  id TEXT PRIMARY KEY, claim_id TEXT NOT NULL REFERENCES claims(id), claim_review_version INTEGER NOT NULL CHECK(claim_review_version>=0),
                  title TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('task','opportunity','ai_suggestion')),
                  intent_actor TEXT NOT NULL CHECK(intent_actor IN ('user','ai')), note TEXT NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('open','completed','dismissed')), validity TEXT NOT NULL CHECK(validity IN ('current','frozen')),
                  version INTEGER NOT NULL DEFAULT 1 CHECK(version>=1), command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL, created_at TEXT NOT NULL,
                  CHECK((kind='ai_suggestion' AND intent_actor='ai') OR (kind!='ai_suggestion' AND intent_actor='user')),
                  CHECK(state!='completed' OR kind='task')
                )
                """)
                try execute("""
                CREATE TABLE action_revisions (
                  id TEXT PRIMARY KEY, action_id TEXT NOT NULL REFERENCES actions(id), version INTEGER NOT NULL CHECK(version>1), from_version INTEGER NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('open','completed','dismissed')), note TEXT NOT NULL, actor TEXT NOT NULL CHECK(actor='user'),
                  command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(action_id,version)
                )
                """)
                try execute("PRAGMA user_version=7")
            }
        }
        if try query("PRAGMA user_version").first?["user_version"] == "7" {
            try transaction {
                try execute("ALTER TABLE action_revisions RENAME TO old_action_revisions")
                try execute("""
                CREATE TABLE action_revisions (
                  id TEXT PRIMARY KEY, action_id TEXT NOT NULL REFERENCES actions(id), version INTEGER NOT NULL CHECK(version>1), from_version INTEGER NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('open','completed','dismissed')), note TEXT NOT NULL, actor TEXT NOT NULL CHECK(actor IN ('user','external')),
                  command_id TEXT NOT NULL UNIQUE, input_fingerprint TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(action_id,version)
                )
                """)
                try execute("INSERT INTO action_revisions SELECT * FROM old_action_revisions")
                try execute("DROP TABLE old_action_revisions")
                try execute("""
                CREATE TABLE reminder_links (
                  id TEXT PRIMARY KEY, action_id TEXT NOT NULL UNIQUE REFERENCES actions(id), action_version INTEGER NOT NULL CHECK(action_version>=1),
                  calendar_id TEXT NOT NULL, marker TEXT NOT NULL UNIQUE, desired_title TEXT NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('reserved','unknown','linked','missing','conflict')),
                  external_id TEXT, created_at TEXT NOT NULL
                )
                """)
                try execute("""
                CREATE TABLE reminder_observations (
                  id TEXT PRIMARY KEY, link_id TEXT NOT NULL REFERENCES reminder_links(id), external_id TEXT NOT NULL,
                  title TEXT NOT NULL, completed INTEGER NOT NULL CHECK(completed IN (0,1)), marker_valid INTEGER NOT NULL CHECK(marker_valid IN (0,1)),
                  feedback_revision_id TEXT REFERENCES action_revisions(id), created_at TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>=1), UNIQUE(link_id,sequence)
                )
                """)
                try execute("PRAGMA user_version=8")
            }
        }
        if try query("PRAGMA user_version").first?["user_version"] == "8" {
            try transaction {
                try execute("ALTER TABLE reminder_links ADD COLUMN last_checked_at TEXT")
                // Device-local authorization history. Deliberately not in portable packages.
                try execute("""
                CREATE TABLE reminder_access (
                  id TEXT PRIMARY KEY, version INTEGER NOT NULL UNIQUE CHECK(version>=1), calendar_id TEXT NOT NULL,
                  title TEXT NOT NULL, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)), created_at TEXT NOT NULL
                )
                """)
                try execute("PRAGMA user_version=9")
            }
        }
        if try query("PRAGMA user_version").first?["user_version"] == "9" {
            try execute("PRAGMA foreign_keys=OFF")
            do {
                try transaction {
                    for table in ["claims", "claim_reviews"] {
                        guard let original = try query("SELECT sql FROM sqlite_master WHERE name=?", [table]).first?["sql"] else { throw VoiceOSError("认知表缺失，不能升级") }
                        let revised = original.replacingOccurrences(of: "CREATE TABLE \(table)", with: "CREATE TABLE \(table)_next").replacingOccurrences(of: "'external','ai_candidate','unresolved'", with: "'external','ai_candidate','unresolved','user_tentative'")
                        try execute(revised)
                        try execute("INSERT INTO \(table)_next SELECT * FROM \(table)")
                        try execute("DROP TABLE \(table)")
                        try execute("ALTER TABLE \(table)_next RENAME TO \(table)")
                    }
                    guard try query("PRAGMA foreign_key_check").isEmpty else { throw VoiceOSError("认知升级引用校验失败") }
                    try execute("ALTER TABLE claims ADD COLUMN action_json TEXT")
                    try execute("ALTER TABLE actions ADD COLUMN auto_send INTEGER NOT NULL DEFAULT 0 CHECK(auto_send IN (0,1))")
                    try execute("PRAGMA user_version=10")
                }
            } catch { try? execute("PRAGMA foreign_keys=ON"); throw error }
            try execute("PRAGMA foreign_keys=ON")
        }
        if try query("PRAGMA user_version").first?["user_version"] == "10" {
            try transaction {
                try execute("ALTER TABLE sources ADD COLUMN feedback_json TEXT")
                try execute("""
                CREATE TABLE action_feedback (
                  id TEXT PRIMARY KEY, action_id TEXT NOT NULL REFERENCES actions(id), action_version INTEGER NOT NULL CHECK(action_version>=1),
                  source_id TEXT NOT NULL UNIQUE REFERENCES sources(id), kind TEXT NOT NULL CHECK(kind IN ('outcome','reflection')), created_at TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>=1), UNIQUE(action_id,sequence)
                )
                """)
                try execute("PRAGMA user_version=11")
            }
        }
        if try query("PRAGMA user_version").first?["user_version"] == "11" {
            try transaction {
                try execute("""
                CREATE TABLE relevance_attempts (
                  id TEXT PRIMARY KEY, command_id TEXT NOT NULL UNIQUE, fingerprint TEXT NOT NULL,
                  snapshot_json TEXT NOT NULL, snapshot_digest TEXT NOT NULL, destination TEXT NOT NULL CHECK(destination IN ('local','cloud')),
                  provider TEXT NOT NULL, model TEXT NOT NULL, prompt_version TEXT NOT NULL, schema_version TEXT NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('reserved','completed','rejected','unknown')),
                  validity TEXT NOT NULL CHECK(validity IN ('current','frozen')), created_at TEXT NOT NULL,
                  selection_json TEXT, result_digest TEXT, usage_json TEXT, error TEXT
                )
                """)
                try execute("""
                CREATE TABLE relevance_inputs (
                  id TEXT PRIMARY KEY, attempt_id TEXT NOT NULL REFERENCES relevance_attempts(id),
                  source_id TEXT NOT NULL REFERENCES sources(id), transcript_version_id TEXT NOT NULL REFERENCES transcript_versions(id),
                  policy_version INTEGER NOT NULL CHECK(policy_version>=1), ordinal INTEGER NOT NULL CHECK(ordinal>=0),
                  UNIQUE(attempt_id,ordinal)
                )
                """)
                try execute("PRAGMA user_version=12")
            }
        }
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ arguments: [String?] = []) throws { _ = try query(sql, arguments) }
    func query(_ sql: String, _ arguments: [String?] = []) throws -> [[String: String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in arguments.enumerated() {
            let code: Int32
            if let value {
                guard value.utf8.count < Int(Int32.max) else { throw VoiceOSError("资料字段过大") }
                code = value.utf8CString.withUnsafeBufferPointer { bytes in
                    sqlite3_bind_text(stmt, Int32(i + 1), bytes.baseAddress, Int32(bytes.count - 1), transient)
                }
            } else { code = sqlite3_bind_null(stmt, Int32(i + 1)) }
            guard code == SQLITE_OK else { throw error() }
        }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw error() }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(stmt) where sqlite3_column_type(stmt, i) != SQLITE_NULL {
                let key = String(cString: sqlite3_column_name(stmt, i))
                if let value = sqlite3_column_text(stmt, i) { row[key] = String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(stmt, i))), as: UTF8.self) }
            }
            rows.append(row)
        }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func backfillTranscriptVersions() throws {
        for row in try query("SELECT * FROM transcripts WHERE current_version_id IS NULL") {
            let versionID = UUID().uuidString
            let speech = SpeechText(text: row["text"]!)
            let spans = String(decoding: try JSONEncoder().encode(speech.spans), as: UTF8.self)
            try execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,?, 'original','system',?)", [versionID,row["id"],row["text"],spans,row["created_at"]])
            try execute("UPDATE transcripts SET current_version_id=? WHERE id=?", [versionID,row["id"]])
        }
    }
    private func error() -> VoiceOSError { VoiceOSError("资料库错误：\(String(cString: sqlite3_errmsg(handle)))") }
}
