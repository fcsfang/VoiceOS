import Foundation

public struct CaptureMetadata: Sendable {
    public let sourceID: String
    public let url: String?
    public let capturedAt: String
}

extension VoiceOSStore {
    public func attachCaptureMetadata(sourceID: String, url: String?) throws {
        guard try db.query("SELECT id FROM sources WHERE id=?", [sourceID]).first != nil else { throw VoiceOSError("来源不存在") }
        if let url {
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https", parsed.host != nil else {
                throw VoiceOSError("抓取链接只接受 http 或 https")
            }
        }
        try db.execute("""
        INSERT INTO source_capture_metadata(source_id,source_url,captured_at) VALUES(?,?,?)
        ON CONFLICT(source_id) DO UPDATE SET source_url=excluded.source_url,captured_at=excluded.captured_at
        """, [sourceID, url, ISO8601DateFormatter().string(from: Date())])
    }

    public func captureMetadata() throws -> [String: CaptureMetadata] {
        var metadata: [String: CaptureMetadata] = [:]
        for row in try db.query("SELECT source_id,source_url,captured_at FROM source_capture_metadata") {
            guard let sourceID = row["source_id"], let capturedAt = row["captured_at"] else { continue }
            metadata[sourceID] = CaptureMetadata(sourceID: sourceID, url: row["source_url"], capturedAt: capturedAt)
        }
        return metadata
    }
}
