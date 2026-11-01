import Foundation

struct VerifiedPanoramaUnit: Sendable {
    let unitID: String
    let input: PanoramaInput
    let proposal: PanoramaProposal
    let generation: PanoramaReceipt
    let review: PanoramaReview
    let verification: PanoramaReceipt
    let rejection: PanoramaRejection?
}
struct PanoramaProposalInput: Encodable {
    let input: PanoramaInput
    let proposal: PanoramaProposal
}
struct PanoramaRepairInput: Encodable {
    let input: PanoramaInput
    let rejection: PanoramaRejection
}

extension VoiceOSStore {
    static func panoramaScope(_ input: PanoramaInput, sourceIDs: Set<String>) throws -> PanoramaInput {
        var sources=sourceIDs, unitIDs=Set<String>(), claimIDs=Set<String>()
        var changed=true
        while changed {
            let before=(sources.count,unitIDs.count,claimIDs.count)
            for unit in input.units where !sources.isDisjoint(with: unit.sourceIDs) {
                unitIDs.insert(unit.id)
                sources.formUnion(unit.sourceIDs + unit.dependencyIDs)
            }
            for claim in input.claims where claim.references.contains(where: { sources.contains($0.sourceID) }) {
                claimIDs.insert(claim.id)
                sources.formUnion(claim.references.map(\.sourceID))
            }
            changed=before != (sources.count,unitIDs.count,claimIDs.count)
        }
        guard sources.isSubset(of: Set(input.manifest.sourceIDs)) else { throw VoiceOSError("全景单元引用超出当前完整输入") }
        let units=input.units.filter { unitIDs.contains($0.id) }
        let selectedSources=input.sources.filter { sources.contains($0.id) }
        let claims=input.claims.filter { claimIDs.contains($0.id) }
        let manifest=PanoramaManifest(digest: input.manifest.digest, sourceIDs: selectedSources.map(\.id), claimIDs: claims.map(\.id), unitIDs: units.map(\.id))
        return .init(manifest: manifest, units: units, sources: selectedSources, claims: claims, exclusions: [])
    }
    static func namespacePanorama(_ proposal: PanoramaProposal, unitID: String) -> PanoramaProposal {
        let prefix="unit["+unitID+"]/"
        func name(_ value: String) -> String { prefix+value }
        return .init(regions: proposal.regions.map { .init(id: name($0.id), title: $0.title, summary: $0.summary) },
            questions: proposal.questions.map { .init(id: name($0.id), regionID: name($0.regionID), title: $0.title, summary: $0.summary, evidence: $0.evidence) },
            relations: proposal.relations.map { .init(id: name($0.id), from: name($0.from), to: name($0.to), label: $0.label, explanation: $0.explanation, fromEvidence: $0.fromEvidence, toEvidence: $0.toEvidence) },
            unrepresentedSources: proposal.unrepresentedSources, unrepresentedClaims: proposal.unrepresentedClaims)
    }
    static func partialPanorama(_ units: [VerifiedPanoramaUnit], input: PanoramaInput, id: String, phase: PanoramaPhase) throws -> PanoramaSnapshot {
        guard let latest=units.last else { throw VoiceOSError("尚无已独立核对的完整单元") }
        let questions=units.flatMap { unit in unit.proposal.questions.map { question in
            let endpointEvidence=unit.proposal.relations.flatMap { relation in
                (relation.from == question.id ? relation.fromEvidence : []) + (relation.to == question.id ? relation.toEvidence : [])
            }
            return PanoramaQuestion(id: question.id, regionID: question.regionID, title: question.title, summary: question.summary, evidence: question.evidence + endpointEvidence)
        } }
        let representedSources=Set(questions.flatMap(\.evidence).map(\.sourceID))
        let representedClaims=Set(questions.flatMap(\.evidence).flatMap(\.claimIDs))
        let sourceIDs=Set(units.flatMap { $0.input.manifest.sourceIDs })
        let claimIDs=Set(units.flatMap { $0.input.manifest.claimIDs })
        func pending(_ values: [PanoramaUnrepresented], submitted: Set<String>, represented: Set<String>) -> [PanoramaUnrepresented] {
            let byID=Dictionary(grouping: values, by: \.id)
            return submitted.subtracting(represented).sorted().compactMap { byID[$0]?.first }
        }
        let unrepresentedSources=pending(units.flatMap { $0.proposal.unrepresentedSources }, submitted: sourceIDs, represented: representedSources)
        let unrepresentedClaims=pending(units.flatMap { $0.proposal.unrepresentedClaims }, submitted: claimIDs, represented: representedClaims)
        let proposal=PanoramaProposal(regions: units.flatMap { $0.proposal.regions }, questions: questions, relations: [],
            unrepresentedSources: unrepresentedSources, unrepresentedClaims: unrepresentedClaims)
        let scoped=PanoramaInput(manifest: .init(digest: input.manifest.digest, sourceIDs: sourceIDs.sorted(), claimIDs: claimIDs.sorted(), unitIDs: units.map(\.unitID)),
            units: input.units.filter { unit in units.contains { $0.unitID == unit.id } }, sources: input.sources.filter { sourceIDs.contains($0.id) }, claims: input.claims.filter { claimIDs.contains($0.id) }, exclusions: [])
        let coverage=try validatePanorama(proposal, input: scoped)
        let receipts=units.flatMap { [PanoramaStepReceipt(stage: "unit.generate", scopeID: $0.unitID, receipt: $0.generation),
                                    PanoramaStepReceipt(stage: "unit.verify", scopeID: $0.unitID, receipt: $0.verification)] }
        return .init(id: id, createdAt: now(), input: input, proposal: proposal, coverage: coverage,
            generation: latest.generation, verification: latest.verification, review: latest.review,
            workflow: .init(phase: phase, verifiedUnitIDs: units.map(\.unitID), totalUnitCount: input.units.count, receipts: receipts))
    }
}

