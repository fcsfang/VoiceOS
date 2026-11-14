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

public struct ActionUndoStack: Equatable, Sendable {
    public static let limit = 10
    public private(set) var entries: [ActionUndoEntry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public var count: Int { entries.count }

    public mutating func record(_ entry: ActionUndoEntry) {
        guard entry.from != entry.to else { return }
        entries.append(entry)
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    public mutating func popLast() -> ActionUndoEntry? {
        entries.popLast()
    }
}
