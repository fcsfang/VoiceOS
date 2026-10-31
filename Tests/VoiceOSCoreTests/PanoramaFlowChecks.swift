import Foundation
import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

actor ProgressivePanoramaFixture: PanoramaModelPort {
    nonisolated let configurationIdentity: String
    let rejectUnits: Bool
    let repairUnits: Bool
    let invalidQuote: Bool
    var invalidQuoteAttempts: Int
    let failGenerationAt: Int?
    let beforeGenerate: (@Sendable (PanoramaInput) async throws -> Void)?
    var transientFailures: Int
    var unitTransientFailures: [String: Int]
    var failCoverage: Bool
    var failConsistency: Bool
    var invalidFocusAttempts: Int
    let failFocusAt: Int?
    let rejectedDecisionSubstring: String?
    let rejectCoverageOnly: Bool
    var generations=0, unitReviews=0, unitRepairs=0, syntheses=0, globalRepairs=0, evidenceReviews=0, coverageReviews=0, consistencyReviews=0
    var generatedSourceIDs: [[String]]=[]
    var focusCalls: [PanoramaGenerationFocus]=[]
    var focusTargets: [PanoramaCoverageTarget]=[]
    var serial=0
    var sawPriorGlobalRejection=false
    var coverageTargets: [PanoramaCoverageTarget]=[]
    var synthesisReferenceFailures: Int

    init(identity: String = "progressive-fixture", failGenerationAt: Int? = nil, rejectUnits: Bool = false, repairUnits: Bool = false, invalidQuote: Bool = false,
         failCoverage: Bool = false, failConsistency: Bool = false, transientFailures: Int = 0, unitTransientFailures: [String: Int] = [:], invalidQuoteAttempts: Int = 0,
         invalidFocusAttempts: Int = 0, failFocusAt: Int? = nil, beforeGenerate: (@Sendable (PanoramaInput) async throws -> Void)? = nil,
         rejectedDecisionSubstring: String? = nil, rejectCoverageOnly: Bool = false, synthesisReferenceFailures: Int = 0) {
        configurationIdentity=identity; self.failGenerationAt=failGenerationAt; self.rejectUnits=rejectUnits; self.repairUnits=repairUnits; self.invalidQuote=invalidQuote
        self.failCoverage=failCoverage; self.failConsistency=failConsistency; self.beforeGenerate=beforeGenerate; self.transientFailures=transientFailures
        self.unitTransientFailures=unitTransientFailures; self.invalidQuoteAttempts=invalidQuoteAttempts
        self.invalidFocusAttempts=invalidFocusAttempts; self.failFocusAt=failFocusAt
        self.rejectedDecisionSubstring=rejectedDecisionSubstring; self.rejectCoverageOnly=rejectCoverageOnly
        self.synthesisReferenceFailures=synthesisReferenceFailures
    }
    private func receipt() -> PanoramaReceipt {
        serial += 1
        return .init(responseID: configurationIdentity+"-response-"+String(serial), model: configurationIdentity, createdAt: "2026-10-23T00:00:00Z")
    }
    private func review(_ proposal: PanoramaProposal, accepted: Bool = true, rejectingIDsContaining: String? = nil,
        coverageAccepted: Bool? = nil) -> PanoramaReview {
        func rejected(_ id: String) -> Bool { rejectingIDsContaining.map { id.contains($0) } ?? false }
        return .init(questions: proposal.questions.map { .init(id: $0.id, accepted: accepted && !rejected($0.id),
                reason: accepted && !rejected($0.id) ? "完整原话与归属对应" : "归纳缺少否定条件") },
            relations: proposal.relations.map { .init(id: $0.id, accepted: accepted && !rejected($0.id),
                reason: accepted && !rejected($0.id) ? "双方完整原文支持条件联系" : "双方原文尚不能支持此联系") },
            coverageAccepted: coverageAccepted ?? accepted, reason: accepted ? "本次指定范围全部核对" : "保留否定条件后重新核对")
    }
    func generate(_ input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt) {
        generations += 1
        generatedSourceIDs.append(input.sources.map(\.id))
        // Models the measured failure this change exists to remove: one response
        // cannot finish an oversized unit inside the service's 600-second stream.
        if input.sources.reduce(0, { $0+$1.transcript.text.unicodeScalars.count }) > 16_000 {
            throw VoiceOSError("模拟单请求超出服务端 600 秒窗口")
        }
        if let failedSource=input.sources.map(\.id).first(where: { unitTransientFailures[$0, default: 0] > 0 }) {
            unitTransientFailures[failedSource, default: 0] -= 1
            throw PanoramaTransientFailure(reason: "模拟上游服务暂时失败")
        }
        if transientFailures > 0 { transientFailures -= 1; throw URLError(.networkConnectionLost) }
        if generations == failGenerationAt { throw VoiceOSError("模拟后续单元暂停") }
        try await beforeGenerate?(input)
        let useInvalidQuote=invalidQuote || invalidQuoteAttempts > 0
        if invalidQuoteAttempts > 0 { invalidQuoteAttempts -= 1 }
        let questions=input.sources.enumerated().map { index, source in
            PanoramaQuestion(id: "q"+String(index), regionID: "r", title: "如何保留完整检索条件？", summary: source.title,
                evidence: [.init(sourceID: source.id, transcriptVersionID: source.transcript.transcriptVersionID, start: 0,
                    end: source.transcript.text.unicodeScalars.count, quote: useInvalidQuote ? "原文不存在的合成引文。" : source.transcript.text,
                    claimIDs: input.claims.filter { claim in claim.references.contains { $0.sourceID == source.id } }.map(\.id))])
        }
        return (.init(regions: [.init(id: "r", title: "检索条件", summary: "完整材料的条件核对")], questions: questions,
            relations: [], unrepresentedSources: [], unrepresentedClaims: []),receipt())
    }
    func generate(_ input: PanoramaInput, focus: PanoramaGenerationFocus, target: PanoramaCoverageTarget) async throws -> (PanoramaProposal, PanoramaReceipt) {
        focusCalls.append(focus)
        focusTargets.append(target)
        if let failFocusAt, focusCalls.count == failFocusAt { throw VoiceOSError("模拟聚焦分片暂停") }
        let regionID="r"
        let claimsByID=Dictionary(uniqueKeysWithValues: input.claims.map { ($0.id,$0) })
        let sourceByID=Dictionary(uniqueKeysWithValues: input.sources.map { ($0.id,$0) })
        func scalars(_ range: PanoramaFocusRange) throws -> (PanoramaSource, [Unicode.Scalar]) {
            guard let source=sourceByID[range.sourceID] else { throw VoiceOSError("聚焦分片来源缺失") }
            return (source, Array(source.transcript.text.unicodeScalars))
        }
        func overlappingClaims(_ range: PanoramaFocusRange, source: PanoramaSource) -> [String] {
            target.claimIDs.filter { id in
                claimsByID[id]?.references.contains { ref in
                    ref.sourceID == range.sourceID && ref.transcriptVersionID == range.transcriptVersionID &&
                    source.transcript.spans.contains { $0.id == ref.spanID && $0.textEnd > range.start && $0.textStart < range.end }
                } == true
            }
        }
        var questions: [PanoramaQuestion]=[]
        for (index, range) in focus.ranges.enumerated() {
            let (source, text)=try scalars(range)
            let quote=String(String.UnicodeScalarView(text[range.start..<range.end]))
            questions.append(.init(id: "q\(index)", regionID: regionID, title: "分片聚焦问题", summary: source.title,
                evidence: [.init(sourceID: range.sourceID, transcriptVersionID: range.transcriptVersionID, start: range.start, end: range.end,
                                 quote: quote, claimIDs: overlappingClaims(range, source: source))]))
        }
        if invalidFocusAttempts > 0, let first=focus.ranges.first {
            invalidFocusAttempts -= 1
            let (_, text)=try scalars(first)
            let start = first.end+2 <= text.count ? first.end : first.start-2
            if start >= 0, start+2 <= text.count {
                let quote=String(String.UnicodeScalarView(text[start..<(start+2)]))
                let extra=PanoramaEvidence(sourceID: first.sourceID, transcriptVersionID: first.transcriptVersionID,
                    start: start, end: start+2, quote: quote, claimIDs: [])
                questions[0] = .init(id: questions[0].id, regionID: questions[0].regionID, title: questions[0].title,
                    summary: questions[0].summary, evidence: questions[0].evidence+[extra])
            }
        }
        let representedSources=Set(questions.flatMap(\.evidence).map(\.sourceID))
        let representedClaims=Set(questions.flatMap(\.evidence).flatMap(\.claimIDs))
        let proposal=PanoramaProposal(regions: [.init(id: regionID, title: "分片聚焦区域", summary: "只依据本片全文范围")],
            questions: questions, relations: [],
            unrepresentedSources: target.sourceIDs.filter { !representedSources.contains($0) }.map { .init(id: $0, reason: "聚焦范围未覆盖该来源") },
            unrepresentedClaims: target.claimIDs.filter { !representedClaims.contains($0) }.map { .init(id: $0, reason: "聚焦范围未涉及该观点") })
        return (proposal,receipt())
    }
    func verify(_ proposal: PanoramaProposal, input: PanoramaInput, priorRejection: PanoramaRejection?) async throws -> (PanoramaReview, PanoramaReceipt) {
        unitReviews += 1
        if priorRejection == nil, let rejectedDecisionSubstring {
            return (review(proposal,rejectingIDsContaining: rejectedDecisionSubstring,coverageAccepted: false),receipt())
        }
        if priorRejection == nil, rejectCoverageOnly { return (review(proposal,coverageAccepted: false),receipt()) }
        return (review(proposal,accepted: !rejectUnits && (!repairUnits || priorRejection != nil)),receipt())
    }
    func repair(_ proposal: PanoramaProposal, input: PanoramaInput, review: PanoramaReview) async throws -> (PanoramaProposal, PanoramaReceipt) {
        unitRepairs += 1
        return (proposal,receipt())
    }
    func synthesize(_ proposals: [PanoramaUnitProposal], input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt) {
        syntheses += 1
        if synthesisReferenceFailures > 0 { synthesisReferenceFailures -= 1; throw PanoramaSynthesisReferenceFailure(reason: "模拟综合引用无效") }
        let regions=proposals.flatMap { $0.proposal.regions }, questions=proposals.flatMap { $0.proposal.questions }
        let relations: [PanoramaRelation]
        if questions.count > 1 {
            relations=[.init(id: "global-edge", from: questions[0].id, to: questions[1].id, label: "尚未核对的联系", explanation: "需要双方全文独立判断",
                fromEvidence: questions[0].evidence, toEvidence: questions[1].evidence)]
        } else { relations=[] }
        return (.init(regions: regions, questions: questions, relations: relations, unrepresentedSources: [], unrepresentedClaims: []),receipt())
    }
    func repairSynthesis(_ proposal: PanoramaProposal, input: PanoramaInput, context: PanoramaInput, rejection: PanoramaRejection) async throws -> (PanoramaProposal, PanoramaReceipt) {
        globalRepairs += 1
        XCTAssertTrue(rejection.review.relations.contains { !$0.accepted })
        let required=Set(rejection.proposal.questions.flatMap(\.evidence).map(\.sourceID))
        XCTAssertTrue(required.isSubset(of: Set(context.manifest.sourceIDs)))
        let relations=proposal.relations.map { PanoramaRelation(id: $0.id, from: $0.from, to: $0.to, label: "限定检索条件", explanation: "保留双方完整原文的否定条件",
            fromEvidence: $0.fromEvidence, toEvidence: $0.toEvidence) }
        return (.init(regions: proposal.regions, questions: proposal.questions, relations: relations,
            unrepresentedSources: proposal.unrepresentedSources, unrepresentedClaims: proposal.unrepresentedClaims),receipt())
    }
    func verifyEvidence(_ proposal: PanoramaProposal, input: PanoramaInput) async throws -> (PanoramaReview, PanoramaReceipt) {
        evidenceReviews += 1
        let accepted=proposal.relations.allSatisfy { $0.label != "尚未核对的联系" }
        let report=review(proposal)
        let relations=report.relations.map { PanoramaDecision(id: $0.id,accepted: accepted,reason: accepted ? $0.reason : "双方原文尚不能支持此联系") }
        return (.init(questions: report.questions,relations: relations,coverageAccepted: accepted,reason: accepted ? report.reason : "关系应保留双方否定条件"),receipt())
    }
    func verifyCoverage(_ proposal: PanoramaProposal, input: PanoramaInput, target: PanoramaCoverageTarget, rejections: [PanoramaRejection]) async throws -> (PanoramaReview, PanoramaReceipt) {
        coverageReviews += 1
        if failCoverage { failCoverage=false; throw VoiceOSError("模拟全局覆盖暂停") }
        XCTAssertTrue(Set(target.sourceIDs).isSubset(of: Set(input.manifest.sourceIDs)))
        XCTAssertTrue(Set(target.claimIDs).isSubset(of: Set(input.manifest.claimIDs)))
        coverageTargets.append(target)
        return (review(proposal),receipt())
    }
    func verifyConsistency(_ proposal: PanoramaProposal, input: PanoramaInput, unitProposals: [PanoramaUnitProposal], reviews: [PanoramaScopedReview], rejections: [PanoramaRejection]) async throws -> (PanoramaReview, PanoramaReceipt) {
        consistencyReviews += 1
        if failConsistency { failConsistency=false; throw VoiceOSError("模拟最后一致性暂停") }
        sawPriorGlobalRejection=rejections.contains { $0.review.relations.contains { !$0.accepted } }
        XCTAssertEqual(Set(unitProposals.map(\.unitID)),Set(input.manifest.unitIDs))
        XCTAssertEqual(Set(reviews.filter { $0.stage == "global.question" }.map(\.scopeID)),Set(proposal.questions.map(\.id)))
        XCTAssertEqual(Set(reviews.filter { $0.stage == "global.relation" }.map(\.scopeID)),Set(proposal.relations.map(\.id)))
        XCTAssertEqual(Set(reviews.filter { $0.stage == "global.coverage" }.map(\.scopeID)),Set(input.manifest.unitIDs))
        return (review(proposal),receipt())
    }
}

