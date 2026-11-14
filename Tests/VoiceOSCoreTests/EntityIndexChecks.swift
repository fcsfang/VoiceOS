import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class EntityIndexChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-entities-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func insertSource(_ store: VoiceOSStore, text: String, spans: [TranscriptSpan]) async throws -> (sourceID: String, versionID: String) {
        let db = await store.db
        let id = UUID().uuidString, assetID = UUID().uuidString, jobID = UUID().uuidString, transcriptID = UUID().uuidString, versionID = UUID().uuidString
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?, 'external_text','unknown','external','reference_only',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, assetID, "version:" + id, "合成资料", "2026-11-01T00:00:00Z", TimeZone.current.identifier, "assets/" + id])
        try db.execute("INSERT INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,?,'0','original')", [assetID, id, "assets/" + id, "0"])
        try db.execute("INSERT INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','fixture','completed')", [jobID, id, "version:" + id])
        try db.execute("INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at) VALUES(?,?,?,?,?,'verbatim',?,'zh_CN','fixture',?)", [transcriptID, id, assetID, "version:" + id, jobID, text, "2026-11-01T00:00:00Z"])
        try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,?, 'original','system',?)", [versionID, transcriptID, text, String(decoding: try JSONEncoder().encode(spans), as: UTF8.self), "2026-11-01T00:00:00Z"])
        try db.execute("UPDATE transcripts SET current_version_id=? WHERE id=?", [versionID, transcriptID])
        return (id, versionID)
    }

    private func insertSourceWithoutTranscript(_ store: VoiceOSStore) async throws -> String {
        let db = await store.db
        let id = UUID().uuidString
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?, 'external_text','unknown','external','reference_only',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, "asset:" + id, "version:" + id, "空资料", "2026-11-01T00:00:00Z", TimeZone.current.identifier, "assets/" + id])
        return id
    }

    private func commitStatements(_ store: VoiceOSStore, sourceID: String, versionID: String, spanID: String, statements: [String]) async throws {
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID], scalarBudget: Int.max)
        let contextID = try await store.persistLocalContext(context, commandID: UUID().uuidString)
        let attemptID = try await store.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
        let proposals = statements.map {
            ClaimProposal(statement: $0, ownership: .external, references: [ClaimReference(sourceID: sourceID, transcriptVersionID: versionID, spanID: spanID)], contentKind: .statement)
        }
        _ = try await store.commitLocalClaims(attemptID: attemptID, proposals: proposals)
    }

    func testEmptyMaterialProducesNoEntities() async throws {
        let store = try await openStore()
        let source = try await insertSourceWithoutTranscript(store)
        let entities = try await store.refreshEntities(sourceID: source)
        XCTAssertTrue(entities.isEmpty)
        let stored = try await store.entities(sourceID: source)
        XCTAssertTrue(stored.isEmpty)
    }

    func testReplaceEntitiesDeletesPreviousEntries() async throws {
        let store = try await openStore()
        let source = try await insertSourceWithoutTranscript(store)
        try await store.replaceEntities(sourceID: source, entries: [
            SourceEntity(sourceID: source, name: "长期主义", kind: .term, sentenceIDs: ["a", "b"], mentionCount: 3),
            SourceEntity(sourceID: source, name: "深海", kind: .term, sentenceIDs: [], mentionCount: 2)
        ])
        let first = try await store.entities(sourceID: source)
        XCTAssertEqual(first.map { $0.name }, ["长期主义", "深海"])
        try await store.replaceEntities(sourceID: source, entries: [
            SourceEntity(sourceID: source, name: "深海", kind: .term, sentenceIDs: ["c"], mentionCount: 5),
            SourceEntity(sourceID: source, name: "锚点", kind: .term, sentenceIDs: [], mentionCount: 1)
        ])
        let listed = try await store.entities(sourceID: source)
        XCTAssertEqual(listed.map { $0.name }, ["深海", "锚点"])
        XCTAssertEqual(listed.first?.sentenceIDs, ["c"])
        XCTAssertEqual(listed.count, 2)
        let repeated = SourceEntity(sourceID: source, name: "重复", kind: .term, sentenceIDs: [], mentionCount: 1)
        do {
            try await store.replaceEntities(sourceID: source, entries: [repeated, repeated])
            XCTFail("重复实体不能写入")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "实体名称重复")
        }
        let kept = try await store.entities(sourceID: source)
        XCTAssertEqual(kept.count, 2)
        do {
            try await store.replaceEntities(sourceID: UUID().uuidString, entries: [repeated])
            XCTFail("来源不存在时不能写实体")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "来源不存在")
        }
    }

    func testRefreshExtractsRepeatedTermsAndLimitsSentenceIDs() async throws {
        let store = try await openStore()
        let text = "结构思维。结构思维。结构思维。结构思维。"
        let spans = (0..<4).map { TranscriptSpan(textStart: $0 * 5, textEnd: $0 * 5 + 5) }
        let source = try await insertSource(store, text: text, spans: spans)
        try await commitStatements(store, sourceID: source.sourceID, versionID: source.versionID, spanID: spans[0].id, statements: ["我要结构思维，结构思维很重要"])
        let entities = try await store.refreshEntities(sourceID: source.sourceID)
        let term = try XCTUnwrap(entities.first { $0.name == "结构思维" })
        XCTAssertEqual(term.kind, .term)
        XCTAssertEqual(term.mentionCount, 2)
        XCTAssertEqual(term.sentenceIDs, spans.prefix(3).map { $0.id })
        XCTAssertFalse(entities.contains { $0.name == "很重要" })
        XCTAssertEqual(entities.map { $0.mentionCount }, entities.map { $0.mentionCount }.sorted(by: >))
        let stored = try await store.entities(sourceID: source.sourceID)
        XCTAssertEqual(stored, entities)
    }
}
