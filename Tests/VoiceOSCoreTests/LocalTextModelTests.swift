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
