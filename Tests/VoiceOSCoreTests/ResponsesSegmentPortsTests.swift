import XCTest
@testable import VoiceOSCore

private struct SegmentHTTPInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private actor SegmentHTTPFixture: ModelHTTPTransport {
    var requests: [[String:Any]]=[]
    let bad: Bool
    let quoteOnly: Bool
    init(bad: Bool = false, quoteOnly: Bool = false) { self.bad=bad;self.quoteOnly=quoteOnly }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        let root=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        requests.append(root)
        let input=(root["input"] as! [[String:Any]])[0]["content"] as! String
        let fields=try JSONSerialization.jsonObject(with:Data(input.utf8)) as! [String:Any]
        let format=(root["text"] as! [String:Any])["format"] as! [String:Any]
        let result: [String:Any]
        if format["name"] as? String == "voiceos_segment_extract" {
            let segment=(fields["segment"] as? [String:Any]) ?? fields, text=segment["text"] as! String, start=(segment["textStart"] as? Int) ?? 0
            let quote=String(text.prefix(8)),end=start+quote.unicodeScalars.count
            let refs=(segment["references"] as? [[String:Any]]) ?? []
            let proposal: [String:Any]=quoteOnly ? ["kind":"statement","statement":"合成陈述","quote":text]:["kind":"statement","statement":"合成陈述","quote":quote,"textStart":start,"textEnd":end,
                "spanIDs":refs.filter { ($0["textStart"] as! Int)<end }.map { $0["spanID"] as! String }]
            result=bad ? ["proposals":[proposal],"tool":"unexpected"]:["proposals":[proposal]]
        } else {
            let ledger=fields["ledger"] as! [String:Any], evidence=ledger["evidence"] as! [[String:Any]],ids=evidence.map { $0["id"] as! String }
            result=["review":["batchID":fields["batchID"]!,"ledgerDigest":ledger["contentDigest"]!,"reviewedEvidenceIDs":ids,"actionDecisions":[]],
                "finalClaims":ids.map { ["statement":"合成最终陈述","ownership":"user_tentative","contentKind":"statement","evidenceIDs":[$0],"actionEvidenceID":NSNull(),"action":NSNull()] as [String:Any] }]
        }
        let text=String(decoding:try JSONSerialization.data(withJSONObject:result),as:UTF8.self)
        let body: [String:Any]=["status":"completed","usage":["input_tokens":20,"output_tokens":10],"output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]]]
        return .init(status:200,body:try JSONSerialization.data(withJSONObject:body))
    }
    func count() -> Int { requests.count }
    func payloads() -> [Data] { requests.map { try! JSONSerialization.data(withJSONObject:$0) } }
}
final class ResponsesSegmentPortsTests: XCTestCase {
    func testCompactExtractionKeepsDurableReferencesWithoutSendingMetadata() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let store=try VoiceOSStore(root:root,inspector:SegmentHTTPInspector());try await store.recover()
        let source=try await store.recordUserExpression("第一段保留原话。第二段明确否定。")
        _=try await store.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false)
        let transport=SegmentHTTPFixture(quoteOnly:true),base=URL(string:"https://api.openai.com/v1")!
        let x=try ResponsesSegmentExtractionPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport,compactInput:true)
        let a=try ResponsesSegmentAggregationPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport,compactInput:true)
        let scope=try await store.prepareSegmentedExpressionProcessingScope(sourceID:source,extraction:x.configuration,aggregation:a.configuration,segmentScalarBudget:10)
        XCTAssertEqual(scope.evidenceScalarBudget,32000)
        let batch=try await store.enqueueSegmentedProcessingBatch(scope,extraction:x.configuration,aggregation:a.configuration)
        let result=try await store.processSegmentedCognition(batchID:batch.id,extraction:x,aggregation:a)
        XCTAssertEqual(result.claimIDs?.count,scope.plan.segments.count)
        let payloads=await transport.payloads()
        for payload in payloads.dropLast() {
            let body=try JSONSerialization.jsonObject(with:payload) as! [String:Any]
            let input=(body["input"] as! [[String:Any]])[0]["content"] as! String
            let fields=try JSONSerialization.jsonObject(with:Data(input.utf8)) as! [String:Any]
            XCTAssertEqual(Set(fields.keys),["origin","speaker","text"])
            XCTAssertFalse(input.contains(source))
        }
        let receipts=try await store.segmentExtractionAttempts(batchID:batch.id)
        XCTAssertEqual(receipts.count,scope.plan.segments.count)
        XCTAssertTrue(receipts.allSatisfy { $0.state == .completed })
        let aggregatePayload=try JSONSerialization.jsonObject(with:try XCTUnwrap(payloads.last)) as! [String:Any]
        let aggregateInput=(aggregatePayload["input"] as! [[String:Any]])[0]["content"] as! String
        let compact=try JSONSerialization.jsonObject(with:Data(aggregateInput.utf8)) as! [String:Any]
        XCTAssertEqual(Set(compact.keys),["batchID","ledger"])
        let compactLedger=compact["ledger"] as! [String:Any]
        let compactEvidence=compactLedger["evidence"] as! [[String:Any]]
        XCTAssertEqual(compactEvidence.count,scope.plan.segments.count)
        XCTAssertEqual(compactEvidence.map { $0["quote"] as! String },scope.plan.segments.map(\.text))
        for item in compactEvidence { XCTAssertEqual(Set(item.keys),["id","segmentID","ordinal","kind","statement","quote"]) }
        XCTAssertFalse(aggregateInput.contains("payloadJSON"));XCTAssertFalse(aggregateInput.contains("containingSpanStartMS"))
        let legacy=try ResponsesSegmentExtractionPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport)
        do { try await store.validateSegmentedExpressionProcessingScope(scope,extraction:legacy.configuration,aggregation:a.configuration); XCTFail("Fixed v3 scope must reject v2 port") } catch {}
        let legacyAggregation=try ResponsesSegmentAggregationPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport)
        do { try await store.validateSegmentedExpressionProcessingScope(scope,extraction:x.configuration,aggregation:legacyAggregation.configuration);XCTFail("Fixed aggregation identity must not drift") } catch {}
        _=try await store.processSegmentedCognition(batchID:batch.id,extraction:x,aggregation:a)
        let calls=await transport.count();XCTAssertEqual(calls,scope.plan.segments.count+1)
    }
    func testQuoteGroundingCountsScalarsAndKeepsEveryIntersectingSpan() throws {
        let a=UUID().uuidString,b=UUID().uuidString
        let segment=TranscriptSegment(id:UUID().uuidString,ordinal:2,textStart:4000,textEnd:4010,text:"前😀e\u{301}后不要购买。",references:[.init(spanID:a,textStart:4000,textEnd:4005,containingSpanStartMS:nil,containingSpanEndMS:nil),.init(spanID:b,textStart:4005,textEnd:4010,containingSpanStartMS:nil,containingSpanEndMS:nil)])
        let proposal=try ResponsesSegmentExtractionPort.groundQuote(kind:.negation,statement:"否定购买",quote:"e\u{301}后不要购买",segment:segment)
        XCTAssertEqual(proposal.textStart,4002);XCTAssertEqual(proposal.textEnd,4009);XCTAssertEqual(proposal.spanIDs,[a,b])
        XCTAssertThrowsError(try ResponsesSegmentExtractionPort.groundQuote(kind:.statement,statement:"不能拆字符",quote:"\u{301}",segment:segment))
        XCTAssertThrowsError(try ResponsesSegmentExtractionPort.groundQuote(kind:.statement,statement:"不能归一化伪造",quote:"é后",segment:segment))
    }
    func testAmbiguousQuoteNeverGuessesWhichOccurrence() throws {
        let span=UUID().uuidString
        let segment=TranscriptSegment(id:UUID().uuidString,ordinal:1,textStart:0,textEnd:10,text:"不要买。不要买。",references:[.init(spanID:span,textStart:0,textEnd:10,containingSpanStartMS:nil,containingSpanEndMS:nil)])
        XCTAssertThrowsError(try ResponsesSegmentExtractionPort.groundQuote(kind:.negation,statement:"重复否定",quote:"不要买",segment:segment))
    }
    func testV2QuoteOnlyProtocolCommitsAndReusesOriginalReceipts() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let store=try VoiceOSStore(root:root,inspector:SegmentHTTPInspector());try await store.recover()
        let source=try await store.recordUserExpression("第一段只谈原话。第二段只谈条件。第三段明确否定。")
        _=try await store.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false)
        let transport=SegmentHTTPFixture(quoteOnly:true),base=URL(string:"https://api.openai.com/v1")!
        let extraction=try ResponsesSegmentExtractionPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport)
        let aggregation=try ResponsesSegmentAggregationPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport)
        let scope=try await store.prepareSegmentedExpressionProcessingScope(sourceID:source,extraction:extraction.configuration,aggregation:aggregation.configuration,segmentScalarBudget:12)
        XCTAssertEqual(scope.evidenceScalarBudget,32000)
        let batch=try await store.enqueueSegmentedProcessingBatch(scope,extraction:extraction.configuration,aggregation:aggregation.configuration)
        let result=try await store.processSegmentedCognition(batchID:batch.id,extraction:extraction,aggregation:aggregation)
        XCTAssertEqual(result.claimIDs?.count,scope.plan.segments.count)
        let replay=try await store.processSegmentedCognition(batchID:batch.id,extraction:extraction,aggregation:aggregation)
        XCTAssertEqual(replay.claimIDs,result.claimIDs)
        let calls=await transport.count();XCTAssertEqual(calls,scope.plan.segments.count+1)
    }
    func testTextHTTPPipelineStagesAndCommitsWithoutFullSourceUpload() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store=try VoiceOSStore(root:root,inspector:SegmentHTTPInspector()); try await store.recover()
        let source=try await store.recordUserExpression("原话片段用于合成验证。"), old=try await store.transcriptHistory(sourceID:source)[0].id
        let full=String(repeating:"原话片段用于合成验证。",count:410)
        _ = try await store.correctTranscript(sourceID:source,expectedVersionID:old,text:full)
        _ = try await store.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false)
        let transport=SegmentHTTPFixture(), base=URL(string:"https://api.openai.com/v1")!
        let extraction=try ResponsesSegmentExtractionPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport,locallyGroundQuotes:false)
        let aggregation=try ResponsesSegmentAggregationPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport)
        let scope=try await store.prepareSegmentedExpressionProcessingScope(sourceID:source,extraction:extraction.configuration,aggregation:aggregation.configuration)
        let batch=try await store.enqueueSegmentedProcessingBatch(scope,extraction:extraction.configuration,aggregation:aggregation.configuration)
        let result=try await store.processSegmentedCognition(batchID:batch.id,extraction:extraction,aggregation:aggregation)
        let receipt=try await store.segmentAggregationAttempt(batchID:batch.id); XCTAssertEqual(receipt?.state,.completed)
        let ids=try XCTUnwrap(result.claimIDs)
        let replay=try await store.processSegmentedCognition(batchID:batch.id,extraction:extraction,aggregation:aggregation)
        XCTAssertEqual(replay.claimIDs,ids)
        XCTAssertEqual(ids.count,scope.plan.segments.count)
        let count=await transport.count(); XCTAssertEqual(count,scope.plan.segments.count+1)
        let payloads=await transport.payloads()
        for data in payloads {
            let payload=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            XCTAssertEqual(payload["store"] as? Bool,false); XCTAssertNil(payload["tools"])
            let input=(payload["input"] as! [[String:Any]])[0]["content"] as! String
            XCTAssertFalse(input.contains(full)); XCTAssertFalse(input.contains("fileURL")); XCTAssertFalse(input.contains("apiKey"))
        }
    }
    func testProxyUnknownFieldsRejectedWithUsageAndNoProducts() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store=try VoiceOSStore(root:root,inspector:SegmentHTTPInspector()); try await store.recover()
        let id=try await store.recordUserExpression("合成测试文字，后面还有需要分段的文字。")
        _ = try await store.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
        let transport=SegmentHTTPFixture(bad:true),base=URL(string:"https://api.openai.com/v1")!
        let x=try ResponsesSegmentExtractionPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport,locallyGroundQuotes:false)
        let a=try ResponsesSegmentAggregationPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport)
        let scope=try await store.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:x.configuration,aggregation:a.configuration,segmentScalarBudget:10)
        let batch=try await store.enqueueSegmentedProcessingBatch(scope,extraction:x.configuration,aggregation:a.configuration)
        let r=try await store.runNextSegmentExtraction(batchID:batch.id,using:x); XCTAssertEqual(r?.state,.rejected); XCTAssertEqual(r?.usage?["input_tokens"],20)
        _ = try await store.runNextSegmentExtraction(batchID:batch.id,using:x)
        let count=await transport.count(); XCTAssertEqual(count,1)
        let claims=try await store.candidateClaims(); XCTAssertTrue(claims.isEmpty)
    }
    func testLocalOnlyCannotPrepareCloudBatchOrSend() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store=try VoiceOSStore(root:root,inspector:SegmentHTTPInspector()); try await store.recover()
        let source=try await store.recordUserExpression("仅本地文字不能发送到模型服务。")
        let transport=SegmentHTTPFixture(),base=URL(string:"https://api.openai.com/v1")!
        let x=try ResponsesSegmentExtractionPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport,locallyGroundQuotes:false)
        let a=try ResponsesSegmentAggregationPort(baseURL:base,apiKey:"test-placeholder",model:"fixture",transport:transport)
        do { _ = try await store.prepareSegmentedExpressionProcessingScope(sourceID:source,extraction:x.configuration,aggregation:a.configuration,segmentScalarBudget:10); XCTFail() } catch {}
        let count=await transport.count(); XCTAssertEqual(count,0)
    }
}
