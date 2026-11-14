import XCTest
@testable import VoiceOSCore

extension CoreFlowTests {
    func testCaptureLinkParsesCompleteRequest() throws {
        let url = try XCTUnwrap(URL(string: "voiceos://capture?text=%E4%BD%A0%E5%A5%BD&title=%E6%A0%87%E9%A2%98&url=https%3A%2F%2Fexample.com%2Fa&x-success=shortcuts%3A%2F%2Frun%3Fname%3Dsave"))
        let link = try XCTUnwrap(CaptureLink.parse(url))
        XCTAssertEqual(link.text, "你好")
        XCTAssertEqual(link.title, "标题")
        XCTAssertEqual(link.url, "https://example.com/a")
        XCTAssertEqual(link.successURL?.absoluteString, "shortcuts://run?name=save")
        XCTAssertEqual(CaptureLink.successCallback(try XCTUnwrap(link.successURL), sourceID: "S1")?.absoluteString,
                       "shortcuts://run?name=save&source_id=S1")
    }

    func testCaptureLinkAcceptsURLWithoutText() throws {
        let link = try XCTUnwrap(CaptureLink.parse(try XCTUnwrap(URL(string: "voiceos://capture?url=https%3A%2F%2Fexample.com"))))
        XCTAssertNil(link.text)
        XCTAssertEqual(link.url, "https://example.com")
    }

    func testCaptureLinkRejectsMissingContent() throws {
        XCTAssertNil(CaptureLink.parse(try XCTUnwrap(URL(string: "voiceos://capture?title=only"))))
        XCTAssertNil(CaptureLink.parse(try XCTUnwrap(URL(string: "voiceos://capture?text=&url="))))
    }

    func testCaptureLinkRejectsForeignSchemeAndHost() throws {
        XCTAssertNil(CaptureLink.parse(try XCTUnwrap(URL(string: "https://capture?text=x"))))
        XCTAssertNil(CaptureLink.parse(try XCTUnwrap(URL(string: "voiceos://task?id=1"))))
    }

    func testCaptureLinkRejectsCallbackWithoutScheme() throws {
        XCTAssertNil(CaptureLink.parse(try XCTUnwrap(URL(string: "voiceos://capture?text=x&x-success=not-a-url"))))
    }
}
