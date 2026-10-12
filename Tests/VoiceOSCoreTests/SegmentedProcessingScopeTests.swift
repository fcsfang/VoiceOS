import XCTest
@testable import VoiceOSCore

private struct ScopeInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { .init(duration:2,kind:"audio") }
}
private struct ScopeSpeech: SpeechPort {
    let text: String
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        .init(text:text,spans:[TranscriptSpan(textStart:0,textEnd:text.unicodeScalars.count,startMS:0,endMS:2000)])
    }
}
final class SegmentedProcessingScopeTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("segment-scope-"+UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    func config(_ model: String = "scope-fixture", destination: ModelDestination = .local) -> ModelConfiguration {
        .init(provider:"scope-test",model:model,promptVersion:"v1",schemaVersion:"v1",destination:destination)
    }
    func store() async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root:root,inspector:ScopeInspector()); try await s.recover(); return s
    }
    func save(_ text: String, store: VoiceOSStore) async throws -> String {
        let file = root.appendingPathComponent(UUID().uuidString+".wav")
        try Data("synthetic media inspector fixture".utf8).write(to:file)
        let id = try await store.importPersonalAudio(file)
        try await store.processTranscriptions(using:ScopeSpeech(text:text))
        return id
    }
    func testLocalPreparationPreservesWholeParentAndCreatesNoExecution() async throws {
        let s = try await store()
        let id = try await save(String(repeating:"原话。",count:2000),store:s)
        let a = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config())
        let b = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config())
        XCTAssertNotEqual(a.id,b.id); XCTAssertEqual(a.contentDigest,b.contentDigest)
        XCTAssertEqual(a.plan.segments.map(\.text).joined(),a.plan.source.text)
        try await s.validateSegmentedExpressionProcessingScope(a,extraction:config(),aggregation:config())
        let policy = try await s.sourcePolicy(sourceID:id), attempts = try await s.modelAttempts(), queue = try await s.processingIntents()
        XCTAssertTrue(policy.localOnly); XCTAssertEqual(policy.version,1)
        XCTAssertTrue(attempts.isEmpty); XCTAssertTrue(queue.isEmpty)
    }
    func testCloudPreparationNeedsExistingTextGrantAndRevocationInvalidates() async throws {
        let s = try await store()
        let id = try await save(String(repeating:"甲",count:5000),store:s), cloud = config(destination:.cloud)
        do { _ = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:cloud,aggregation:cloud); XCTFail() } catch {}
        _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
        let scope = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:cloud,aggregation:cloud)
        _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:2,localOnly:true)
        do { try await s.validateSegmentedExpressionProcessingScope(scope,extraction:cloud,aggregation:cloud); XCTFail() } catch {}
        let attempts = try await s.modelAttempts(); XCTAssertTrue(attempts.isEmpty)
    }
    func testCorrectionConfigurationAndForgedPlanAreRejected() async throws {
        let s = try await store()
        let id = try await save(String(repeating:"原话。",count:2000),store:s)
        let scope = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config())
        do { try await s.validateSegmentedExpressionProcessingScope(scope,extraction:config("different"),aggregation:config()); XCTFail() } catch {}
        let p = scope.plan
        let altered = TranscriptSegmentationPlan(algorithm:p.algorithm,source:p.source,policyVersion:p.policyVersion,
            scalarBudget:p.scalarBudget,segments:Array(p.segments.dropLast()),contentDigest:p.contentDigest)
        let forged = SegmentedExpressionProcessingScope(id:scope.id,plan:altered,extraction:scope.extraction,
            aggregation:scope.aggregation,evidenceScalarBudget:scope.evidenceScalarBudget,contentDigest:scope.contentDigest)
        do { try await s.validateSegmentedExpressionProcessingScope(forged,extraction:config(),aggregation:config()); XCTFail() } catch {}
        _ = try await s.correctTranscript(sourceID:id,expectedVersionID:p.source.transcriptVersionID,text:String(repeating:"改",count:5000))
        do { try await s.validateSegmentedExpressionProcessingScope(scope,extraction:config(),aggregation:config()); XCTFail() } catch {}
    }
    func testExternalUnknownSpeakerCannotBecomePersonalProcessingScope() async throws {
        let s = try await store(), file = root.appendingPathComponent("external.wav")
        try Data("synthetic external media".utf8).write(to:file)
        let id = try await s.importFile(file)
        try await s.processTranscriptions(using:ScopeSpeech(text:String(repeating:"资料",count:2500)))
        do { _ = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config()); XCTFail() } catch {}
        let records = try await s.sources(); XCTAssertEqual(records[0].origin,"external"); XCTAssertEqual(records[0].speaker,"unknown")
    }
    func testShortTextInvalidBudgetAndMixedDestinationsAreRejected() async throws {
        let s = try await store()
        let id = try await save("短文字",store:s)
        do { _ = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config()); XCTFail() } catch {}
        do { _ = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config(),evidenceScalarBudget:0); XCTFail() } catch {}
        do { _ = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config(destination:.cloud)); XCTFail() } catch {}
        // A smaller explicit segment budget remains part of the scope identity.
        let a = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config(),segmentScalarBudget:2)
        let b = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config(),segmentScalarBudget:1)
        XCTAssertNotEqual(a.contentDigest,b.contentDigest)
    }
}
