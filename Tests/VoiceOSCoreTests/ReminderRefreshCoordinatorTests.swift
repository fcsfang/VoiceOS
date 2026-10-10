import XCTest
import VoiceOSPlatform

@MainActor
final class ReminderRefreshCoordinatorTests: XCTestCase {
    func testBurstAndInFlightEventsCoalesceWithoutConcurrentHandlers() async {
        let started = expectation(description: "first read")
        let finished = expectation(description: "trailing read")
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0; var active = 0; var peak = 0
        let coordinator = ReminderRefreshCoordinator(delay: .milliseconds(5)) {
            calls += 1; active += 1; peak = max(peak,active)
            if calls == 1 { await withCheckedContinuation { gate = $0; started.fulfill() } }
            else { finished.fulfill() }
            active -= 1
        }
        for _ in 0..<20 { coordinator.request() }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<20 { coordinator.request() }
        gate?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(calls,2); XCTAssertEqual(peak,1); coordinator.stop()
    }
    func testStopAndRestartWaitForOldInFlightHandlerToReturn() async {
        let started = expectation(description: "first read")
        let restarted = expectation(description: "new read")
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0; var active = 0; var peak = 0
        let coordinator = ReminderRefreshCoordinator(delay: .milliseconds(5)) {
            calls += 1; active += 1; peak = max(peak,active)
            if calls == 1 { await withCheckedContinuation { gate = $0; started.fulfill() } }
            else { restarted.fulfill() }
            active -= 1
        }
        coordinator.request(); await fulfillment(of: [started], timeout: 2)
        coordinator.stop(); coordinator.request()
        gate?.resume(); await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(calls,2); XCTAssertEqual(peak,1); coordinator.stop()
    }
}
