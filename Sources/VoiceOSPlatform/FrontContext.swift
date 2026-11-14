import AppKit
import CoreGraphics

public struct FrontContext: Equatable, Sendable {
    public let app: String
    public let window: String?

    public init(app: String, window: String?) {
        self.app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanWindow = window?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.window = cleanWindow.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
    }

    public var display: String {
        guard let window else { return app }
        return app + " · " + window
    }
}

public enum FrontContextReader {
    public static func current() -> FrontContext? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let name = frontmost.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return FrontContext(app: name, window: windowTitle(ownerPID: frontmost.processIdentifier))
    }

    private static func windowTitle(ownerPID: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let title = window[kCGWindowName as String] as? String else { continue }
            if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        }
        return nil
    }
}
