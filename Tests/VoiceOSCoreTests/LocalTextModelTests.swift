import XCTest
import Foundation
import VoiceOSPlatform
final class LocalTextModelTests: XCTestCase {
    func testLocalConfigurationUsesExistingProviderWithoutExposingCredential() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("# local\nOPENAI_BASE_URL=\"https://api.chiyi.cc/v1\"\nOPENAI_API_KEY=\"test-secret\"\n".utf8).write(to: file)
        let port = try LocalTextModel.load(from: file)
        XCTAssertEqual(port.configuration.provider, "responses:api.chiyi.cc")
        XCTAssertEqual(port.configuration.model, "gpt-6.1-sol")
        let relevance = try LocalTextModel.loadRelevance(from:file)
        XCTAssertEqual(relevance.configuration.provider,port.configuration.provider)
        XCTAssertEqual(relevance.configuration.promptVersion,"relevance-single-v1")
        let outcome=try LocalTextModel.loadOutcome(from:file)
        XCTAssertEqual(outcome.configuration.provider,port.configuration.provider)
        XCTAssertEqual(outcome.configuration.model,"gpt-6.1-sol")
        XCTAssertEqual(outcome.configuration.promptVersion,"discussion-outcomes-reuse-v1")
    }
    func testMalformedDuplicateAndOversizedConfigurationFailWithoutEchoingContents() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for text in ["OPENAI_API_KEY=secret-not-json", "OPENAI_API_KEY=\"test-secret\"\nOPENAI_API_KEY=\"second-secret\"", String(repeating: "test-secret", count: 2000)] {
            try Data(text.utf8).write(to: file)
            do { _ = try LocalTextModel.load(from: file); XCTFail("must reject") }
            catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
        }
    }
}
