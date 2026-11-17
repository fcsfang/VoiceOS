import Foundation
import XCTest
@testable import VoiceOSCore

/// A panorama port whose early responses attribute a quote to a claim outside
/// the unit's claim list, the shape of the measured chronic unit failure, and
/// whose later responses return valid proposals.
private actor OwnershipFaultPanoramaFixture: PanoramaModelPort {
    nonisolated let configurationIdentity: String
    let faultedGenerations: Int
    let faultedSyntheses: Int
    let faultClaimID: String
    var generations=0, syntheses=0, serial=0

    init(identity: String = "ownership-fault-fixture", faultedGenerations: Int = 0, faultedSyntheses: Int = 0,
         faultClaimID: String = "claim-outside-evidence") {
        configurationIdentity=identity; self.faultedGenerations=faultedGenerations
        self.faultedSyntheses=faultedSyntheses; self.faultClaimID=faultClaimID
    }
    private func receipt() -> PanoramaReceipt {
        serial += 1
        return .init(responseID: configurationIdentity+"-response-"+String(serial), model: configurationIdentity, createdAt: "2026-11-17T00:00:00Z")
    }
    private func review(_ proposal: PanoramaProposal) -> PanoramaReview {
        .init(questions: proposal.questions.map { .init(id: $0.id, accepted: true, reason: "完整原话与归属对应") },
              relations: proposal.relations.map { .init(id: $0.id, accepted: true, reason: "双方完整原文支持该联系") },
              coverageAccepted: true, reason: "本次指定范围全部核对")
    }
    func proposal(_ input: PanoramaInput, faulted: Bool) -> PanoramaProposal {
        let questions=input.sources.enumerated().map { index, source in
            let ownedClaims=input.claims.filter { claim in claim.references.contains { $0.sourceID == source.id } }.map(\.id)
            return PanoramaQuestion(id: "q"+String(index), regionID: "r", title: "如何保留完整检索条件？", summary: source.title,
                evidence: [.init(sourceID: source.id, transcriptVersionID: source.transcript.transcriptVersionID, start: 0,
                    end: source.transcript.text.unicodeScalars.count, quote: source.transcript.text,
                    claimIDs: faulted ? [faultClaimID] : ownedClaims)])
        }
        return merged(regions: [.init(id: "r", title: "检索条件", summary: "完整材料的条件核对")], questions: questions, relations: [], input: input)
    }
    private func merged(regions: [PanoramaRegion], questions: [PanoramaQuestion], relations: [PanoramaRelation],
                        input: PanoramaInput) -> PanoramaProposal {
        let representedSources=Set(questions.flatMap(\.evidence).map(\.sourceID))
        let representedClaims=Set(questions.flatMap(\.evidence).flatMap(\.claimIDs))
        return .init(regions: regions, questions: questions, relations: relations,
            unrepresentedSources: input.manifest.sourceIDs.filter { !representedSources.contains($0) }.map { .init(id: $0, reason: "本轮未归入具体问题") },
            unrepresentedClaims: input.manifest.claimIDs.filter { !representedClaims.contains($0) }.map { .init(id: $0, reason: "本轮未归入具体问题") })
    }
    func generate(_ input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt) {
        generations += 1
        return (proposal(input, faulted: generations <= faultedGenerations), receipt())
    }
    func synthesize(_ proposals: [PanoramaUnitProposal], input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt) {
        syntheses += 1
        var questions=proposals.flatMap(\.proposal.questions)
        if syntheses <= faultedSyntheses, let first=questions.first {
            questions[0]=PanoramaQuestion(id: first.id, regionID: first.regionID, title: first.title, summary: first.summary,
                evidence: first.evidence.map { .init(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID,
                    start: $0.start, end: $0.end, quote: $0.quote, claimIDs: [faultClaimID]) })
        }
        return (merged(regions: proposals.flatMap(\.proposal.regions), questions: questions,
            relations: proposals.flatMap(\.proposal.relations), input: input), receipt())
    }
    func verify(_ proposal: PanoramaProposal, input: PanoramaInput, priorRejection: PanoramaRejection?) async throws -> (PanoramaReview, PanoramaReceipt) {
        (review(proposal), receipt())
    }
    func repair(_ proposal: PanoramaProposal, input: PanoramaInput, review: PanoramaReview) async throws -> (PanoramaProposal, PanoramaReceipt) {
        (proposal, receipt())
    }
    func verifyEvidence(_ proposal: PanoramaProposal, input: PanoramaInput) async throws -> (PanoramaReview, PanoramaReceipt) {
        (review(proposal), receipt())
    }
    func verifyCoverage(_ proposal: PanoramaProposal, input: PanoramaInput, target: PanoramaCoverageTarget, rejections: [PanoramaRejection]) async throws -> (PanoramaReview, PanoramaReceipt) {
        (review(proposal), receipt())
    }
    func verifyConsistency(_ proposal: PanoramaProposal, input: PanoramaInput, unitProposals: [PanoramaUnitProposal], reviews: [PanoramaScopedReview], rejections: [PanoramaRejection]) async throws -> (PanoramaReview, PanoramaReceipt) {
        (review(proposal), receipt())
    }
    func groupAreas(_ proposal: PanoramaProposal, input: PanoramaInput) async throws -> ([PanoramaArea], PanoramaReceipt) {
        let regionIDs=proposal.regions.map(\.id)
        return (regionIDs.isEmpty ? [] : [.init(id: "area-all", title: "全部区域", summary: "覆盖全部区域", regionIDs: regionIDs)], receipt())
    }
}

