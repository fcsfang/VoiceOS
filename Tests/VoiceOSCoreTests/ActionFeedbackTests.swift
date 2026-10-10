import XCTest
import Foundation
@testable import VoiceOSCore

private struct FeedbackInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("Text must not be decoded as media") }
}
final class ActionFeedbackTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-" + UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:base.path) { try FileManager.default.removeItem(at:base) } }
    func fixture() async throws -> (VoiceOSStore,ActionRecord) {
        let s = try VoiceOSStore(root:base.appendingPathComponent("root"),inspector:FeedbackInspector()); try await s.recover()
        let id = try await s.recordUserExpression("我会整理验证素材")
        let c = try await s.prepareLocalTranscriptContext(sourceIDs:[id]); let input = c.sources[0]
        let context = try await s.persistLocalContext(c)
        let attempt = try await s.reserveLocalModelAttempt(contextID:context,model:"fixture",promptVersion:"fixture",schemaVersion:"fixture")
        _ = try await s.commitLocalClaims(attemptID:attempt,proposals:[ClaimProposal(statement:input.text,ownership:.userTentative,references:[ClaimReference(sourceID:id,transcriptVersionID:input.transcriptVersionID,spanID:input.spans[0].id)],action:ExtractedAction(title:"整理验证素材",kind:.task,quote:input.text))])
        let actions = try await s.actions(); let action = try XCTUnwrap(actions.first)
        _ = try await s.setActionState(actionID:action.id,expectedVersion:1,state:.completed)
        let completed = try await s.actions(includeHistory:true)
        return (s,try XCTUnwrap(completed.first))
    }
    func testFeedbackDoesNotChangeCompletionOrValidateBelief() async throws {
        let (s,a) = try await fixture()
        let id = try await s.recordActionFeedback(actionID:a.id,expectedVersion:2,kind:.outcome,text:"合成结果：素材已整理")
        let sources = try await s.sources(); let source = try XCTUnwrap(sources.first { $0.id == id })
        XCTAssertTrue(source.localOnly); XCTAssertEqual(source.origin,"user"); XCTAssertEqual(source.feedbackActionID,a.id)
        let records = try await s.actionFeedback(actionID:a.id); XCTAssertEqual(records.count,1); XCTAssertEqual(records[0].actionVersion,2)
        let actions = try await s.actions(includeHistory:true); XCTAssertEqual(actions.count,1); XCTAssertEqual(actions[0].version,2); XCTAssertEqual(actions[0].state,"completed")
        let claims = try await s.candidateClaims(); XCTAssertTrue(claims.allSatisfy { $0.evidenceState == "unverified" })
    }
    func testIdempotencePinsOriginalVersionAfterLaterActionChange() async throws {
        let (s,a) = try await fixture()
        let first = try await s.recordActionFeedback(actionID:a.id,expectedVersion:2,kind:.reflection,text:"下次分批处理",commandID:"same")
        _ = try await s.setActionState(actionID:a.id,expectedVersion:2,state:.open)
        let replay = try await s.recordActionFeedback(actionID:a.id,expectedVersion:2,kind:.reflection,text:"下次分批处理",commandID:"same")
        XCTAssertEqual(first,replay)
        do { _ = try await s.recordActionFeedback(actionID:a.id,expectedVersion:2,kind:.outcome,text:"下次分批处理",commandID:"same"); XCTFail() } catch {}
        let records = try await s.actionFeedback(actionID:a.id); XCTAssertEqual(records[0].actionVersion,2)
    }
    func testStaleVersionCreatesNoFeedbackSource() async throws {
        let (s,a) = try await fixture()
        do { _ = try await s.recordActionFeedback(actionID:a.id,expectedVersion:1,kind:.outcome,text:"stale"); XCTFail() } catch {}
        let sources = try await s.sources(); XCTAssertEqual(sources.count,1)
    }
    func testFeedbackOrderAndAssociationSurvivePortableRestore() async throws {
        let (s,a) = try await fixture()
        for text in ["第一条结果","第二条反思","第三条结果"] { _ = try await s.recordActionFeedback(actionID:a.id,expectedVersion:2,kind:.reflection,text:text) }
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to:package,includeMedia:true)
        let target = base.appendingPathComponent("restored"); try await VoiceOSStore.restorePackage(from:package,to:target,inspector:FeedbackInspector())
        let restored = try VoiceOSStore(root:target,inspector:FeedbackInspector()); try await restored.recover()
        let records = try await restored.actionFeedback(actionID:a.id)
        XCTAssertEqual(records.map(\.text),["第一条结果","第二条反思","第三条结果"])
        let access = try await restored.reminderAccess(); XCTAssertNil(access)
    }
    func testCorrectionPreservesFeedbackAssociationAndOriginalHistory() async throws {
        let (s,a) = try await fixture()
        let id = try await s.recordActionFeedback(actionID:a.id,expectedVersion:2,kind:.outcome,text:"原始结果")
        let sources = try await s.sources(); let source = try XCTUnwrap(sources.first { $0.id == id })
        _ = try await s.correctTranscript(sourceID:id,expectedVersionID:source.transcriptVersionID!,text:"校对结果")
        let records = try await s.actionFeedback(actionID:a.id); XCTAssertEqual(records[0].text,"校对结果"); XCTAssertEqual(records[0].actionVersion,2)
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to:package,includeMedia:true)
        try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("restored"),inspector:FeedbackInspector())
    }
    func testRestoreRejectsMissingAssociationEvenWithMatchingManifest() async throws {
        let (s,a) = try await fixture(); _ = try await s.recordActionFeedback(actionID:a.id,expectedVersion:2,kind:.outcome,text:"结果")
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to:package)
        let file = package.appendingPathComponent("action_feedback.jsonl"); try Data().write(to:file)
        let mf = package.appendingPathComponent("manifest.json"); var m = try JSONSerialization.jsonObject(with:Data(contentsOf:mf)) as! [String:Any]
        var counts = m["counts"] as! [String:Int]; counts["action_feedback"] = 0; m["counts"] = counts
        var files = m["files"] as! [[String:Any]]; let i = files.firstIndex { $0["path"] as? String == "action_feedback.jsonl" }!; let hash = try DurableFiles.hash(file); files[i]["sha256"] = hash.1; files[i]["bytes"] = hash.0; m["files"] = files
        try JSONSerialization.data(withJSONObject:m).write(to:mf)
        let target = base.appendingPathComponent("rejected")
        do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:FeedbackInspector()); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("反馈")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
    func testPackagePreviewDescribesOmittedOriginalsWithoutCreatingLibrary() async throws {
        let (s,_) = try await fixture(); let package = base.appendingPathComponent("preview")
        try await s.exportPackage(to:package)
        let summary = try VoiceOSStore.packageSummary(at:package)
        XCTAssertEqual(summary.version,10); XCTAssertEqual(summary.sourceCount,1)
        XCTAssertEqual(summary.omittedAssetCount,1); XCTAssertFalse(summary.mediaIncluded)
        XCTAssertFalse(FileManager.default.fileExists(atPath:package.appendingPathComponent("voiceos.sqlite").path))
    }
    func testPackagePreviewRejectsSymlinkManifestAndUnknownVersion() async throws {
        let (s,_) = try await fixture(); let package = base.appendingPathComponent("preview")
        try await s.exportPackage(to:package)
        let mf = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:mf)) as! [String:Any]
        manifest["version"] = 999; try JSONSerialization.data(withJSONObject:manifest).write(to:mf)
        XCTAssertThrowsError(try VoiceOSStore.packageSummary(at:package))
        let outside = base.appendingPathComponent("outside-manifest"); try FileManager.default.moveItem(at:mf,to:outside)
        try FileManager.default.createSymbolicLink(at:mf,withDestinationURL:outside)
        XCTAssertThrowsError(try VoiceOSStore.packageSummary(at:package))
    }

}
