import XCTest
@testable import VoiceOSCore

private struct IntentInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text only") }
}
final class ExpressionProcessingIntentTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func config(_ version: String = "v1", destination: ModelDestination = .cloud) -> ModelConfiguration {
        .init(provider: "intent_fixture", model: "synthetic", promptVersion: version, schemaVersion: version, destination: destination)
    }
    func store() async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root: root, inspector: IntentInspector()); try await s.recover(); return s
    }
    func testPreparationCannotGrantCloudPermissionOrCreateWork() async throws {
        let s = try await store(), source = try await s.recordUserExpression("明确个人文字，不允许快照代替授权。")
        do { _ = try await s.prepareExpressionProcessingIntent(sourceID: source, cognition: config(), association: config()); XCTFail("implicit permission") } catch {}
        let policy = try await s.sourcePolicy(sourceID: source), attempts = try await s.modelAttempts(), associations = try await s.expressionAssociationAttempts()
        XCTAssertTrue(policy.localOnly); XCTAssertEqual(policy.version, 1)
        XCTAssertTrue(attempts.isEmpty); XCTAssertTrue(associations.isEmpty)
    }
    func testAuthorizedIntentPinsFullSourceEpochAndBothPortsWithoutDispatch() async throws {
        let s = try await store(), source = try await s.recordUserExpression("我想记录一个猜想，并核对以前的表达。")
        _ = try await s.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        let snapshot = try await s.prepareExpressionProcessingIntent(sourceID: source, cognition: config(), association: config())
        let decoded = try JSONDecoder().decode(ExpressionProcessingIntentSnapshot.self, from: JSONEncoder().encode(snapshot))
        try await s.validateExpressionProcessingIntent(decoded, cognition: config(), association: config())
        XCTAssertEqual(decoded.policyVersion, 2); XCTAssertEqual(decoded.context.sources[0].sourceID, source)
        XCTAssertEqual(decoded.context.scalarBudget, 4000)
        let attempts = try await s.modelAttempts(), associations = try await s.expressionAssociationAttempts()
        XCTAssertTrue(attempts.isEmpty); XCTAssertTrue(associations.isEmpty)
        for pair in [(config("v2"), config()), (config(), config("v2"))] {
            do { try await s.validateExpressionProcessingIntent(decoded, cognition: pair.0, association: pair.1); XCTFail("configuration drift") } catch {}
        }
    }
    func testCorrectionAndRegrantCannotReactivateOriginalIntent() async throws {
        let s = try await store(), source = try await s.recordUserExpression("原话：保留原处理范围。")
        _ = try await s.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        let snapshot = try await s.prepareExpressionProcessingIntent(sourceID: source, cognition: config(), association: config())
        _ = try await s.correctTranscript(sourceID: source, expectedVersionID: snapshot.context.sources[0].transcriptVersionID, text: "更正后的文字需新意图。")
        do { try await s.validateExpressionProcessingIntent(snapshot, cognition: config(), association: config()); XCTFail("new text") } catch {}
        let fresh = try await s.prepareExpressionProcessingIntent(sourceID: source, cognition: config(), association: config())
        _ = try await s.setSourceLocalOnly(sourceID: source, expectedVersion: 2, localOnly: true)
        _ = try await s.setSourceLocalOnly(sourceID: source, expectedVersion: 3, localOnly: false)
        do { try await s.validateExpressionProcessingIntent(fresh, cognition: config(), association: config()); XCTFail("regrant old scope") } catch {}
    }
    func testMixedDestinationsAndForgedIntentFailBeforeAnyDispatch() async throws {
        let s = try await store(), source = try await s.recordUserExpression("合成个人表达")
        do { _ = try await s.prepareExpressionProcessingIntent(sourceID: source, cognition: config(destination: .local), association: config()); XCTFail("mixed destinations") } catch {}
        let valid = try await s.prepareExpressionProcessingIntent(sourceID: source, cognition: config(destination: .local), association: config(destination: .local))
        let forged = ExpressionProcessingIntentSnapshot(id: valid.id, context: valid.context, policyVersion: valid.policyVersion, cognition: valid.cognition, association: valid.association, contentDigest: "changed")
        do { try await s.validateExpressionProcessingIntent(forged, cognition: config(destination: .local), association: config(destination: .local)); XCTFail("forged digest") } catch {}
    }
}