extension CoreFlowTests {
    func testPanoramaProposalInvalidRetriesOnceThenCompletes() async throws {
        let directory=root.appendingPathComponent("proposal-invalid-retry")
        let store=try await panoramaFixtureStore(directory, count: 1)
        let port=OwnershipFaultPanoramaFixture(faultedGenerations: 1)
        try await store.generatePanorama(using: port)
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"completed")
        XCTAssertNotNil(state.snapshot)
        let generations=await port.generations
        XCTAssertEqual(generations,2,"首次归属不符必须在同一步骤内重试一次")
        let database=try Database(directory.appendingPathComponent("voiceos.sqlite"))
        let rows=try database.query("SELECT state,error FROM panorama_steps WHERE stage='unit.generate' ORDER BY rowid")
        XCTAssertEqual(rows.compactMap { $0["state"] },["failed","completed"])
        let firstError=rows.first?["error"] ?? ""
        XCTAssertTrue(firstError.contains("q0"))
        XCTAssertTrue(firstError.contains("观点归属"))
    }

    func testPanoramaProposalInvalidStopsWithDiagnosis() async throws {
        let directory=root.appendingPathComponent("proposal-invalid-exhausted")
        let store=try await panoramaFixtureStore(directory, count: 1)
        let port=OwnershipFaultPanoramaFixture(faultedGenerations: .max)
        do {
            try await store.generatePanorama(using: port)
            XCTFail("两次归属不符必须停止")
        } catch let failure as PanoramaUnitFailures {
            let text=failure.errorDescription ?? ""
            XCTAssertTrue(text.contains("q0"))
            XCTAssertTrue(text.contains("观点归属"))
            XCTAssertTrue(text.contains("第 1 条证据"))
        } catch {
            XCTFail("单元失败应聚合为 PanoramaUnitFailures：\(error)")
        }
        let generations=await port.generations
        XCTAssertEqual(generations,2,"重试预算只有一次")
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"failed")
        XCTAssertTrue(state.error?.contains("q0") == true)
        XCTAssertTrue(state.error?.contains("观点归属") == true)
        let input=try await store.panoramaInput()
        let bad=await port.proposal(input, faulted: true)
        XCTAssertThrowsError(try VoiceOSStore.validatePanorama(bad, input: input)) { error in
            guard let invalid=error as? PanoramaProposalInvalid else { return XCTFail("应为 PanoramaProposalInvalid：\(error)") }
            XCTAssertEqual(invalid.questionID,"q0")
            XCTAssertEqual(invalid.evidenceIndex,1)
            XCTAssertEqual(invalid.claimIDs,["claim-outside-evidence"])
            XCTAssertTrue(invalid.errorDescription?.contains("q0") == true)
            XCTAssertTrue(invalid.errorDescription?.contains("观点归属") == true)
        }
    }

    func testPanoramaProposalInvalidSurfacesFromSynthesis() async throws {
        let directory=root.appendingPathComponent("proposal-invalid-synthesis")
        let store=try await panoramaFixtureStore(directory, count: 1)
        let input=try await store.panoramaInput()
        let unit=try XCTUnwrap(input.units.first)
        let port=OwnershipFaultPanoramaFixture(faultedSyntheses: .max)
        do {
            try await store.generatePanorama(using: port)
            XCTFail("两次归属不符必须停止")
        } catch let invalid as PanoramaProposalInvalid {
            let text=invalid.errorDescription ?? ""
            XCTAssertEqual(invalid.questionID,"unit[\(unit.id)]/q0")
            XCTAssertEqual(invalid.evidenceIndex,1)
            XCTAssertTrue(text.contains("unit[\(unit.id)]/q0"))
            XCTAssertTrue(text.contains("观点归属"))
        } catch {
            XCTFail("全局综合的归属不符应抛出 PanoramaProposalInvalid：\(error)")
        }
        let syntheses=await port.syntheses
        XCTAssertEqual(syntheses,2,"综合归属不符必须重试一次后停止")
        let database=try Database(directory.appendingPathComponent("voiceos.sqlite"))
        let rows=try database.query("SELECT state,error FROM panorama_steps WHERE stage='global.synthesize' ORDER BY rowid")
        XCTAssertEqual(rows.compactMap { $0["state"] },["failed","failed"])
        XCTAssertTrue(rows.first?["error"]?.contains("观点归属") == true)
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"failed")
        XCTAssertTrue(state.error?.contains("观点归属") == true)
    }
}