extension CoreFlowTests {
    func assertPanoramaProgressiveRecovery(root: URL) async throws {
        let store=try await panoramaFixtureStore(root.appendingPathComponent("progressive"), count: 3)
        let port=ProgressivePanoramaFixture(failGenerationAt: 2, failCoverage: true, failConsistency: true)
        do { try await store.generatePanorama(using: port); XCTFail("后续单元失败应暂停") } catch {}
        let first=try await store.panoramaState(), partial=try XCTUnwrap(first.snapshot)
        XCTAssertEqual(first.status,"failed")
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(partial.workflow?.verifiedUnitIDs.count,2)
        XCTAssertEqual(partial.coverage.submittedSourceIDs.count,2)
        XCTAssertEqual(partial.input.sources.count,3)
        XCTAssertTrue(partial.proposal.relations.isEmpty)
        try await store.generatePanorama(using: port)
        let unchangedGenerations=await port.generations
        XCTAssertEqual(unchangedGenerations,3)
        do { try await store.generatePanorama(using: port,retry: true); XCTFail("后续覆盖请求失败应保留单元结果") } catch {}
        let coverageFailure=try await store.panoramaState()
        XCTAssertEqual(coverageFailure.snapshot?.workflow?.verifiedUnitIDs.count,3)
        XCTAssertEqual(coverageFailure.snapshot?.workflow?.phase,.coverage)
        XCTAssertTrue(coverageFailure.snapshot?.proposal.relations.isEmpty == true)
        do { try await store.generatePanorama(using: port,retry: true); XCTFail("最后一致性请求失败仍不能完成") } catch {}
        let consistencyFailure=try await store.panoramaState()
        XCTAssertEqual(consistencyFailure.status,"failed")
        XCTAssertTrue(consistencyFailure.snapshot?.isPartial == true)
        try await store.generatePanorama(using: port,retry: true)
        let final=try await store.panoramaState(), snapshot=try XCTUnwrap(final.snapshot)
        XCTAssertEqual(final.status,"completed")
        XCTAssertFalse(snapshot.isPartial)
        XCTAssertEqual(snapshot.workflow?.phase,.completed)
        XCTAssertEqual(snapshot.coverage.submittedSourceIDs.count,3)
        XCTAssertEqual(snapshot.coverage.representedSourceIDs.count,3)
        XCTAssertEqual(snapshot.proposal.relations.first?.label,"限定检索条件")
        let counts=await (port.generations,port.syntheses,port.globalRepairs,port.evidenceReviews,port.coverageReviews,port.consistencyReviews)
        XCTAssertEqual(counts.0,4); XCTAssertEqual(counts.1,1); XCTAssertEqual(counts.2,1)
        XCTAssertEqual(counts.3,5); XCTAssertEqual(counts.4,4); XCTAssertEqual(counts.5,2)
        let sawPriorGlobalRejection=await port.sawPriorGlobalRejection
        XCTAssertTrue(sawPriorGlobalRejection)
        let targets=await port.coverageTargets
        XCTAssertEqual(Set(targets.flatMap(\.sourceIDs)),Set(snapshot.input.manifest.sourceIDs))
        let entry=try await store.beginPanoramaConversation(snapshotID: snapshot.id,selection: .relation("global-edge"))
        XCTAssertTrue(entry.draft.contains("AI 全景候选"))
        let source=try XCTUnwrap(snapshot.input.sources.first)
        _ = try await store.setSourceLocalOnly(sourceID: source.id,expectedVersion: 2,localOnly: true)
        let invalidated=try await store.panoramaState()
        XCTAssertNil(invalidated.snapshot)
        do { _ = try await store.beginPanoramaConversation(snapshotID: snapshot.id,selection: .relation("global-edge")); XCTFail("许可变化应撤下旧全景") } catch {}
        try await assertPanoramaRejectsUnverified(root: root)
        try await assertPanoramaConfigurationReuse(root: root)
        try await assertPanoramaCompleteUnitReuse(root: root)
        try await assertPanoramaManifestDuringAwait(root: root)
        try await assertPanoramaUnknownRecovery(root: root)
        try await assertPanoramaStagedWire()
        try await assertPanoramaCompactSynthesis(root: root)
        try await assertPanoramaTransientRetry(root: root)
    }
    func panoramaFixtureStore(_ root: URL, count: Int) async throws -> VoiceOSStore {
        let store=try VoiceOSStore(root: root,inspector: NativeMediaInspector())
        try await store.recover()
        var ids: [String]=[]
        for index in 0..<count {
            let id=try await store.recordUserExpression("完整检索材料第\(index)项，不能遗漏否定条件。")
            _ = try await store.setSourceLocalOnly(sourceID: id,expectedVersion: 1,localOnly: false)
            ids.append(id)
        }
        let context=try await store.prepareLocalTranscriptContext(sourceIDs: ids,scalarBudget: Int.max)
        _ = try await store.importOrganizedClaims(context: context,proposals: [],commandID: "complete-fixture")
        return store
    }
    private func assertPanoramaRejectsUnverified(root: URL) async throws {
        let store=try await panoramaFixtureStore(root.appendingPathComponent("unverified"),count: 1)
        let port=ProgressivePanoramaFixture(rejectUnits: true)
        do { try await store.generatePanorama(using: port); XCTFail("独立拒绝后不能显示候选") } catch {}
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"failed")
        XCTAssertNil(state.snapshot)
        let unitReviews=await port.unitReviews
        XCTAssertEqual(unitReviews,2)
        _ = try await appendPanoramaFixture(store,text: String(repeating: "新增独立材料仍须完整核对。",count: 30))
        do { try await store.generatePanorama(using: port); XCTFail("旧单元的拒绝结果不能跨全景发布") } catch {}
        let rejectedAgain=try await store.panoramaState(), rejectedGenerations=await port.generations
        XCTAssertNil(rejectedAgain.snapshot)
        XCTAssertEqual(rejectedGenerations,3)
        let directory=root.appendingPathComponent("invalid-quote")
        let invalid=try await panoramaFixtureStore(directory,count: 1)
        let invalidPort=ProgressivePanoramaFixture(identity: "invalid-quote-fixture",invalidQuote: true)
        do { try await invalid.generatePanorama(using: invalidPort); XCTFail("非逐字引文不能发布") } catch {}
        let invalidState=try await invalid.panoramaState()
        XCTAssertEqual(invalidState.status,"failed")
        XCTAssertNil(invalidState.snapshot)
        let database=try Database(directory.appendingPathComponent("voiceos.sqlite"))
        let step=try XCTUnwrap(database.query("SELECT state,result_json,receipt_json FROM panorama_steps WHERE stage='unit.generate'").first)
        XCTAssertEqual(step["state"],"failed")
        let raw=try XCTUnwrap(step["result_json"]), receipt=try XCTUnwrap(step["receipt_json"])
        let proposal=try JSONDecoder().decode(PanoramaProposal.self,from: Data(raw.utf8))
        XCTAssertEqual(proposal.questions.first?.evidence.first?.quote,"原文不存在的合成引文。")
        let actualReceipt=try JSONDecoder().decode(PanoramaReceipt.self,from: Data(receipt.utf8))
        XCTAssertEqual(actualReceipt.responseID,"invalid-quote-fixture-response-1")
        XCTAssertEqual(actualReceipt.model,"invalid-quote-fixture")
        XCTAssertEqual(actualReceipt.createdAt,"2026-10-23T00:00:00Z")
    }
    private func assertPanoramaConfigurationReuse(root: URL) async throws {
        let store=try await panoramaFixtureStore(root.appendingPathComponent("configuration"),count: 2)
        let first=ProgressivePanoramaFixture(identity: "first-model",failGenerationAt: 2)
        do { try await store.generatePanorama(using: first) } catch {}
        let second=ProgressivePanoramaFixture(identity: "second-model")
        try await store.generatePanorama(using: second,retry: true)
        let generations=await second.generations
        XCTAssertEqual(generations,2)
        let state=try await store.panoramaState(), snapshot=try XCTUnwrap(state.snapshot)
        XCTAssertTrue(snapshot.workflow?.receipts.filter { $0.stage == "unit.generate" }.allSatisfy { $0.receipt.model == "second-model" } == true)
    }
    private func appendPanoramaFixture(_ store: VoiceOSStore, text: String) async throws -> String {
        let id=try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        let context=try await store.prepareLocalTranscriptContext(sourceIDs: [id], scalarBudget: Int.max)
        _ = try await store.importOrganizedClaims(context: context, proposals: [], commandID: UUID().uuidString)
        return id
    }
    private func assertPanoramaCompleteUnitReuse(root: URL) async throws {
        let directory=root.appendingPathComponent("complete-unit-reuse")
        let store=try await panoramaFixtureStore(directory, count: 1)
        let originalInput=try await store.panoramaInput(), source=try XCTUnwrap(originalInput.sources.first)
        let context=try await store.prepareLocalTranscriptContext(sourceIDs: [source.id], scalarBudget: Int.max)
        let claimIDs=try await store.importOrganizedClaims(context: context, proposals: [.init(statement: source.transcript.text, ownership: .unresolved,
            references: [.init(sourceID: source.id, transcriptVersionID: source.transcript.transcriptVersionID, spanID: source.transcript.spans[0].id)])], commandID: "reuse-claim")
        let port=ProgressivePanoramaFixture(repairUnits: true, failConsistency: true)
        do { try await store.generatePanorama(using: port); XCTFail("全局未完成应保留已修复单元") } catch {}
        let first=try await store.panoramaState(), prior=try XCTUnwrap(first.snapshot)
        let originalReceipt=try XCTUnwrap(prior.workflow?.receipts.first { $0.stage == "unit.generate" && $0.scopeID == source.id })
        XCTAssertEqual(originalReceipt.receipt.responseID,"progressive-fixture-response-3")
        let added=try await appendPanoramaFixture(store,text: "新增独立材料，保留不同的检索条件。")
        try await store.generatePanorama(using: port)
        let second=try await store.panoramaState(), snapshot=try XCTUnwrap(second.snapshot)
        XCTAssertEqual(second.status,"completed")
        XCTAssertNotEqual(snapshot.input.manifest.digest,prior.input.manifest.digest)
        let counts=await (port.generations,port.unitReviews,port.unitRepairs,port.syntheses,port.consistencyReviews)
        XCTAssertEqual(counts.0,2); XCTAssertEqual(counts.1,4); XCTAssertEqual(counts.2,2)
        XCTAssertEqual(counts.3,2); XCTAssertEqual(counts.4,2)
        let generatedSources=await port.generatedSourceIDs
        XCTAssertEqual(generatedSources,[[source.id],[added]])
        let reusedReceipt=try XCTUnwrap(snapshot.workflow?.receipts.first { $0.stage == "unit.generate" && $0.scopeID == source.id })
        XCTAssertEqual(reusedReceipt.receipt.responseID,originalReceipt.receipt.responseID)
        let database=try Database(directory.appendingPathComponent("voiceos.sqlite"))
        XCTAssertTrue(try database.query("SELECT id FROM panorama_steps WHERE attempt_id=? AND scope_id=? AND stage LIKE 'unit.%'",[snapshot.id,source.id]).isEmpty)
        XCTAssertFalse(try database.query("SELECT id FROM panorama_steps WHERE attempt_id=? AND stage='global.synthesize'",[snapshot.id]).isEmpty)
        _ = try await store.reviewClaim(claimID: claimIDs[0],expectedVersion: 0,action: .correct,statement: "检索条件已更正，必须重新核对。",note: "核对原意")
        try await store.generatePanorama(using: port)
        let afterClaim=await port.generatedSourceIDs
        XCTAssertEqual(afterClaim,[[source.id],[added],[source.id]])
        _ = try await store.correctTranscript(sourceID: source.id,expectedVersionID: source.transcript.transcriptVersionID,text: source.transcript.text + "保留新增的否定条件。")
        let changed=try await store.prepareLocalTranscriptContext(sourceIDs: [source.id],scalarBudget: Int.max)
        _ = try await store.importOrganizedClaims(context: changed,proposals: [],commandID: "changed-source")
        try await store.generatePanorama(using: port)
        let afterSource=await port.generatedSourceIDs
        XCTAssertEqual(afterSource.last,[source.id]); XCTAssertEqual(afterSource.count,4)
        let policy=try await store.sourcePolicy(sourceID: source.id)
        let revoked=try await store.setSourceLocalOnly(sourceID: source.id,expectedVersion: policy.version,localOnly: true)
        _ = try await store.setSourceLocalOnly(sourceID: source.id,expectedVersion: revoked,localOnly: false)
        let allowed=try await store.prepareLocalTranscriptContext(sourceIDs: [source.id],scalarBudget: Int.max)
        _ = try await store.importOrganizedClaims(context: allowed,proposals: [],commandID: "changed-policy")
        try await store.generatePanorama(using: port)
        let afterPolicy=await port.generatedSourceIDs
        XCTAssertEqual(afterPolicy.last,[source.id]); XCTAssertEqual(afterPolicy.count,5)
        _ = try await appendPanoramaFixture(store,text: "第三份独立材料，配置改变后重新理解。")
        let changedPort=ProgressivePanoramaFixture(identity: "changed-config")
        try await store.generatePanorama(using: changedPort)
        let changedCalls=await changedPort.generations
        XCTAssertEqual(changedCalls,3)
        print("Panorama complete-unit reuse preserved accepted repair receipt, skipped unchanged unit calls, reran global synthesis, and invalidated claim/source/policy/config changes")
    }
    private func assertPanoramaManifestDuringAwait(root: URL) async throws {
        let store=try await panoramaFixtureStore(root.appendingPathComponent("invalidation"),count: 1)
        let input=try await store.panoramaInput(), source=try XCTUnwrap(input.sources.first)
        let port=ProgressivePanoramaFixture(beforeGenerate: { _ in
            _ = try await store.setSourceLocalOnly(sourceID: source.id,expectedVersion: 2,localOnly: true)
        })
        do { try await store.generatePanorama(using: port); XCTFail("请求期间授权变化不能发布") } catch {}
        let invalidated=try await store.panoramaState()
        XCTAssertNil(invalidated.snapshot)
    }
    private func assertPanoramaTransientRetry(root: URL) async throws {
        let directory=root.appendingPathComponent("transient-retry")
        let store=try await panoramaFixtureStore(directory,count: 1)
        let port=ProgressivePanoramaFixture(transientFailures: 2)
        try await store.generatePanorama(using: port)
        let state=try await store.panoramaState(), generations=await port.generations
        XCTAssertEqual(state.status,"completed")
        XCTAssertEqual(generations,3)
        let database=try Database(directory.appendingPathComponent("voiceos.sqlite"))
        let steps=try database.query("SELECT state,receipt_json FROM panorama_steps WHERE stage='unit.generate' ORDER BY rowid")
        XCTAssertEqual(steps.compactMap { $0["state"] },["failed","failed","completed"])
        XCTAssertNil(steps[0]["receipt_json"])
        XCTAssertNotNil(steps[2]["receipt_json"])
        let exhausted=try await panoramaFixtureStore(root.appendingPathComponent("retry-exhausted"),count: 1)
        let exhaustedPort=ProgressivePanoramaFixture(transientFailures: 3)
        do { try await exhausted.generatePanorama(using: exhaustedPort); XCTFail("瞬时重试预算用尽应停止") } catch {}
        let failed=try await exhausted.panoramaState(), failedCalls=await exhaustedPort.generations
        XCTAssertEqual(failed.status,"failed")
        XCTAssertNil(failed.snapshot)
        XCTAssertEqual(failedCalls,3)
        try await exhausted.generatePanorama(using: exhaustedPort)
        let unchangedCalls=await exhaustedPort.generations
        XCTAssertEqual(unchangedCalls,3)
        try await exhausted.generatePanorama(using: exhaustedPort,retry: true)
        let resumed=try await exhausted.panoramaState(), resumedCalls=await exhaustedPort.generations
        XCTAssertEqual(resumed.status,"completed")
        XCTAssertEqual(resumedCalls,4)
    }
    private func assertPanoramaUnknownRecovery(root: URL) async throws {
        let directory=root.appendingPathComponent("unknown")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let file=directory.appendingPathComponent("voiceos.sqlite"), attemptID=UUID().uuidString
        var database: Database?=try Database(file)
        try database?.execute("INSERT INTO panorama_attempts(id,digest,state,input_json,created_at) VALUES(?,?,'running','{}','fixture')",[attemptID,"unknown-fixture"])
        try database?.execute("INSERT INTO panorama_steps(id,attempt_id,stage,scope_id,input_digest,state,input_json,created_at) VALUES(?,?,'unit.generate','fixture','fixture','running','{}','fixture')",[UUID().uuidString,attemptID])
        database=nil
        let store=try VoiceOSStore(root: directory,inspector: NativeMediaInspector())
        try await store.recover()
        let reopened=try Database(file)
        XCTAssertEqual(try reopened.query("SELECT state FROM panorama_attempts").first?["state"],"unknown")
        XCTAssertEqual(try reopened.query("SELECT state FROM panorama_steps").first?["state"],"unknown")
    }
    private func assertPanoramaCompactSynthesis(root: URL) async throws {
        let directory=root.appendingPathComponent("synthesis-identity")
        let store=try await panoramaFixtureStore(directory,count: 2)
        let port=ProgressivePanoramaFixture(identity: "identity-fixture")
        try await store.generatePanorama(using: port)
        let state=try await store.panoramaState(), snapshot=try XCTUnwrap(state.snapshot)
        XCTAssertEqual(state.status,"completed")
        let database=try Database(directory.appendingPathComponent("voiceos.sqlite"))
        func completedStep(_ stage: String, _ scopeID: String) throws -> [String:String] {
            try XCTUnwrap(database.query("SELECT input_json,input_digest FROM panorama_steps WHERE attempt_id=? AND stage=? AND scope_id=? AND state='completed' ORDER BY rowid DESC LIMIT 1",
                [snapshot.id,stage,scopeID]).first)
        }
        func digest(_ json: String, _ identity: String) -> String {
            VoiceOSStore.relevanceHash(Data(("panorama-staged-v1|"+identity+"|"+json).utf8))
        }
        let synthesize=try completedStep("global.synthesize","all")
        let synthesizeJSON=try XCTUnwrap(synthesize["input_json"]), synthesizeDigest=try XCTUnwrap(synthesize["input_digest"])
        XCTAssertEqual(synthesizeDigest,digest(synthesizeJSON,"identity-fixture|compact-synthesis-v1"))
        XCTAssertNotEqual(synthesizeDigest,digest(synthesizeJSON,"identity-fixture"))
        let repair=try completedStep("global.repair","all")
        let repairJSON=try XCTUnwrap(repair["input_json"]), repairDigest=try XCTUnwrap(repair["input_digest"])
        XCTAssertEqual(repairDigest,digest(repairJSON,"identity-fixture|compact-synthesis-v1"))
        let unitID=try XCTUnwrap(snapshot.input.units.first?.id)
        let unit=try completedStep("unit.generate",unitID)
        let unitJSON=try XCTUnwrap(unit["input_json"]), unitDigest=try XCTUnwrap(unit["input_digest"])
        XCTAssertEqual(unitDigest,digest(unitJSON,"identity-fixture"))
        XCTAssertNotEqual(unitDigest,digest(unitJSON,"identity-fixture|compact-synthesis-v1"))
        let retryDirectory=root.appendingPathComponent("synthesis-reference-retry")
        let retryStore=try await panoramaFixtureStore(retryDirectory,count: 1)
        let retryPort=ProgressivePanoramaFixture(identity: "reference-retry-fixture",synthesisReferenceFailures: 1)
        try await retryStore.generatePanorama(using: retryPort)
        let retried=try await retryStore.panoramaState(), retryCalls=await retryPort.syntheses
        XCTAssertEqual(retried.status,"completed")
        XCTAssertEqual(retryCalls,2)
        let failedDirectory=root.appendingPathComponent("synthesis-reference-exhausted")
        let failedStore=try await panoramaFixtureStore(failedDirectory,count: 1)
        let failedPort=ProgressivePanoramaFixture(identity: "reference-failed-fixture",synthesisReferenceFailures: 2)
        do { try await failedStore.generatePanorama(using: failedPort); XCTFail("引用失败重试预算用尽应停止") } catch {}
        let failed=try await failedStore.panoramaState(), failedCalls=await failedPort.syntheses
        XCTAssertEqual(failed.status,"failed")
        XCTAssertTrue(failed.error?.contains("全景综合引用无效") == true)
        XCTAssertEqual(failedCalls,2)
        print("Panorama compact synthesis expanded refs locally, scoped its identity, and retried invalid references once")
    }
}

