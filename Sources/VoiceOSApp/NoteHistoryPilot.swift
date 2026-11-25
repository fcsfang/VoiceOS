import Foundation
import Security
import VoiceOSCore

/// A library-local manifest limits the pilot to the notes explicitly selected for it.
struct NoteHistoryPilot: Codable, Equatable {
    struct Source: Codable, Equatable {
        let documentID: String
        let sourceID: String
        let noteID: String
    }

    let bankID: String
    let targetSourceIDs: [String]
    let sources: [Source]

    static func load(root: URL?) -> Self? {
        guard let root,
              let data = try? Data(contentsOf: root.appendingPathComponent("note-history-pilot.json")),
              let pilot = try? JSONDecoder().decode(Self.self, from: data),
              !pilot.bankID.isEmpty, pilot.bankID.utf8.allSatisfy({
                  (48...57).contains($0) || (97...122).contains($0) || $0 == 45
              }) else { return nil }
        return pilot
    }

    func recalledDocuments(query: String) async throws -> Set<String> {
        struct Result: Decodable {
            struct Match: Decodable { let document_id: String? }
            let results: [Match]
        }
        let queryKey: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "VoiceOS Hindsight Cloud",
            kSecAttrAccount as String: "VoiceOS", kSecReturnData as String: true
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(queryKey as CFDictionary, &value) == errSecSuccess,
              let bytes = value as? Data, let key = String(data: bytes, encoding: .utf8), !key.isEmpty else {
            throw VoiceOSError("钥匙串中缺少 Hindsight 密钥")
        }
        let url = URL(string: "https://api.hindsight.vectorize.io/v1/default/banks")!
            .appendingPathComponent(bankID).appendingPathComponent("memories").appendingPathComponent("recall")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "types": ["experience", "world"], "max_tokens": 600
        ])
        let reply = try await DirectModelHTTPTransport().send(request)
        guard reply.status == 200 else { throw VoiceOSError("历史检索失败（HTTP \(reply.status)）") }
        return Set(try JSONDecoder().decode(Result.self, from: reply.body).results.compactMap(\.document_id))
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
