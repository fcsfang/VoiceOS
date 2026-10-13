import XCTest
import Foundation
@testable import VoiceOSCore

private struct ImpactInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private actor ImpactReminders: RemindersPort {
    var item: ReminderSnapshot?
    var writes = 0
    func create(calendarID: String, title: String, marker: String) async throws {
        writes += 1; item = .init(id: "impact-item", title: title, completed: false, marker: marker, dueDate: .some(.none))
    }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] { item.map { [$0] } ?? [] }
    func complete() { let old = item!; item = .init(id: old.id,title: old.title,completed: true,marker: old.marker,dueDate: old.dueDate) }
}
final class CorrectionImpactTests: XCTestCase {
    private var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("correction-impact-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: base,withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func fixture() async throws -> (VoiceOSStore,String,String,String,ImpactReminders) {
        let store = try VoiceOSStore(root: base.appendingPathComponent(UUID().uuidString),inspector: ImpactInspector())
        try await store.recover()
        let text = "我要整理研究资料。", source = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: source,expectedVersion: 1,localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source]), input = context.sources[0]
        let contextID = try await store.persistLocalContext(context)
        let attempt = try await store.reserveLocalModelAttempt(contextID: contextID,model: "fixture",promptVersion: "v1",schemaVersion: "v1")
        let ids = try await store.commitLocalClaims(attemptID: attempt,proposals: [
            .init(statement: text,ownership: .userTentative,references: [.init(sourceID: source,transcriptVersionID: input.transcriptVersionID,spanID: input.spans[0].id)],action: .init(title: "整理研究资料",kind: .task,quote: text))
        ])
        let action = try await store.actions()[0]
        return (store,source,ids[0],action.id,ImpactReminders())
    }
    private func connect(_ store: VoiceOSStore,_ port: ImpactReminders) async throws -> ReminderLink {
        _ = try await store.setReminderAccess(calendarID: "impact",title: "impact",enabled: true,expectedVersion: 0)
        try await store.activateExtractedTasks(expectedAccessVersion: 1,using: port)
        return try await store.reminderLinks()[0]
    }
    private func correct(_ store: VoiceOSStore,_ claim: String) async throws {
        _ = try await store.reviewClaim(claimID: claim,expectedVersion: 0,action: .correct,statement: "我暂时不整理研究资料。",note: "原意被误解")
    }
    func testClaimCorrectionListsExternalImpactWithoutModifyingTaskOrGeneratingOutcome() async throws {
        let (store,_,claim,action,port) = try await fixture()
        let link = try await connect(store,port)
        try await correct(store,claim)
        let impacts = try await store.correctionActionImpacts()
        XCTAssertEqual(impacts.count,1); XCTAssertEqual(impacts[0].action.id,action); XCTAssertEqual(impacts[0].link?.id,link.id)
        XCTAssertEqual(impacts[0].roots[0].kind,"claim_correction"); XCTAssertTrue(impacts[0].summary.contains("尚未执行补偿"))
        let repeatImpacts = try await store.correctionActionImpacts(); XCTAssertEqual(repeatImpacts[0].digest,impacts[0].digest)
        let writes = await port.writes; XCTAssertEqual(writes,1)
        let item = await port.item; XCTAssertFalse(item!.completed)
        let feedback = try await store.actionFeedback(actionID: action); XCTAssertTrue(feedback.isEmpty)
        let current = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(current.validity,"frozen"); XCTAssertEqual(current.state,"open")
    }
    func testEndorsementAndPrivacyFreezeAreNotDiagnosedAsErrors() async throws {
        let (store,_,claim,_,_) = try await fixture()
        _ = try await store.reviewClaim(claimID: claim,expectedVersion: 0,action: .endorse)
        let endorsed = try await store.correctionActionImpacts(); XCTAssertTrue(endorsed.isEmpty)
        let (privateStore,source,_,_,_) = try await fixture()
        _ = try await privateStore.setSourceLocalOnly(sourceID: source,expectedVersion: 2,localOnly: true)
        let restricted = try await privateStore.correctionActionImpacts(); XCTAssertTrue(restricted.isEmpty)
    }
    func testTranscriptCorrectionKeepsRootAndLocalOnlyImpactWithoutExternalCompensation() async throws {
        let (store,source,_,_,port) = try await fixture()
        let history = try await store.transcriptHistory(sourceID: source)
        _ = try await store.correctTranscript(sourceID: source,expectedVersionID: history[0].id,text: "我不要整理研究资料。")
        let impacts = try await store.correctionActionImpacts(); XCTAssertEqual(impacts.count,1)
        XCTAssertEqual(impacts[0].roots[0].sourceID,source); XCTAssertEqual(impacts[0].roots[0].kind,"transcription_error")
        XCTAssertNil(impacts[0].link); XCTAssertTrue(impacts[0].summary.contains("不需要外部撤销"))
        let writes = await port.writes; XCTAssertEqual(writes,0)
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testCompletedFactRemainsCompletedAfterCorrectionAndReadback() async throws {
        let (store,_,claim,action,port) = try await fixture()
        let link = try await connect(store,port)
        await port.complete()
        try await store.readReminder(linkID: link.id,calendarID: link.calendarID,using: port,expectedAccessVersion: 1)
        try await correct(store,claim)
        let impacts = try await store.correctionActionImpacts(); XCTAssertTrue(impacts[0].summary.contains("保留外部已完成事实"))
        XCTAssertEqual(impacts[0].action.state,"completed")
        let feedback = try await store.actionFeedback(actionID: action); XCTAssertTrue(feedback.isEmpty)
        let item = await port.item; XCTAssertTrue(item!.completed)
    }
    func testMigrationFreezingAloneDoesNotCreateCorrectionImpact() async throws {
        let (store,_,_,_,_) = try await fixture()
        let package = base.appendingPathComponent("no-error-package")
        try await store.exportPackage(to: package,includeMedia: true)
        let root = base.appendingPathComponent("no-error-restored")
        try await VoiceOSStore.restorePackage(from: package,to: root,inspector: ImpactInspector())
        let restored = try VoiceOSStore(root: root,inspector: ImpactInspector()); try await restored.recover()
        let impacts = try await restored.correctionActionImpacts(); XCTAssertTrue(impacts.isEmpty)
    }
    func testCorrectionImpactRestoresFromHistoricalRecordsWithoutRecreatingExternalTask() async throws {
        let (store,_,claim,_,port) = try await fixture()
        _ = try await connect(store,port); try await correct(store,claim)
        let before = try await store.correctionActionImpacts()
        let package = base.appendingPathComponent("error-package")
        try await store.exportPackage(to: package,includeMedia: true)
        let root = base.appendingPathComponent("error-restored")
        try await VoiceOSStore.restorePackage(from: package,to: root,inspector: ImpactInspector())
        let restored = try VoiceOSStore(root: root,inspector: ImpactInspector()); try await restored.recover()
        let after = try await restored.correctionActionImpacts()
        XCTAssertEqual(after.count,1); XCTAssertEqual(after[0].roots.map(\.id),before[0].roots.map(\.id))
        XCTAssertTrue(after[0].summary.contains("未核对"))
        let access = try await restored.reminderAccess(); XCTAssertNil(access)
        let writes = await port.writes; XCTAssertEqual(writes,1)
        let valid = try await restored.integrityCheck(); XCTAssertTrue(valid)
    }
}
