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
                let saved=try db.query("SELECT snapshot_json FROM panorama_attempts WHERE id=?", [id]).first?["snapshot_json"]
                let visible=try saved.map { try JSONDecoder().decode(PanoramaSnapshot.self, from: Data($0.utf8)) }
                let visibleUnits=Set(visible?.workflow?.verifiedUnitIDs ?? [])
                if visibleUnits.isSubset(of: Set(verified.map(\.unitID))) {
                    try db.execute("UPDATE panorama_attempts SET snapshot_json=?,generation_receipt=?,verification_receipt=? WHERE id=?", [try Self.relevanceJSON(partial),try Self.relevanceJSON(result.generation),try Self.relevanceJSON(result.verification),id])
                }
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
        var priorRejection: PanoramaRejection?
        do { try Self.validatePanoramaReview(first.0, proposal: generated.0, generation: generated.1, verification: first.1) }
        catch {
            let rejection=PanoramaRejection(proposal: generated.0, review: first.0)
            priorRejection=Self.panoramaRejection(rejection, unitID: unitID)
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
        return .init(unitID: unitID, input: input, proposal: Self.namespacePanorama(generated.0, unitID: unitID), generation: generated.1, review: review.0, verification: review.1, rejection: priorRejection)
    }
    private func panoramaStep<Input: Encodable, Result: Codable & Sendable>(attemptID: String, stage: String, scopeID: String, input: Input,
        whole: PanoramaInput, identity: String, operation: () async throws -> (Result, PanoramaReceipt),
        validate: (Result, PanoramaReceipt) throws -> Void, normalize: (Result) throws -> Result = { $0 }, retainSemanticRejection: Bool = false) async throws -> (Result, PanoramaReceipt) {
        var retries=0
        while true {
            do {
                return try await panoramaStepAttempt(attemptID: attemptID,stage: stage,scopeID: scopeID,input: input,whole: whole,identity: identity,
                    operation: operation,validate: validate,normalize: normalize,retainSemanticRejection: retainSemanticRejection)
            } catch {
                guard retries < 2, let network=error as? URLError,
                      [.networkConnectionLost,.timedOut,.notConnectedToInternet].contains(network.code) else { throw error }
                retries += 1
                try await Task.sleep(for: .seconds(retries))
            }
        }
    }
    private func panoramaStepAttempt<Input: Encodable, Result: Codable & Sendable>(attemptID: String, stage: String, scopeID: String, input: Input,
        whole: PanoramaInput, identity: String, operation: () async throws -> (Result, PanoramaReceipt),
        validate: (Result, PanoramaReceipt) throws -> Void, normalize: (Result) throws -> Result = { $0 }, retainSemanticRejection: Bool = false) async throws -> (Result, PanoramaReceipt) {
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
        var receivedResult: String?, receivedReceipt: String?
        do {
            let (raw,receipt)=try await operation()
            try Task.checkCancellation()
            try requirePanoramaManifest(whole.manifest)
            guard !receipt.responseID.isEmpty, !receipt.model.isEmpty else { throw VoiceOSError("全景步骤缺少真实完成回执") }
            let result=try normalize(raw)
            receivedResult=try Self.relevanceJSON(result)
            receivedReceipt=try Self.relevanceJSON(receipt)
            try validate(result,receipt)
            try db.execute("UPDATE panorama_steps SET state='completed',result_json=?,receipt_json=?,finished_at=? WHERE id=?", [try Self.relevanceJSON(result),try Self.relevanceJSON(receipt),Self.now(),id])
            return (result,receipt)
        } catch {
            let state=retainSemanticRejection && error is PanoramaSemanticIssue ? "completed" : "failed"
            try db.execute("UPDATE panorama_steps SET state=?,result_json=?,receipt_json=?,error=?,finished_at=? WHERE id=?", [state,receivedResult,receivedReceipt,Self.panoramaFailure(error),Self.now(),id])
            throw error
        }
    }
    private func finishPanorama(_ units: [VerifiedPanoramaUnit], input: PanoramaInput, attemptID: String, port: any PanoramaModelPort) async throws {
        let proposals=units.map { PanoramaUnitProposal(unitID: $0.unitID, proposal: $0.proposal) }
        try publishPanoramaPhase(.synthesis, units: units, input: input, attemptID: attemptID)
        let generated: (PanoramaProposal, PanoramaReceipt)=try await panoramaStep(attemptID: attemptID, stage: "global.synthesize", scopeID: "all",
            input: PanoramaSynthesisInput(input: input, proposals: proposals), whole: input, identity: port.configurationIdentity,
            operation: { try await port.synthesize(proposals, input: input) }, validate: { proposal, _ in
                _ = try Self.validatePanorama(proposal, input: input)
            }, normalize: { try Self.locatePanoramaQuotes($0, input: input) })
        var candidate=generated
        var issues: [PanoramaSemanticIssue]=[]
        let validation: PanoramaGlobalValidation
        do {
            validation=try await reviewPanoramaCandidate(candidate.0, generation: candidate.1, units: units, input: input, attemptID: attemptID, port: port, issues: issues)
        } catch let issue as PanoramaSemanticIssue {
            issues.append(issue)
            let original=candidate.0
            candidate=try await panoramaStep(attemptID: attemptID, stage: "global.repair", scopeID: "all",
                input: PanoramaGlobalRepairInput(input: input, proposal: original, issue: issue), whole: input, identity: port.configurationIdentity,
                operation: { try await port.repairSynthesis(original, input: input, context: issue.input, rejection: issue.rejection) }, validate: { proposal, _ in
                    _ = try Self.validatePanorama(proposal, input: input)
                }, normalize: { try Self.locatePanoramaQuotes($0, input: input) })
            validation=try await reviewPanoramaCandidate(candidate.0, generation: candidate.1, units: units, input: input, attemptID: attemptID, port: port, issues: issues)
        }
        let proposal=candidate.0
        let final=(validation.finalReview,validation.finalReceipt), reviews=validation.reviews
        try Task.checkCancellation()
        try requirePanoramaManifest(input.manifest)
        let coverage=try Self.validatePanorama(proposal, input: input)
        let unitReceipts=units.flatMap { [PanoramaStepReceipt(stage: "unit.generate", scopeID: $0.unitID, receipt: $0.generation), PanoramaStepReceipt(stage: "unit.verify", scopeID: $0.unitID, receipt: $0.verification)] }
        let receipts=unitReceipts + [.init(stage: "global.synthesize", scopeID: "all", receipt: generated.1)]
            + (issues.isEmpty ? [] : [PanoramaStepReceipt(stage: "global.repair", scopeID: "all", receipt: candidate.1)])
            + reviews.map { PanoramaStepReceipt(stage: $0.stage, scopeID: $0.scopeID, receipt: $0.receipt) }
            + [.init(stage: "global.consistency", scopeID: "all", receipt: final.1)]
        let snapshot=PanoramaSnapshot(id: attemptID, createdAt: Self.now(), input: input, proposal: proposal, coverage: coverage,
            generation: candidate.1, verification: final.1, review: final.0,
            workflow: .init(phase: .completed, verifiedUnitIDs: units.map(\.unitID), totalUnitCount: input.units.count, receipts: receipts))
        try db.execute("UPDATE panorama_attempts SET state='completed',snapshot_json=?,generation_receipt=?,verification_receipt=?,error=NULL WHERE id=?", [try Self.relevanceJSON(snapshot),try Self.relevanceJSON(candidate.1),try Self.relevanceJSON(final.1),attemptID])
    }
    private func reviewPanoramaCandidate(_ proposal: PanoramaProposal, generation: PanoramaReceipt, units: [VerifiedPanoramaUnit], input: PanoramaInput,
        attemptID: String, port: any PanoramaModelPort, issues: [PanoramaSemanticIssue]) async throws -> PanoramaGlobalValidation {
        let proposals=units.map { PanoramaUnitProposal(unitID: $0.unitID, proposal: $0.proposal) }
        let rejections=units.compactMap(\.rejection) + issues.map(\.rejection)
        var reviews: [PanoramaScopedReview]=[]
        try publishPanoramaPhase(.evidence, units: units, input: input, attemptID: attemptID)
        for question in proposal.questions {
            let scoped=try Self.panoramaScope(input, sourceIDs: Set(question.evidence.map(\.sourceID)))
            let selected=Self.panoramaProjection(proposal, input: scoped, questionIDs: [question.id], relationIDs: [])
            let result: (PanoramaReview, PanoramaReceipt)=try await panoramaStep(attemptID: attemptID, stage: "global.question", scopeID: question.id,
                input: PanoramaProposalInput(input: scoped, proposal: selected), whole: input, identity: port.configurationIdentity,
                operation: { try await port.verifyEvidence(selected, input: scoped) }, validate: { review, receipt in
                    _ = try Self.validatePanorama(selected, input: scoped)
                    try Self.validatePanoramaStageReview(review, proposal: selected, input: scoped, generation: generation, verification: receipt)
                }, retainSemanticRejection: issues.isEmpty)
            reviews.append(.init(stage: "global.question", scopeID: question.id, review: result.0, receipt: result.1))
        }
        for relation in proposal.relations {
            let endpointIDs=Set([relation.from,relation.to])
            let evidence=proposal.questions.filter { endpointIDs.contains($0.id) }.flatMap(\.evidence) + relation.fromEvidence + relation.toEvidence
            let scoped=try Self.panoramaScope(input, sourceIDs: Set(evidence.map(\.sourceID)))
            let selected=Self.panoramaProjection(proposal, input: scoped, questionIDs: endpointIDs, relationIDs: [relation.id])
            let result: (PanoramaReview, PanoramaReceipt)=try await panoramaStep(attemptID: attemptID, stage: "global.relation", scopeID: relation.id,
                input: PanoramaProposalInput(input: scoped, proposal: selected), whole: input, identity: port.configurationIdentity,
                operation: { try await port.verifyEvidence(selected, input: scoped) }, validate: { review, receipt in
                    _ = try Self.validatePanorama(selected, input: scoped)
                    try Self.validatePanoramaStageReview(review, proposal: selected, input: scoped, generation: generation, verification: receipt)
                }, retainSemanticRejection: issues.isEmpty)
            reviews.append(.init(stage: "global.relation", scopeID: relation.id, review: result.0, receipt: result.1))
        }
        try publishPanoramaPhase(.coverage, units: units, input: input, attemptID: attemptID)
        for unit in units {
            let sourceIDs=Set(unit.input.manifest.sourceIDs), claimIDs=Set(unit.input.manifest.claimIDs)
            func relevant(_ evidence: [PanoramaEvidence]) -> Bool {
                evidence.contains { sourceIDs.contains($0.sourceID) || !claimIDs.isDisjoint(with: $0.claimIDs) }
            }
            let questionIDs=Set(proposal.questions.filter { relevant($0.evidence) }.map(\.id))
            let relationIDs=Set(proposal.relations.filter { relevant($0.fromEvidence + $0.toEvidence) }.map(\.id))
            let endpointIDs=Set(proposal.relations.filter { relationIDs.contains($0.id) }.flatMap { [$0.from,$0.to] })
            let evidence=proposal.questions.filter { questionIDs.union(endpointIDs).contains($0.id) }.flatMap(\.evidence)
                + proposal.relations.filter { relationIDs.contains($0.id) }.flatMap { $0.fromEvidence + $0.toEvidence }
            let relatedIssues=issues.filter { issue in
                !sourceIDs.isDisjoint(with: issue.input.manifest.sourceIDs) || !claimIDs.isDisjoint(with: issue.input.manifest.claimIDs)
            }
            let rejectedSourceIDs=relatedIssues.flatMap { $0.input.manifest.sourceIDs }
            let contextSourceIDs=sourceIDs.union(evidence.map(\.sourceID)).union(rejectedSourceIDs)
            let scoped=try Self.panoramaScope(input, sourceIDs: contextSourceIDs)
            let selected=Self.panoramaProjection(proposal, input: scoped, questionIDs: questionIDs, relationIDs: relationIDs)
            let target=PanoramaCoverageTarget(sourceIDs: unit.input.manifest.sourceIDs, claimIDs: unit.input.manifest.claimIDs)
            let relevantRejections=(unit.rejection.map { [$0] } ?? []) + relatedIssues.map(\.rejection)
            let request=PanoramaCoverageInput(input: scoped, proposal: selected, target: target, rejections: relevantRejections)
            let result: (PanoramaReview, PanoramaReceipt)=try await panoramaStep(attemptID: attemptID, stage: "global.coverage", scopeID: unit.unitID,
                input: request, whole: input, identity: port.configurationIdentity,
                operation: { try await port.verifyCoverage(selected, input: scoped, target: target, rejections: relevantRejections) }, validate: { review, receipt in
                    _ = try Self.validatePanorama(selected, input: scoped)
                    try Self.validatePanoramaStageReview(review, proposal: selected, input: scoped, generation: generation, verification: receipt)
                }, retainSemanticRejection: issues.isEmpty)
            reviews.append(.init(stage: "global.coverage", scopeID: unit.unitID, review: result.0, receipt: result.1, target: target))
        }
        try publishPanoramaPhase(.consistency, units: units, input: input, attemptID: attemptID)
        let request=PanoramaConsistencyInput(input: input, proposal: proposal, unitProposals: proposals, reviews: reviews, rejections: rejections)
        let final: (PanoramaReview, PanoramaReceipt)=try await panoramaStep(attemptID: attemptID, stage: "global.consistency", scopeID: "all",
            input: request, whole: input, identity: port.configurationIdentity,
            operation: { try await port.verifyConsistency(proposal, input: input, unitProposals: proposals, reviews: reviews, rejections: rejections) }, validate: { review, receipt in
                try Self.validatePanoramaStageReview(review, proposal: proposal, input: input, generation: generation, verification: receipt)
            }, retainSemanticRejection: issues.isEmpty)
        return .init(reviews: reviews, finalReview: final.0, finalReceipt: final.1)
    }
    private func publishPanoramaPhase(_ phase: PanoramaPhase, units: [VerifiedPanoramaUnit], input: PanoramaInput, attemptID: String) throws {
        try requirePanoramaManifest(input.manifest)
        let partial=try Self.partialPanorama(units, input: input, id: attemptID, phase: phase)
        try db.execute("UPDATE panorama_attempts SET snapshot_json=? WHERE id=?", [try Self.relevanceJSON(partial),attemptID])
    }
    private static func panoramaFailure(_ error: Error) -> String {
        if let error=error as? VoiceOSError { return error.message }
        if let issue=error as? PanoramaSemanticIssue { return "全景独立语义核对未通过：" + issue.rejection.review.reason + "；已核对区域保留，可明确重试" }
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
        let sourceIDs=try Self.panoramaScope(state.input, sourceIDs: Set(evidence.map(\.sourceID))).manifest.sourceIDs
        let id=try beginConversation(sourceIDs: sourceIDs, commandID: "panorama:"+snapshotID+":"+key+":"+UUID().uuidString)
        return .init(conversation: try conversation(id: id), draft: "以下是 AI 全景候选解释，尚未得到我认可：\n\(explanation)\n\n请结合双方完整原文核对这条线索，说明支持、差异和仍不确定之处。")
    }
}
private struct PanoramaDigestInput: Codable {
    let units: [PanoramaUnit]
    let sources: [PanoramaSource]
    let claims: [PanoramaClaim]
}
