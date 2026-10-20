import Foundation

extension VoiceOSStore {
    /// Re-enrol the complete personal recording after an explicit transcription
    /// correction. Only membership and old action identities are queued here;
    /// current interpretation still requires normal independent model review.
    @discardableResult
    public func queueCorrectedRecordingUnderstanding(sourceID: String, previousActionIDs: [String]) throws -> [String] {
        guard let corrected = try sources().first(where: { $0.id == sourceID }), ["audio", "video"].contains(corrected.kind),
              let version = corrected.transcriptVersionID,
              try db.query("SELECT id FROM transcript_versions WHERE id=? AND reason='transcription_error' AND actor='user'", [version]).first != nil else {
            throw VoiceOSError("当前录音没有可自动继续的本人明确更正，或文字处理权限已暂停")
        }
        let completed = try recordingExpressions().filter { $0.state == "completed" }
        if completed.contains(where: { $0.sourceIDs.contains(sourceID) }) { return [] }
        return try queueRecordingUnderstanding(sourceID: sourceID, previousActionIDs: previousActionIDs, transcriptionCorrection: true)
    }

    /// Explicit whole-recording reorganization or continuation after permission
    /// is restored. Existing permissions are checked, never implicitly granted.
    @discardableResult
    public func queueRecordingUnderstanding(sourceID: String, previousActionIDs: [String]) throws -> [String] {
        try queueRecordingUnderstanding(sourceID: sourceID, previousActionIDs: previousActionIDs, transcriptionCorrection: false)
    }

