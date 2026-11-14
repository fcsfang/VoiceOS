public struct ActionUndoEntry: Equatable, Sendable {
    public let actionID: String
    public let title: String
    public let from: LocalActionState
    public let to: LocalActionState
    public let successorID: String?

    public init(actionID: String, title: String, from: LocalActionState, to: LocalActionState, successorID: String? = nil) {
        self.actionID = actionID
        self.title = title
        self.from = from
        self.to = to
        self.successorID = successorID
    }
}

public struct MaterialDispositionChange: Equatable, Sendable {
    public let sourceIDs: [String]
    public let title: String
    public let from: MaterialDisposition
    public let to: MaterialDisposition

    public init(sourceIDs: [String], title: String, from: MaterialDisposition, to: MaterialDisposition) {
        self.sourceIDs = sourceIDs
        self.title = title
        self.from = from
        self.to = to
    }
}

public struct MaterialTitleChange: Equatable, Sendable {
    public let sourceID: String
    public let title: String
    public let from: String?
    public let to: String?

    public init(sourceID: String, title: String, from: String?, to: String?) {
        self.sourceID = sourceID
        self.title = title
        self.from = from
        self.to = to
    }
}

public enum WorkspaceChange: Equatable, Sendable {
    case action(ActionUndoEntry)
    case materialDisposition(MaterialDispositionChange)
    case materialTitle(MaterialTitleChange)

    public var actionEntry: ActionUndoEntry? {
        guard case .action(let entry) = self else { return nil }
        return entry
    }

    var unchanged: Bool {
        switch self {
        case .action(let entry): return entry.from == entry.to
        case .materialDisposition(let change): return change.from == change.to
        case .materialTitle(let change): return change.from == change.to
        }
    }
}

public enum UndoSkip: Equatable, Sendable {
    case objectChanged

    public var message: String { "已跳过：对象已变化" }
}

public extension ActionUndoEntry {
    func skipReason(current: LocalActionState?) -> UndoSkip? { current == to ? nil : .objectChanged }
}

public extension MaterialDispositionChange {
    func skipReason(current: [String: MaterialDisposition]) -> UndoSkip? {
        sourceIDs.allSatisfy { current[$0] == to } ? nil : .objectChanged
    }
}

public extension MaterialTitleChange {
    func skipReason(currentTitle: String?) -> UndoSkip? { currentTitle == to ? nil : .objectChanged }
}

public struct ActionUndoStack: Equatable, Sendable {
    public static let limit = 10
    public private(set) var entries: [WorkspaceChange] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public var count: Int { entries.count }

    public mutating func record(_ entry: ActionUndoEntry) {
        record(.action(entry))
    }

    public mutating func record(_ change: WorkspaceChange) {
        guard !change.unchanged else { return }
        entries.append(change)
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    public mutating func popLast() -> WorkspaceChange? {
        entries.popLast()
    }
}
