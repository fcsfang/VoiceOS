import Foundation
import VoiceOSCore
import VoiceOSPlatform

struct NoteHistoryMemory: Codable, Sendable {
    private static let credential = KeychainCredential(service: "VoiceOS Hindsight Cloud", account: "VoiceOS")

    private struct Pilot: Decodable {
        struct Source: Decodable { let documentID: String }
        let bankID: String
        let sources: [Source]
    }

    let bankID: String
    // false also covers an interrupted request. Keep its ID so it can be
    // retried or erased even if the server accepted it before disconnecting.
    var documents: [String: Bool]

    private static func file(_ root: URL) -> URL {
        root.appendingPathComponent("note-history-memory.json")
    }

    static func load(root: URL) throws -> Self? {
        let file = file(root)
        let memory: Self
        if FileManager.default.fileExists(atPath: file.path) {
            memory = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        } else {
            let legacy = root.appendingPathComponent("note-history-pilot.json")
            guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
            let pilot = try JSONDecoder().decode(Pilot.self, from: Data(contentsOf: legacy))
            memory = .init(bankID: pilot.bankID, documents: pilot.sources.reduce(into: [:]) {
                $0[$1.documentID] = false
            })
        }
        guard Self.isIdentifier(memory.bankID), memory.documents.keys.allSatisfy(Self.isIdentifier) else {
            throw VoiceOSError("历史记忆库配置无效")
        }
        return memory
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func isConfigured(root: URL) -> Bool {
        [file(root), root.appendingPathComponent("note-history-pilot.json")].contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func save(root: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.file(root), options: .atomic)
    }

    static func documentID(_ note: StoredMaterialNote) -> String { "voiceos-note-" + note.id.lowercased() }

    static func members(_ note: StoredMaterialNote) -> [String] {
        note.expressionKey.split(separator: "|").map(String.init)
    }

    static func canIndex(_ note: StoredMaterialNote, catalog: [String: SourceRecord]) -> Bool {
        let ids = members(note)
        return !ids.isEmpty && MaterialNoteGating.unavailableReason(memberIDs: ids, catalog: catalog) == nil
            && note.transcriptVersions == MaterialNoteGating.transcriptVersions(memberIDs: ids, catalog: catalog)
    }

    static func body(_ note: MaterialNote) -> String {
        NoteBoardAdapting.blocks(for: note)
            .filter { $0.kind == "text" }
            .flatMap { block in [block.heading, block.text].compactMap { $0 } + (block.paragraphs ?? []).map(\.text) }
            .joined(separator: "\n\n")
    }

    private func request(_ path: [String], method: String, payload: [String: Any]? = nil) throws -> URLRequest {
        let inaccessible = VoiceOSError("VoiceOS 需要读取 Hindsight 的钥匙串权限")
        let credentialValue: String?
        do {
            credentialValue = try Self.credential.read()
        } catch {
            throw inaccessible
        }
        guard let key = credentialValue else { throw VoiceOSError("钥匙串中缺少 Hindsight 密钥") }
        guard !key.isEmpty else { throw inaccessible }
        let base = URL(string: "https://api.hindsight.vectorize.io/v1/default/banks")!.appendingPathComponent(bankID)
        let url = path.reduce(base) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = method
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let payload { request.httpBody = try JSONSerialization.data(withJSONObject: payload) }
        return request
    }

    func retain(_ note: StoredMaterialNote) async throws {
        struct Result: Decodable { let success: Bool }
        let request = try request(["memories"], method: "POST", payload: [
            "async": false, "items": [[
                "document_id": Self.documentID(note),
                "content": note.note.title + "\n\n" + Self.body(note.note),
                "tags": ["voiceos-note"]
            ]]
        ])
        let reply = try await DirectModelHTTPTransport().send(request)
        guard (200..<300).contains(reply.status),
              try JSONDecoder().decode(Result.self, from: reply.body).success else {
            throw VoiceOSError("同步历史记忆失败（HTTP \(reply.status)）")
        }
    }

    func remove(documentID: String) async throws {
        let request = try request(["documents", documentID], method: "DELETE")
        let reply = try await DirectModelHTTPTransport().send(request)
        guard (200..<300).contains(reply.status) || reply.status == 404 else {
            throw VoiceOSError("撤回历史记忆失败（HTTP \(reply.status)）")
        }
    }

    func recalledDocuments(query: String) async throws -> [String] {
        struct Result: Decodable {
            struct Match: Decodable { let document_id: String? }
            let results: [Match]
        }
        let request = try request(["memories", "recall"], method: "POST", payload: [
            "query": query, "types": ["experience", "world"], "max_tokens": 4096,
            "tags": ["voiceos-note"], "tags_match": "any_strict"
        ])
        let reply = try await DirectModelHTTPTransport().send(request)
        guard reply.status == 200 else { throw VoiceOSError("历史检索失败（HTTP \(reply.status)）") }
        var seen = Set<String>()
        return try JSONDecoder().decode(Result.self, from: reply.body).results.compactMap(\.document_id)
            .filter { seen.insert($0).inserted }
    }
}

extension ControlCenter {
    func scheduleNoteHistorySync() {
        guard let root = libraryRoot, let store, NoteHistoryMemory.isConfigured(root: root) else { return }
        noteHistorySyncPending = true
        guard noteHistorySyncWorker == nil else { return }
        noteHistorySyncWorker = Task {
            defer { noteHistorySyncWorker = nil }
            while noteHistorySyncPending && !Task.isCancelled {
                noteHistorySyncPending = false
                do {
                    try await synchronizeNoteHistory(root: root, store: store)
                } catch {
                    noteHistorySyncIssue = error.localizedDescription
                }
            }
        }
    }