private actor PanoramaWireTransport: ModelHTTPTransport {
    var replies: [ModelHTTPReply]
    var requests: [Data]=[]
    init(_ replies: [ModelHTTPReply]) { self.replies=replies }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        requests.append(request.httpBody ?? Data())
        guard !replies.isEmpty else { throw VoiceOSError("回放响应不足") }
        return replies.removeFirst()
    }
}

extension CoreFlowTests {
    private func assertPanoramaStagedWire() async throws {
        let texts=["👩‍💻 s1 t1 c1 是原话，不应替换。","外部作者认为检索需要保留条件。"]
        let sources=texts.enumerated().map { index,text in
            PanoramaSource(transcript: .init(sourceID: "canonical-source-\(index)",sourceVersionID: "canonical-source-version-\(index)",transcriptVersionID: "canonical-text-\(index)",
                origin: index == 0 ? "user" : "external",speaker: index == 0 ? "user" : "external",localOnly: false,text: text,
                spans: [.init(textStart: 0,textEnd: text.unicodeScalars.count)]),title: "完整来源\(index)",occurredAt: "2026-10-23",policyVersion: 1)
        }
        let units=sources.enumerated().map { index,source in PanoramaUnit(id: "canonical-unit-\(index)",sourceIDs: [source.id],dependencyIDs: [],producerID: "fixture",completionDigest: "complete") }
        let references=sources.map { ClaimReference(sourceID: $0.id,transcriptVersionID: $0.transcript.transcriptVersionID,spanID: $0.transcript.spans[0].id) }
        let claims=[PanoramaClaim(id: "canonical-claim",statement: "s1 t1 c1 是待核对原话。",ownership: "unresolved",reviewVersion: 1,references: references)]
        let input=PanoramaInput(manifest: .init(digest: "wire-fixture",sourceIDs: sources.map(\.id),claimIDs: claims.map(\.id),unitIDs: units.map(\.id)),units: units,sources: sources,claims: claims,exclusions: [])
        let questions=sources.enumerated().map { index,source in PanoramaQuestion(id: "q\(index)",regionID: "r",title: "如何保留检索条件？",summary: texts[index],
            evidence: [.init(sourceID: source.id,transcriptVersionID: source.transcript.transcriptVersionID,start: 0,end: source.transcript.text.unicodeScalars.count,quote: source.transcript.text,claimIDs: claims.map(\.id))]) }
        let relation=PanoramaRelation(id: "e",from: "q0",to: "q1",label: "限定检索条件",explanation: "s1 t1 c1 只是原话，不改写归属",fromEvidence: questions[0].evidence,toEvidence: questions[1].evidence)
        let proposal=PanoramaProposal(regions: [.init(id: "r",title: "检索条件",summary: "保持待核对归属")],questions: questions,relations: [relation],unrepresentedSources: [],unrepresentedClaims: [])
        _ = try VoiceOSStore.validatePanorama(proposal,input: input)
        let closure=try VoiceOSStore.panoramaScope(input,sourceIDs: [sources[0].id])
        XCTAssertEqual(closure.manifest.sourceIDs,sources.map(\.id))
        XCTAssertEqual(closure.sources.map { $0.transcript.text },texts)
        let wire=try PanoramaModelInput(input)
        let report=PanoramaReview(questions: questions.map { .init(id: $0.id,accepted: true,reason: "完整原文一致") },relations: [.init(id: "e",accepted: true,reason: "双方条件对应")],coverageAccepted: true,reason: "全部指定范围一致")
        let unitOutputs=[PanoramaUnitProposal(unitID: units[1].id,
                proposal: PanoramaProposal(regions: proposal.regions,questions: [questions[1]],relations: [],unrepresentedSources: [],unrepresentedClaims: [])),
            PanoramaUnitProposal(unitID: units[0].id,
                proposal: PanoramaProposal(regions: proposal.regions,questions: [questions[0]],relations: [],unrepresentedSources: [],unrepresentedClaims: []))]
        let coverageTarget=PanoramaCoverageTarget(sourceIDs: [sources[1].id],claimIDs: claims.map(\.id))
        let independent=PanoramaScopedReview(stage: "global.coverage",scopeID: units[1].id,review: report,
            receipt: .init(responseID: "independent-fixture",model: "fixture",createdAt: "fixture"),target: coverageTarget)
        func reply<T: Encodable>(_ value: T,index: Int) throws -> ModelHTTPReply {
            let text=String(decoding: try JSONEncoder().encode(value),as: UTF8.self)
            let message: [String: Any]=["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]
            let body: [String: Any]=["id":"wire-response-\(index)","status":"completed","output":[message]]
            return .init(status: 200,body: try JSONSerialization.data(withJSONObject: body))
        }
        func compactReply(_ value: [String:Any],index: Int) throws -> ModelHTTPReply {
            let text=String(decoding: try JSONSerialization.data(withJSONObject: value),as: UTF8.self)
            let message: [String: Any]=["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]
            let body: [String: Any]=["id":"wire-response-\(index)","status":"completed","output":[message]]
            return .init(status: 200,body: try JSONSerialization.data(withJSONObject: body))
        }
        func compactSynthesisBody(questionRefs: (first:[String],second:[String]),fromRefs:[String],toRefs:[String]) -> [String:Any] {
            ["regions":[["id":"r","title":"检索条件","summary":"保持待核对归属"]],
             "questions":[["id":"gq0","regionID":"r","title":"跨单元问题一","summary":"引用第一条单元问题","evidenceRefs":questionRefs.first],
                          ["id":"gq1","regionID":"r","title":"跨单元问题二","summary":"引用第二条单元问题","evidenceRefs":questionRefs.second]],
             "relations":[["id":"ge","from":"gq0","to":"gq1","label":"限定检索条件","explanation":"引用双方单元问题","fromEvidenceRefs":fromRefs,"toEvidenceRefs":toRefs]],
             "unrepresentedSources":[],"unrepresentedClaims":[]]
        }
        let mergedBody=compactSynthesisBody(questionRefs: (first: ["q0","q0"],second: ["q1"]),fromRefs: ["q0","q0"],toRefs: ["q1"])
        let repairedBody: [String:Any]=["regions":[["id":"r","title":"检索条件","summary":"保持待核对归属"]],
            "questions":[["id":"q0","regionID":"r","title":questions[0].title,"summary":questions[0].summary,"evidenceRefs":["q0"]],
                         ["id":"q1","regionID":"r","title":questions[1].title,"summary":questions[1].summary,"evidenceRefs":["q1"]]],
            "relations":[["id":"e","from":"q0","to":"q1","label":"限定检索条件","explanation":"保留双方完整原文的否定条件","fromEvidenceRefs":["q0"],"toEvidenceRefs":["q1"]]],
            "unrepresentedSources":[],"unrepresentedClaims":[]]
        let replies=try [compactReply(mergedBody,index: 1),compactReply(repairedBody,index: 2),reply(report,index: 3),reply(report,index: 4),reply(report,index: 5)]
        let transport=PanoramaWireTransport(replies)
        let port=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!,apiKey: "fixture",model: "fixture",transport: transport)
        let merged=try await port.synthesize(unitOutputs,input: input)
        XCTAssertEqual(merged.0.questions[0].summary,"引用第一条单元问题")
        func evidenceKeys(_ values: [PanoramaEvidence]) -> [String] {
            values.map { "\($0.sourceID)|\($0.transcriptVersionID)|\($0.start)|\($0.end)|\($0.quote)|\($0.claimIDs.joined(separator: ","))" }
        }
        XCTAssertEqual(evidenceKeys(merged.0.questions[0].evidence),evidenceKeys(questions[0].evidence))
        XCTAssertEqual(merged.0.questions[0].evidence.count,1)
        XCTAssertEqual(evidenceKeys(merged.0.questions[1].evidence),evidenceKeys(questions[1].evidence))
        let mergedRelation=try XCTUnwrap(merged.0.relations.first)
        XCTAssertEqual(evidenceKeys(mergedRelation.fromEvidence),evidenceKeys(questions[0].evidence))
        XCTAssertEqual(evidenceKeys(mergedRelation.toEvidence),evidenceKeys(questions[1].evidence))
        _ = try VoiceOSStore.validatePanorama(merged.0,input: input)
        let rejection=PanoramaRejection(proposal: proposal,review: report)
        let repaired=try await port.repairSynthesis(proposal,input: input,context: closure,rejection: rejection)
        XCTAssertEqual(evidenceKeys(repaired.0.questions.flatMap { $0.evidence }),evidenceKeys(proposal.questions.flatMap { $0.evidence }))
        let repairedRelation=try XCTUnwrap(repaired.0.relations.first)
        XCTAssertEqual(evidenceKeys(repairedRelation.fromEvidence),evidenceKeys(proposal.questions[0].evidence))
        _ = try VoiceOSStore.validatePanorama(repaired.0,input: input)
        _ = try await port.verifyEvidence(proposal,input: closure)
        _ = try await port.verifyCoverage(proposal,input: closure,target: coverageTarget,rejections: [rejection])
        _ = try await port.verifyConsistency(proposal,input: input,unitProposals: unitOutputs,reviews: [independent],rejections: [rejection])
        let requests=await transport.requests
        XCTAssertEqual(requests.count,5)
        func content(_ data: Data) throws -> [String: Any] {
            let body=try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages=try XCTUnwrap(body["input"] as? [[String: Any]])
            let text=try XCTUnwrap(messages.first?["content"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let mergeRequest=try content(requests[0])
        let index=try XCTUnwrap(mergeRequest["index"] as? [String: Any])
        let indexSources=try XCTUnwrap(index["sources"] as? [[String: Any]])
        XCTAssertEqual(indexSources.count,2)
        XCTAssertTrue(indexSources.allSatisfy { $0["text"] == nil })
        XCTAssertEqual(indexSources.compactMap { $0["origin"] as? String },["user","external"])
        let referenceEvidence=try XCTUnwrap(index["referenceEvidence"] as? [[String: Any]])
        XCTAssertEqual(referenceEvidence.compactMap { $0["quote"] as? String },texts)
        let sentOutputs=try XCTUnwrap(mergeRequest["unitProposals"] as? [[String: Any]])
        XCTAssertEqual(sentOutputs.compactMap { $0["unitID"] as? String },["u2","u1"])
        for requestIndex in 1...3 {
            let request=try content(requests[requestIndex])
            let context=try XCTUnwrap(request[requestIndex == 1 ? "context" : "input"] as? [String: Any])
            let fullSources=try XCTUnwrap(context["sources"] as? [[String: Any]])
            XCTAssertEqual(fullSources.compactMap { $0["text"] as? String },texts)
        }
        let coverage=try content(requests[3]), target=try XCTUnwrap(coverage["target"] as? [String: Any])
        XCTAssertEqual(target["sourceIDs"] as? [String],["s2"])
        XCTAssertEqual(target["claimIDs"] as? [String],["c1"])
        let consistency=try content(requests[4])
        let sentReviews=try XCTUnwrap(consistency["independentReviews"] as? [[String: Any]])
        XCTAssertEqual(sentReviews.first?["scopeID"] as? String,"u2")
        let sentTarget=try XCTUnwrap(sentReviews.first?["target"] as? [String: Any])
        XCTAssertEqual(sentTarget["sourceIDs"] as? [String],["s2"])
        XCTAssertEqual(sentTarget["claimIDs"] as? [String],["c1"])
        let mergeBody=try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0]) as? [String:Any])
        let mergeText=try XCTUnwrap(mergeBody["text"] as? [String:Any])
        let mergeFormat=try XCTUnwrap(mergeText["format"] as? [String:Any])
        XCTAssertEqual(mergeFormat["name"] as? String,"voiceos_panorama_merge_refs")
        let mergeSchema=try XCTUnwrap(mergeFormat["schema"] as? [String:Any])
        let mergeProperties=try XCTUnwrap(mergeSchema["properties"] as? [String:Any])
        let mergeQuestionItem=try XCTUnwrap((mergeProperties["questions"] as? [String:Any])?["items"] as? [String:Any])
        let mergeQuestionProperties=try XCTUnwrap(mergeQuestionItem["properties"] as? [String:Any])
        XCTAssertNotNil(mergeQuestionProperties["evidenceRefs"])
        XCTAssertNil(mergeQuestionProperties["evidence"])
        let mergeRelationItem=try XCTUnwrap((mergeProperties["relations"] as? [String:Any])?["items"] as? [String:Any])
        let mergeRelationProperties=try XCTUnwrap(mergeRelationItem["properties"] as? [String:Any])
        XCTAssertNotNil(mergeRelationProperties["fromEvidenceRefs"])
        XCTAssertNotNil(mergeRelationProperties["toEvidenceRefs"])
        let repairBody=try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1]) as? [String:Any])
        let repairText=try XCTUnwrap(repairBody["text"] as? [String:Any])
        let repairFormat=try XCTUnwrap(repairText["format"] as? [String:Any])
        XCTAssertEqual(repairFormat["name"] as? String,"voiceos_panorama_global_repair_refs")
        XCTAssertEqual(try wire.pendingFromModel([.init(id:"s2",reason:"未归入")],claim:false).first?.id,sources[1].id)
        XCTAssertEqual(try wire.pendingFromModel([.init(id:"c1",reason:"未归入")],claim:true).first?.id,claims[0].id)
        func expectReferenceFailure(_ body: [String:Any]) async throws {
            let transport=PanoramaWireTransport([try compactReply(body,index: 9)])
            let port=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!,apiKey: "fixture",model: "fixture",transport: transport)
            do { _ = try await port.synthesize(unitOutputs,input: input); XCTFail("无效综合引用必须可重试失败") }
            catch is PanoramaSynthesisReferenceFailure {}
        }
        try await expectReferenceFailure(compactSynthesisBody(questionRefs: (first: ["q-missing"],second: ["q1"]),fromRefs: ["q0"],toRefs: ["q1"]))
        try await expectReferenceFailure(compactSynthesisBody(questionRefs: (first: ["q0"],second: ["q1"]),fromRefs: ["q1"],toRefs: ["q1"]))
        try await expectReferenceFailure(compactSynthesisBody(questionRefs: (first: [],second: ["q1"]),fromRefs: ["q0"],toRefs: ["q1"]))
    }
}


