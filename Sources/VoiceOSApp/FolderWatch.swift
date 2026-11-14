import Darwin
import Foundation
import VoiceOSCore

@MainActor
final class FolderWatch {
    private struct State: Codable {
        var folderPath: String?
        var initialized: Bool
        var enabled: Bool
        var fingerprints: [String]
    }

    private let defaults: UserDefaults
    private let key: String
    private var folder: URL?
    private var source: DispatchSourceFileSystemObject?
    private var ledger: FolderWatchLedger
    private var storedFolderPath: String?
    private var enabled: Bool
    private var pending: [String: String] = [:]
    private var scanWork: DispatchWorkItem?
    var onFiles: (([URL]) -> Void)?

    init(root: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "voiceos.folderWatch.v1:" + root.standardizedFileURL.path
        if let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(State.self, from: data) {
            storedFolderPath = state.folderPath
            enabled = state.enabled
            ledger = FolderWatchLedger(fingerprints: Set(state.fingerprints), initialized: state.initialized)
        } else {
            enabled = false
            ledger = FolderWatchLedger()
        }
    }

    var isWatching: Bool { source != nil }

    func resume() {
        guard enabled, let path = storedFolderPath, FileManager.default.fileExists(atPath: path) else { return }
        _ = start(folder: URL(fileURLWithPath: path, isDirectory: true))
    }

    @discardableResult
    func start(folder url: URL) -> Bool {
        closeSource()
        let standardized = url.standardizedFileURL
        if storedFolderPath != standardized.path {
            ledger = FolderWatchLedger()
            pending = [:]
        }
        storedFolderPath = standardized.path
        enabled = true
        let descriptor = open(standardized.path, O_EVTONLY)
        guard descriptor >= 0 else {
            persist()
            return false
        }
        folder = standardized
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduleScan(after: 0.3)
            }
        }
        source.setCancelHandler { _ = close(descriptor) }
        self.source = source
        source.resume()
        persist()
        scheduleScan(after: 0)
        return true
    }

    func stop() {
        closeSource()
        enabled = false
        persist()
    }

    private func closeSource() {
        scanWork?.cancel()
        scanWork = nil
        source?.cancel()
        source = nil
        folder = nil
        pending = [:]
    }

    private func scheduleScan(after delay: TimeInterval) {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scan()
            }
        }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan() {
        scanWork = nil
        guard let folder else { return }
        let current = entries(in: folder)
        if !ledger.initialized {
            ledger.adoptBaseline(current)
            persist()
            return
        }
        let candidates = ledger.newEntries(in: current)
        let present = Set(current.map(\.path))
        pending = pending.filter { present.contains($0.key) }
        var ready: [FolderWatchEntry] = []
        for candidate in candidates {
            if pending[candidate.path] == candidate.fingerprint {
                ready.append(candidate)
            } else {
                pending[candidate.path] = candidate.fingerprint
            }
        }
        if !ready.isEmpty {
            ledger.record(ready)
            for entry in ready { pending[entry.path] = nil }
            persist()
            onFiles?(ready.map { URL(fileURLWithPath: $0.path) })
        }
        if !pending.isEmpty { scheduleScan(after: 1.0) }
    }

    private func entries(in folder: URL) -> [FolderWatchEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { return nil }
            return FolderWatchEntry(path: url.standardizedFileURL.path, size: Int64(size), modified: modified)
        }
    }

    private func persist() {
        let state = State(folderPath: storedFolderPath, initialized: ledger.initialized, enabled: enabled, fingerprints: ledger.fingerprints.sorted())
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
