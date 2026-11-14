import XCTest
@testable import VoiceOSCore

final class ActionUndoStackChecks: XCTestCase {
    private func entry(_ id: Int, from: LocalActionState = .open, to: LocalActionState = .completed) -> ActionUndoEntry {
        ActionUndoEntry(actionID: "action-\(id)", title: "行动 \(id)", from: from, to: to)
    }

    func testRecordsChangesInOrder() {
        var stack = ActionUndoStack()
        stack.record(entry(1))
        stack.record(entry(2))
        XCTAssertEqual(stack.entries.map(\.actionID), ["action-1", "action-2"])
        XCTAssertEqual(stack.count, 2)
        XCTAssertFalse(stack.isEmpty)
    }

    func testPopReturnsMostRecentChangeFirst() {
        var stack = ActionUndoStack()
        stack.record(entry(1))
        stack.record(entry(2))
        XCTAssertEqual(stack.popLast()?.actionID, "action-2")
        XCTAssertEqual(stack.popLast()?.actionID, "action-1")
        XCTAssertNil(stack.popLast())
        XCTAssertTrue(stack.isEmpty)
    }

    func testKeepsOnlyTenMostRecentChanges() {
        var stack = ActionUndoStack()
        for index in 1...12 { stack.record(entry(index)) }
        XCTAssertEqual(stack.count, ActionUndoStack.limit)
        XCTAssertEqual(stack.entries.first?.actionID, "action-3")
        XCTAssertEqual(stack.entries.last?.actionID, "action-12")
    }

    func testIgnoresUnchangedState() {
        var stack = ActionUndoStack()
        stack.record(entry(1, from: .completed, to: .completed))
        XCTAssertTrue(stack.isEmpty)
    }

    func testEntryKeepsPreviousAndNewState() throws {
        var stack = ActionUndoStack()
        stack.record(entry(1, from: .completed, to: .open))
        let popped = try XCTUnwrap(stack.popLast())
        XCTAssertEqual(popped.from, LocalActionState.completed)
        XCTAssertEqual(popped.to, LocalActionState.open)
    }
}
