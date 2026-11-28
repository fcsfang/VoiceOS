import Foundation

/// On-disk paths shared by the app, CLI, and library recovery.
package enum LibraryLayout {
    package static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceOS", isDirectory: true)
    }

    package static func database(in root: URL) -> URL {
        root.appendingPathComponent("voiceos.sqlite", isDirectory: false)
    }
}