    private func synchronizeNoteHistory(root: URL, store: VoiceOSStore) async throws {
        guard var memory = try NoteHistoryMemory.load(root: root) else { return }
        let catalog = Dictionary(uniqueKeysWithValues: try await store.sources().map { ($0.id, $0) })
        let notes = try await store.recentMaterialNotes(limit: nil)
            .filter { NoteHistoryMemory.canIndex($0, catalog: catalog) }
        let liveIDs = Set(notes.map(NoteHistoryMemory.documentID))
        let removals = Set(memory.documents.keys).subtracting(liveIDs)
        let additions = notes.filter { memory.documents[NoteHistoryMemory.documentID($0)] != true }
        guard !removals.isEmpty || !additions.isEmpty else {
            noteHistorySyncIssue = nil
            return
        }
        noteHistorySyncing = true
        defer { noteHistorySyncing = false }
        try memory.save(root: root)
        var failure: String?
        for id in removals.sorted() {
            do {
                try await memory.remove(documentID: id)
                memory.documents.removeValue(forKey: id)
                try memory.save(root: root)
            } catch { failure = error.localizedDescription }
        }
        for note in additions {
            let members = NoteHistoryMemory.members(note)
            let current = try await store.latestMaterialNote(memberSourceIDs: members)
            let currentCatalog = Dictionary(uniqueKeysWithValues: try await store.sourceRecords(ids: members).map { ($0.id, $0) })
            guard current?.id == note.id, NoteHistoryMemory.canIndex(note, catalog: currentCatalog) else { continue }
            let id = NoteHistoryMemory.documentID(note)
            memory.documents[id] = false
            try memory.save(root: root)
            do {
                try await memory.retain(note)
                memory.documents[id] = true
                try memory.save(root: root)
            } catch { failure = error.localizedDescription }
            if noteHistorySyncPending { break }
        }
        noteHistorySyncIssue = failure
    }
}

struct NoteHistoryResult: Codable {
    let noteID: String
    let sourceNoteIDs: [String: String]
    let sourceTitles: [String: String]
    let recordVersions: [String: String]
    let annotations: [NoteHistoryAnnotation]

    static func file(root: URL, sourceID: String) -> URL {
        root.appendingPathComponent("note-history", isDirectory: true)
            .appendingPathComponent(sourceID).appendingPathExtension("json")
    }

    static func read(root: URL, sourceID: String) -> Self? {
        guard let data = try? Data(contentsOf: file(root: root, sourceID: sourceID)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(root: URL, sourceID: String) throws {
        let url = Self.file(root: root, sourceID: sourceID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func version(_ source: SourceRecord) -> String {
        "\(source.transcriptVersionID ?? "")|\(source.policyVersion)|\(source.state)|\(source.localOnly)"
    }
}
