import Foundation

extension VoiceOSStore {
    public func panoramaInput() throws -> PanoramaInput {
        guard ready else { throw VoiceOSError("资料库尚未恢复") }
        let catalog=try sources(), byID=Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let expressions=try recordingExpressions()
        let completed=try db.query("SELECT a.*,x.snapshot_json FROM model_attempts a JOIN contexts x ON x.id=a.context_id WHERE a.state='completed' AND x.state='current' ORDER BY a.producer_sequence DESC")
        var units: [PanoramaUnit]=[], selected=Set<String>(), exclusions: [PanoramaExclusion]=[], assigned=Set<String>()
        func usable(_ source: SourceRecord) -> Bool {
            ["saved", "reference_only"].contains(source.state) && !source.localOnly && !source.needsTranscriptionReview && source.transcriptVersionID != nil && !(source.transcript ?? "").isEmpty
        }
        for source in catalog.sorted(by: { $0.id < $1.id }) where !assigned.contains(source.id) {
            guard usable(source) else {
                exclusions.append(.init(id: source.id, title: source.name, reason: source.localOnly ? "仅本机保存" : "原文或全文校正尚不可用")); continue
            }
            let expression=expressions.first { $0.sourceIDs.contains(source.id) }
            if source.presentation?.expression != nil && expression == nil {
                exclusions.append(.init(id: source.id, title: source.name, reason: "完整表达的成员、节目或许可已变化")); continue
            }
            if let expression, expression.state != "completed" {
                exclusions.append(.init(id: source.id, title: source.name, reason: "完整表达尚未整理完成")); continue
            }
            let members=expression?.sourceIDs ?? [source.id]
            let expanded: [String]
            do { expanded=try recordingContextSourceIDs(sourceIDs: members) }
            catch { exclusions.append(.init(id: source.id, title: source.name, reason: "节目依赖需要重新核对")); continue }
            guard expanded.allSatisfy({ byID[$0].map(usable) == true }) else {
                exclusions.append(.init(id: source.id, title: source.name, reason: "完整表达依赖尚不可用")); continue
            }
            var producer: [String:String]?
            for attempt in completed {
                let wholeProducer=attempt["provider"] == "organized_import" || attempt["prompt_version"] == "expression-comprehensive-v5" || attempt["execution_kind"] == "segmented_derivation"
                guard wholeProducer else { continue }
                let saved=try JSONDecoder().decode(LocalTranscriptContext.self, from: Data(attempt["snapshot_json"]!.utf8))
                guard Set(expanded).isSubset(of: Set(saved.sources.map(\.sourceID))) else { continue }
                do {
                    _ = try localContext(id: attempt["context_id"]!)
                    try validateLocalTranscriptContext(saved)
                    if attempt["execution_kind"] == "segmented_derivation" {
                        guard !(try db.query("SELECT id FROM segmented_cognitive_commits WHERE model_attempt_id=?", [attempt["id"]])).isEmpty else { continue }
                    }
                    producer=attempt; break
                } catch { continue }
            }
            guard let producer else {
                exclusions.append(.init(id: source.id, title: source.name, reason: "尚无覆盖当前完整原文的理解完成回执")); continue
            }
            assigned.formUnion(members); selected.formUnion(expanded)
            units.append(.init(id: expression?.id ?? source.id, sourceIDs: members, dependencyIDs: expanded.filter { !members.contains($0) }, producerID: producer["id"]!, completionDigest: Self.relevanceHash(Data(try Self.relevanceJSON(expression).utf8)) + ":" + (producer["result_digest"] ?? "")))
        }
        let ids=selected.sorted()
        let context=ids.isEmpty ? nil : try prepareLocalTranscriptContext(sourceIDs: ids, scalarBudget: Int.max)
        let sourceValues=(context?.sources ?? []).map { transcript -> PanoramaSource in
            let record=byID[transcript.sourceID]!
            return .init(transcript: transcript, title: record.presentation?.manualTitle ?? record.presentation?.automatic?.title ?? record.name,
                         occurredAt: record.expressedDate?.ISO8601Format() ?? record.createdAt, policyVersion: record.policyVersion)
        }
        let current=try latestCandidateClaimsBySource()
        let candidates=Dictionary(grouping: ids.flatMap { current[$0] ?? [] }, by: \.id).values.compactMap(\.first)
        let claims=candidates.filter { claim in claim.references.allSatisfy { ref in
            context?.sources.contains { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID } == true
        } }.sorted { $0.id < $1.id }.map { PanoramaClaim(id: $0.id, statement: $0.statement, ownership: $0.ownership, reviewVersion: $0.reviewVersion, references: $0.references) }
        units.sort { $0.id < $1.id }
        let digest=Self.relevanceHash(Data(try Self.relevanceJSON(PanoramaDigestInput(units: units, sources: sourceValues, claims: claims)).utf8))
        return .init(manifest: .init(digest: digest, sourceIDs: ids, claimIDs: claims.map(\.id), unitIDs: units.map(\.id)), units: units, sources: sourceValues, claims: claims, exclusions: exclusions.filter { !selected.contains($0.id) })
    }
    public func panoramaState() throws -> PanoramaState {
        let input=try panoramaInput()
        let row=try db.query("SELECT * FROM panorama_attempts WHERE digest=? ORDER BY rowid DESC LIMIT 1", [input.manifest.digest]).first
        let snapshot=try row?["snapshot_json"].map { try JSONDecoder().decode(PanoramaSnapshot.self, from: Data($0.utf8)) }
        return .init(input: input, snapshot: snapshot, status: row?["state"] ?? (input.units.isEmpty ? "empty" : "pending"), error: row?["error"])
    }
    public func generatePanorama(using port: any PanoramaModelPort, retry: Bool = false) async throws {
        let input=try panoramaInput(), digest=input.manifest.digest
        guard !input.units.isEmpty, !activePanoramaDigests.contains(digest) else { return }
        if let row=try db.query("SELECT state FROM panorama_attempts WHERE digest=? ORDER BY rowid DESC LIMIT 1", [digest]).first {
            guard retry && row["state"] != "completed" && row["state"] != "running" else { return }
        }
        let id=UUID().uuidString
        try db.execute("INSERT INTO panorama_attempts(id,digest,state,input_json,created_at) VALUES(?,?,'running',?,?)", [id,digest,try Self.relevanceJSON(input),Self.now()])
        activePanoramaDigests.insert(digest)
        defer { activePanoramaDigests.remove(digest) }
        do {
            let generated=try await port.generate(input)
            try requirePanoramaManifest(input.manifest)
            try db.execute("UPDATE panorama_attempts SET generation_receipt=? WHERE id=?", [try Self.relevanceJSON(generated.1),id])
            var proposal=try Self.locatePanoramaQuotes(generated.0, input: input), generation=generated.1
            var coverage=try Self.validatePanorama(proposal, input: input)
            var (review,verification)=try await port.verify(proposal, input: input, priorRejection: nil)
            try requirePanoramaManifest(input.manifest)
            try db.execute("UPDATE panorama_attempts SET verification_receipt=? WHERE id=?", [try Self.relevanceJSON(verification),id])
            do { try Self.validatePanoramaReview(review, proposal: proposal, generation: generation, verification: verification) }
            catch {
                let rejection=PanoramaRejection(proposal: proposal, review: review)
                let repaired=try await port.repair(proposal, input: input, review: review)
                try requirePanoramaManifest(input.manifest)
                try db.execute("UPDATE panorama_attempts SET generation_receipt=? WHERE id=?", [try Self.relevanceJSON(repaired.1),id])
                proposal=try Self.locatePanoramaQuotes(repaired.0, input: input); generation=repaired.1
                coverage=try Self.validatePanorama(proposal, input: input)
                (review,verification)=try await port.verify(proposal, input: input, priorRejection: rejection)
                try requirePanoramaManifest(input.manifest)
                try db.execute("UPDATE panorama_attempts SET verification_receipt=? WHERE id=?", [try Self.relevanceJSON(verification),id])
            }
            try Self.validatePanoramaReview(review, proposal: proposal, generation: generation, verification: verification)
            let snapshot=PanoramaSnapshot(id: id, createdAt: Self.now(), input: input, proposal: proposal, coverage: coverage, generation: generation, verification: verification, review: review)
            try db.transaction {
                try db.execute("UPDATE panorama_attempts SET state='completed',snapshot_json=?,verification_receipt=?,error=NULL WHERE id=?", [try Self.relevanceJSON(snapshot),try Self.relevanceJSON(verification),id])
            }
        } catch {
            try db.execute("UPDATE panorama_attempts SET state='failed',error=? WHERE id=?", [Self.panoramaFailure(error),id])
            throw error
        }
    }
    private static func panoramaFailure(_ error: Error) -> String {
        if let error=error as? VoiceOSError { return error.message }
        if error is CancellationError { return "全景生成已停止，可明确重试" }
        return "全景请求未完成或结果格式无效；材料保留，请明确重试"
    }
    private func requirePanoramaManifest(_ manifest: PanoramaManifest) throws {
        guard try panoramaInput().manifest.digest == manifest.digest else { throw VoiceOSError("全景依据、授权或完整整理状态已变化，旧结果未发布") }
    }
    public func beginPanoramaConversation(snapshotID: String, selection: PanoramaSelection) throws -> PanoramaDiscussion {
        let state=try panoramaState()
        guard let snapshot=state.snapshot, snapshot.id == snapshotID else { throw VoiceOSError("全景已失效，请从当前全景重新进入讨论") }
        let evidence: [PanoramaEvidence], explanation: String, key: String
        switch selection {
        case .question(let id):
            guard let question=snapshot.proposal.questions.first(where: { $0.id == id }) else { throw VoiceOSError("全景问题不存在") }
            evidence=question.evidence; explanation=question.title + "\n" + question.summary; key="question:"+id
        case .relation(let id):
            guard let relation=snapshot.proposal.relations.first(where: { $0.id == id }) else { throw VoiceOSError("全景联系不存在") }
            evidence=relation.fromEvidence + relation.toEvidence; explanation=relation.label + "\n" + relation.explanation; key="relation:"+id
        }
        let sourceIDs=Array(Set(evidence.map(\.sourceID))).sorted()
        let id=try beginConversation(sourceIDs: sourceIDs, commandID: "panorama:"+snapshotID+":"+key+":"+UUID().uuidString)
        return .init(conversation: try conversation(id: id), draft: "以下是 AI 全景候选解释，尚未得到我认可：\n\(explanation)\n\n请结合双方完整原文核对这条线索，说明支持、差异和仍不确定之处。")
    }
}
private struct PanoramaDigestInput: Codable {
    let units: [PanoramaUnit]
    let sources: [PanoramaSource]
    let claims: [PanoramaClaim]
}
