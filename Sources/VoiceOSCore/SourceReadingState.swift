import Foundation

public enum SourceReadingState: String, CaseIterable, Codable, Sendable {
    case unread, reading, read
}

extension VoiceOSStore {
    public func sourceReadingStates() throws -> [String: SourceReadingState] {
        var states: [String: SourceReadingState] = [:]
        for row in try db.query("SELECT source_id,state FROM source_reading_states") {
            guard let sourceID = row["source_id"], let state = row["state"].flatMap(SourceReadingState.init(rawValue:)) else { continue }
            states[sourceID] = state
        }
        return states
    }

    public func setSourceReadingState(sourceID: String, state: SourceReadingState) throws {
        guard try db.query("SELECT id FROM sources WHERE id=?", [sourceID]).first != nil else { throw VoiceOSError("来源不存在") }
        try db.execute("""
        INSERT INTO source_reading_states(source_id,state,updated_at) VALUES(?,?,?)
        ON CONFLICT(source_id) DO UPDATE SET state=excluded.state,updated_at=excluded.updated_at
        """, [sourceID, state.rawValue, ISO8601DateFormatter().string(from: Date())])
    }
}
