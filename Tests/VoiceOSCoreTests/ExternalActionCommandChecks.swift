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

    func testNavigationRouteReturnsNil() throws {
        XCTAssertNil(try ExternalActionCommand.parse(url("/\(actionID)")))
    }

    func testUnknownRouteReturnsNil() throws {
        XCTAssertNil(try ExternalActionCommand.parse(url("/\(actionID)/open")))
    }

    func testNonVoiceOSSchemeReturnsNil() throws {
        let external = URL(string: "https://example.com/action/\(actionID)/feedback?text=hello")!
        XCTAssertNil(try ExternalActionCommand.parse(external))
    }

    func testInvalidActionIDThrows() {
        XCTAssertThrowsError(try ExternalActionCommand.parse(url("/not-a-uuid/feedback", query: [
            URLQueryItem(name: "text", value: "x"),
        ]))) { XCTAssertTrue($0 is VoiceOSError) }
    }

    func testEmptyTextThrows() {
        XCTAssertThrowsError(try ExternalActionCommand.parse(url("/\(actionID)/feedback", query: [
            URLQueryItem(name: "text", value: "   "),
        ])))
    }

    func testMissingTextThrows() {
        XCTAssertThrowsError(try ExternalActionCommand.parse(url("/\(actionID)/feedback")))
    }

    func testOverlongTextThrows() {
        let text = String(repeating: "字", count: ExternalActionCommand.maximumTextLength + 1)
        XCTAssertThrowsError(try ExternalActionCommand.parse(url("/\(actionID)/feedback", query: [
            URLQueryItem(name: "text", value: text),
        ])))
    }

    func testUnknownQueryKeyThrows() {
        XCTAssertThrowsError(try ExternalActionCommand.parse(url("/\(actionID)/feedback", query: [
            URLQueryItem(name: "text", value: "x"),
            URLQueryItem(name: "note", value: "y"),
        ])))
    }

    func testInvalidKindThrows() {
        XCTAssertThrowsError(try ExternalActionCommand.parse(url("/\(actionID)/feedback", query: [
            URLQueryItem(name: "text", value: "x"),
            URLQueryItem(name: "kind", value: "progress"),
        ])))
    }

    func testInvalidCommandThrows() {
        XCTAssertThrowsError(try ExternalActionCommand.parse(url("/\(actionID)/feedback", query: [
            URLQueryItem(name: "text", value: "x"),
            URLQueryItem(name: "command", value: "not-a-uuid"),
        ])))
    }

    func testCompleteRejectsQuery() {
        XCTAssertThrowsError(try ExternalActionCommand.parse(url("/\(actionID)/complete", query: [
            URLQueryItem(name: "text", value: "x"),
        ])))
    }
}