import Foundation
import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor ProgressivePanoramaFixture: PanoramaModelPort {
    nonisolated let configurationIdentity: String
    let rejectUnits: Bool
    let invalidQuote: Bool
    let failGenerationAt: Int?
    let beforeGenerate: (@Sendable (PanoramaInput) async throws -> Void)?
    var transientFailures: Int
    var failCoverage: Bool
    var failConsistency: Bool
    var generations=0, unitReviews=0, syntheses=0, globalRepairs=0, evidenceReviews=0, coverageReviews=0, consistencyReviews=0
    var serial=0
    var sawPriorGlobalRejection=false
    var coverageTargets: [PanoramaCoverageTarget]=[]

    init(identity: String = "progressive-fixture", failGenerationAt: Int? = nil, rejectUnits: Bool = false, invalidQuote: Bool = false,
         failCoverage: Bool = false, failConsistency: Bool = false, transientFailures: Int = 0, beforeGenerate: (@Sendable (PanoramaInput) async throws -> Void)? = nil) {
        configurationIdentity=identity; self.failGenerationAt=failGenerationAt; self.rejectUnits=rejectUnits; self.invalidQuote=invalidQuote
        self.failCoverage=failCoverage; self.failConsistency=failConsistency; self.beforeGenerate=beforeGenerate; self.transientFailures=transientFailures
    }
    private func receipt() -> PanoramaReceipt {
        serial += 1
        return .init(responseID: configurationIdentity+"-response-"+String(serial), model: configurationIdentity, createdAt: "2026-10-23T00:00:00Z")
    }
    private func review(_ proposal: PanoramaProposal, accepted: Bool = true) -> PanoramaReview {
        .init(questions: proposal.questions.map { .init(id: $0.id, accepted: accepted, reason: accepted ? "完整原话与归属对应" : "归纳缺少否定条件") },
            relations: proposal.relations.map { .init(id: $0.id, accepted: accepted, reason: accepted ? "双方完整原文支持条件联系" : "双方原文尚不能支持此联系") },
            coverageAccepted: accepted, reason: accepted ? "本次指定范围全部核对" : "保留否定条件后重新核对")
    }
    func generate(_ input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt) {
        generations += 1
        if transientFailures > 0 { transientFailures -= 1; throw URLError(.networkConnectionLost) }
        if generations == failGenerationAt { throw VoiceOSError("模拟后续单元暂停") }
        try await beforeGenerate?(input)
        let questions=input.sources.enumerated().map { index, source in
            PanoramaQuestion(id: "q"+String(index), regionID: "r", title: "如何保留完整检索条件？", summary: source.title,
                evidence: [.init(sourceID: source.id, transcriptVersionID: source.transcript.transcriptVersionID, start: 0,
                    end: source.transcript.text.unicodeScalars.count, quote: invalidQuote ? "原文不存在的合成引文。" : source.transcript.text,
                    claimIDs: input.claims.filter { claim in claim.references.contains { $0.sourceID == source.id } }.map(\.id))])
        }
        return (.init(regions: [.init(id: "r", title: "检索条件", summary: "完整材料的条件核对")], questions: questions,
            relations: [], unrepresentedSources: [], unrepresentedClaims: []),receipt())
    }
    func verify(_ proposal: PanoramaProposal, input: PanoramaInput, priorRejection: PanoramaRejection?) async throws -> (PanoramaReview, PanoramaReceipt) {
        unitReviews += 1
        return (review(proposal,accepted: !rejectUnits),receipt())
    }
    func repair(_ proposal: PanoramaProposal, input: PanoramaInput, review: PanoramaReview) async throws -> (PanoramaProposal, PanoramaReceipt) {
        (proposal,receipt())
    }
    func synthesize(_ proposals: [PanoramaUnitProposal], input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt) {
        syntheses += 1
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
        XCTAssertEqual(partial.workflow?.verifiedUnitIDs.count,1)
        XCTAssertEqual(partial.coverage.submittedSourceIDs.count,1)
        XCTAssertEqual(partial.input.sources.count,3)
        XCTAssertTrue(partial.proposal.relations.isEmpty)
        try await store.generatePanorama(using: port)
        let unchangedGenerations=await port.generations
        XCTAssertEqual(unchangedGenerations,2)
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
        try await assertPanoramaManifestDuringAwait(root: root)
        try await assertPanoramaUnknownRecovery(root: root)
        try await assertPanoramaStagedWire()
        try await assertPanoramaTransientRetry(root: root)
    }
    private func panoramaFixtureStore(_ root: URL, count: Int) async throws -> VoiceOSStore {
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
        let modelProposal=try wire.proposalForModel(proposal)
        let report=PanoramaReview(questions: questions.map { .init(id: $0.id,accepted: true,reason: "完整原文一致") },relations: [.init(id: "e",accepted: true,reason: "双方条件对应")],coverageAccepted: true,reason: "全部指定范围一致")
        let unitOutputs=units.reversed().map { PanoramaUnitProposal(unitID: $0.id,proposal: proposal) }
        let coverageTarget=PanoramaCoverageTarget(sourceIDs: [sources[1].id],claimIDs: claims.map(\.id))
        let independent=PanoramaScopedReview(stage: "global.coverage",scopeID: units[1].id,review: report,
            receipt: .init(responseID: "independent-fixture",model: "fixture",createdAt: "fixture"),target: coverageTarget)
        func reply<T: Encodable>(_ value: T,index: Int) throws -> ModelHTTPReply {
            let text=String(decoding: try JSONEncoder().encode(value),as: UTF8.self)
            let message: [String: Any]=["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]
            let body: [String: Any]=["id":"wire-response-\(index)","status":"completed","output":[message]]
            return .init(status: 200,body: try JSONSerialization.data(withJSONObject: body))
        }
        let replies=try [reply(modelProposal,index: 1),reply(modelProposal,index: 2),reply(report,index: 3),reply(report,index: 4),reply(report,index: 5)]
        let transport=PanoramaWireTransport(replies)
        let port=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!,apiKey: "fixture",model: "fixture",transport: transport)
        let merged=try await port.synthesize(unitOutputs,input: input)
        XCTAssertEqual(merged.0.questions[0].summary,texts[0])
        let rejection=PanoramaRejection(proposal: proposal,review: report)
        let repaired=try await port.repairSynthesis(proposal,input: input,context: closure,rejection: rejection)
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
    }
}