extension CoreFlowTests {
    func assertPanoramaTitleChangeContinues(root: URL) async throws {
        let store=try await panoramaFixtureStore(root.appendingPathComponent("title-change"), count: 2)
        let input=try await store.panoramaInput(), sourceID=try XCTUnwrap(input.sources.first?.id)
        let port=ProgressivePanoramaFixture(beforeGenerate: { _ in
            try await store.renameRecording(sourceID: sourceID, title: "更名后的检索材料")
        })
        try await store.generatePanorama(using: port)
        let completed=try await store.panoramaState()
        XCTAssertEqual(completed.status,"completed")
        XCTAssertNotNil(completed.snapshot)
        try await store.renameRecording(sourceID: sourceID, title: "完成后再更名")
        let visible=try await store.panoramaState()
        XCTAssertEqual(visible.status,"completed")
        XCTAssertNotNil(visible.snapshot)
    }
}


extension CoreFlowTests {
    func assertPanoramaQuoteRetry(root: URL) async throws {
        let store=try await panoramaFixtureStore(root.appendingPathComponent("quote-retry"), count: 1)
        let port=ProgressivePanoramaFixture(invalidQuoteAttempts: 1)
        try await store.generatePanorama(using: port)
        let generations=await port.generations
        XCTAssertEqual(generations,2)
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"completed")
        XCTAssertNotNil(state.snapshot)
    }
}