    private func queueRecordingUnderstanding(sourceID: String, previousActionIDs: [String], transcriptionCorrection: Bool) throws -> [String] {
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        guard let corrected = catalog[sourceID], ["audio", "video"].contains(corrected.kind),
              corrected.transcriptVersionID != nil, !corrected.localOnly, corrected.state == "saved" else {
            throw VoiceOSError("当前录音或现有文字处理权限不可用，未继续处理")
        }
        let seeds: [String]
        if corrected.origin == "user", corrected.speaker == "user" {
            seeds = [corrected.id]
        } else if corrected.origin == "external", corrected.speaker != "user" {
            seeds = catalog.values.filter { $0.presentation?.recordingContext?.externalSourceID == sourceID }.map(\.id)
        } else {
            throw VoiceOSError("来源没有已保存的本人录音归属")
        }
        guard !seeds.isEmpty else { throw VoiceOSError("这份节目原文没有可接续的本人录音") }
        if transcriptionCorrection {
            let completed = try recordingExpressions().filter { $0.state == "completed" }
            if seeds.allSatisfy({ id in completed.contains { $0.sourceIDs.contains(id) } }) { return [] }
        }
        var memberIDs = Set<String>(), pending = seeds
        while let id = pending.popLast() {
            guard memberIDs.insert(id).inserted else { continue }
            guard let member = catalog[id], member.origin == "user", member.speaker == "user",
                  ["audio", "video"].contains(member.kind), member.state == "saved", !member.localOnly,
                  !(member.transcript ?? "").isEmpty else {
                throw VoiceOSError("关联录音的原文或现有文字许可不可用，原文与历史仍已保存")
            }
            pending += member.presentation?.expression?.sourceIDs ?? []
            pending += member.presentation?.correctedSourceIDs ?? []
        }
        let ordered = memberIDs.sorted {
            let lhs = catalog[$0]!, rhs = catalog[$1]!
            return (lhs.expressedDate?.ISO8601Format() ?? lhs.createdAt, lhs.id) < (rhs.expressedDate?.ISO8601Format() ?? rhs.createdAt, rhs.id)
        }
        for id in ordered {
            if let pair = catalog[id]?.presentation?.recordingContext {
                guard let external = catalog[pair.externalSourceID], external.origin == "external", external.speaker != "user",
                      external.state == "saved", !external.localOnly,
                      !(external.transcript ?? "").isEmpty else {
                    throw VoiceOSError("节目上下文的原文或文字许可不可用，暂未继续整体理解")
                }
            }
        }
        let actions = try actions(includeHistory: true)
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims(includeFrozen: true).map { ($0.id, $0) })
        var candidates = Set(previousActionIDs)
        candidates.formUnion(actions.filter { $0.validity == "current" }.map(\.id))
        var durable = Set<String>(), latestActionIDs = Set<String>()
        for id in ordered {
            let source = catalog[id]!
            durable.formUnion(source.presentation?.correctedActionIDs ?? [])
            candidates.formUnion(source.presentation?.correctedActionIDs ?? [])
            candidates.formUnion(catalog[id]?.presentation?.expression?.previousActionIDs ?? [])
            var priorVersion = source.presentation?.expression?.versions[id] ?? source.transcriptVersionID
            if transcriptionCorrection, id == sourceID, source.presentation?.expression == nil,
               let current = source.transcriptVersionID,
               let revision = try db.query("SELECT from_version_id FROM transcript_revisions WHERE to_version_id=?", [current]).first {
                priorVersion = revision["from_version_id"]
            }
            if let priorVersion {
                let rows = try db.query("""
                    SELECT a.id FROM actions a JOIN claims c ON c.id=a.claim_id
                    WHERE c.attempt_id=(
                        SELECT m.id FROM model_attempts m JOIN context_inputs i ON i.context_id=m.context_id
                        WHERE i.source_id=? AND i.transcript_version_id=? AND m.state='completed'
                          AND EXISTS(SELECT 1 FROM claims own JOIN actions task ON task.claim_id=own.id WHERE own.attempt_id=m.id)
                        ORDER BY m.producer_sequence DESC LIMIT 1
                    )
                    """, [id, priorVersion])
                latestActionIDs.formUnion(rows.compactMap { $0["id"] })
            }
        }
        let retained = actions.filter { action in
            guard candidates.contains(action.id), let claim = claims[action.claimID] else { return false }
            guard action.validity == "current" || durable.contains(action.id) || latestActionIDs.contains(action.id) else { return false }
            return !memberIDs.isDisjoint(with: claim.references.map(\.sourceID))
        }.map(\.id).sorted()
        try db.transaction {
            for id in ordered {
                let source = catalog[id]!
                var presentation = source.presentation ?? RecordingPresentation()
                presentation.expression = nil
                presentation.contextLinks = nil
                presentation.correctedActionIDs = retained
                presentation.correctedSourceIDs = ordered
                presentation.recordingUnderstandingIsCorrection = transcriptionCorrection || source.presentation?.recordingUnderstandingIsCorrection == true ? true : nil
                if presentation.automaticInput == nil {
                    presentation.automaticInput = .init(inbox: transcriptionCorrection ? "corrected-recording" : "requested-recording", recordedAt: source.expressedDate?.ISO8601Format(), discoveredAt: Self.now())
                }
                try saveExpressionPresentation(presentation, sourceID: id)
                try invalidateCognition(sourceID: id)
            }
        }
        return ordered
    }

    /// After the ordinary full-text checks finish, update saved physical pair
    /// versions. It cannot enrol sources or authorize an unavailable companion.
    public func refreshCorrectedRecordingContexts(sourceIDs: [String]) throws {
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        var pairs: [RecordingContext] = []
        for id in Set(sourceIDs) {
            guard let personal = catalog[id], personal.presentation?.correctedSourceIDs != nil,
                  personal.origin == "user", personal.speaker == "user", !personal.localOnly,
                  personal.state == "saved", !personal.needsTranscriptionReview,
                  !(personal.transcript ?? "").isEmpty else {
                throw VoiceOSError("更正录音的全文核对或当前文字许可尚未就绪")
            }
            if let pair = personal.presentation?.recordingContext {
                guard let external = catalog[pair.externalSourceID], external.state == "saved",
                      external.origin == "external", external.speaker != "user", !external.localOnly,
                      !external.needsTranscriptionReview, !(external.transcript ?? "").isEmpty else {
                    throw VoiceOSError("节目原文的全文核对或当前文字许可尚未就绪")
                }
                pairs.append(pair)
            }
        }
        try db.transaction {
            for pair in pairs {
                try attachRecordingContext(personalSourceID: pair.personalSourceID, externalSourceID: pair.externalSourceID, sessionID: pair.sessionID, offsetMS: pair.offsetMS)
            }
        }
    }
}
