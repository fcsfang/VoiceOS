import Foundation

/// Coalesces bursts, serializes work, and keeps one trailing refresh while busy.
@MainActor
public final class ReminderRefreshCoordinator {
    private let handler: @MainActor () async -> Void
    private let delay: Duration
    private var worker: Task<Void, Never>?
    private var pending = false
    private var generation = 0
    public init(delay: Duration = .milliseconds(500), handler: @escaping @MainActor () async -> Void) { self.delay = delay; self.handler = handler }
    public func request() {
        pending = true
        guard worker == nil else { return }
        let epoch = generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; if self.pending { self.request() } }
            do {
                repeat {
                    try await Task.sleep(for: self.delay)
                    try Task.checkCancellation()
                    guard self.generation == epoch else { return }
                    self.pending = false
                    await self.handler()
                } while self.pending && !Task.isCancelled && self.generation == epoch
            } catch {}
        }
    }
    public func stop() { generation += 1; pending = false; worker?.cancel() }
}