extension CoreFlowTests {
    func assertPanoramaSlicedGeneration(root: URL) async throws {
        try assertPanoramaSlicingPlanAndMerge()
        try await assertPanoramaFocusedGeneration(root: root.appendingPathComponent("focused-generation"))
        try await assertPanoramaFocusViolationRetry(root: root.appendingPathComponent("focused-violation"))
        try await assertPanoramaSliceFailureReuse(root: root.appendingPathComponent("focused-failure"))
        try await assertPanoramaLegacyGenerationReplay(root: root.appendingPathComponent("focused-legacy"))
        try await assertPanoramaSlicedRepair(root: root.appendingPathComponent("focused-repair"))
        try await assertPanoramaSameAttemptReuse(root: root.appendingPathComponent("focused-same-attempt"))
        try await assertPanoramaSlicedRepairScope(root: root.appendingPathComponent("focused-repair-scope"))
        try await assertPanoramaFocusedWire()
        print("Panorama sliced generation planned, merged, reused failed slices, replayed legacy and same-attempt rows, and repaired only rejected slices")
    }

    private func slicingSource(_ id: String, text: String, spanSize: Int) -> PanoramaSource {
        var spans: [TranscriptSpan]=[], start=0
        let count=text.unicodeScalars.count
        while start < count {
            let end=min(count, start+spanSize)
            spans.append(.init(textStart: start, textEnd: end))
            start=end
        }
        return PanoramaSource(transcript: .init(sourceID: id, sourceVersionID: id+"-version", transcriptVersionID: id+"-text",
            origin: "user", speaker: "user", localOnly: false, text: text, spans: spans), title: id, occurredAt: "2026-11-01", policyVersion: 1)
    }

    private func slicingInput(_ sources: [PanoramaSource], claims: [PanoramaClaim]=[], unitID: String) -> PanoramaInput {
        let unit=PanoramaUnit(id: unitID, sourceIDs: [sources[0].id], dependencyIDs: sources.dropFirst().map(\.id),
            producerID: "fixture", completionDigest: "complete")
        return PanoramaInput(manifest: .init(digest: "slicing-fixture", sourceIDs: sources.map(\.id), claimIDs: claims.map(\.id), unitIDs: [unitID]),
            units: [unit], sources: sources, claims: claims, exclusions: [])
    }

