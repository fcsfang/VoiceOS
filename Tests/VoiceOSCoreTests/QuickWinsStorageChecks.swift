import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class QuickWinsStorageChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-quick-wins-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func insertSource(_ db: Database, id: String = UUID().uuidString) throws -> String {
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?,?,'unknown','external','saved',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, "asset:" + id, "version:" + id, "合成资料", "external_text", "2026-11-14T00:00:00Z", TimeZone.current.identifier, "assets/" + id])
        return id
    }

    private func insertClaim(_ db: Database, id: String = UUID().uuidString) throws -> String {
        let contextID = UUID().uuidString, attemptID = UUID().uuidString
        try db.execute("INSERT INTO contexts(id,command_id,snapshot_json,digest,state,created_at) VALUES(?,?,?,?, 'current',?)",
                       [contextID, "context:" + contextID, "{}", contextID, "2026-11-14T00:00:00Z"])
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at) VALUES(?,?,?,?,?,?, 'completed',?)",
                       [attemptID, contextID, "fixture", "fixture", "v1", "v1", "2026-11-14T00:00:00Z"])
        try db.execute("INSERT INTO claims(id,attempt_id,ordinal,statement,ownership,evidence_state,validity,refs_json,created_at) VALUES(?,?,0,?, 'external','unverified','current','[]',?)",
                       [id, attemptID, "合成观点", "2026-11-14T00:00:00Z"])
        return id
    }

    private func insertAction(_ db: Database, claimID: String, state: String = "open", validity: String = "current") throws -> String {
        let id = UUID().uuidString
        try db.execute("""
        INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,command_id,input_fingerprint,created_at)
        VALUES(?,?,0,?,'task','user','',?,?,?,?,?)
        """, [id, claimID, "合成行动", state, validity, "action:" + id, id, "2026-11-14T00:00:00Z"])
        return id
    }

    func testActionFocusKeepsAtMostThreeAndToggles() async throws {
        let store = try await openStore()
        let db = await store.db
        let version = try db.query("PRAGMA user_version").first?["user_version"]
        XCTAssertEqual(version, "56")
        let claimID = try insertClaim(db)
        let first = try insertAction(db, claimID: claimID)
        let second = try insertAction(db, claimID: claimID)
        let third = try insertAction(db, claimID: claimID)
        let fourth = try insertAction(db, claimID: claimID)
        let focusedFirst = try await store.toggleActionFocus(actionID: first)
        XCTAssertTrue(focusedFirst)
        let focusedSecond = try await store.toggleActionFocus(actionID: second)
        XCTAssertTrue(focusedSecond)
        let focusedThird = try await store.toggleActionFocus(actionID: third)
        XCTAssertTrue(focusedThird)
        let focused = try await store.focusedActionIDs()
        XCTAssertEqual(focused, Set([first, second, third]))
        do {
            _ = try await store.toggleActionFocus(actionID: fourth)
            XCTFail("第四条专注必须被拒绝")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "最多只能置顶 3 条专注行动")
        }
        let removed = try await store.toggleActionFocus(actionID: second)
        XCTAssertFalse(removed)
        let afterRemoval = try await store.focusedActionIDs()
        XCTAssertEqual(afterRemoval, Set([first, third]))
        let closed = try insertAction(db, claimID: claimID, state: "dismissed")
        do {
            _ = try await store.toggleActionFocus(actionID: closed)
            XCTFail("已关闭行动不能加入专注")
        } catch {}
        do {
            _ = try await store.toggleActionFocus(actionID: UUID().uuidString)
            XCTFail("不存在的行动不能加入专注")
        } catch {}
        let frozen = try insertAction(db, claimID: claimID, validity: "frozen")
        do {
            _ = try await store.toggleActionFocus(actionID: frozen)
            XCTFail("冻结行动不能加入专注")
        } catch {}
        try db.execute("UPDATE actions SET state='dismissed' WHERE id=?", [third])
        let visible = try await store.focusedActionIDs()
        XCTAssertEqual(visible, Set([first]))
    }

    func testClaimNotesTrimBoundsAndPreserveCreatedAt() async throws {
        let store = try await openStore()
        let db = await store.db
        let claimID = try insertClaim(db)
        let first = try await store.saveClaimNote(claimID: claimID, body: "  第一条旁注  ")
        XCTAssertEqual(first.body, "第一条旁注")
        let savedFirst = try await store.claimNotes()
        XCTAssertEqual(savedFirst[claimID]?.body, "第一条旁注")
        XCTAssertEqual(savedFirst[claimID]?.createdAt, first.createdAt)
        try db.execute("UPDATE claim_notes SET created_at='2020-01-01T00:00:00Z' WHERE claim_id=?", [claimID])
        let second = try await store.saveClaimNote(claimID: claimID, body: "第二条旁注")
        XCTAssertEqual(second.createdAt, "2020-01-01T00:00:00Z")
        XCTAssertNotEqual(second.updatedAt, "2020-01-01T00:00:00Z")
        XCTAssertEqual(second.body, "第二条旁注")
        let savedSecond = try await store.claimNotes()
        XCTAssertEqual(savedSecond[claimID]?.body, "第二条旁注")
        XCTAssertEqual(savedSecond[claimID]?.updatedAt, second.updatedAt)
        do {
            _ = try await store.saveClaimNote(claimID: claimID, body: " \n ")
            XCTFail("空正文必须被拒绝")
        } catch {}
        do {
            _ = try await store.saveClaimNote(claimID: claimID, body: String(repeating: "长", count: 1001))
            XCTFail("超长正文必须被拒绝")
        } catch {}
        let boundary = try await store.saveClaimNote(claimID: claimID, body: String(repeating: "长", count: 1000))
        XCTAssertEqual(boundary.body.unicodeScalars.count, 1000)
        do {
            _ = try await store.saveClaimNote(claimID: UUID().uuidString, body: "旁注")
            XCTFail("观点不存在时不能保存旁注")
        } catch {}
        try await store.deleteClaimNote(claimID: claimID)
        let deleted = try await store.claimNotes()
        XCTAssertNil(deleted[claimID])
    }

    func testTopicClaimConfirmationsAreCommandIdempotent() async throws {
        let store = try await openStore()
        let db = await store.db
        let claimA = try insertClaim(db)
        let claimB = try insertClaim(db)
        let topicID = "topic-fixture"
        let first = try await store.confirmTopicClaim(topicID: topicID, claimID: claimA, commandID: "command-1")
        XCTAssertTrue(first)
        let replay = try await store.confirmTopicClaim(topicID: topicID, claimID: claimA, commandID: "command-1")
        XCTAssertFalse(replay)
        do {
            _ = try await store.confirmTopicClaim(topicID: topicID, claimID: claimB, commandID: "command-1")
            XCTFail("同一命令不能更换观点")
        } catch {}
        let alreadyConfirmed = try await store.confirmTopicClaim(topicID: topicID, claimID: claimA, commandID: "command-2")
        XCTAssertFalse(alreadyConfirmed)
        let second = try await store.confirmTopicClaim(topicID: topicID, claimID: claimB, commandID: "command-3")
        XCTAssertTrue(second)
        try db.execute("UPDATE topic_claim_confirmations SET created_at='2026-11-14T00:00:02Z' WHERE claim_id=?", [claimA])
        try db.execute("UPDATE topic_claim_confirmations SET created_at='2026-11-14T00:00:01Z' WHERE claim_id=?", [claimB])
        let ordered = try await store.confirmedTopicClaimIDs(topicID: topicID)
        XCTAssertEqual(ordered, [claimB, claimA])
        try await store.unconfirmTopicClaim(topicID: topicID, claimID: claimA)
        let remaining = try await store.confirmedTopicClaimIDs(topicID: topicID)
        XCTAssertEqual(remaining, [claimB])
        try await store.unconfirmTopicClaim(topicID: topicID, claimID: claimA)
        let stable = try await store.confirmedTopicClaimIDs(topicID: topicID)
        XCTAssertEqual(stable, [claimB])
    }

    func testSourceReadingStatesUpsert() async throws {
        let store = try await openStore()
        let db = await store.db
        let sourceA = try insertSource(db)
        let sourceB = try insertSource(db)
        let empty = try await store.sourceReadingStates()
        XCTAssertTrue(empty.isEmpty)
        try await store.setSourceReadingState(sourceID: sourceA, state: .reading)
        try await store.setSourceReadingState(sourceID: sourceB, state: .read)
        let initial = try await store.sourceReadingStates()
        XCTAssertEqual(initial, [sourceA: .reading, sourceB: .read])
        try await store.setSourceReadingState(sourceID: sourceA, state: .read)
        let updated = try await store.sourceReadingStates()
        XCTAssertEqual(updated, [sourceA: .read, sourceB: .read])
        XCTAssertEqual(SourceReadingState.allCases, [.unread, .reading, .read])
        do {
            try await store.setSourceReadingState(sourceID: UUID().uuidString, state: .unread)
            XCTFail("来源不存在时不能写入阅读状态")
        } catch {}
    }

    func testCaptureMetadataAcceptsOnlyWebURLs() async throws {
        let store = try await openStore()
        let db = await store.db
        let sourceID = try insertSource(db)
        try await store.attachCaptureMetadata(sourceID: sourceID, url: "https://example.com/page")
        let initial = try await store.captureMetadata()
        XCTAssertEqual(initial[sourceID]?.url, "https://example.com/page")
        XCTAssertFalse(initial[sourceID]?.capturedAt.isEmpty ?? true)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: initial[sourceID]?.capturedAt ?? ""))
        try await store.attachCaptureMetadata(sourceID: sourceID, url: "http://example.com/next")
        let updated = try await store.captureMetadata()
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[sourceID]?.url, "http://example.com/next")
        try await store.attachCaptureMetadata(sourceID: sourceID, url: nil)
        let cleared = try await store.captureMetadata()
        XCTAssertNil(cleared[sourceID]?.url)
        for invalid in ["ftp://example.com/a", "file:///tmp/a", "mailto:someone@example.com", "example.com/page"] {
            do {
                try await store.attachCaptureMetadata(sourceID: sourceID, url: invalid)
                XCTFail("非 http/https 链接必须被拒绝：\(invalid)")
            } catch {}
        }
        do {
            try await store.attachCaptureMetadata(sourceID: UUID().uuidString, url: nil)
            XCTFail("来源不存在时不能写入抓取元数据")
        } catch {}
    }

    func testCapturedTextWritesSourceURLMetadata() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordCapturedText("网页选区正文", title: "选区标题", ownership: .external, sourceURL: "https://example.com/selection")
        let metadata = try await store.captureMetadata()
        XCTAssertEqual(metadata[sourceID]?.url, "https://example.com/selection")
        XCTAssertFalse(metadata[sourceID]?.capturedAt.isEmpty ?? true)
    }
}