struct PanoramaSynthesisInput: Encodable {
    let input: PanoramaInput
    let proposals: [PanoramaUnitProposal]
}
struct PanoramaCoverageInput: Encodable {
    let input: PanoramaInput
    let proposal: PanoramaProposal
    let target: PanoramaCoverageTarget
    let rejections: [PanoramaRejection]
}
struct PanoramaConsistencyInput: Encodable {
    let input: PanoramaInput
    let proposal: PanoramaProposal
    let unitProposals: [PanoramaUnitProposal]
    let reviews: [PanoramaScopedReview]
    let rejections: [PanoramaRejection]
}

extension VoiceOSStore {
    static func panoramaProjection(_ proposal: PanoramaProposal, input: PanoramaInput, questionIDs: Set<String>, relationIDs: Set<String>) -> PanoramaProposal {
        let relations=proposal.relations.filter { relationIDs.contains($0.id) }
        let included=questionIDs.union(relations.flatMap { [$0.from,$0.to] })
        let questions=proposal.questions.filter { included.contains($0.id) }
        let regions=Set(questions.map(\.regionID))
        let evidence=questions.flatMap(\.evidence) + relations.flatMap { $0.fromEvidence + $0.toEvidence }
        let sources=Set(evidence.map(\.sourceID)), claims=Set(evidence.flatMap(\.claimIDs))
        let sourceReasons=Dictionary(uniqueKeysWithValues: proposal.unrepresentedSources.map { ($0.id,$0.reason) })
        let claimReasons=Dictionary(uniqueKeysWithValues: proposal.unrepresentedClaims.map { ($0.id,$0.reason) })
        let scopedReason="本次仅核对指定问题、联系或单元；其余内容由对应单元的全局覆盖核对负责"
        return .init(regions: proposal.regions.filter { regions.contains($0.id) }, questions: questions, relations: relations,
            unrepresentedSources: input.manifest.sourceIDs.filter { !sources.contains($0) }.map { .init(id: $0, reason: sourceReasons[$0] ?? scopedReason) },
            unrepresentedClaims: input.manifest.claimIDs.filter { !claims.contains($0) }.map { .init(id: $0, reason: claimReasons[$0] ?? scopedReason) })
    }
    static func panoramaRejection(_ rejection: PanoramaRejection, unitID: String) -> PanoramaRejection {
        let prefix="unit["+unitID+"]/"
        let review=PanoramaReview(questions: rejection.review.questions.map { .init(id: prefix+$0.id, accepted: $0.accepted, reason: $0.reason) },
            relations: rejection.review.relations.map { .init(id: prefix+$0.id, accepted: $0.accepted, reason: $0.reason) }, coverageAccepted: rejection.review.coverageAccepted, reason: rejection.review.reason)
        return .init(proposal: namespacePanorama(rejection.proposal, unitID: unitID), review: review)
    }
}

