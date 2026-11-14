import AppKit
import Foundation

public struct ClipboardHistory: Sendable {
    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: String
        public let text: String
        public let isURL: Bool
    }

    public static let limit = 20
    public static let maximumTextLength = 100_000
    public private(set) var entries: [Entry] = []

    public init() {}

    @discardableResult
    public mutating func record(_ raw: String, isURL: Bool = false) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maximumTextLength else { return false }
        guard entries.first?.text != text else { return false }
        entries.insert(Entry(id: UUID().uuidString, text: text, isURL: isURL), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        return true
    }
}

@MainActor
public final class ClipboardMonitor {
    public private(set) var history = ClipboardHistory()
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history.record(text)
            return
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let url = urls.first {
            history.record(url.absoluteString, isURL: true)
        }
    }
}
