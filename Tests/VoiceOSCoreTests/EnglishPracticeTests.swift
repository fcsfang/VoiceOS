import XCTest
import Foundation
@testable import VoiceOSCore

private struct EnglishPracticeInspector:MediaInspector {
    func inspect(_ url:URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
final class EnglishPracticeTests:XCTestCase {
    var root:URL!
    override func setUpWithError() throws { root=FileManager.default.temporaryDirectory.appendingPathComponent("english-practice-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:root.path) { try FileManager.default.removeItem(at:root) } }
    func store(_ name:String="root") async throws -> VoiceOSStore { let s=try VoiceOSStore(root:root.appendingPathComponent(name),inspector:EnglishPracticeInspector());try await s.recover();return s }
    func quote(_ snapshot:EnglishPracticeSnapshot,_ index:Int,_ text:String?=nil)->OutcomeSourceEvidence {
        let source=snapshot.context.sources[index]
        return .init(reference:.init(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id),quote:text ?? source.text)
    }
    func suggestion(_ q:OutcomeSourceEvidence)->EnglishSuggestionProposal { .init(kind:.grammar,original:q,suggestedText:"The model has two layers.",explanation:"Text-only suggestion: use has with a singular subject.",possibleTranscriptIssue:true) }
    func testPersonalMixedTextOriginalAndNoCognitiveSideEffects() async throws {
        let s=try await store(),old=try await s.recordUserExpression("Earlier practice: the model have one layer."),current=try await s.recordUserExpression("The model have two layers. 这里的layer表示网络层。")
        let snapshot=try await s.prepareEnglishPractice(currentSourceID:current,priorSourceIDs:[old])
        try await s.validateEnglishPractice(snapshot)
        XCTAssertEqual(snapshot.context.sources.map(\.sourceID),[current,old]);XCTAssertTrue(snapshot.context.sources[0].text.contains("网络层"));XCTAssertTrue(snapshot.context.sources.allSatisfy(\.localOnly))
        let proposals=[suggestion(quote(snapshot,0,"The model have two layers."))]
        let comparison=EnglishComparisonProposal(kind:.similarIssue,currentSuggestionIndex:0,current:proposals[0].original,prior:quote(snapshot,1,"the model have one layer."),explanation:"Both quoted transcripts use have with model; transcription may be wrong.")
        try VoiceOSStore.validateEnglishProposals(suggestions:proposals,comparisons:[comparison],snapshot:snapshot)
        let attempts=try await s.modelAttempts(),claims=try await s.candidateClaims(),actions=try await s.actions();XCTAssertTrue(attempts.isEmpty);XCTAssertTrue(claims.isEmpty);XCTAssertTrue(actions.isEmpty)
    }
    func testCompleteSelectedTextPermissionsAndBudgetNoSilentFiltering() async throws {
        let s=try await store(),old=try await s.recordUserExpression("Old personal practice."),current=try await s.recordUserExpression("Current personal practice.")
        _=try await s.setSourceLocalOnly(sourceID:current,expectedVersion:1,localOnly:false)
        do { _=try await s.prepareEnglishPractice(currentSourceID:current,priorSourceIDs:[old],destination:.cloud);XCTFail() } catch {}
        _=try await s.setSourceLocalOnly(sourceID:old,expectedVersion:1,localOnly:false)
        let input=try await s.prepareEnglishPractice(currentSourceID:current,priorSourceIDs:[old],destination:.cloud);try await s.validateEnglishPractice(input)
        do { _=try await s.prepareEnglishPractice(currentSourceID:current,priorSourceIDs:[old],scalarBudget:30);XCTFail() } catch {}
        do { _=try await s.prepareEnglishPractice(currentSourceID:current,priorSourceIDs:[current]);XCTFail() } catch {}
        do { _=try await s.prepareEnglishPractice(currentSourceID:current,priorSourceIDs:[old,old]);XCTFail() } catch {}
        do { _=try await s.prepareEnglishPractice(currentSourceID:current,scalarBudget:8001);XCTFail() } catch {}
    }
    func testCorrectionAndRevocationInvalidateEvenExcludedPriorInput() async throws {
        for mode in ["currentCorrection","priorCorrection","priorRevoke"] {
            let s=try await store(mode),old=try await s.recordUserExpression("Old model have one layer."),current=try await s.recordUserExpression("Current model have two layers.")
            for id in [old,current] { _=try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false) }
            let snapshot=try await s.prepareEnglishPractice(currentSourceID:current,priorSourceIDs:[old],destination:.cloud)
            if mode=="priorRevoke" { _=try await s.setSourceLocalOnly(sourceID:old,expectedVersion:2,localOnly:true) }
            else { let source=snapshot.context.sources[mode=="currentCorrection" ? 0:1];_=try await s.correctTranscript(sourceID:source.sourceID,expectedVersionID:source.transcriptVersionID,text:"Corrected: the model has layers.") }
            do { try await s.validateEnglishPractice(snapshot);XCTFail(mode) } catch {}
        }
    }
    func testFalseQuotesVersionRoleSuggestionIndicesAndDuplicatesRejected() async throws {
        let s=try await store(),old=try await s.recordUserExpression("The model have one layer."),current=try await s.recordUserExpression("The model have two layers.")
        let snapshot=try await s.prepareEnglishPractice(currentSourceID:current,priorSourceIDs:[old]),q=quote(snapshot,0),proposal=suggestion(q)
        let badSuggestions=[suggestion(quote(snapshot,1)),suggestion(quote(snapshot,0,"The model has three layers.")),suggestion(.init(reference:.init(sourceID:current,transcriptVersionID:UUID().uuidString,spanID:q.reference.spanID),quote:q.quote)),.init(kind:.grammar,original:q,suggestedText:"",explanation:"empty is invalid")]
        for p in badSuggestions { XCTAssertThrowsError(try VoiceOSStore.validateEnglishProposals(suggestions:[p],comparisons:[],snapshot:snapshot)) }
        XCTAssertThrowsError(try VoiceOSStore.validateEnglishProposals(suggestions:[proposal,proposal],comparisons:[],snapshot:snapshot))
        let badComparisons:[EnglishComparisonProposal]=[
            .init(kind:.similarIssue,currentSuggestionIndex:1,current:q,prior:quote(snapshot,1),explanation:"out of range"),
            .init(kind:.similarIssue,currentSuggestionIndex:0,current:q,prior:q,explanation:"current cannot be prior"),
            .init(kind:.similarIssue,currentSuggestionIndex:0,current:quote(snapshot,0,"two layers"),prior:quote(snapshot,1),explanation:"comparison must match suggestion quote"),
            .init(kind:.similarIssue,currentSuggestionIndex:0,current:q,prior:quote(snapshot,1,"invented past error"),explanation:"false previous quote")]
        for c in badComparisons { XCTAssertThrowsError(try VoiceOSStore.validateEnglishProposals(suggestions:[proposal],comparisons:[c],snapshot:snapshot)) }
        let valid=EnglishComparisonProposal(kind:.differentExpression,currentSuggestionIndex:0,current:q,prior:quote(snapshot,1),explanation:"The count changed; no mastery assertion.")
        XCTAssertThrowsError(try VoiceOSStore.validateEnglishProposals(suggestions:[proposal],comparisons:[valid,valid],snapshot:snapshot))
    }
    func testPreviewTamperingAndPortableOriginalsKeepVersions() async throws {
        let s=try await store(),id=try await s.recordUserExpression("My model have layers."),snapshot=try await s.prepareEnglishPractice(currentSourceID:id)
        let encoded=try JSONEncoder().encode(snapshot),decoded=try JSONDecoder().decode(EnglishPracticeSnapshot.self,from:encoded);try await s.validateEnglishPractice(decoded)
        var data=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any]);data["currentSourceID"]=UUID().uuidString
        let forged=try JSONDecoder().decode(EnglishPracticeSnapshot.self,from:JSONSerialization.data(withJSONObject:data))
        do { try await s.validateEnglishPractice(forged);XCTFail() } catch {}
        let package=root.appendingPathComponent("package");try await s.exportPackage(to:package,includeMedia:true)
        try await VoiceOSStore.restorePackage(from:package,to:root.appendingPathComponent("restored"),inspector:EnglishPracticeInspector())
        let restored=try await store("restored"),again=try await restored.prepareEnglishPractice(currentSourceID:id)
        XCTAssertEqual(again.context.sources[0].transcriptVersionID,snapshot.context.sources[0].transcriptVersionID);XCTAssertEqual(again.context.sources[0].text,snapshot.context.sources[0].text)
        let models=try await restored.modelAttempts();XCTAssertTrue(models.isEmpty)
    }
}
