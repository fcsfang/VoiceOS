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
        var progress: PanoramaProgress?
        if let id=row?["id"] {
            let steps=try db.query("SELECT stage,scope_id,state FROM panorama_steps WHERE attempt_id=? ORDER BY rowid", [id])
            let verified=Set(snapshot?.workflow?.verifiedUnitIDs ?? [])
            progress = .init(phase: snapshot?.workflow?.phase ?? .units, verifiedUnitCount: verified.count,
                             totalUnitCount: input.units.count, activeStage: steps.last(where: { $0["state"] == "running" })?["stage"])
        }
        return .init(input: input, snapshot: snapshot, status: row?["state"] ?? (input.units.isEmpty ? "empty" : "pending"), error: row?["error"], progress: progress)
    }
    public func generatePanorama(using port: any PanoramaModelPort, retry: Bool = false) async throws {
        let input=try panoramaInput(), digest=input.manifest.digest
        guard !input.units.isEmpty, !activePanoramaDigests.contains(digest) else { return }
        let previous=try db.query("SELECT * FROM panorama_attempts WHERE digest=? ORDER BY rowid DESC LIMIT 1", [digest]).first
        if let previous {
            guard retry && previous["state"] != "completed" && previous["state"] != "running" else { return }
        }
        let id=previous?["id"] ?? UUID().uuidString
        if previous == nil {
            try db.execute("INSERT INTO panorama_attempts(id,digest,state,input_json,created_at) VALUES(?,?,'running',?,?)", [id,digest,try Self.relevanceJSON(input),Self.now()])
        } else {
            try db.execute("UPDATE panorama_attempts SET state='running',error=NULL WHERE id=?", [id])
        }
        activePanoramaDigests.insert(digest)
        defer { activePanoramaDigests.remove(digest) }
        do {
            var verified: [VerifiedPanoramaUnit]=[]
            var scheduled: [(unit: PanoramaUnit, input: PanoramaInput, size: Int)]=[]
            for unit in input.units {
                let sourceIDs=Set(unit.sourceIDs + unit.dependencyIDs)
                let scope=try Self.panoramaScope(input, sourceIDs: sourceIDs)
                let size=scope.sources.reduce(0) { $0 + $1.transcript.text.unicodeScalars.count }
                scheduled.append((unit,scope,size))
            }
            scheduled.sort { left, right in
                if left.size == right.size { return left.unit.id < right.unit.id }
                return left.size < right.size
            }
            for (unit,scoped,_) in scheduled {
                let result=try await verifyPanoramaUnit(unit.id, input: scoped, whole: input, attemptID: id, port: port)
                verified.append(result)
                try requirePanoramaManifest(input.manifest)
                let partial=try Self.partialPanorama(verified, input: input, id: id, phase: .units)
                try db.execute("UPDATE panorama_attempts SET snapshot_json=?,generation_receipt=?,verification_receipt=? WHERE id=?", [try Self.relevanceJSON(partial),try Self.relevanceJSON(result.generation),try Self.relevanceJSON(result.verification),id])
            }
            try await finishPanorama(verified, input: input, attemptID: id, port: port)
        } catch {
            try db.execute("UPDATE panorama_attempts SET state='failed',error=? WHERE id=?", [Self.panoramaFailure(error),id])
            throw error
        }
    }
    private func verifyPanoramaUnit(_ unitID: String, input: PanoramaInput, whole: PanoramaInput, attemptID: String, port: any PanoramaModelPort) async throws -> VerifiedPanoramaUnit {
        var generated: (PanoramaProposal, PanoramaReceipt)=try await panoramaStep(attemptID: attemptID, stage: "unit.generate", scopeID: unitID,
            input: input, whole: whole, identity: port.configurationIdentity, operation: { try await port.generate(input) }, validate: { proposal, _ in
                _ = try Self.validatePanorama(proposal, input: input)
            }, normalize: { try Self.locatePanoramaQuotes($0, input: input) })
        let first: (PanoramaReview, PanoramaReceipt)=try await panoramaStep(attemptID: attemptID, stage: "unit.review", scopeID: unitID,
            input: PanoramaProposalInput(input: input, proposal: generated.0), whole: whole, identity: port.configurationIdentity,
            operation: { try await port.verify(generated.0, input: input, priorRejection: nil) }, validate: { _, _ in })
        var review=first
        do { try Self.validatePanoramaReview(first.0, proposal: generated.0, generation: generated.1, verification: first.1) }
        catch {
            let rejection=PanoramaRejection(proposal: generated.0, review: first.0)
            let original=generated.0
            generated=try await panoramaStep(attemptID: attemptID, stage: "unit.repair", scopeID: unitID,
                input: PanoramaRepairInput(input: input, rejection: rejection), whole: whole, identity: port.configurationIdentity,
                operation: { try await port.repair(original, input: input, review: first.0) }, validate: { proposal, _ in
                    _ = try Self.validatePanorama(proposal, input: input)
                }, normalize: { try Self.locatePanoramaQuotes($0, input: input) })
            review=try await panoramaStep(attemptID: attemptID, stage: "unit.review-repair", scopeID: unitID,
                input: PanoramaRepairInput(input: input, rejection: .init(proposal: generated.0, review: first.0)), whole: whole, identity: port.configurationIdentity,
                operation: { try await port.verify(generated.0, input: input, priorRejection: rejection) }, validate: { value, receipt in
                    try Self.validatePanoramaReview(value, proposal: generated.0, generation: generated.1, verification: receipt)
                })
        }
        try Self.validatePanoramaReview(review.0, proposal: generated.0, generation: generated.1, verification: review.1)
        return .init(unitID: unitID, input: input, proposal: Self.namespacePanorama(generated.0, unitID: unitID), generation: generated.1, review: review.0, verification: review.1)
    }
    private func panoramaStep<Input: Encodable, Result: Codable & Sendable>(attemptID: String, stage: String, scopeID: String, input: Input,
        whole: PanoramaInput, identity: String, operation: () async throws -> (Result, PanoramaReceipt),
        validate: (Result, PanoramaReceipt) throws -> Void, normalize: (Result) throws -> Result = { $0 }) async throws -> (Result, PanoramaReceipt) {
        try Task.checkCancellation()
        try requirePanoramaManifest(whole.manifest)
        let json=try Self.relevanceJSON(input)
        let digest=Self.relevanceHash(Data(("panorama-staged-v1|"+identity+"|"+json).utf8))
        if let row=try db.query("SELECT result_json,receipt_json FROM panorama_steps WHERE attempt_id=? AND stage=? AND scope_id=? AND input_digest=? AND state='completed' ORDER BY rowid DESC LIMIT 1", [attemptID,stage,scopeID,digest]).first,
           let result=row["result_json"], let receipt=row["receipt_json"] {
            let decoded=try JSONDecoder().decode(Result.self, from: Data(result.utf8))
            let savedReceipt=try JSONDecoder().decode(PanoramaReceipt.self, from: Data(receipt.utf8))
            try validate(decoded,savedReceipt)
            return (decoded,savedReceipt)
        }
        let id=UUID().uuidString
        try db.execute("INSERT INTO panorama_steps(id,attempt_id,stage,scope_id,input_digest,state,input_json,created_at) VALUES(?,?,?,?,?,'running',?,?)", [id,attemptID,stage,scopeID,digest,json,Self.now()])
        do {
            let (raw,receipt)=try await operation()
            try Task.checkCancellation()
            try requirePanoramaManifest(whole.manifest)
            guard !receipt.responseID.isEmpty, !receipt.model.isEmpty else { throw VoiceOSError("全景步骤缺少真实完成回执") }
            let result=try normalize(raw)
            try validate(result,receipt)
            try db.execute("UPDATE panorama_steps SET state='completed',result_json=?,receipt_json=?,finished_at=? WHERE id=?", [try Self.relevanceJSON(result),try Self.relevanceJSON(receipt),Self.now(),id])
            return (result,receipt)
        } catch {
            try db.execute("UPDATE panorama_steps SET state='failed',error=?,finished_at=? WHERE id=?", [Self.panoramaFailure(error),Self.now(),id])
            throw error
        }
    }
    private func finishPanorama(_ units: [VerifiedPanoramaUnit], input: PanoramaInput, attemptID: String, port: any PanoramaModelPort) async throws {
        let partial=try Self.partialPanorama(units, input: input, id: attemptID, phase: .synthesis)
        try db.execute("UPDATE panorama_attempts SET snapshot_json=? WHERE id=?", [try Self.relevanceJSON(partial),attemptID])
        throw VoiceOSError("所有完整单元已独立核对；跨单元归纳与全局核对尚未完成")
    }
    private static func panoramaFailure(_ error: Error) -> String {
        if let error=error as? VoiceOSError { return error.message }
        if case ModelPortFailure.rejected(let reason, _, _) = error { return reason }
        if error is CancellationError { return "全景生成已停止，可明确重试" }
        if let error=error as? URLError { return "全景网络请求失败（错误码 \(error.code.rawValue)）；材料保留，请明确重试" }
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
