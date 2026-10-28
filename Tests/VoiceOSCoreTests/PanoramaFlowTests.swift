import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class PanoramaFlowTests: FlowTestCase {
    func testIdeaFindsHistoryWithoutCreatingTask() async throws {
        try assertPanoramaDatabaseReopens()
        try await assertPanoramaSchemaRepair()
        try await assertPanoramaProgressiveRecovery(root: root)
        let store = try await openStore(), model = FlowModel()
        let oldID = try await expression(store, text: "记忆系统需要关注检索质量。", model: model)
        let previous = try await store.retrieve("检索质量", using: NativeRetrieval())
        XCTAssertEqual(previous.hits.first?.document.sourceID, oldID)
        _ = try await expression(store, text: "今天又想到检索质量和容量的关系。", model: model)
        do { try await store.validateRetrievalResult(previous); XCTFail("新表达出现后应重新查找历史") } catch {}
        let current = try await store.retrieve("检索质量", using: NativeRetrieval()), actions = try await store.actions()
        XCTAssertEqual(current.matchingSources, 2)
        XCTAssertTrue(actions.isEmpty)
        let claims = try await store.latestCandidateClaims(for: oldID), claim = try XCTUnwrap(claims.first)
        let opportunityID = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: claim.reviewVersion, title: "【问题】检索质量如何改善", kind: .opportunity)
        let taskID = try await store.confirmOpportunityAsTask(actionID: opportunityID, expectedVersion: 1, title: "研究检索质量的改进方法")
        let history = try await store.actions(includeHistory: true)
        XCTAssertEqual(history.first(where: { $0.id == opportunityID })?.state, "dismissed")
        XCTAssertEqual(history.first(where: { $0.id == taskID })?.kind, "task")
        XCTAssertEqual(history.first(where: { $0.id == taskID })?.intent?.uncertain, false)

        var corpus: [String]=[]
        for index in 0..<4 {
            let source=try await store.recordUserExpression(String(repeating: "合成检索资料需要完整保留。", count: 240)+String(index))
            _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
            corpus.append(source)
        }
        let full=try await store.prepareLocalTranscriptContext(sourceIDs: corpus, scalarBudget: Int.max)
        _ = try await store.importOrganizedClaims(context: full, proposals: [], commandID: "complete-zero-claims")
        let panorama=FlowPanorama()
        let eligible=try await store.panoramaInput()
        XCTAssertEqual(Set(eligible.manifest.sourceIDs), Set(corpus))
        XCTAssertEqual(eligible.claims.count, 0)
        XCTAssertGreaterThan(eligible.sources.reduce(0) { $0+$1.transcript.text.unicodeScalars.count }, 12000)
        let largeSummary=String(repeating: "完整合成解释。", count: 16000)
        let largeProposal=PanoramaProposal(regions: [.init(id: "r", title: "检索研究", summary: largeSummary)], questions: [], relations: [], unrepresentedSources: eligible.sources.indices.map { .init(id: "s"+String($0+1), reason: "保留全文入口") }, unrepresentedClaims: [])
        let text=String(decoding: try JSONEncoder().encode(largeProposal), as: UTF8.self)
        let envelope=try JSONSerialization.data(withJSONObject: ["id":"large-panorama", "status":"completed", "usage":["input_tokens":120, "output_tokens":100], "output":[["type":"message", "role":"assistant", "status":"completed", "content":[["type":"output_text", "text":text]]]]])
        XCTAssertGreaterThan(envelope.count, 262144)
        XCTAssertThrowsError(try ResponsesEnvelope.parse(envelope))
        let largePort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([.init(status: 200, body: envelope)]))
        let (decoded, receipt)=try await largePort.generate(eligible)
        XCTAssertEqual(decoded.regions.first?.summary, largeSummary)
        XCTAssertEqual(receipt.responseID, "large-panorama")
        XCTAssertEqual(receipt.inputTokens, 120)
        XCTAssertEqual(receipt.outputTokens, 100)
        XCTAssertEqual(decoded.unrepresentedSources.map(\.id), eligible.sources.map(\.id))

        let prefix = "👩‍💻e\u{301} s1 t1 c1。", repeatedQuote = "重复原话。"
        let unicodeText = prefix + repeatedQuote + repeatedQuote
        let repeatedStart = (prefix + repeatedQuote).unicodeScalars.count
        let firstSpan = TranscriptSpan(textStart: 0, textEnd: repeatedStart)
        let repeatedSpan = TranscriptSpan(textStart: repeatedStart, textEnd: unicodeText.unicodeScalars.count)
        let externalText = "外部节目关于检索。"
        let externalSpan = TranscriptSpan(textStart: 0, textEnd: externalText.unicodeScalars.count)
        let literalReason = "s1 t1 c1 和真实身份 s2、c2 只是原话，不得替换。"
        let transcriptReview = TranscriptionReview(completed: true, changed: true, response_id: "private-review-receipt", response_ids: ["private-review-receipt"], context_review_version: 3,
            corrections: [.init(span_id: firstSpan.id, before: "旧词", after: "新词", context_quote: prefix, reason: literalReason, independent_reason: "保留独立核对理由 c1")],
            unresolved_issues: [.init(span_id: repeatedSpan.id, reason: literalReason)], transcriptVersionID: "t2")
        let wireSources: [PanoramaSource] = [
            .init(transcript: .init(sourceID: "s2", sourceVersionID: "original-source-version", transcriptVersionID: "t2", origin: "user", speaker: "self", localOnly: false, text: unicodeText, spans: [firstSpan, repeatedSpan], transcriptionReview: transcriptReview), title: "完整 Unicode 原文", occurredAt: "2026-10-22T01:00:00Z", policyVersion: 1),
            .init(transcript: .init(sourceID: "external-source", sourceVersionID: "external-source-version", transcriptVersionID: "external-version", origin: "external", speaker: "external", localOnly: false, text: externalText, spans: [externalSpan]), title: "完整节目", occurredAt: "2026-10-21T01:00:00Z", policyVersion: 2)
        ]
        let wireClaims: [PanoramaClaim] = [
            .init(id: "c2", statement: literalReason, ownership: "user_tentative", reviewVersion: 1, references: [.init(sourceID: "s2", transcriptVersionID: "t2", spanID: repeatedSpan.id), .init(sourceID: "external-source", transcriptVersionID: "external-version", spanID: externalSpan.id)]),
            .init(id: "other-claim", statement: "保留全部当前观点", ownership: "unresolved", reviewVersion: 2, references: [.init(sourceID: "s2", transcriptVersionID: "t2", spanID: firstSpan.id)])
        ]
        let wireInput = PanoramaInput(manifest: .init(digest: "local-manifest", sourceIDs: wireSources.map(\.id), claimIDs: wireClaims.map(\.id), unitIDs: ["expression"]),
            units: [.init(id: "expression", sourceIDs: ["s2"], dependencyIDs: ["external-source"], producerID: "private-producer", completionDigest: "private-completion")],
            sources: wireSources, claims: wireClaims, exclusions: [.init(id: "excluded-private-source", title: "不应发送", reason: "本机资料")])
        let modelEvidence = PanoramaEvidence(sourceID: "s1", transcriptVersionID: "t1", start: repeatedStart, end: unicodeText.unicodeScalars.count, quote: repeatedQuote, claimIDs: ["c1"])
        let unicodeEvidence = PanoramaEvidence(sourceID: "s1", transcriptVersionID: "t1", start: 0, end: prefix.unicodeScalars.count, quote: prefix, claimIDs: [])
        let modelProposal = PanoramaProposal(regions: [.init(id: "t1", title: "原话研究", summary: literalReason)],
            questions: [.init(id: "s1", regionID: "t1", title: "如何理解原话？", summary: literalReason, evidence: [modelEvidence]), .init(id: "c1", regionID: "t1", title: "哪些条件尚待核对？", summary: literalReason, evidence: [unicodeEvidence])],
            relations: [.init(id: "s2", from: "s1", to: "c1", label: literalReason, explanation: literalReason, fromEvidence: [modelEvidence], toEvidence: [unicodeEvidence])],
            unrepresentedSources: [.init(id: "s2", reason: literalReason)], unrepresentedClaims: [.init(id: "c2", reason: literalReason)])
        let modelReview = PanoramaReview(questions: modelProposal.questions.map { .init(id: $0.id, accepted: true, reason: literalReason) }, relations: [.init(id: "s2", accepted: false, reason: literalReason)], coverageAccepted: true, reason: literalReason)
        func modelEnvelope<T: Encodable>(_ value: T) throws -> ModelHTTPReply {
            let encoded = try JSONEncoder().encode(value)
            let content: [String: Any] = ["type": "output_text", "text": String(decoding: encoded, as: UTF8.self)]
            let message: [String: Any] = ["type": "message", "role": "assistant", "status": "completed", "content": [content]]
            let envelope: [String: Any] = ["id": "compact-fixture", "status": "completed", "output": [message]]
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: envelope))
        }
        let compactTransport = FlowFollowupTransport(try [modelEnvelope(modelProposal), modelEnvelope(modelReview), modelEnvelope(modelProposal), modelEnvelope(modelReview)])
        let compactPort = try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: compactTransport)
        let (canonical, _) = try await compactPort.generate(wireInput)
        _ = try VoiceOSStore.validatePanorama(canonical, input: wireInput)
        XCTAssertEqual(canonical.questions.map(\.id), ["s1", "c1"])
        XCTAssertEqual(canonical.relations.first?.id, "s2")
        XCTAssertEqual(canonical.questions.first?.evidence.first?.sourceID, "s2")
        XCTAssertEqual(canonical.questions.first?.evidence.first?.transcriptVersionID, "t2")
        XCTAssertEqual(canonical.questions.first?.evidence.first?.claimIDs, ["c2"])
        XCTAssertEqual(canonical.questions.first?.evidence.first?.start, repeatedStart)
        XCTAssertEqual(canonical.questions.first?.evidence.first?.quote, repeatedQuote)
        XCTAssertEqual(canonical.questions[1].evidence[0].quote, prefix)
        XCTAssertEqual(canonical.questions[1].evidence[0].end, prefix.unicodeScalars.count)
        XCTAssertEqual(canonical.unrepresentedSources.first?.id, "external-source")
        XCTAssertEqual(canonical.unrepresentedClaims.first?.id, "other-claim")
        XCTAssertEqual(canonical.relations.first?.explanation, literalReason)
        let (rejectionReview, _) = try await compactPort.verify(canonical, input: wireInput)
        let (repaired, _) = try await compactPort.repair(canonical, input: wireInput, review: rejectionReview)
        let orderedEncoder = JSONEncoder()
        orderedEncoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try orderedEncoder.encode(repaired), try orderedEncoder.encode(canonical))
        _ = try await compactPort.verify(repaired, input: wireInput, priorRejection: .init(proposal: canonical, review: rejectionReview))
        let compactRequests = await compactTransport.requests
        func content(_ request: Data) throws -> [String: Any] {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
            let text = try XCTUnwrap(messages.first?["content"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let generationContent = try content(compactRequests[0])
        XCTAssertEqual(Set(generationContent.keys), ["units", "sources", "claims"])
        let sentSources = try XCTUnwrap(generationContent["sources"] as? [[String: Any]])
        XCTAssertEqual(sentSources.count, wireSources.count)
        XCTAssertEqual(sentSources.compactMap { $0["text"] as? String }, [unicodeText, externalText])
        XCTAssertEqual(sentSources.compactMap { $0["title"] as? String }, wireSources.map(\.title))
        XCTAssertEqual(sentSources.compactMap { $0["occurredAt"] as? String }, wireSources.map(\.occurredAt))
        XCTAssertEqual(sentSources.compactMap { $0["origin"] as? String }, ["user", "external"])
        XCTAssertEqual(sentSources.compactMap { $0["speaker"] as? String }, ["self", "external"])
        XCTAssertNil(sentSources[0]["spans"])
        let sentReview = try XCTUnwrap(sentSources[0]["transcriptionReview"] as? [String: Any])
        let sentIssues = try XCTUnwrap(sentReview["unresolvedIssues"] as? [[String: Any]])
        XCTAssertEqual(sentReview["transcriptVersionID"] as? String, "t1")
        XCTAssertEqual(sentIssues.count, 1)
        XCTAssertEqual(sentIssues[0]["start"] as? Int, repeatedStart)
        XCTAssertEqual(sentIssues[0]["end"] as? Int, unicodeText.unicodeScalars.count)
        XCTAssertEqual(sentIssues[0]["reason"] as? String, literalReason)
        let sentCorrections = try XCTUnwrap(sentReview["corrections"] as? [[String: Any]])
        XCTAssertEqual(sentCorrections.count, 1)
        XCTAssertEqual(sentCorrections[0]["start"] as? Int, 0)
        XCTAssertEqual(sentCorrections[0]["end"] as? Int, repeatedStart)
        XCTAssertEqual(sentCorrections[0]["before"] as? String, "旧词")
        XCTAssertEqual(sentCorrections[0]["after"] as? String, "新词")
        XCTAssertEqual(sentCorrections[0]["context_quote"] as? String, prefix)
        XCTAssertEqual(sentCorrections[0]["reason"] as? String, literalReason)
        XCTAssertEqual(sentCorrections[0]["independent_reason"] as? String, "保留独立核对理由 c1")
        let sentClaims = try XCTUnwrap(generationContent["claims"] as? [[String: Any]])
        XCTAssertEqual(sentClaims.count, wireClaims.count)
        XCTAssertEqual(sentClaims.compactMap { $0["statement"] as? String }, wireClaims.map(\.statement))
        XCTAssertEqual(sentClaims.compactMap { $0["ownership"] as? String }, wireClaims.map(\.ownership))
        let sentReferences = try sentClaims.map { try XCTUnwrap($0["references"] as? [[String: Any]]) }
        XCTAssertEqual(sentReferences.map(\.count), [2, 1])
        XCTAssertEqual(sentReferences[0].compactMap { $0["sourceID"] as? String }, ["s1", "s2"])
        XCTAssertEqual(sentReferences[0].compactMap { $0["transcriptVersionID"] as? String }, ["t1", "t2"])
        XCTAssertEqual(sentReferences[0].compactMap { $0["start"] as? Int }, [repeatedStart, 0])
        XCTAssertEqual(sentReferences[0].compactMap { $0["end"] as? Int }, [unicodeText.unicodeScalars.count, externalText.unicodeScalars.count])
        XCTAssertEqual(sentReferences[1][0]["start"] as? Int, 0)
        XCTAssertEqual(sentReferences[1][0]["end"] as? Int, repeatedStart)
        let sentUnits = try XCTUnwrap(generationContent["units"] as? [[String: Any]])
        XCTAssertEqual(sentUnits[0]["sourceIDs"] as? [String], ["s1"])
        XCTAssertEqual(sentUnits[0]["dependencyIDs"] as? [String], ["s2"])
        let expectedProposal = try orderedEncoder.encode(modelProposal)
        let expectedReview = try orderedEncoder.encode(modelReview)
        for index in 1...3 {
            let sent = try content(compactRequests[index])
            let sentProposal = try XCTUnwrap(sent["proposal"] as? [String: Any])
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: sentProposal, options: .sortedKeys), expectedProposal)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: sent["input"] as Any, options: .sortedKeys), try JSONSerialization.data(withJSONObject: generationContent, options: .sortedKeys))
        }
        let prior = try XCTUnwrap(try content(compactRequests[3])["priorRejection"] as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: prior["proposal"] as Any, options: .sortedKeys), expectedProposal)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: prior["review"] as Any, options: .sortedKeys), expectedReview)
        let wireBytes = try JSONSerialization.data(withJSONObject: generationContent, options: .sortedKeys).count
        let canonicalBytes = try JSONEncoder().encode(wireInput).count
        XCTAssertLessThan(wireBytes, canonicalBytes)
        print("Panorama synthetic transport fixture canonical=\(canonicalBytes) bytes compact=\(wireBytes) bytes; complete text, 2 sources, 2 claims, 3 references")

        let unknownProposal = PanoramaProposal(regions: [], questions: [], relations: [], unrepresentedSources: [.init(id: "unknown-alias", reason: literalReason)], unrepresentedClaims: [])
        let unknownPort = try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([try modelEnvelope(unknownProposal)]))
        do { _ = try await unknownPort.generate(wireInput); XCTFail("未知短身份不能返回资料库") } catch {}
        let wrongVersion = PanoramaProposal(regions: modelProposal.regions, questions: [.init(id: "s1", regionID: "t1", title: "版本错误", summary: literalReason, evidence: [.init(sourceID: "s1", transcriptVersionID: "t2", start: repeatedStart, end: unicodeText.unicodeScalars.count, quote: repeatedQuote, claimIDs: ["c1"])])], relations: [], unrepresentedSources: [], unrepresentedClaims: [])
        let wrongVersionPort = try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([try modelEnvelope(wrongVersion)]))
        do { _ = try await wrongVersionPort.generate(wireInput); XCTFail("短身份存在也不能串用来源和版本") } catch {}
        var missingIssueTranscript = wireSources[0].transcript
        missingIssueTranscript.transcriptionReview = .init(completed: true, changed: false, response_id: "fixture", response_ids: nil, context_review_version: nil, unresolved_issues: [.init(span_id: "missing-span", reason: literalReason)], transcriptVersionID: "t2")
        let missingIssueInput = PanoramaInput(manifest: wireInput.manifest, units: wireInput.units, sources: [.init(transcript: missingIssueTranscript, title: wireSources[0].title, occurredAt: wireSources[0].occurredAt, policyVersion: 1), wireSources[1]], claims: wireClaims, exclusions: [])
        let missingTransport = FlowFollowupTransport([])
        let missingPort = try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: missingTransport)
        do { _ = try await missingPort.generate(missingIssueInput); XCTFail("无法定位的待核对项不能丢弃") } catch {}
        let missingReferenceInput = PanoramaInput(manifest: wireInput.manifest, units: wireInput.units, sources: wireSources, claims: [.init(id: "c2", statement: literalReason, ownership: "unresolved", reviewVersion: 1, references: [.init(sourceID: "s2", transcriptVersionID: "t2", spanID: "missing-span")])], exclusions: [])
        do { _ = try await missingPort.generate(missingReferenceInput); XCTFail("无法定位的观点引用不能丢弃") } catch {}
        let missingRequests = await missingTransport.requests
        XCTAssertTrue(missingRequests.isEmpty)
        let invalid=try JSONSerialization.data(withJSONObject: ["status":"completed", "output":[["type":"unsupported"]]])
        let rejectedPort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowFollowupTransport([.init(status: 200, body: invalid)]))
        do { try await store.generatePanorama(using: rejectedPort); XCTFail("无效响应不能发布") } catch {}
        let rejected=try await store.panoramaState()
        XCTAssertEqual(rejected.status, "failed")
        XCTAssertEqual(rejected.error, "响应包含不支持的输出项")
        XCTAssertNil(rejected.snapshot)
        let privateDetail="https://fixture.invalid/private?key=fixture-secret"
        let terminalFailures: [([String:Any],String)]=[
            (["status":"failed", "error":["code":"server_error", "message":privateDetail]], "响应未完成（status=failed；error.code=server_error）；未接纳部分结果"),
            (["status":"failed", "error":["code":"upstream_error", "message":privateDetail]], "响应未完成（status=failed；error.code=upstream_error）；未接纳部分结果"),
            (["status":"failed", "error":["code":privateDetail, "message":privateDetail]], "响应未完成（status=failed；error.code=unknown）；未接纳部分结果"),
            (["status":"completed"], "响应已完成但 output 缺失或格式无效（status=completed）"),
            (["status":"incomplete", "incomplete_details":["reason":"max_output_tokens"]], "响应未完成（status=incomplete；incomplete_details.reason=max_output_tokens）；未接纳部分结果"),
            (["status":"incomplete", "incomplete_details":["reason":privateDetail]], "响应未完成（status=incomplete；incomplete_details.reason=unknown）；未接纳部分结果"),
            (["status":privateDetail], "响应未完成（status=unknown）；未接纳部分结果")
        ]
        for (var response, expected) in terminalFailures {
            response["usage"]=["input_tokens":120,"output_tokens":100]
            let transport=FlowFollowupTransport([.init(status:200,body:try JSONSerialization.data(withJSONObject:response))])
            let port=try ResponsesPanoramaPort(baseURL:URL(string:"https://api.openai.com/v1")!,apiKey:"fixture",model:"fixture",transport:transport)
            do { try await store.generatePanorama(using:port,retry:true); XCTFail("终态失败不能发布") }
            catch ModelPortFailure.rejected(let reason,let input,let output) {
                XCTAssertEqual(reason,expected)
                XCTAssertEqual(input,120); XCTAssertEqual(output,100)
            }
            let failure=try await store.panoramaState()
            XCTAssertEqual(failure.status,"failed")
            XCTAssertEqual(failure.error,expected)
            XCTAssertFalse(failure.error?.contains("fixture-secret") ?? true)
            XCTAssertNil(failure.snapshot)
            let requests=await transport.requests
            XCTAssertEqual(requests.count,1)
        }
        let timedOutPort=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: FlowPanoramaFailureTransport())
        do { try await store.generatePanorama(using: timedOutPort, retry: true); XCTFail("网络失败不能发布") } catch {}
        let timedOut=try await store.panoramaState()
        XCTAssertEqual(timedOut.status, "failed")
        XCTAssertEqual(timedOut.error, "全景网络请求失败（错误码 -1001）；材料保留，请明确重试")
        XCTAssertNil(timedOut.snapshot)
        do { try await store.generatePanorama(using: panorama, retry: true); XCTFail("全局核对尚未完成不能完成全景") }
        catch { XCTAssertEqual((error as? VoiceOSError)?.message, "当前模型端口尚不支持跨单元全景核对，已核对区域保留") }
        try await store.generatePanorama(using: panorama)
        let state=try await store.panoramaState(), snapshot=try XCTUnwrap(state.snapshot)
        XCTAssertEqual(snapshot.coverage.submittedSourceIDs.count, 4)
        XCTAssertEqual(snapshot.coverage.representedSourceIDs.count, 4)
        XCTAssertEqual(snapshot.coverage.unrepresentedSources.count, 0)
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertEqual(snapshot.workflow?.verifiedUnitIDs.count, 4)
        XCTAssertEqual(state.status, "failed")
        XCTAssertTrue(snapshot.proposal.relations.isEmpty)
        let generationCount=await panorama.generations, reviewCount=await panorama.reviews, repairCount=await panorama.repairs
        XCTAssertEqual(generationCount, 4); XCTAssertEqual(reviewCount, 5); XCTAssertEqual(repairCount, 1)
        let receivedRejection=await panorama.receivedRejection
        XCTAssertTrue(receivedRejection)
        XCTAssertEqual(snapshot.proposal.questions.first?.evidence.first?.start, 0)
        XCTAssertEqual(snapshot.generation.responseID, "generation-4")
        do { try await store.generatePanorama(using: panorama, retry: true) } catch {}
        let resumedGenerationCount=await panorama.generations
        XCTAssertEqual(resumedGenerationCount, generationCount)
        let repeated=eligible.sources[0]
        let ambiguous=PanoramaEvidence(sourceID: repeated.id, transcriptVersionID: repeated.transcript.transcriptVersionID, start: -1, end: -1, quote: "合成检索资料需要完整保留。", claimIDs: [])
        let ambiguousProposal=PanoramaProposal(regions: snapshot.proposal.regions, questions: [.init(id: "ambiguous", regionID: "r", title: "重复原话", summary: "不能猜测位置", evidence: [ambiguous])], relations: [], unrepresentedSources: [], unrepresentedClaims: [])
        XCTAssertThrowsError(try VoiceOSStore.locatePanoramaQuotes(ambiguousProposal, input: eligible))
        let entry=try await store.beginPanoramaConversation(snapshotID: snapshot.id, selection: .question(snapshot.proposal.questions[0].id))
        XCTAssertTrue(entry.draft.contains("AI 全景候选"))
        let noTurns=try await store.conversationUserTurns(conversationID: entry.conversation.id)
        XCTAssertTrue(noTurns.isEmpty)
        try await store.endConversation(id: entry.conversation.id, expectedVersion: 1)
        let reopened=try await store.beginPanoramaConversation(snapshotID: snapshot.id, selection: .question(snapshot.proposal.questions[0].id))
        XCTAssertNotEqual(reopened.conversation.id, entry.conversation.id)
        XCTAssertEqual(reopened.conversation.state, "active")
        let conversation=try await store.beginConversation(sourceIDs: corpus)
        let discussion=FlowCompleteDiscussion()
        for ordinal in 1...2 {
            let turn=try await store.recordUserExpression("请核对合成资料第\(ordinal)轮。")
            _ = try await store.appendConversationUserSource(conversationID: conversation, sourceID: turn, expectedVersion: ordinal)
            let input=try await store.prepareConversationInput(id: conversation, expectedVersion: ordinal+1, destination: .local)
            _ = try await store.performConversationReply(input, using: discussion)
        }
        let sent=await discussion.snapshots
        XCTAssertEqual(sent[1].priorReplies.count, 1)
        XCTAssertEqual(sent[1].context.sources.count, 6)
        XCTAssertGreaterThan(sent[1].context.scalarBudget, 12000)
        try await store.endConversation(id: conversation, expectedVersion: 3)
        let outcome=try await store.prepareConversationOutcome(id: conversation, expectedVersion: 4, destination: .local)
        XCTAssertEqual(outcome.replies.count, 2)
        XCTAssertGreaterThan(outcome.context.scalarBudget, 12000)
        _ = try await store.setSourceLocalOnly(sourceID: corpus[0], expectedVersion: 2, localOnly: true)
        let invalidated=try await store.panoramaState()
        XCTAssertNil(invalidated.snapshot)
        do { _ = try await store.beginPanoramaConversation(snapshotID: snapshot.id, selection: .question(snapshot.proposal.questions[0].id)); XCTFail("旧图不能继续讨论") } catch {}
    }

    private func assertPanoramaDatabaseReopens() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url=root.appendingPathComponent("panorama-schema.sqlite")
        var created: Database?=try Database(url)
        XCTAssertEqual(try created?.query("PRAGMA user_version").first?["user_version"], "43")
        created=nil
        let reopened=try Database(url)
        XCTAssertEqual(try reopened.query("PRAGMA table_info(panorama_steps)").filter { $0["name"] == "receipt_json" }.count, 1)
    }
    private func assertPanoramaSchemaRepair() async throws {
        let text="格式核对需要完整原文。"
        let transcript=ContextTranscript(sourceID: "format-source", sourceVersionID: "format-source-version", transcriptVersionID: "format-version", origin: "user", speaker: "user", localOnly: false,
            text: text, spans: [.init(textStart: 0, textEnd: text.unicodeScalars.count)])
        let input=PanoramaInput(manifest: .init(digest: "format-fixture", sourceIDs: [transcript.sourceID], claimIDs: [], unitIDs: ["format-unit"]),
            units: [.init(id: "format-unit", sourceIDs: [transcript.sourceID], dependencyIDs: [], producerID: "format-producer", completionDigest: "format-complete")],
            sources: [.init(transcript: transcript, title: "格式回放", occurredAt: "2026-10-23", policyVersion: 1)], claims: [], exclusions: [])
        let evidence: [String: Any]=["sourceID":"s1","transcriptVersionID":"t1","start":0,"end":text.unicodeScalars.count,"quote":text,"claimIDs":[]]
        let nestedQuestion: [String: Any]=["id":"q","title":"如何核对格式？","summary":"保留原话","evidence":[evidence]]
        let bad: [String: Any]=["regions":[["id":"r","title":"格式核对","summary":"保留原话","questions":[nestedQuestion]]], "relations":[], "unrepresentedSources":[], "unrepresentedClaims":[]]
        var flatQuestion=nestedQuestion; flatQuestion["regionID"]="r"
        let valid: [String: Any]=["regions":[["id":"r","title":"格式核对","summary":"保留原话"]], "questions":[flatQuestion], "relations":[], "unrepresentedSources":[], "unrepresentedClaims":[]]
        func reply(_ object: [String: Any], id: String) throws -> ModelHTTPReply {
            let content=String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["id":id,"status":"completed","output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":content]]]]]))
        }
        let transport=FlowFollowupTransport(try [reply(bad,id: "nested-fixture"),reply(valid,id: "flat-fixture")])
        let port=try ResponsesPanoramaPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture", model: "fixture", transport: transport)
        let (proposal,receipt)=try await port.generate(input)
        _ = try VoiceOSStore.validatePanorama(proposal, input: input)
        XCTAssertEqual(receipt.responseID,"flat-fixture")
        XCTAssertEqual(proposal.questions.first?.regionID,"r")
        let requests=await transport.requests
        XCTAssertEqual(requests.count,2)
        let body=try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1]) as? [String: Any])
        let messages=try XCTUnwrap(body["input"] as? [[String: Any]])
        let instruction=try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(instruction.contains("keyNotFound"))
        XCTAssertTrue(instruction.contains("$.questions"))
        XCTAssertTrue(instruction.contains("regionID"))
        XCTAssertTrue(instruction.contains("绝不嵌套 questions"))
    }
}
