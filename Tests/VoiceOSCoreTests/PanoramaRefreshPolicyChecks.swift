import XCTest
@testable import VoiceOSCore

extension CoreFlowTests {
    func testHiddenWorkspaceChangeWaitsForPanoramaVisibility() {
        var policy = PanoramaRefreshPolicy()
        XCTAssertFalse(policy.workspaceChanged())
        XCTAssertTrue(policy.isStale)
        XCTAssertTrue(policy.setVisible(true))
        policy.markRefreshed()
        XCTAssertFalse(policy.isStale)
        XCTAssertFalse(policy.setVisible(true))
    }

    func testVisibleWorkspaceChangeRefreshesImmediately() {
        var policy = PanoramaRefreshPolicy(isVisible: true, isStale: false)
        XCTAssertTrue(policy.workspaceChanged())
        XCTAssertFalse(policy.isStale)
        policy.markRefreshed()
        XCTAssertTrue(policy.workspaceChanged())
    }
}