    private func assertPanoramaSlicingPlanAndMerge() throws {
        let policy=PanoramaUnitSlicePolicy.current
        XCTAssertEqual(policy.version,"panorama-unit-slices-v1")
        XCTAssertEqual(policy.unitScalarThreshold,16_000)
        XCTAssertEqual(policy.focusScalarBudget,8_000)

        let main=slicingSource("a-main",text: String(repeating: "字",count: 26_868),spanSize: 1_000)
        let dependencyText=String(repeating: "依赖",count: 16)
        let dependency=slicingSource("b-dep",text: dependencyText,spanSize: dependencyText.unicodeScalars.count)
        let claimMain=PanoramaClaim(id: "claim-main",statement: "检索条件需要保留。",ownership: "unresolved",reviewVersion: 1,
            references: [.init(sourceID: main.id,transcriptVersionID: main.transcript.transcriptVersionID,spanID: main.transcript.spans[0].id)])
        let claimDependency=PanoramaClaim(id: "claim-dependency",statement: "依赖来源仍需完整阅读。",ownership: "unresolved",reviewVersion: 1,
            references: [.init(sourceID: dependency.id,transcriptVersionID: dependency.transcript.transcriptVersionID,spanID: dependency.transcript.spans[0].id)])
        let input=slicingInput([main,dependency],claims: [claimMain,claimDependency],unitID: "big-unit")
        let plan=try XCTUnwrap(try PanoramaUnitSlicePlan.make(unitID: "big-unit",input: input))
        XCTAssertEqual(plan.slices.count,4)
        XCTAssertEqual(plan.slices.map { $0.focus.ranges.reduce(0) { $0+$1.end-$1.start } },[8_000,8_000,8_000,2_900])
        XCTAssertEqual(plan.slices.map(\.focus.ordinal),[1,2,3,4])
        XCTAssertEqual(plan.slices.map(\.focus.count),[4,4,4,4])
        XCTAssertEqual(plan.slices.last?.focus.ranges.last?.sourceID,dependency.id)
        XCTAssertTrue(plan.slices[0].target.claimIDs.contains(claimMain.id))
        XCTAssertFalse(plan.slices[0].target.claimIDs.contains(claimDependency.id))
        XCTAssertTrue(plan.slices[3].target.claimIDs.contains(claimDependency.id))
        XCTAssertFalse(plan.slices[3].target.claimIDs.contains(claimMain.id))
        XCTAssertTrue(plan.slices[1].target.claimIDs.isEmpty)
        let spanEnds=Set(main.transcript.spans.map(\.textEnd))
        for range in plan.slices.flatMap(\.focus.ranges) where range.sourceID == main.id {
            XCTAssertTrue(range.start == 0 || spanEnds.contains(range.start))
            XCTAssertTrue(spanEnds.contains(range.end))
        }
        let again=try XCTUnwrap(try PanoramaUnitSlicePlan.make(unitID: "big-unit",input: input))
        XCTAssertEqual(again.digest,plan.digest)
        XCTAssertEqual(again.slices.map(\.focus),plan.slices.map(\.focus))

        let smallInput=slicingInput([slicingSource("small",text: String(repeating: "字",count: 7_184),spanSize: 1_000)],unitID: "small-unit")
        XCTAssertNil(try PanoramaUnitSlicePlan.make(unitID: "small-unit",input: smallInput))

        let emoji=slicingSource("emoji",text: String(repeating: "👩‍💻",count: 10_000),spanSize: 30_000)
        let emojiPlan=try XCTUnwrap(try PanoramaUnitSlicePlan.make(unitID: "emoji-unit",input: slicingInput([emoji],unitID: "emoji-unit")))
        let emojiRanges=emojiPlan.slices.flatMap(\.focus.ranges)
        XCTAssertEqual(emojiRanges.map { $0.end-$0.start },[7_998,7_998,7_998,6_006])
        XCTAssertEqual(emojiRanges.first?.start,0)
        XCTAssertEqual(emojiRanges.last?.end,30_000)
        for range in emojiRanges {
            let index=emoji.transcript.text.unicodeScalars.index(emoji.transcript.text.startIndex,offsetBy: range.end)
            // `indices` is half-open, so a cut at the end of the text is safe but not contained.
            XCTAssertTrue(index == emoji.transcript.text.endIndex || emoji.transcript.text.indices.contains(index))
        }

        func overlappingClaimIDs(_ range: PanoramaFocusRange) -> [String] {
            let spans = range.sourceID == main.id ? main.transcript.spans : dependency.transcript.spans
            return input.claims.filter { claim in
                claim.references.contains { ref in
                    ref.sourceID == range.sourceID && ref.transcriptVersionID == range.transcriptVersionID &&
                    spans.contains { $0.id == ref.spanID && $0.textEnd > range.start && $0.textStart < range.end }
                }
            }.map(\.id)
        }
        func sliceEvidence(_ range: PanoramaFocusRange) -> PanoramaEvidence {
            let source = range.sourceID == main.id ? main : dependency
            let text=Array(source.transcript.text.unicodeScalars)
            return .init(sourceID: range.sourceID,transcriptVersionID: range.transcriptVersionID,start: range.start,end: range.end,
                quote: String(String.UnicodeScalarView(text[range.start..<range.end])),claimIDs: overlappingClaimIDs(range))
        }
        var proposals: [PanoramaProposal]=[]
        for (index, slice) in plan.slices.enumerated() {
            var ranges=slice.focus.ranges
            var sources: [PanoramaUnrepresented]=[], claims: [PanoramaUnrepresented]=[]
            if index == 3 {
                ranges=ranges.filter { $0.sourceID == main.id }
                sources=[.init(id: dependency.id,reason: "依赖只在上下文中出现")]
                claims=[.init(id: claimDependency.id,reason: "观点只作上下文")]
            }
            let questions=ranges.enumerated().map { offset, range in
                PanoramaQuestion(id: "q\(offset)",regionID: "r",title: "如何保留检索条件？",summary: "完整材料的条件核对",evidence: [sliceEvidence(range)])
            }
            proposals.append(.init(regions: [.init(id: "r",title: "检索条件",summary: "完整材料的条件核对")],
                questions: questions,relations: [],unrepresentedSources: sources,unrepresentedClaims: claims))
        }
        let merged=try plan.merge(proposals)
        XCTAssertEqual(Set(merged.regions.map(\.id)).count,merged.regions.count)
        XCTAssertTrue(merged.regions.allSatisfy { $0.id.hasPrefix("part[") })
        XCTAssertEqual(merged.questions.map(\.id),["part[1]/q0","part[2]/q0","part[3]/q0","part[4]/q0"])
        XCTAssertEqual(merged.unrepresentedSources.map(\.id),[dependency.id])
        XCTAssertEqual(merged.unrepresentedSources.first?.reason,"依赖只在上下文中出现")
        XCTAssertEqual(merged.unrepresentedClaims.map(\.id),[claimDependency.id])
        XCTAssertEqual(merged.unrepresentedClaims.first?.reason,"观点只作上下文")
        _ = try VoiceOSStore.validatePanorama(merged,input: input)

        let duplicate=sliceEvidence(plan.slices[0].focus.ranges[0])
        var withOverlap=proposals
        withOverlap[1] = .init(regions: [.init(id: "r-overlap",title: "重叠证据",summary: "重叠证据仍可合并")],
            questions: [.init(id: "q0",regionID: "r-overlap",title: "重叠证据",summary: "重叠证据仍可合并",
                evidence: [duplicate,duplicate])],relations: [],unrepresentedSources: [],unrepresentedClaims: [])
        let mergedOverlap=try plan.merge(withOverlap)
        XCTAssertEqual(mergedOverlap.questions.first { $0.id == "part[2]/q0" }?.evidence.count,2)

        var prefixed=proposals
        prefixed[0] = .init(regions: proposals[0].regions.map { .init(id: "part[1]/"+$0.id,title: $0.title,summary: $0.summary) },
            questions: proposals[0].questions.map { .init(id: "part[1]/"+$0.id,regionID: "part[1]/"+$0.regionID,title: $0.title,
                summary: $0.summary,evidence: $0.evidence) },relations: [],unrepresentedSources: [],unrepresentedClaims: [])
        XCTAssertEqual(try plan.merge(prefixed).regions.first?.id,"part[1]/r")
    }

