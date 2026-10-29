import Foundation

public enum MaterialDisposition: Equatable, Sendable { case active, archived, trashed }

public extension SourceRecord {
    var isArchived: Bool { state != "trashed" && presentation?.archived == true }
    var isTrashed: Bool { state == "trashed" }
}

extension VoiceOSStore {
    /// Archive changes presentation only. Trash invalidates evidence without removing originals or history.
    public func setMaterialDisposition(sourceIDs: [String], disposition: MaterialDisposition) throws {
        guard ready, !sourceIDs.isEmpty else { throw VoiceOSError("请先打开资料库并选择材料") }
        let ids = Set(sourceIDs)
        guard ids.isDisjoint(with: activeCaptures) else { throw VoiceOSError("请先停止并保存正在录制或导入的材料") }
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        let selected = try ids.sorted().map { id in
            guard let source = catalog[id], ["saved", "reference_only", "quarantined", "trashed"].contains(source.state) else { throw VoiceOSError("材料尚未保存完成，请完成导入后再管理") }
            return source
        }
        // Revocation is recorded using the existing policy history before trashing.
        // A failed later step can only leave a source more private.
        if case .trashed = disposition {
            for source in selected where !source.localOnly {
                _ = try setSourceLocalOnly(sourceID: source.id, expectedVersion: source.policyVersion, localOnly: true)
            }
        }
        try db.transaction {
            for source in selected {
                var presentation = source.presentation ?? RecordingPresentation()
                switch disposition {
                case .trashed:
                    guard !source.isTrashed else { continue }
                    presentation.stateBeforeTrash = source.state
                    try db.execute("UPDATE sources SET state='trashed' WHERE id=?", [source.id])
                    try invalidateCognition(sourceID: source.id)
                    try db.execute("UPDATE processing_intents SET state='blocked',error='材料已移入回收站' WHERE source_id=? AND state='queued'", [source.id])
                    try db.execute("UPDATE recording_processing_requests SET state='blocked',error='材料已移入回收站' WHERE source_id=? AND state='waiting'", [source.id])
                case .active, .archived:
                    if source.isTrashed {
                        guard let previous = presentation.stateBeforeTrash, ["saved", "reference_only", "quarantined"].contains(previous) else { throw VoiceOSError("缺少回收站恢复状态，请保留原资料库") }
                        if previous == "saved" {
                            let file = try assetURL(relativePath: source.relativePath)
                            let actual = try DurableFiles.hash(file)
                            guard let expected = try db.query("SELECT expected_hash FROM sources WHERE id=?", [source.id]).first?["expected_hash"], actual.0 == source.bytes, actual.1 == expected else { throw VoiceOSError("原件不完整，未恢复材料；请保留回收站记录") }
                        }
                        try db.execute("UPDATE sources SET state=? WHERE id=?", [previous, source.id])
                        presentation.stateBeforeTrash = nil
                    }
                    presentation.archived = disposition == .archived
                }
                try savePresentation(presentation, sourceID: source.id)
            }
        }
    }
}