struct PanoramaSemanticIssue: Error, Codable, Sendable {
    let input: PanoramaInput
    let rejection: PanoramaRejection
}
struct PanoramaGlobalRepairInput: Encodable {
    let input: PanoramaInput
    let proposal: PanoramaProposal
    let issue: PanoramaSemanticIssue
}
struct PanoramaGlobalValidation: Sendable {
    let reviews: [PanoramaScopedReview]
    let finalReview: PanoramaReview
    let finalReceipt: PanoramaReceipt
}

/// One independent evidence review covers a whole region's questions, or a
/// group of relations sharing an endpoint-region pair, so the shared context is
/// read once. The review semantics are unchanged; only the grouping is.
struct PanoramaReviewBatch: Sendable {
    let scopeID: String
    let questionIDs: [String]
    let relationIDs: [String]
    let sourceIDs: Set<String>
}

/// Caps how many global review requests one attempt may spend. A repaired
/// candidate only invalidates the batches it touches, but a pathological chain
/// must still stop with a clear error instead of consuming the whole budget.
final class PanoramaReviewBudget {
    private(set) var remaining: Int
    init(_ limit: Int) { remaining = limit }
    func spend() throws {
        guard remaining > 0 else { throw VoiceOSError("全景核对达到本轮预算上限，已保留部分结果；可明确重试继续") }
        remaining -= 1
    }
}

extension VoiceOSStore {
    static func panoramaQuestionBatches(_ proposal: PanoramaProposal) -> [PanoramaReviewBatch] {
        var order: [String] = []
        var grouped: [String: [PanoramaQuestion]] = [:]
        for question in proposal.questions {
            if grouped[question.regionID] == nil { order.append(question.regionID) }
            grouped[question.regionID, default: []].append(question)
        }
        return order.compactMap { regionID in
            guard let questions = grouped[regionID] else { return nil }
            return .init(scopeID: regionID, questionIDs: questions.map(\.id), relationIDs: [],
                         sourceIDs: Set(questions.flatMap { $0.evidence.map(\.sourceID) }))
        }
    }
    static func panoramaRelationBatches(_ proposal: PanoramaProposal) -> [PanoramaReviewBatch] {
        let regionByQuestion = Dictionary(uniqueKeysWithValues: proposal.questions.map { ($0.id, $0.regionID) })
        var order: [String] = []
        var grouped: [String: [PanoramaRelation]] = [:]
        var pairByScope: [String: [String]] = [:]
        for relation in proposal.relations {
            guard let from = regionByQuestion[relation.from], let to = regionByQuestion[relation.to] else { continue }
            let pair = from <= to ? [from, to] : [to, from]
            let scopeID = pair.joined(separator: "|")
            if grouped[scopeID] == nil { order.append(scopeID); pairByScope[scopeID] = pair }
            grouped[scopeID, default: []].append(relation)
        }
        let questionsByRegion = Dictionary(grouping: proposal.questions, by: \.regionID)
        return order.compactMap { scopeID in
            guard let relations = grouped[scopeID], let pair = pairByScope[scopeID] else { return nil }
            let regionSources = Set(pair.flatMap { regionID in
                (questionsByRegion[regionID] ?? []).flatMap { $0.evidence.map(\.sourceID) }
            })
            let relationSources = relations.flatMap { ($0.fromEvidence + $0.toEvidence).map(\.sourceID) }
            return .init(scopeID: scopeID, questionIDs: Set(relations.flatMap { [$0.from, $0.to] }).sorted(),
                         relationIDs: relations.map(\.id), sourceIDs: regionSources.union(relationSources))
        }
    }
}

extension VoiceOSStore {
    static func validatePanoramaStageReview(_ review: PanoramaReview, proposal: PanoramaProposal, input: PanoramaInput,
        generation: PanoramaReceipt, verification: PanoramaReceipt) throws {
        do { try validatePanoramaReview(review, proposal: proposal, generation: generation, verification: verification) }
        catch {
            let decisions=review.questions + review.relations
            let identified=Set(review.questions.map(\.id)) == Set(proposal.questions.map(\.id))
                && Set(review.relations.map(\.id)) == Set(proposal.relations.map(\.id))
                && review.questions.count == proposal.questions.count && review.relations.count == proposal.relations.count
            guard identified, !review.reason.isEmpty, decisions.allSatisfy({ !$0.reason.isEmpty }),
                  !verification.responseID.isEmpty, verification.responseID != generation.responseID,
                  !verification.model.isEmpty, !review.coverageAccepted || decisions.contains(where: { !$0.accepted }) else { throw error }
            throw PanoramaSemanticIssue(input: input, rejection: .init(proposal: proposal, review: review))
        }
    }
}
