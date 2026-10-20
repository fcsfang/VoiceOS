import XCTest
@testable import VoiceOSPlatform

@MainActor
final class CallbackWaitTests: XCTestCase {
    func testSynchronousCompletionResolvesOnceWithoutNativeCancel() async throws {
        let gate = CallbackWait<Int>(); var canceled = 0
        let value = try await gate.wait(timeout: .milliseconds(10)) { complete in
            complete(.success(7)); complete(.success(9)); return { canceled += 1 }
        }
        XCTAssertEqual(value,7); XCTAssertEqual(canceled,0); XCTAssertFalse(gate.isWaiting)
    }
    func testMissingCallbackTimesOutCancelsAndLateReplyDoesNotPoisonNextRead() async throws {
        let gate = CallbackWait<Int>(); var canceled = 0
        var late: (@MainActor (Result<Int,Error>) -> Void)?
        do {
            _ = try await gate.wait(timeout: .milliseconds(10)) { complete in late = complete; return { canceled += 1 } }
            XCTFail("missing callback must terminate")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertEqual(canceled,1); XCTAssertFalse(gate.isWaiting)
        let next = CallbackWait<Int>()
        let value = try await next.wait(timeout: .seconds(1)) { complete in
            late?(.success(99)); complete(.success(5)); return { canceled += 1 }
        }
        XCTAssertEqual(value,5); XCTAssertEqual(canceled,1)
    }
    func testCancellationResolvesWithoutWaitingForNativeCallback() async {
        let gate = CallbackWait<Int>(); let started = expectation(description:"native request started")
        var canceled = 0; var late: (@MainActor (Result<Int,Error>) -> Void)?
        let task = Task {
            try await gate.wait(timeout: .seconds(10)) { complete in late = complete; started.fulfill(); return { canceled += 1 } }
        }
        await fulfillment(of:[started],timeout:1); task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        late?(.success(12)); XCTAssertEqual(canceled,1); XCTAssertFalse(gate.isWaiting)
    }
    func testAlreadyCanceledCallerNeverStartsNativeRead() async {
        let gate = CallbackWait<Int>(); var calls = 0
        let task = Task {
            try await gate.wait(timeout: .seconds(10)) { complete in calls += 1; complete(.success(1)); return {} }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls,0)
    }
    func testRefreshStopAndRestartReleasesNativeWaitBeforeNextHandler() async {
        let started = expectation(description:"old handler waiting"), restarted = expectation(description:"new handler completed")
        var calls = 0, active = 0, peak = 0, canceled = 0
        let coordinator = ReminderRefreshCoordinator(delay:.milliseconds(1)) {
            calls += 1; active += 1; peak = max(peak,active)
            defer { active -= 1 }
            let gate = CallbackWait<Int>()
            do {
                _ = try await gate.wait(timeout:.seconds(10)) { complete in
                    if calls == 1 { started.fulfill() } else { complete(.success(1)) }
                    return { canceled += 1 }
                }
            } catch {}
            if calls == 2 { restarted.fulfill() }
        }
        coordinator.request(); await fulfillment(of:[started],timeout:1)
        coordinator.stop(); coordinator.request(); await fulfillment(of:[restarted],timeout:1)
        XCTAssertEqual(calls,2); XCTAssertEqual(canceled,1); XCTAssertEqual(peak,1); coordinator.stop()
    }
}
