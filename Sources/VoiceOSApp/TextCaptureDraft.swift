import Foundation
import Darwin
import VoiceOSCore

struct TextCaptureDraft: Codable {
    var title = ""
    var text = "" { didSet { if text != oldValue { commandID = UUID().uuidString } } }
    var ownership = TextCaptureOwnership.personal {
        didSet {
            if ownership != oldValue { commandID = UUID().uuidString; allowCloud = ownership == .personal }
        }
    }
    var allowCloud = true
    var fileName: String?
    var commandID = UUID().uuidString
    var saving = false
    var error = ""
    private enum CodingKeys: String, CodingKey { case title, text, ownership, allowCloud, fileName, commandID }

    func hasSameContents(as other: Self) -> Bool {
        title == other.title && text == other.text && ownership == other.ownership &&
            allowCloud == other.allowCloud && fileName == other.fileName && commandID == other.commandID
    }
    static func load(from file: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let draft = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard UUID(uuidString: draft.commandID) != nil else { throw VoiceOSError("草稿保存身份无效") }
        return draft
    }
    func save(to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw VoiceOSError("无法打开草稿保存目录") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw VoiceOSError("无法确认草稿保存完成") }
    }
}
