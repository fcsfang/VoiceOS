import XCTest
@testable import VoiceOSCore

final class DiscussionEntryTokenChecks: XCTestCase {
    func testSearchRowTokenResolvesKindAndIdentity() {
        let material = DiscussionEntryToken(raw: "material:abc")
        XCTAssertEqual(material?.kind, .material)
        XCTAssertEqual(material?.id, "abc")
        let action = DiscussionEntryToken(raw: "action:def")
        XCTAssertEqual(action?.kind, .action)
        XCTAssertEqual(action?.id, "def")
        let claim = DiscussionEntryToken(raw: "claim:ghi")
        XCTAssertEqual(claim?.kind, .claim)
        XCTAssertEqual(claim?.id, "ghi")
        let topic = DiscussionEntryToken(raw: "topic:jkl")
        XCTAssertEqual(topic?.kind, .topic)
        XCTAssertEqual(topic?.id, "jkl")
    }
    func testUnknownKindOrMissingIdentityDoesNotResolve() {
        XCTAssertNil(DiscussionEntryToken(raw: "unknown:abc"))
        XCTAssertNil(DiscussionEntryToken(raw: "material:"))
        XCTAssertNil(DiscussionEntryToken(raw: "material"))
        XCTAssertNil(DiscussionEntryToken(raw: ":abc"))
        XCTAssertNil(DiscussionEntryToken(raw: ""))
    }
}
