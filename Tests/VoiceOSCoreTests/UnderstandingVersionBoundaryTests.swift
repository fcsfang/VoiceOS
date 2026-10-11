import XCTest
@testable import VoiceOSCore

private struct VersionBoundaryInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text only") }
}
private actor VersionBoundaryPort: ModelPort {
    let configuration: ModelConfiguration
    let fail: Bool
    var calls = 0
    init(_ version: String, fail: Bool = false) { configuration = .init(provider: "contract_version_fixture", model: version, promptVersion: version, schemaVersion: version, destination: .local); self.fail = fail }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1
        if fail { throw VoiceOSError("合成传输故障") }
        return .init(status: .completed, claims: [])
    }
}
final class UnderstandingVersionBoundaryTests: XCTestCase {
    func testModelAndSchemaUpgradeCannotReplayCompletedOrUnknownExpression() async throws {
        for fail in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let s = try VoiceOSStore(root: root, inspector: VersionBoundaryInspector()); try await s.recover()
            let source = try await s.recordUserExpression("原始表达？这不是自动重新理解的许可。")
            let old = VersionBoundaryPort("v2", fail: fail), new = VersionBoundaryPort("v3")
            do { _ = try await s.understandSource(sourceID: source, using: old) } catch { XCTAssertTrue(fail) }
            do { _ = try await s.understandSource(sourceID: source, using: new); XCTFail("contract upgrade replay") } catch {}
            let calls = await new.calls, attempts = try await s.modelAttempts(sourceID: source)
            XCTAssertEqual(calls, 0); XCTAssertEqual(attempts.count, 1)
            XCTAssertEqual(attempts[0].state, fail ? "unknown" : "completed")
        }
    }
    func testExplicitCorrectedTranscriptCanHaveIndependentNewAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try VoiceOSStore(root: root, inspector: VersionBoundaryInspector()); try await s.recover()
        let source = try await s.recordUserExpression("旧表达"), old = VersionBoundaryPort("v2"), new = VersionBoundaryPort("v3")
        _ = try await s.understandSource(sourceID: source, using: old)
        let records = try await s.sources(), version = try XCTUnwrap(records.first?.transcriptVersionID)
        _ = try await s.correctTranscript(sourceID: source, expectedVersionID: version, text: "更正后的表达")
        _ = try await s.understandSource(sourceID: source, using: new)
        let calls = await new.calls, attempts = try await s.modelAttempts(sourceID: source)
        XCTAssertEqual(calls, 1); XCTAssertEqual(attempts.count, 2)
    }
}
