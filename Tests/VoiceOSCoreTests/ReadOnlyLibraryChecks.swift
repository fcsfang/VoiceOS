import XCTest
@testable import VoiceOSCore

final class ReadOnlyLibraryChecks: XCTestCase {
    private var base: URL!
    private var database: Database!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-readonly-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        database = try Database(base.appendingPathComponent("voiceos.sqlite"))
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: base)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @discardableResult
    private func insertSource(_ id: String, name: String, kind: String = "user_text",
                              presentation: RecordingPresentation? = nil, transcript: String? = nil) throws -> String? {
        let presentationJSON: String? = try presentation.map { try json($0) }
        try database.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,state,created_at,timezone,expected_bytes,expected_hash,relative_path,presentation_json)
        VALUES(?,?,?,?,?,?,?,'saved',?,'Asia/Shanghai','0',?,?,?)
        """, [id, "command-" + id, "fingerprint-" + id, "asset-" + id, "version-" + id, name, kind,
              "2026-11-01T00:00:00Z", "hash-" + id, "relative/" + id, presentationJSON])
        guard let transcript else { return nil }
        try database.execute("""
        INSERT INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,'10',?,'original')
        """, ["asset-" + id, id, "relative/" + id, "sha-" + id])
        try database.execute("""
        INSERT INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcribe','{}','completed')
        """, ["job-" + id, id, "version-" + id])
        try database.execute("""
        INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at,current_version_id)
        VALUES(?,?,?,?,?,'verbatim',?,'zh-CN','fixture',?,?)
        """, ["transcript-" + id, id, "asset-" + id, "version-" + id, "job-" + id, transcript,
              "2026-11-01T00:00:00Z", "transcript-version-" + id])
        try database.execute("""
        INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at)
        VALUES(?,?,1,?,'[]','original','system',?)
        """, ["transcript-version-" + id, "transcript-" + id, transcript, "2026-11-01T00:00:00Z"])
        return "transcript-version-" + id
    }

    private func insertClaim(_ id: String, sourceID: String, statement: String) throws {
        try database.execute("""
        INSERT INTO contexts(id,command_id,snapshot_json,digest,state,created_at) VALUES(?,?,'{}',?,'current',?)
        """, ["context-" + id, "context-command-" + id, "digest-" + id, "2026-11-01T00:00:00Z"])
        try database.execute("""
        INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at)
        VALUES(?,?,'local_fixture','fixture','v1','v1','completed',?)
        """, ["attempt-" + id, "context-" + id, "2026-11-01T00:00:00Z"])
        let refs = try json([ClaimReference(sourceID: sourceID, transcriptVersionID: "transcript-version-" + sourceID, spanID: "span-1")])
        try database.execute("""
        INSERT INTO claims(id,attempt_id,ordinal,statement,ownership,evidence_state,validity,refs_json,created_at)
        VALUES(?,?,0,?,'user_tentative','unverified','current',?,?)
        """, [id, "attempt-" + id, statement, refs, "2026-11-01T00:00:00Z"])
    }

    private func insertAction(_ id: String, claimID: String, title: String, kind: String = "task",
                              state: String = "open", validity: String = "current",
                              nature: String = "unknown", createdAt: String) throws {
        let actor = kind == "ai_suggestion" ? "ai" : "user"
        try database.execute("""
        INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,version,command_id,input_fingerprint,created_at,nature)
        VALUES(?,?,0,?,?,?,?,?,?,1,?,?,?,?)
        """, [id, claimID, title, kind, actor, "note-" + id, state, validity,
              "action-command-" + id, "action-fingerprint-" + id, createdAt, nature])
    }

    private func insertFeedback(_ id: String, actionID: String, sequence: Int, kind: String,
                                sourceID: String, relation: String?, createdAt: String) throws {
        guard let feedbackKind = ActionFeedbackKind(rawValue: kind) else {
            throw VoiceOSError("未知反馈类型：\(kind)")
        }
        try database.execute("""
        INSERT INTO action_feedback(id,action_id,action_version,source_id,kind,created_at,sequence)
        VALUES(?,?,1,?,?,?,?)
        """, [id, actionID, sourceID, kind, createdAt, String(sequence)])
        var intent = FeedbackIntent(actionID: actionID, actionVersion: 1, kind: feedbackKind)
        intent.relation = relation
        try database.execute("UPDATE sources SET feedback_json=? WHERE id=?", [try json(intent), sourceID])
    }

    private func insertSchedule(_ id: String, actionID: String, version: Int, due: ReminderDueDate,
                                validity: String = "current", authority: String = "user_commitment") throws {
        try database.execute("""
        INSERT INTO action_schedule_intents(id,action_id,action_version,schedule_version,due_json,authority,actor,raw_expression,anchor_event_time,anchor_time_zone,base_authority,validity,command_id,input_fingerprint,created_at)
        VALUES(?,?,1,?,?,?,'user',?,?,'Asia/Shanghai','unknown',?,?,?,?)
        """, [id, actionID, String(version), try json(due), authority, "raw-" + id,
              "2026-11-01T00:00:00.000Z", validity, "schedule-command-" + id, "schedule-fingerprint-" + id,
              "2026-11-01T00:00:00Z"])
    }

    private func insertReminder(_ actionID: String, due: ReminderDueDate) throws {
        try database.execute("""
        INSERT INTO reminder_links(id,action_id,action_version,calendar_id,marker,desired_title,state,external_id,created_at)
        VALUES(?,?,1,'calendar',?,?,'linked',?,?)
        """, ["link-" + actionID, actionID, "marker-" + actionID, "title-" + actionID, "external-" + actionID, "2026-11-01T00:00:00Z"])
        try database.execute("""
        INSERT INTO reminder_observations(id,link_id,external_id,title,completed,marker_valid,created_at,sequence)
        VALUES(?,?,?,?,0,1,?,1)
        """, ["observation-" + actionID, "link-" + actionID, "external-" + actionID, "title-" + actionID,
              "2026-11-01T00:00:00Z"])
        try database.execute("INSERT INTO reminder_time_observations(id,due_json) VALUES(?,?)",
                             ["observation-" + actionID, try json(due)])
    }

    private func insertTopic(_ id: String, title: String, actionID: String, sourceID: String) throws {
        let summary = TopicOrganizationSummary(summary: "摘要", questions: [], sourceVersions: [:],
                                               policyVersions: [:], responseID: "response",
                                               sections: [TopicReadingSection(id: "section-1", title: "节", summary: "",
                                                                              claimIDs: [], actionIDs: [actionID], evidence: [])])
        try database.execute("""
        INSERT INTO reflection_questions(id,title,title_source_id,version,created_at,updated_at,organization_json,ai_named)
        VALUES(?,?,?,1,?,?,?,1)
        """, [id, title, sourceID, "2026-11-01T00:00:00Z", "2026-11-01T00:00:00Z", try json(summary)])
    }

    func testActionsListFiltersAggregatesAndSourceTitle() throws {
        try insertSource("source-a", name: "原始名字", presentation: RecordingPresentation(manualTitle: "雨林笔记"))
        try insertSource("source-b", name: "普通来源", presentation: RecordingPresentation(automatic: RecordingTitleProposal(sourceID: "source-b", title: "自动标题", summary: "s", quotes: [])))
        try insertSource("source-c", name: "只有名字")
        try insertClaim("claim-a", sourceID: "source-a", statement: "整理雨林笔记")
        try insertClaim("claim-b", sourceID: "source-b", statement: "完成录音复盘")
        try insertClaim("claim-c", sourceID: "source-c", statement: "旧计划")
        try insertAction("action-a", claimID: "claim-a", title: "整理雨林笔记",
                         nature: "goal", createdAt: "2026-11-02T00:00:00Z")
        try insertAction("action-b", claimID: "claim-b", title: "完成录音复盘", kind: "opportunity",
                         state: "completed", nature: "goal", createdAt: "2026-11-03T00:00:00Z")
        try insertAction("action-c", claimID: "claim-c", title: "旧计划", state: "dismissed",
                         validity: "frozen", createdAt: "2026-11-01T00:00:00Z")

        try insertSource("feedback-1", name: "反馈一", transcript: "反馈正文")
        try insertSource("feedback-2", name: "反馈二", transcript: "反思正文")
        try insertFeedback("feedback-row-1", actionID: "action-a", sequence: 1, kind: "outcome",
                           sourceID: "feedback-1", relation: "progress", createdAt: "2026-11-05T00:00:00Z")
        try insertFeedback("feedback-row-2", actionID: "action-a", sequence: 2, kind: "reflection",
                           sourceID: "feedback-2", relation: nil, createdAt: "2026-11-06T00:00:00Z")

        let library = try ReadOnlyLibrary(root: base)
        let all = try library.actions(limit: 100, offset: 0)
        XCTAssertEqual(all.map(\.id), ["action-c", "action-a", "action-b"])

        let open = try library.actions(state: "open", validity: "current", limit: 100, offset: 0)
        XCTAssertEqual(open.map(\.id), ["action-a"])
        XCTAssertEqual(open.first?.feedbackCount, 2)
        XCTAssertEqual(open.first?.lastFeedbackAt, "2026-11-06T00:00:00Z")
        XCTAssertEqual(open.first?.sourceTitle, "雨林笔记")

        XCTAssertEqual(try library.actions(validity: "frozen", limit: 100, offset: 0).map(\.id), ["action-c"])
        XCTAssertEqual(try library.actions(kind: "opportunity", limit: 100, offset: 0).map(\.id), ["action-b"])
        XCTAssertEqual(try library.actions(kind: "opportunity", limit: 100, offset: 0).first?.sourceTitle, "自动标题")
        XCTAssertEqual(try library.actions(validity: "frozen", limit: 100, offset: 0).first?.sourceTitle, "只有名字")
        XCTAssertEqual(try library.actions(limit: 2, offset: 1).map(\.id), ["action-a", "action-b"])

        let status = try library.status()
        XCTAssertEqual(status.userVersion, Database.schemaVersion)
        XCTAssertTrue(status.walPresent)
        XCTAssertEqual(status.sources, 5)
        XCTAssertEqual(status.actionsOpen, 1)
        XCTAssertEqual(status.actionsCompleted, 1)
        XCTAssertEqual(status.actionsDismissed, 1)
        XCTAssertEqual(status.actionsSomeday, 0)
        XCTAssertEqual(status.actionsCurrent, 2)
        XCTAssertEqual(status.actionsFrozen, 1)
        XCTAssertEqual(status.feedback, 2)
        XCTAssertEqual(status.topics, 0)
    }

    func testDisplayTitleMatchesApplicationPresentationFunnel() throws {
        try insertSource("source-manual", name: "原始名字", presentation: RecordingPresentation(manualTitle: "  雨林笔记  "))
        try insertSource("source-auto", name: "原始名字",
                         presentation: RecordingPresentation(automatic: RecordingTitleProposal(
                             sourceID: "source-auto",
                             title: "## **整理雨林笔记的后续安排与行动清单，先确认素材来源并记录**。",
                             summary: "s", quotes: [])))
        let machineName = "行动反馈 · 2026-10-14T12:28:35Z"
        try insertSource("source-machine", name: machineName)
        try insertSource("source-plain", name: "普通来源")
        for suffix in ["manual", "auto", "machine", "plain"] {
            try insertClaim("claim-" + suffix, sourceID: "source-" + suffix, statement: "语句-" + suffix)
            try insertAction("action-" + suffix, claimID: "claim-" + suffix,
                             title: "标题-" + suffix, createdAt: "2026-11-02T00:00:00Z")
        }

        let rows = try ReadOnlyLibrary(root: base).actions(limit: 100, offset: 0)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["action-manual"]?.sourceTitle, "雨林笔记")
        XCTAssertEqual(byID["action-auto"]?.sourceTitle, "整理雨林笔记的后续安排与行动清单，先确认素材来源…")
        XCTAssertEqual(byID["action-machine"]?.sourceTitle, MaterialNaming.displayName(machineName))
        XCTAssertEqual(byID["action-plain"]?.sourceTitle, "普通来源")
    }

    func testAutomaticTitleRequiresMatchingTranscriptVersion() throws {
        var current = RecordingPresentation(automatic: RecordingTitleProposal(
            sourceID: "source-current", title: "**当前版本标题**。", summary: "s", quotes: []))
        current.transcriptVersionID = "transcript-version-source-current"
        try insertSource("source-current", name: "当前版本原名", presentation: current, transcript: "当前正文")

        var stale = RecordingPresentation(automatic: RecordingTitleProposal(
            sourceID: "source-stale", title: "过期版本标题", summary: "s", quotes: []))
        stale.transcriptVersionID = "transcript-version-old"
        try insertSource("source-stale", name: "过期版本原名", presentation: stale, transcript: "过期正文")

        var manual = RecordingPresentation(manualTitle: "  人工标题  ")
        manual.automatic = RecordingTitleProposal(sourceID: "source-manual", title: "不应采用的自动标题",
                                                  summary: "s", quotes: [])
        manual.transcriptVersionID = "transcript-version-old"
        try insertSource("source-manual", name: "人工版本原名", presentation: manual, transcript: "人工正文")

        for suffix in ["current", "stale", "manual"] {
            try insertClaim("claim-" + suffix, sourceID: "source-" + suffix, statement: "语句-" + suffix)
            try insertAction("action-" + suffix, claimID: "claim-" + suffix,
                             title: "标题-" + suffix, createdAt: "2026-11-02T00:00:00Z")
        }

        let rows = try ReadOnlyLibrary(root: base).actions(limit: 100, offset: 0)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["action-current"]?.sourceTitle, "当前版本标题")
        XCTAssertEqual(byID["action-stale"]?.sourceTitle, "过期版本原名")
        XCTAssertEqual(byID["action-manual"]?.sourceTitle, "人工标题")
    }

    func testUnnamedAudioUsesRecordingDateInsteadOfStoredName() throws {
        let storedName = "我的口述 · 2026-11-01T00:00:00Z"
        try insertSource("source-voice", name: storedName, kind: "audio")
        try insertClaim("claim-voice", sourceID: "source-voice", statement: "语音材料")
        try insertAction("action-voice", claimID: "claim-voice", title: "语音材料",
                         createdAt: "2026-11-02T00:00:00Z")

        let rows = try ReadOnlyLibrary(root: base).actions(limit: 100, offset: 0)
        XCTAssertEqual(rows.first?.sourceTitle, "录音 · 11月1日 08:00")
        let humanized = MaterialNaming.displayName(storedName, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertNotEqual(rows.first?.sourceTitle, humanized)
    }

    func testDuePrefersLocalScheduleAndMirrorsTimeSurface() throws {
        try insertSource("source-a", name: "来源")
        try insertClaim("claim-a", sourceID: "source-a", statement: "排期依据")
        try insertAction("action-a", claimID: "claim-a", title: "本地优先", createdAt: "2026-11-01T00:00:00Z")
        try insertSchedule("schedule-a", actionID: "action-a", version: 1,
                           due: .dateOnly(localDate: "2026-12-01", timeZone: "Asia/Shanghai"))
        try insertReminder("action-a", due: .instant(utc: "2026-01-01T00:00:00.000Z", timeZone: "Asia/Shanghai"))

        try insertAction("action-b", claimID: "claim-a", title: "只看外部", createdAt: "2026-11-02T00:00:00Z")
        try insertReminder("action-b", due: .instant(utc: "2020-01-01T00:00:00.000Z", timeZone: "Asia/Shanghai"))

        try insertAction("action-c", claimID: "claim-a", title: "明确无期限", createdAt: "2026-11-03T00:00:00Z")
        try insertSchedule("schedule-c", actionID: "action-c", version: 1, due: .none)
        try insertReminder("action-c", due: .instant(utc: "2030-01-01T00:00:00.000Z", timeZone: "Asia/Shanghai"))

        let rows = try ReadOnlyLibrary(root: base).actions(limit: 100, offset: 0)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["action-a"]?.due?.kind, "dateOnly")
        XCTAssertEqual(byID["action-a"]?.due?.localDate, "2026-12-01")
        XCTAssertEqual(byID["action-a"]?.due?.timeZone, "Asia/Shanghai")
        XCTAssertEqual(byID["action-a"]?.due?.source, "localSchedule")
        XCTAssertEqual(byID["action-a"]?.due?.isOverdue, false)
        XCTAssertEqual(byID["action-b"]?.due?.kind, "instant")
        XCTAssertEqual(byID["action-b"]?.due?.source, "reminderObservation")
        XCTAssertEqual(byID["action-b"]?.due?.isOverdue, true)
        XCTAssertEqual(byID["action-c"]?.due?.kind, "none")
        XCTAssertEqual(byID["action-c"]?.due?.source, "localSchedule")
        XCTAssertEqual(byID["action-c"]?.due?.isOverdue, false)
    }

    func testShowDefaultsHideFeedbackTextNoteAndTopics() throws {
        try insertSource("source-a", name: "原始名字", presentation: RecordingPresentation(manualTitle: "雨林笔记"))
        try insertClaim("claim-a", sourceID: "source-a", statement: "整理雨林笔记")
        try insertAction("action-a", claimID: "claim-a", title: "整理雨林笔记", createdAt: "2026-11-02T00:00:00Z")
        try database.execute("""
        INSERT INTO action_revisions(id,action_id,version,from_version,state,note,actor,command_id,input_fingerprint,created_at)
        VALUES('revision-a','action-a',2,1,'open','继续推进','user','revision-command-a','revision-fingerprint-a','2026-11-07T00:00:00Z')
        """)
        try insertSource("feedback-1", name: "反馈一", transcript: "反馈正文")
        try insertSource("feedback-2", name: "反馈二", transcript: "反思正文")
        try insertFeedback("feedback-row-1", actionID: "action-a", sequence: 1, kind: "outcome",
                           sourceID: "feedback-1", relation: "progress", createdAt: "2026-11-05T00:00:00Z")
        try insertFeedback("feedback-row-2", actionID: "action-a", sequence: 2, kind: "reflection",
                           sourceID: "feedback-2", relation: nil, createdAt: "2026-11-06T00:00:00Z")
        try insertTopic("topic-1", title: "雨林主题", actionID: "action-a", sourceID: "source-a")

        let library = try ReadOnlyLibrary(root: base)
        let plain = try XCTUnwrap(try library.action(id: "action-a"))
        XCTAssertNil(plain.note)
        XCTAssertNil(plain.feedback)
        XCTAssertNil(plain.topics)
        XCTAssertEqual(plain.source?.title, "雨林笔记")
        XCTAssertEqual(plain.revisions.map(\.version), [2])
        XCTAssertEqual(plain.revisions.first?.actor, "user")
        XCTAssertNil(try library.action(id: "missing-action"))

        let withFeedback = try XCTUnwrap(try library.action(id: "action-a", includeFeedback: true,
                                                            includeNote: true, includeTopics: true))
        let feedback = try XCTUnwrap(withFeedback.feedback)
        XCTAssertEqual(feedback.count, 2)
        XCTAssertTrue(feedback.allSatisfy { $0.text == nil })
        XCTAssertEqual(feedback.map(\.label), ["实际进展", "我的反思"])
        XCTAssertEqual(withFeedback.note, "note-action-a")
        XCTAssertEqual(withFeedback.topics?.map(\.title), ["雨林主题"])

        let withText = try XCTUnwrap(try library.action(id: "action-a", includeFeedback: true,
                                                        includeFeedbackText: true))
        XCTAssertEqual(withText.feedback?.compactMap(\.text), ["反馈正文", "反思正文"])
    }

    func testRejectsMissingLibraryAndWrongSchemaVersion() throws {
        let missingRoot = base.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: missingRoot, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ReadOnlyLibrary(root: missingRoot)) { error in
            guard case .unavailable? = error as? ReadOnlyLibraryError else {
                return XCTFail("期望资料库不可用错误，实际：\(error)")
            }
        }

        let otherRoot = base.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let otherDatabase = try Database(otherRoot.appendingPathComponent("voiceos.sqlite"))
        try otherDatabase.execute("PRAGMA user_version=75")
        XCTAssertThrowsError(try ReadOnlyLibrary(root: otherRoot)) { error in
            guard let libraryError = error as? ReadOnlyLibraryError else {
                return XCTFail("期望 ReadOnlyLibraryError，实际：\(error)")
            }
            guard case let .incompatibleSchema(found) = libraryError else {
                return XCTFail("期望格式不兼容错误")
            }
            XCTAssertEqual(found, 75)
        }
    }

    func testReadConnectionRejectsWritesAndKeepsItsSnapshot() throws {
        try insertSource("source-a", name: "来源")
        let library = try ReadOnlyLibrary(root: base)
        XCTAssertThrowsError(try library.query("INSERT INTO sources(id) VALUES('probe')"))
        XCTAssertThrowsError(try library.query("CREATE TABLE probe_write(x TEXT)"))
        try insertSource("source-b", name: "并发写入")
        XCTAssertEqual(try library.query("SELECT COUNT(*) AS n FROM sources").first?["n"], "1")
        let nextLibrary = try ReadOnlyLibrary(root: base)
        XCTAssertEqual(try nextLibrary.query("SELECT COUNT(*) AS n FROM sources").first?["n"], "2")
    }

    func testDisplayTitleFunnelSharesExplicitTitleContract() throws {
        func row(manual: String? = nil, automatic: String? = nil,
                 presentationVersion: String?, transcriptVersion: String?) throws -> [String: String] {
            let presentation = RecordingPresentation(
                manualTitle: manual,
                automatic: automatic.map {
                    RecordingTitleProposal(sourceID: "source", title: $0, summary: "s", quotes: [])
                },
                transcriptVersionID: presentationVersion)
            return ["name": "原始名字", "kind": "user_text",
                    "created_at": "2026-11-01T00:00:00Z", "timezone": "Asia/Shanghai",
                    "transcript_version_id": transcriptVersion ?? "",
                    "presentation_json": try json(presentation)]
        }
        XCTAssertEqual(try ReadOnlyLibrary.displayTitle(row(manual: "  人工标题  ", presentationVersion: "t-old",
                                                            transcriptVersion: "t-new")), "人工标题")
        XCTAssertEqual(try ReadOnlyLibrary.displayTitle(row(automatic: "**周会结论**。", presentationVersion: "t-1",
                                                            transcriptVersion: "t-1")), "周会结论")
        XCTAssertEqual(try ReadOnlyLibrary.displayTitle(row(automatic: "过期标题", presentationVersion: "t-old",
                                                            transcriptVersion: "t-new")), "原始名字")
    }
}
