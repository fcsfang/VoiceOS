import XCTest
@testable import VoiceOSCore

final class MenuBarMarkChecks: XCTestCase {
    private func white(_ width: Int, _ height: Int, ink: [(Int, Int)]) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for (x, y) in ink {
            let offset = (y * width + x) * 4
            rgba[offset] = 0
            rgba[offset + 1] = 0
            rgba[offset + 2] = 0
        }
        return rgba
    }

    func testInkBecomesOpaqueAndIsCroppedToItsBounds() {
        let ink = (0..<6).flatMap { y in [(2, y), (3, y)] }
        let mask = MenuBarMark.derive(rgba: white(6, 6, ink: ink), width: 6, height: 6)
        XCTAssertEqual(mask?.width, 2)
        XCTAssertEqual(mask?.height, 6)
        XCTAssertEqual(mask?.alpha, [UInt8](repeating: 255, count: 12))
    }

    func testBlankTileYieldsNoMark() {
        XCTAssertNil(MenuBarMark.derive(rgba: white(4, 4, ink: []), width: 4, height: 4))
    }

    func testMidToneEdgesGetPartialAlpha() {
        var rgba = white(1, 1, ink: [])
        rgba[0] = 125
        rgba[1] = 125
        rgba[2] = 125
        let mask = MenuBarMark.derive(rgba: rgba, width: 1, height: 1)
        XCTAssertEqual(mask?.alpha, [127])
    }

    func testMismatchedBufferIsRejected() {
        XCTAssertNil(MenuBarMark.derive(rgba: [0, 0, 0], width: 1, height: 1))
        XCTAssertNil(MenuBarMark.derive(rgba: [], width: 0, height: 0))
    }
}
