import Foundation
import XCTest
@testable import VoiceOSCore

final class ExternalActionCommandChecks: XCTestCase {
    private let actionID = "6F1B2A9C-0E73-4D4B-9E2F-7C5A8D3102B4"
    private let commandID = "2C9D8F4A-1B67-4E20-8A3D-5F0C9E7B6A12"

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "voiceos"
        components.host = "action"
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    func testFeedbackParsesAllFields() throws {
        let parsed = try ExternalActionCommand.parse(url("/\(actionID)/feedback", query: [
            URLQueryItem(name: "text", value: "读完了第三章"),
            URLQueryItem(name: "kind", value: "reflection"),
            URLQueryItem(name: "command", value: commandID),
        ]))
        guard case let .feedback(parsedAction, text, kind, parsedCommand) = try XCTUnwrap(parsed) else {
            return XCTFail("期望反馈命令")
        }
        XCTAssertEqual(parsedAction, actionID)
        XCTAssertEqual(text, "读完了第三章")
        XCTAssertEqual(kind, .reflection)
        XCTAssertEqual(parsedCommand, commandID)
    }

    func testFeedbackDefaultsKindToOutcomeAndGeneratesCommand() throws {
        let parsed = try ExternalActionCommand.parse(url("/\(actionID)/feedback", query: [
            URLQueryItem(name: "text", value: "完成"),
        ]))
        guard case let .feedback(_, _, kind, command) = try XCTUnwrap(parsed) else {
            return XCTFail("期望反馈命令")
        }
        XCTAssertEqual(kind, .outcome)
        XCTAssertNotNil(UUID(uuidString: command))
    }

    func testPercentEncodingRoundTrip() throws {
        let text = "空格 与 & = + % # 换行\n引号\" 中文 😀"
        let parsed = try ExternalActionCommand.parse(url("/\(actionID)/feedback", query: [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "command", value: commandID),
        ]))
        guard case let .feedback(_, roundTripped, _, _) = try XCTUnwrap(parsed) else {
            return XCTFail("期望反馈命令")
        }
        XCTAssertEqual(roundTripped, text)
    }

    func testCompleteParses() throws {
        XCTAssertEqual(try ExternalActionCommand.parse(url("/\(actionID)/complete")),
                       .complete(actionID: actionID))
    }

    func testNilReturningURLs() throws {
        let cases: [(name: String, url: URL)] = [
            ("navigation route", url("/\(actionID)")),
            ("unknown route", url("/\(actionID)/open")),
            ("non-voiceos scheme", URL(string: "https://example.com/action/\(actionID)/feedback?text=hello")!),
        ]
        for c in cases {
            XCTAssertNil(try ExternalActionCommand.parse(c.url), c.name)
        }
    }

    func testThrowingURLs() {
        let cases: [(name: String, url: URL, isVoiceOSError: Bool)] = [
            ("invalid action ID", url("/not-a-uuid/feedback", query: [URLQueryItem(name: "text", value: "x")]), true),
            ("empty text", url("/\(actionID)/feedback", query: [URLQueryItem(name: "text", value: "   ")]), false),
            ("missing text", url("/\(actionID)/feedback"), false),
            ("overlong text", url("/\(actionID)/feedback", query: [
                URLQueryItem(name: "text", value: String(repeating: "字", count: ExternalActionCommand.maximumTextLength + 1)),
            ]), false),
            ("unknown query key", url("/\(actionID)/feedback", query: [
                URLQueryItem(name: "text", value: "x"),
                URLQueryItem(name: "note", value: "y"),
            ]), false),
            ("invalid kind", url("/\(actionID)/feedback", query: [
                URLQueryItem(name: "text", value: "x"),
                URLQueryItem(name: "kind", value: "progress"),
            ]), false),
            ("invalid command", url("/\(actionID)/feedback", query: [
                URLQueryItem(name: "text", value: "x"),
                URLQueryItem(name: "command", value: "not-a-uuid"),
            ]), false),
            ("complete with query", url("/\(actionID)/complete", query: [
                URLQueryItem(name: "text", value: "x"),
            ]), false),
        ]
        for c in cases {
            XCTAssertThrowsError(try ExternalActionCommand.parse(c.url), c.name) { error in
                if c.isVoiceOSError { XCTAssertTrue(error is VoiceOSError, c.name) }
            }
        }
    }
}
