import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class ActionUndoStackChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-undo-stack-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func entry(_ id: Int, from: LocalActionState = .open, to: LocalActionState = .completed) -> ActionUndoEntry {
        ActionUndoEntry(actionID: "action-\(id)", title: "行动 \(id)", from: from, to: to)
    }

    private func dispositionChange(_ id: Int, from: MaterialDisposition = .active, to: MaterialDisposition = .archived) -> MaterialDispositionChange {
        MaterialDispositionChange(sourceIDs: ["source-\(id)"], title: "材料 \(id)", from: from, to: to)
    }

    private func titleChange(_ id: Int, from: String? = nil, to: String? = "新标题") -> MaterialTitleChange {
        MaterialTitleChange(sourceID: "source-\(id)", title: "材料 \(id)", from: from, to: to)
    }

    private func kindName(_ change: WorkspaceChange) -> String {
        switch change {
        case .action: return "action"
        case .materialDisposition: return "disposition"
        case .materialTitle: return "title"
        }
    }

    func testRecordsChangesInOrder() {
        var stack = ActionUndoStack()
        stack.record(entry(1))
        stack.record(entry(2))
        XCTAssertEqual(stack.entries.compactMap(\.actionEntry).map(\.actionID), ["action-1", "action-2"])
        XCTAssertEqual(stack.count, 2)
        XCTAssertFalse(stack.isEmpty)
    }

    func testPopReturnsMostRecentChangeFirst() {
        var stack = ActionUndoStack()
        stack.record(entry(1))
        stack.record(entry(2))
        XCTAssertEqual(stack.popLast()?.actionEntry?.actionID, "action-2")
        XCTAssertEqual(stack.popLast()?.actionEntry?.actionID, "action-1")
        XCTAssertNil(stack.popLast())
        XCTAssertTrue(stack.isEmpty)
    }

    func testKeepsOnlyTenMostRecentChanges() {
        var stack = ActionUndoStack()
        for index in 1...12 { stack.record(entry(index)) }
        XCTAssertEqual(stack.count, ActionUndoStack.limit)
        XCTAssertEqual(stack.entries.first?.actionEntry?.actionID, "action-3")
        XCTAssertEqual(stack.entries.last?.actionEntry?.actionID, "action-12")
    }

    func testIgnoresUnchangedState() {
        var stack = ActionUndoStack()
        stack.record(entry(1, from: .completed, to: .completed))
        stack.record(.materialDisposition(dispositionChange(1, from: .archived, to: .archived)))
        stack.record(.materialTitle(titleChange(1, from: "同一标题", to: "同一标题")))
        XCTAssertTrue(stack.isEmpty)
    }

    func testEntryKeepsPreviousAndNewState() throws {
        var stack = ActionUndoStack()
        stack.record(entry(1, from: .completed, to: .open))
        let popped = try XCTUnwrap(stack.popLast()?.actionEntry)
        XCTAssertEqual(popped.from, LocalActionState.completed)
        XCTAssertEqual(popped.to, LocalActionState.open)
    }

    func testEntrySuccessorDefaultsToNil() {
        let value = ActionUndoEntry(actionID: "action-1", title: "行动 1", from: .completed, to: .open)
        XCTAssertNil(value.successorID)
    }

    func testEntryKeepsSuccessorID() throws {
        var stack = ActionUndoStack()
        stack.record(ActionUndoEntry(actionID: "action-1", title: "行动 1", from: .completed, to: .open, successorID: "action-2"))
        let popped = try XCTUnwrap(stack.popLast()?.actionEntry)
        XCTAssertEqual(popped.successorID, "action-2")
    }

    func testMixedChangesKeepOrderAndLimit() {
        var stack = ActionUndoStack()
        for index in 1...12 {
            switch index % 3 {
            case 0: stack.record(entry(index))
            case 1: stack.record(.materialDisposition(dispositionChange(index)))
            default: stack.record(.materialTitle(titleChange(index)))
            }
        }
        XCTAssertEqual(stack.count, ActionUndoStack.limit)
        XCTAssertEqual(stack.entries.map(kindName), ["action", "disposition", "title", "action", "disposition", "title", "action", "disposition", "title", "action"])
    }

    func testSkipReasonMatrix() {
        let action = entry(1, from: .open, to: .completed)
        let disposition = MaterialDispositionChange(sourceIDs: ["source-1", "source-2"], title: "材料", from: .active, to: .archived)
        let title = MaterialTitleChange(sourceID: "source-1", title: "材料", from: "旧标题", to: "新标题")
        let cases: [(name: String, check: () -> Void)] = [
            ("action unchanged", { XCTAssertNil(action.skipReason(current: .completed)) }),
            ("action changed", { XCTAssertEqual(action.skipReason(current: .open), .objectChanged) }),
            ("action missing", { XCTAssertEqual(action.skipReason(current: nil), .objectChanged) }),
            ("disposition unchanged", { XCTAssertNil(disposition.skipReason(current: ["source-1": .archived, "source-2": .archived])) }),
            ("disposition moved again", { XCTAssertEqual(disposition.skipReason(current: ["source-1": .trashed, "source-2": .archived]), .objectChanged) }),
            ("disposition partially moved", { XCTAssertEqual(disposition.skipReason(current: ["source-1": .archived]), .objectChanged) }),
            ("title unchanged", { XCTAssertNil(title.skipReason(currentTitle: "新标题")) }),
            ("title renamed again", { XCTAssertEqual(title.skipReason(currentTitle: "另一个标题"), .objectChanged) }),
            ("title missing", { XCTAssertEqual(title.skipReason(currentTitle: nil), .objectChanged) }),
            ("message", { XCTAssertEqual(UndoSkip.objectChanged.message, "已跳过：对象已变化") }),
        ]
        for c in cases { c.check() }
    }

    func testDispositionUndoRestoresPreviousState() async throws {
        struct Case {
            let name: String
            let text: String
            let title: String
            let moved: MaterialDisposition
            let isRestored: (SourceRecord) -> Bool
        }
        let cases = [
            Case(name: "archive", text: "归档撤销的合成材料", title: "归档撤销", moved: .archived, isRestored: { !$0.isArchived }),
            Case(name: "trash", text: "回收站撤销的合成材料", title: "回收站撤销", moved: .trashed, isRestored: { !$0.isTrashed }),
        ]
        let store = try await openStore()
        for c in cases {
            let id = try await store.recordCapturedText(c.text, title: c.title, ownership: .personal)
            try await store.setMaterialDisposition(sourceIDs: [id], disposition: c.moved)
            var sources = try await store.sources()
            let moved = try XCTUnwrap(sources.first { $0.id == id })
            XCTAssertEqual(moved.disposition, c.moved, c.name)

            try await store.setMaterialDisposition(sourceIDs: [id], disposition: .active)
            sources = try await store.sources()
            let restored = try XCTUnwrap(sources.first { $0.id == id })
            XCTAssertEqual(restored.disposition, .active, c.name)
            XCTAssertTrue(c.isRestored(restored), c.name)
            XCTAssertEqual(restored.transcript, c.text, c.name)

            try await store.setMaterialDisposition(sourceIDs: [id], disposition: .active)
            sources = try await store.sources()
            let repeated = sources.first { $0.id == id }
            XCTAssertEqual(repeated?.disposition, .active, c.name)
        }
    }

    func testTitleUndoRestoresPreviousTitle() async throws {
        let store = try await openStore()
        let id = try await store.recordCapturedText("改名撤销的合成材料", title: "改名撤销", ownership: .personal)
        try await store.renameRecording(sourceID: id, title: "第一标题")
        try await store.renameRecording(sourceID: id, title: "第二标题")
        let renamedSources = try await store.sources()
        let renamed = try XCTUnwrap(renamedSources.first { $0.id == id })
        XCTAssertEqual(renamed.presentation?.manualTitle, "第二标题")
        let change = MaterialTitleChange(sourceID: id, title: renamed.displayTitle, from: "第一标题", to: "第二标题")
        XCTAssertNil(change.skipReason(currentTitle: renamed.presentation?.manualTitle))
        try await store.renameRecording(sourceID: id, title: change.from)
        let undoneSources = try await store.sources()
        let undone = try XCTUnwrap(undoneSources.first { $0.id == id })
        XCTAssertEqual(undone.presentation?.manualTitle, "第一标题")
        XCTAssertEqual(change.skipReason(currentTitle: undone.presentation?.manualTitle), .objectChanged)
    }
}
