/// Whether a panorama rebuild is due now or should wait until the page is visible.
public struct PanoramaRefreshPolicy: Equatable, Sendable {
    public private(set) var isVisible: Bool
    public private(set) var isStale: Bool

    public init(isVisible: Bool = false, isStale: Bool = true) {
        self.isVisible = isVisible
        self.isStale = isStale
    }

    /// Records a visibility change. Returns true when a refresh is due.
    public mutating func setVisible(_ visible: Bool) -> Bool {
        isVisible = visible
        return visible && isStale
    }

    /// Records a workspace change. Returns true when the page is visible and should refresh now.
    public mutating func workspaceChanged() -> Bool {
        if isVisible { return true }
        isStale = true
        return false
    }

    public mutating func markRefreshed() {
        isStale = false
    }
}
