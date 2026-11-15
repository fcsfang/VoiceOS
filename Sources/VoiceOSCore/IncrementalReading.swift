import Foundation

public struct IncrementalPlan: Sendable, Equatable {
    public let sourceID: String
    public let chunkSize: Int
    public let currentChunk: Int
    public let transcriptVersionID: String
    public let updatedAt: String
    public init(sourceID: String, chunkSize: Int, currentChunk: Int, transcriptVersionID: String, updatedAt: String) {
        self.sourceID = sourceID; self.chunkSize = chunkSize; self.currentChunk = currentChunk; self.transcriptVersionID = transcriptVersionID; self.updatedAt = updatedAt
    }
}

public struct ReadingChunk: Sendable, Equatable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

public enum ReadingChunks {
    public static func split(text: String, spans: [TranscriptSpan], targetSize: Int) -> [ReadingChunk] {
        let scalars = Array(text.unicodeScalars)
        let total = scalars.count
        guard total > 0 else { return [] }
        let size = max(1, targetSize)
        var bounds = Set([0, total])
        for span in spans {
            bounds.insert(min(max(span.textStart, 0), total))
            bounds.insert(min(max(span.textEnd, 0), total))
        }
        for (index, scalar) in scalars.enumerated() where scalar == "\n" { bounds.insert(index + 1) }
        let ordered = bounds.sorted()
        var pieces: [ReadingChunk] = []
        for index in 0..<(ordered.count - 1) {
            var start = ordered[index]
            let end = ordered[index + 1]
            guard end > start else { continue }
            while end - start > size {
                pieces.append(ReadingChunk(start: start, end: start + size))
                start += size
            }
            pieces.append(ReadingChunk(start: start, end: end))
        }
        var chunks: [ReadingChunk] = []
        for piece in pieces {
            if let last = chunks.last, piece.end - last.start <= size {
                chunks[chunks.count - 1] = ReadingChunk(start: last.start, end: piece.end)
            } else {
                chunks.append(piece)
            }
        }
        return chunks
    }
}

extension VoiceOSStore {
    public func incrementalPlan(sourceID: String) throws -> IncrementalPlan? {
        guard let row = try db.query("SELECT * FROM incremental_reading WHERE source_id=?", [sourceID]).first else { return nil }
        return try converged(row)
    }

    public func incrementalPlans() throws -> [IncrementalPlan] {
        try db.query("SELECT * FROM incremental_reading ORDER BY updated_at DESC, source_id").map { try converged($0) }
    }

    @discardableResult
    public func startIncrementalReading(sourceID: String, chunkSize: Int = 1200) throws -> IncrementalPlan {
        guard (400...4000).contains(chunkSize) else { throw VoiceOSError("按天读块大小需在 400 到 4000 字之间") }
        guard let row = try db.query("SELECT s.state,t.current_version_id FROM sources s LEFT JOIN transcripts t ON t.source_id=s.id WHERE s.id=?", [sourceID]).first else {
            throw VoiceOSError("来源不存在")
        }
        guard row["state"] == "saved" else { throw VoiceOSError("此原件尚未可靠保存") }
        guard let versionID = row["current_version_id"] else { throw VoiceOSError("此来源没有转写") }
        try db.execute("""
        INSERT INTO incremental_reading(source_id,chunk_size,current_chunk,transcript_version_id,updated_at) VALUES(?,?,0,?,?)
        ON CONFLICT(source_id) DO UPDATE SET chunk_size=excluded.chunk_size,current_chunk=0,transcript_version_id=excluded.transcript_version_id,updated_at=excluded.updated_at
        """, [sourceID, String(chunkSize), versionID, Self.now()])
        guard let plan = try incrementalPlan(sourceID: sourceID) else { throw VoiceOSError("按天读记录损坏") }
        return plan
    }

    @discardableResult
    public func setIncrementalChunk(sourceID: String, index: Int) throws -> IncrementalPlan {
        let plan = try requirePlan(sourceID: sourceID)
        let total = try chunkTotal(sourceID: sourceID, chunkSize: plan.chunkSize)
        let clamped = min(max(index, 0), max(0, total - 1))
        try db.execute("UPDATE incremental_reading SET current_chunk=?,updated_at=? WHERE source_id=?", [String(clamped), Self.now(), sourceID])
        guard let updated = try incrementalPlan(sourceID: sourceID) else { throw VoiceOSError("按天读记录损坏") }
        return updated
    }

    @discardableResult
    public func advanceIncrementalChunk(sourceID: String) throws -> Bool {
        let plan = try requirePlan(sourceID: sourceID)
        let total = try chunkTotal(sourceID: sourceID, chunkSize: plan.chunkSize)
        let next = plan.currentChunk + 1
        guard next < max(1, total) else { return false }
        try db.execute("UPDATE incremental_reading SET current_chunk=?,updated_at=? WHERE source_id=?", [String(next), Self.now(), sourceID])
        return true
    }

    public func stopIncrementalReading(sourceID: String) throws {
        try db.execute("DELETE FROM incremental_reading WHERE source_id=?", [sourceID])
    }

    private func requirePlan(sourceID: String) throws -> IncrementalPlan {
        guard let plan = try incrementalPlan(sourceID: sourceID) else { throw VoiceOSError("尚未开始按天读") }
        return plan
    }

    private func converged(_ row: [String: String]) throws -> IncrementalPlan {
        guard let sourceID = row["source_id"], let chunkSize = row["chunk_size"].flatMap(Int.init),
              let currentChunk = row["current_chunk"].flatMap(Int.init), let versionID = row["transcript_version_id"],
              let updatedAt = row["updated_at"] else { throw VoiceOSError("按天读记录损坏") }
        guard let live = try currentTranscript(sourceID: sourceID) else {
            return IncrementalPlan(sourceID: sourceID, chunkSize: chunkSize, currentChunk: currentChunk, transcriptVersionID: versionID, updatedAt: updatedAt)
        }
        let total = ReadingChunks.split(text: live.text, spans: live.spans, targetSize: chunkSize).count
        let clamped = min(max(currentChunk, 0), max(0, total - 1))
        if live.versionID != versionID || clamped != currentChunk {
            try db.execute("UPDATE incremental_reading SET current_chunk=?,transcript_version_id=? WHERE source_id=?", [String(clamped), live.versionID, sourceID])
        }
        return IncrementalPlan(sourceID: sourceID, chunkSize: chunkSize, currentChunk: clamped, transcriptVersionID: live.versionID, updatedAt: updatedAt)
    }

    private func chunkTotal(sourceID: String, chunkSize: Int) throws -> Int {
        guard let live = try currentTranscript(sourceID: sourceID) else { throw VoiceOSError("此来源没有转写") }
        return ReadingChunks.split(text: live.text, spans: live.spans, targetSize: chunkSize).count
    }

    private func currentTranscript(sourceID: String) throws -> (versionID: String, text: String, spans: [TranscriptSpan])? {
        guard let row = try db.query("""
        SELECT t.current_version_id,v.text,v.spans_json FROM transcripts t
        JOIN transcript_versions v ON v.id=t.current_version_id WHERE t.source_id=?
        """, [sourceID]).first, let versionID = row["current_version_id"], let text = row["text"], let spansJSON = row["spans_json"] else { return nil }
        return (versionID, text, try JSONDecoder().decode([TranscriptSpan].self, from: Data(spansJSON.utf8)))
    }
}