    private func assertPanoramaFocusedGeneration(root: URL) async throws {
        let long=String(repeating: "长文",count: 9_000), small="短材料，保留完整检索条件。"
        let store=try await panoramaFixtureStore(root,texts: [small,long])
        let port=ProgressivePanoramaFixture(identity: "focused-fixture")
        try await store.generatePanorama(using: port)
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"completed")
        let snapshot=try XCTUnwrap(state.snapshot)
        XCTAssertEqual(snapshot.workflow?.verifiedUnitIDs.count,2)
        let calls=await port.focusCalls, targets=await port.focusTargets, generations=await port.generations
        XCTAssertEqual(calls.count,3)
        XCTAssertEqual(calls.map(\.ordinal),[1,2,3])
        XCTAssertEqual(Set(calls.map(\.count)),Set([3]))
        XCTAssertEqual(generations,1)
        XCTAssertTrue(targets.allSatisfy { !$0.sourceIDs.isEmpty })
        let source=try XCTUnwrap(snapshot.input.sources.first { $0.transcript.text == long })
        let unit=try XCTUnwrap(snapshot.input.units.first { $0.sourceIDs.contains(source.id) })
        let database=try Database(root.appendingPathComponent("voiceos.sqlite"))
        let slices=try database.query("SELECT state,scope_id FROM panorama_steps WHERE stage='unit.focus.generate' ORDER BY rowid")
        XCTAssertEqual(slices.compactMap { $0["state"] },["completed","completed","completed"])
        XCTAssertEqual(slices.compactMap { $0["scope_id"] },(1...3).map { "\(unit.id)#slice-\($0)" })
        let row=try XCTUnwrap(database.query("SELECT input_json,result_json,receipt_json FROM panorama_steps WHERE stage='unit.generate' AND scope_id=?",[unit.id]).first)
        let record=try PanoramaUnitGenerationRecord.decode(Data(try XCTUnwrap(row["input_json"]).utf8))
        guard case .sliced(let sliced)=record else { return XCTFail("超大单元应写入自描述分片记录") }
        XCTAssertEqual(sliced.policy.version,"panorama-unit-slices-v1")
        let receipt=try JSONDecoder().decode(PanoramaReceipt.self,from:Data(try XCTUnwrap(row["receipt_json"]).utf8))
        XCTAssertTrue(receipt.responseID.hasPrefix("panorama-slices-v1:generate:"))
        XCTAssertEqual(receipt.sourceResponseIDs?.count,3)
        XCTAssertEqual(receipt.generationIdentity,"focused-fixture|unit-slices-v1")
        let merged=try JSONDecoder().decode(PanoramaProposal.self,from:Data(try XCTUnwrap(row["result_json"]).utf8))
        XCTAssertTrue(merged.regions.allSatisfy { $0.id.hasPrefix("part[") })
        let workflowReceipt=snapshot.workflow?.receipts.first { $0.stage == "unit.generate" && $0.scopeID == unit.id }
        XCTAssertEqual(workflowReceipt?.receipt.responseID,receipt.responseID)
    }

    private func assertPanoramaFocusViolationRetry(root: URL) async throws {
        let store=try await panoramaFixtureStore(root,texts: [String(repeating: "长文",count: 9_000)])
        let port=ProgressivePanoramaFixture(identity: "focus-violation-fixture",invalidFocusAttempts: 1)
        try await store.generatePanorama(using: port)
        let state=try await store.panoramaState(), calls=await port.focusCalls
        XCTAssertEqual(state.status,"completed")
        XCTAssertEqual(calls.count,4)
        XCTAssertEqual(calls.filter { $0.ordinal == 1 }.count,2)
        let database=try Database(root.appendingPathComponent("voiceos.sqlite"))
        let rows=try database.query("SELECT state FROM panorama_steps WHERE stage='unit.focus.generate' AND scope_id LIKE '%#slice-1' ORDER BY rowid")
        XCTAssertEqual(rows.compactMap { $0["state"] },["failed","completed"])
    }

    private func assertPanoramaSliceFailureReuse(root: URL) async throws {
        let store=try await panoramaFixtureStore(root,texts: [String(repeating: "长文",count: 9_000)])
        let port=ProgressivePanoramaFixture(identity: "focus-failure-fixture",failFocusAt: 2)
        do { try await store.generatePanorama(using: port); XCTFail("聚焦分片失败应让该单元失败") }
        catch let failure as PanoramaUnitFailures {
            XCTAssertEqual(failure.unitIDs.count,1)
            XCTAssertFalse(failure.errorDescription?.contains("#slice") == true)
        }
        let first=try await store.panoramaState()
        XCTAssertEqual(first.status,"failed")
        XCTAssertFalse(first.error?.contains("#slice") == true)
        let current=try await store.panoramaInput()
        let unitID=try XCTUnwrap(current.units.first?.id)
        let database=try Database(root.appendingPathComponent("voiceos.sqlite"))
        var rows=try database.query("SELECT state FROM panorama_steps WHERE stage='unit.focus.generate' ORDER BY rowid")
        XCTAssertEqual(rows.compactMap { $0["state"] },["completed","failed"])
        let firstOrdinals=await port.focusCalls.map(\.ordinal)
        XCTAssertEqual(firstOrdinals,[1,2])
        try await store.generatePanorama(using: port,retry: true)
        let resumed=try await store.panoramaState()
        XCTAssertEqual(resumed.status,"completed")
        let resumedOrdinals=await port.focusCalls.map(\.ordinal)
        XCTAssertEqual(resumedOrdinals,[1,2,2,3])
        rows=try database.query("SELECT state FROM panorama_steps WHERE stage='unit.focus.generate' ORDER BY rowid")
        XCTAssertEqual(rows.compactMap { $0["state"] },["completed","failed","completed","completed"])
        let sliceTwo=try database.query("SELECT state FROM panorama_steps WHERE stage='unit.focus.generate' AND scope_id=? ORDER BY rowid",["\(unitID)#slice-2"])
        XCTAssertEqual(sliceTwo.compactMap { $0["state"] },["failed","completed"])
    }

    private func assertPanoramaLegacyGenerationReplay(root: URL) async throws {
        let store=try await panoramaFixtureStore(root,texts: [String(repeating: "长文",count: 9_000)])
        let whole=try await store.panoramaInput()
        let unit=try XCTUnwrap(whole.units.first)
        let scoped=try VoiceOSStore.panoramaScope(whole,sourceIDs: Set(unit.sourceIDs+unit.dependencyIDs))
        let source=try XCTUnwrap(scoped.sources.first)
        let proposal=PanoramaProposal(regions: [.init(id: "r",title: "检索条件",summary: "完整材料的条件核对")],
            questions: [.init(id: "q",regionID: "r",title: "如何保留检索条件？",summary: "完整材料",
                evidence: [.init(sourceID: source.id,transcriptVersionID: source.transcript.transcriptVersionID,start: 0,
                    end: source.transcript.text.unicodeScalars.count,quote: source.transcript.text,claimIDs: [])])],
            relations: [],
            unrepresentedSources: scoped.manifest.sourceIDs.filter { $0 != source.id }.map { .init(id: $0,reason: "本轮未归入具体问题") },
            unrepresentedClaims: [])
        let review=PanoramaReview(questions: [.init(id: "q",accepted: true,reason: "完整原话一致")],relations: [],
            coverageAccepted: true,reason: "本次指定范围全部核对")
        let generation=PanoramaReceipt(responseID: "legacy-raw-response",model: "progressive-fixture",createdAt: "2026-10-23T00:00:00Z")
        let verification=PanoramaReceipt(responseID: "legacy-review-response",model: "progressive-fixture",createdAt: "2026-10-23T00:00:00Z")
        let attempt="legacy-attempt-"+UUID().uuidString
        let database=try Database(root.appendingPathComponent("voiceos.sqlite"))
        try database.execute("INSERT INTO panorama_attempts(id,digest,state,input_json,created_at) VALUES(?,?,'completed','{}','fixture')",[attempt,"legacy-fixture-digest"])
        func insertStep(_ stage: String, _ input: String, _ result: String, _ receipt: String) throws {
            let digest=VoiceOSStore.relevanceHash(Data(("panorama-staged-v1|progressive-fixture|"+input).utf8))
            try database.execute("INSERT INTO panorama_steps(id,attempt_id,stage,scope_id,input_digest,state,input_json,result_json,receipt_json,created_at,finished_at) VALUES(?,?,?,?,?,'completed',?,?,?,'fixture','fixture')",
                [UUID().uuidString,attempt,stage,unit.id,digest,input,result,receipt])
        }
        try insertStep("unit.generate",VoiceOSStore.relevanceJSON(scoped),VoiceOSStore.relevanceJSON(proposal),VoiceOSStore.relevanceJSON(generation))
        try insertStep("unit.review",VoiceOSStore.relevanceJSON(PanoramaProposalInput(input: scoped,proposal: proposal)),
            VoiceOSStore.relevanceJSON(review),VoiceOSStore.relevanceJSON(verification))
        let port=ProgressivePanoramaFixture(identity: "progressive-fixture")
        try await store.generatePanorama(using: port)
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"completed")
        let snapshot=try XCTUnwrap(state.snapshot)
        let reused=snapshot.workflow?.receipts.first { $0.stage == "unit.generate" && $0.scopeID == unit.id }
        XCTAssertEqual(reused?.receipt.responseID,"legacy-raw-response")
        let focusCalls=await port.focusCalls, generations=await port.generations
        XCTAssertTrue(focusCalls.isEmpty)
        XCTAssertEqual(generations,0)
    }

    private func assertPanoramaSlicedRepair(root: URL) async throws {
        let store=try await panoramaFixtureStore(root,texts: [String(repeating: "长文",count: 9_000)])
        let port=ProgressivePanoramaFixture(identity: "sliced-repair-fixture",repairUnits: true)
        try await store.generatePanorama(using: port)
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"completed")
        let repairs=await port.unitRepairs, reviews=await port.unitReviews
        XCTAssertEqual(repairs,3)
        XCTAssertEqual(reviews,2)
        let unit=try XCTUnwrap(state.snapshot?.input.units.first)
        let database=try Database(root.appendingPathComponent("voiceos.sqlite"))
        let row=try XCTUnwrap(database.query("SELECT input_json,receipt_json FROM panorama_steps WHERE stage='unit.repair' AND scope_id=?",[unit.id]).first)
        let record=try JSONDecoder().decode(PanoramaSlicedRepairRecord.self,from:Data(try XCTUnwrap(row["input_json"]).utf8))
        XCTAssertEqual(record.kind,"panorama-unit-slices-v1")
        let receipt=try JSONDecoder().decode(PanoramaReceipt.self,from:Data(try XCTUnwrap(row["receipt_json"]).utf8))
        XCTAssertTrue(receipt.responseID.hasPrefix("panorama-slices-v1:repair:"))
        XCTAssertEqual(receipt.sourceResponseIDs?.count,3)
        let slices=try database.query("SELECT state FROM panorama_steps WHERE stage='unit.focus.repair' ORDER BY rowid")
        XCTAssertEqual(slices.compactMap { $0["state"] },["completed","completed","completed"])
        XCTAssertFalse(try database.query("SELECT id FROM panorama_steps WHERE stage='unit.review-repair'").isEmpty)
    }

    private func assertPanoramaSameAttemptReuse(root: URL) async throws {
        let store=try await panoramaFixtureStore(root,texts: [String(repeating: "长文",count: 9_000)])
        let failing=ProgressivePanoramaFixture(identity: "progressive-fixture",failFocusAt: 1)
        do { try await store.generatePanorama(using: failing); XCTFail("聚焦分片失败应暂停") } catch {}
        let failed=try await store.panoramaState()
        XCTAssertEqual(failed.status,"failed")
        let database=try Database(root.appendingPathComponent("voiceos.sqlite"))
        let attempt=try XCTUnwrap(database.query("SELECT id FROM panorama_attempts WHERE state='failed' ORDER BY rowid DESC LIMIT 1").first?["id"])
        let whole=try await store.panoramaInput(), unit=try XCTUnwrap(whole.units.first)
        let scoped=try VoiceOSStore.panoramaScope(whole,sourceIDs: Set(unit.sourceIDs+unit.dependencyIDs))
        let source=try XCTUnwrap(scoped.sources.first)
        let proposal=PanoramaProposal(regions: [.init(id: "r",title: "检索条件",summary: "完整材料的条件核对")],
            questions: [.init(id: "q",regionID: "r",title: "如何保留检索条件？",summary: "完整材料",
                evidence: [.init(sourceID: source.id,transcriptVersionID: source.transcript.transcriptVersionID,start: 0,
                    end: source.transcript.text.unicodeScalars.count,quote: source.transcript.text,claimIDs: [])])],
            relations: [],
            unrepresentedSources: scoped.manifest.sourceIDs.filter { $0 != source.id }.map { .init(id: $0,reason: "本轮未归入具体问题") },
            unrepresentedClaims: [])
        let review=PanoramaReview(questions: [.init(id: "q",accepted: true,reason: "完整原话一致")],relations: [],
            coverageAccepted: true,reason: "本次指定范围全部核对")
        let generation=PanoramaReceipt(responseID: "same-attempt-generation-response",model: "progressive-fixture",createdAt: "2026-10-23T00:00:00Z")
        let verification=PanoramaReceipt(responseID: "same-attempt-review-response",model: "progressive-fixture",createdAt: "2026-10-23T00:00:00Z")
        func insertStep(_ stage: String, _ input: String, _ result: String, _ receipt: String) throws {
            let digest=VoiceOSStore.relevanceHash(Data(("panorama-staged-v1|progressive-fixture|"+input).utf8))
            try database.execute("INSERT INTO panorama_steps(id,attempt_id,stage,scope_id,input_digest,state,input_json,result_json,receipt_json,created_at,finished_at) VALUES(?,?,?,?,?,'completed',?,?,?,'fixture','fixture')",
                [UUID().uuidString,attempt,stage,unit.id,digest,input,result,receipt])
        }
        try insertStep("unit.generate",VoiceOSStore.relevanceJSON(scoped),VoiceOSStore.relevanceJSON(proposal),VoiceOSStore.relevanceJSON(generation))
        try insertStep("unit.review",VoiceOSStore.relevanceJSON(PanoramaProposalInput(input: scoped,proposal: proposal)),
            VoiceOSStore.relevanceJSON(review),VoiceOSStore.relevanceJSON(verification))
        let port=ProgressivePanoramaFixture(identity: "progressive-fixture")
        try await store.generatePanorama(using: port,retry: true)
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"completed")
        let snapshot=try XCTUnwrap(state.snapshot)
        let reused=snapshot.workflow?.receipts.first { $0.stage == "unit.generate" && $0.scopeID == unit.id }
        XCTAssertEqual(reused?.receipt.responseID,"same-attempt-generation-response")
        let reviewed=snapshot.workflow?.receipts.first { $0.stage == "unit.verify" && $0.scopeID == unit.id }
        XCTAssertEqual(reviewed?.receipt.responseID,"same-attempt-review-response")
        let focusCalls=await port.focusCalls, generations=await port.generations
        XCTAssertTrue(focusCalls.isEmpty)
        XCTAssertEqual(generations,0)
    }

    private func assertPanoramaSlicedRepairScope(root: URL) async throws {
        let long=String(repeating: "长文",count: 9_000)
        let store=try await panoramaFixtureStore(root,texts: [long])
        let port=ProgressivePanoramaFixture(identity: "slice-repair-scope-fixture",rejectedDecisionSubstring: "part[2]/")
        try await store.generatePanorama(using: port)
        let state=try await store.panoramaState()
        XCTAssertEqual(state.status,"completed")
        let repairs=await port.unitRepairs, reviews=await port.unitReviews
        XCTAssertEqual(repairs,1)
        XCTAssertEqual(reviews,2)
        let unit=try XCTUnwrap(state.snapshot?.input.units.first)
        let database=try Database(root.appendingPathComponent("voiceos.sqlite"))
        let slices=try database.query("SELECT scope_id FROM panorama_steps WHERE stage='unit.focus.repair' ORDER BY rowid")
        XCTAssertEqual(slices.compactMap { $0["scope_id"] },["\(unit.id)#slice-2"])
        let row=try XCTUnwrap(database.query("SELECT receipt_json FROM panorama_steps WHERE stage='unit.repair' AND scope_id=?",[unit.id]).first)
        let receipt=try JSONDecoder().decode(PanoramaReceipt.self,from: Data(try XCTUnwrap(row["receipt_json"]).utf8))
        XCTAssertEqual(receipt.sourceResponseIDs?.count,1)
        XCTAssertEqual(try database.query("SELECT id FROM panorama_steps WHERE stage='unit.review-repair'").count,1)

        let coverageRoot=root.appendingPathComponent("coverage-only")
        let coverageStore=try await panoramaFixtureStore(coverageRoot,texts: [long])
        let coveragePort=ProgressivePanoramaFixture(identity: "slice-repair-coverage-fixture",rejectCoverageOnly: true)
        try await coverageStore.generatePanorama(using: coveragePort)
        let coverageState=try await coverageStore.panoramaState()
        XCTAssertEqual(coverageState.status,"completed")
        let coverageRepairs=await coveragePort.unitRepairs
        XCTAssertEqual(coverageRepairs,3)
        let coverageUnit=try XCTUnwrap(coverageState.snapshot?.input.units.first)
        let coverageDatabase=try Database(coverageRoot.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try coverageDatabase.query("SELECT id FROM panorama_steps WHERE stage='unit.focus.repair'").count,3)
        let coverageRow=try XCTUnwrap(coverageDatabase.query("SELECT receipt_json FROM panorama_steps WHERE stage='unit.repair' AND scope_id=?",[coverageUnit.id]).first)
        let coverageReceipt=try JSONDecoder().decode(PanoramaReceipt.self,from: Data(try XCTUnwrap(coverageRow["receipt_json"]).utf8))
        XCTAssertEqual(coverageReceipt.sourceResponseIDs?.count,3)
    }

    private func assertPanoramaFocusedWire() async throws {
        let texts=["聚焦分片仍须读取完整原文。","另一来源只作上下文。"]
        let sources=texts.enumerated().map { index, text in
            PanoramaSource(transcript: .init(sourceID: "canonical-source-\(index)",sourceVersionID: "canonical-source-version-\(index)",
                transcriptVersionID: "canonical-text-\(index)",origin: "user",speaker: "user",localOnly: false,text: text,
                spans: [.init(textStart: 0,textEnd: text.unicodeScalars.count)]),title: "完整来源\(index)",occurredAt: "2026-11-01",policyVersion: 1)
        }
        let unit=PanoramaUnit(id: "canonical-unit",sourceIDs: [sources[0].id],dependencyIDs: [sources[1].id],producerID: "fixture",completionDigest: "complete")
        let claim=PanoramaClaim(id: "canonical-claim",statement: "聚焦分片需要完整上下文。",ownership: "unresolved",reviewVersion: 1,
            references: [.init(sourceID: sources[0].id,transcriptVersionID: sources[0].transcript.transcriptVersionID,spanID: sources[0].transcript.spans[0].id)])
        let input=PanoramaInput(manifest: .init(digest: "focus-wire",sourceIDs: sources.map(\.id),claimIDs: [claim.id],unitIDs: [unit.id]),
            units: [unit],sources: sources,claims: [claim],exclusions: [])
        let focus=PanoramaGenerationFocus(unitID: unit.id,ordinal: 1,count: 1,ranges: [
            .init(sourceID: sources[0].id,transcriptVersionID: sources[0].transcript.transcriptVersionID,start: 0,
                  end: sources[0].transcript.text.unicodeScalars.count)])
        let target=PanoramaCoverageTarget(sourceIDs: [sources[0].id],claimIDs: [claim.id])
        let proposal=PanoramaProposal(regions: [],questions: [],relations: [],unrepresentedSources: [],unrepresentedClaims: [])
        let replyText=String(decoding: try JSONEncoder().encode(proposal),as: UTF8.self)
        let message: [String:Any]=["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":replyText]]]
        let reply=ModelHTTPReply(status: 200,body: try JSONSerialization.data(withJSONObject: ["id":"focus-wire-response","status":"completed","output": [message]]))
        let transport=PanoramaWireTransport([reply])
        let port=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!,apiKey: "fixture",model: "fixture",transport: transport)
        let result=try await port.generate(input,focus: focus,target: target)
        XCTAssertEqual(result.1.responseID,"focus-wire-response")
        let requests=await transport.requests
        let body=try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests.first)) as? [String:Any])
        let messages=try XCTUnwrap(body["input"] as? [[String:Any]])
        let content=try XCTUnwrap(messages.first?["content"] as? String)
        let request=try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String:Any])
        let sentInput=try XCTUnwrap(request["input"] as? [String:Any])
        let sentSources=try XCTUnwrap(sentInput["sources"] as? [[String:Any]])
        XCTAssertEqual(sentSources.compactMap { $0["text"] as? String },texts)
        let sentFocus=try XCTUnwrap(request["focus"] as? [String:Any])
        XCTAssertEqual(sentFocus["unitID"] as? String,"u1")
        XCTAssertEqual(sentFocus["ordinal"] as? Int,1)
        let ranges=try XCTUnwrap(sentFocus["ranges"] as? [[String:Any]])
        XCTAssertEqual(ranges.first?["sourceID"] as? String,"s1")
        XCTAssertEqual(ranges.first?["transcriptVersionID"] as? String,"t1")
        XCTAssertEqual(ranges.first?["start"] as? Int,0)
        XCTAssertEqual(ranges.first?["end"] as? Int,texts[0].unicodeScalars.count)
        let sentTarget=try XCTUnwrap(request["target"] as? [String:Any])
        XCTAssertEqual(sentTarget["sourceIDs"] as? [String],["s1"])
        XCTAssertEqual(sentTarget["claimIDs"] as? [String],["c1"])
        let format=try XCTUnwrap((body["text"] as? [String:Any])?["format"] as? [String:Any])
        XCTAssertEqual(format["name"] as? String,"voiceos_panorama_focus")
        let instructions=try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains("聚焦分片"))
        XCTAssertTrue(instructions.contains("全文坐标"))
        XCTAssertThrowsError(try PanoramaModelInput(input).focusForModel(.init(unitID: unit.id,ordinal: 1,count: 1,
            ranges: [.init(sourceID: sources[0].id,transcriptVersionID: "wrong-version",start: 0,end: 1)])))
    }

    private func panoramaFixtureStore(_ root: URL, texts: [String]) async throws -> VoiceOSStore {
        let store=try VoiceOSStore(root: root,inspector: NativeMediaInspector())
        try await store.recover()
        var ids: [String]=[]
        for text in texts {
            let id=try await store.recordUserExpression(text)
            _ = try await store.setSourceLocalOnly(sourceID: id,expectedVersion: 1,localOnly: false)
            ids.append(id)
        }
        let context=try await store.prepareLocalTranscriptContext(sourceIDs: ids,scalarBudget: Int.max)
        _ = try await store.importOrganizedClaims(context: context,proposals: [],commandID: "slices-fixture")
        return store
    }
}
