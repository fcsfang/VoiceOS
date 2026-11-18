import Foundation

public struct MarkdownMirror: Sendable {
    public let directory: URL
    public let minimumInterval: TimeInterval
    private var lastWrite: Date?
    private var writtenDocuments: [String: String] = [:]

    public init(directory: URL, minimumInterval: TimeInterval = 60) {
        self.directory = directory
        self.minimumInterval = minimumInterval
    }

    @discardableResult
    public mutating func write(sources: [SourceRecord], claims: [CandidateClaim], actions: [ActionRecord], now: Date = Date()) throws -> Bool {
        if let lastWrite, now.timeIntervalSince(lastWrite) < minimumInterval { return false }
        let materials = directory.appendingPathComponent("materials", isDirectory: true)
        let claimDirectory = directory.appendingPathComponent("claims", isDirectory: true)
        let actionDirectory = directory.appendingPathComponent("actions", isDirectory: true)
        for folder in [materials, claimDirectory, actionDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try writeDocuments(sources.map { ($0.id, material($0)) }, to: materials)
        try writeDocuments(claims.filter { $0.validity == "current" }.map { ($0.id, claim($0)) }, to: claimDirectory)
        try writeDocuments(actions.filter { $0.validity == "current" }.map { ($0.id, action($0)) }, to: actionDirectory)
        lastWrite = now
        return true
    }

    private mutating func writeDocuments(_ documents: [(String, String)], to folder: URL) throws {
        for (id, text) in documents {
            let url = folder.appendingPathComponent(id + ".md")
            // An unchanged document is already on disk; the atomic rewrite only
            // churns its mtime.
            if writtenDocuments[url.path] == text, FileManager.default.fileExists(atPath: url.path) { continue }
            try Data(text.utf8).write(to: url, options: .atomic)
            writtenDocuments[url.path] = text
        }
    }

    private func material(_ record: SourceRecord) -> String {
        let transcript = record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = transcript.isEmpty ? "尚无转写。" : transcript
        return """
        ---
        id: \(yaml(record.id))
        type: material
        state: \(yaml(record.state))
        created: \(yaml(record.createdAt))
        title: \(yaml(record.name))
        ---

        # \(singleLine(record.name))

        \(body)
        """
    }

    private func claim(_ record: CandidateClaim) -> String {
        var text = """
        ---
        id: \(yaml(record.id))
        type: claim
        ownership: \(yaml(record.ownership))
        validity: \(yaml(record.validity))
        ---

        # \(singleLine(record.statement))
        """
        var seen = Set<String>()
        let sources = record.references.map { $0.sourceID }.filter { seen.insert($0).inserted }
        if !sources.isEmpty { text += "\n\n来源：" + sources.joined(separator: "、") }
        return text
    }

    private func action(_ record: ActionRecord) -> String {
        var text = """
        ---
        id: \(yaml(record.id))
        type: action
        claim: \(yaml(record.claimID))
        kind: \(yaml(record.kind))
        state: \(yaml(record.state))
        created: \(yaml(record.createdAt))
        title: \(yaml(record.title))
        ---

        # \(singleLine(record.title))
        """
        let note = record.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { text += "\n\n" + note }
        return text
    }

    private func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func yaml(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"" + escaped + "\""
    }
}
