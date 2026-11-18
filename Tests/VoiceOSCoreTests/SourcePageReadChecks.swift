import XCTest
@testable import VoiceOSCore

final class SourcePageReadChecks: XCTestCase {
    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    func testParagraphWindowMatchesFirstMatchScanAndIsFaster() {
        var paragraphs: [SourceParagraphWindow.Paragraph] = []
        for index in 0..<4000 {
            let start = index * 3000
            paragraphs.append(.init(id: "p-\(index)", startMS: start, endMS: start + 2800))
        }
        let window = SourceParagraphWindow(paragraphs: paragraphs)
        func linear(_ milliseconds: Int?) -> String? {
            guard let milliseconds else { return nil }
            return paragraphs.first { milliseconds >= $0.startMS && milliseconds < $0.endMS }?.id
        }
        for milliseconds in stride(from: -10, to: 4000 * 3000 + 3000, by: 997) {
            XCTAssertEqual(window.activeID(at: milliseconds), linear(milliseconds),
                           "段落窗口定位必须与逐段首匹配一致：\(milliseconds)")
        }
        let overlapping = [SourceParagraphWindow.Paragraph(id: "a", startMS: 0, endMS: 5000),
                           SourceParagraphWindow.Paragraph(id: "b", startMS: 1000, endMS: 6000),
                           SourceParagraphWindow.Paragraph(id: "c", startMS: 2000, endMS: 3000)]
        let fallback = SourceParagraphWindow(paragraphs: overlapping)
        for milliseconds in [0, 999, 1000, 2500, 5000, 5500] {
            XCTAssertEqual(fallback.activeID(at: milliseconds),
                           overlapping.first { milliseconds >= $0.startMS && milliseconds < $0.endMS }?.id,
                           "重叠段落必须保持逐段首匹配：\(milliseconds)")
        }
        let ticks = (0..<3000).map { ($0 * 137) % (4000 * 3000) }
        let clock = ContinuousClock()
        var linearWork = 0, windowWork = 0
        let linearDuration = clock.measure {
            for milliseconds in ticks where linear(milliseconds) != nil { linearWork += 1 }
        }
        let windowDuration = clock.measure {
            for milliseconds in ticks where window.activeID(at: milliseconds) != nil { windowWork += 1 }
        }
        XCTAssertEqual(linearWork, windowWork, "两侧定位命中的段落数必须相等")
        print("paragraph highlight: linear=\(seconds(linearDuration))s windowed=\(seconds(windowDuration))s (3000 ticks, 4000 paragraphs)")
        XCTAssertLessThan(windowDuration, linearDuration, "固定窗口段落定位必须快于逐段扫描")
    }

    func testLedgerReviewGateMatchesDecisionScanAndIsFaster() {
        let decisions = (0..<200).map { index in
            RecordingExpressionActionDecision(oldID: "old-\(index)", newID: "", relation: "uncertain",
                                              sourceID: "source", quote: "原话",
                                              possibleNewIDs: (0..<5).map { "new-\(index)-\($0)" })
        }
        var expression = RecordingExpression(id: "expression", sourceIDs: ["source"], title: "标题",
                                             summary: "摘要", reason: "依据", responseIDs: ["response"],
                                             versions: ["source": "t-source"], policies: ["source": 1],
                                             state: "completed", previousActionIDs: [])
        expression.actionReviewDecisions = decisions
        expression.taskReviewPending = true
        let ledger = ActionReviewLedger.build(expression: expression, actionsByID: [:],
                                              resolutions: [], acknowledgements: [], linkedActionIDs: [])
        let checkedIDs = (0..<200).map { "old-\($0)" }
            + (0..<200).flatMap { index in (0..<5).map { "new-\(index)-\($0)" } }
            + ["missing"]
        for actionID in checkedIDs {
            XCTAssertEqual(ledger.requiresReview(actionID: actionID),
                           expression.requiresActionReview(actionID: actionID),
                           "预计算核对门必须与逐条决策扫描一致：" + actionID)
        }
        let timingIDs = (0..<200).map { "old-\($0)" } + ["missing"]
        let clock = ContinuousClock()
        let passes = 200
        var scanned = 0, gated = 0
        let scanDuration = clock.measure {
            for _ in 0..<passes {
                for actionID in timingIDs where expression.requiresActionReview(actionID: actionID) { scanned += 1 }
            }
        }
        let gateDuration = clock.measure {
            for _ in 0..<passes {
                for actionID in timingIDs where ledger.requiresReview(actionID: actionID) { gated += 1 }
            }
        }
        XCTAssertEqual(scanned, gated, "两侧核对命中数必须相等")
        print("ledger review gate: decision-scan=\(seconds(scanDuration))s precomputed=\(seconds(gateDuration))s (\(passes) passes)")
        XCTAssertLessThan(gateDuration, scanDuration, "预计算核对门必须快于逐条决策扫描")
    }

    func testValidContextLinksMatchesStoreFilter() throws {
        let pairing = RecordingContext(personalSourceID: "personal", externalSourceID: "external",
                                       sessionID: "session", offsetMS: 0,
                                       personalVersionID: "t-personal", externalVersionID: "t-external",
                                       personalPolicyVersion: 1, externalPolicyVersion: 1)
        var presentation = RecordingPresentation()
        presentation.recordingContext = pairing
        presentation.contextLinks = [
            link(pairing: pairing, personalReview: 1, externalReview: 1),
            link(pairing: pairing, personalReview: 0, externalReview: 1)
        ]
        let source = record(presentation: presentation)
        let claims = [
            claim(id: "personal-claim", ownership: "user_tentative", reviewVersion: 1, reviewState: "pending"),
            claim(id: "external-claim", ownership: "external", reviewVersion: 1, reviewState: "pending")
        ]
        let claimsByID = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0) })
        let valid = try VoiceOSStore.validContextLinks(source: source, claimsByID: claimsByID, pairing: pairing)
        XCTAssertEqual(valid.count, 1, "只有版本匹配的节目关联可以通过")
        var rejected = claimsByID
        rejected["external-claim"] = claim(id: "external-claim", ownership: "external", reviewVersion: 1, reviewState: "rejected")
        XCTAssertTrue(try VoiceOSStore.validContextLinks(source: source, claimsByID: rejected, pairing: pairing).isEmpty,
                      "被拒绝的节目观点不能保留关联")
        let otherPairing = RecordingContext(personalSourceID: "personal", externalSourceID: "external",
                                            sessionID: "other-session", offsetMS: 0,
                                            personalVersionID: "t-personal", externalVersionID: "t-external",
                                            personalPolicyVersion: 1, externalPolicyVersion: 1)
        XCTAssertTrue(try VoiceOSStore.validContextLinks(source: source, claimsByID: claimsByID, pairing: otherPairing).isEmpty,
                      "配对已变化时旧关联必须失效")
    }

    private func record(presentation: RecordingPresentation) -> SourceRecord {
        SourceRecord(id: "personal", assetID: "asset", name: "材料", state: "saved", kind: "user_text",
                     createdAt: "2026-01-01T00:00:00Z", bytes: 1, duration: nil, jobState: "completed",
                     transcript: "原话", error: nil, relativePath: "assets/personal",
                     transcriptVersionID: "t-personal", transcriptionBackend: nil, spans: [],
                     localOnly: false, policyVersion: 1, origin: "user", speaker: "user",
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil,
                     feedbackRelation: nil, timeZone: "Asia/Shanghai", presentation: presentation)
    }

    private func claim(id: String, ownership: String, reviewVersion: Int, reviewState: String) -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: "理解 " + id, ownership: ownership,
                       evidenceState: "unverified", validity: "current", references: [],
                       reviewVersion: reviewVersion, reviewState: reviewState)
    }

    private func link(pairing: RecordingContext, personalReview: Int, externalReview: Int) -> RecordingContextLink {
        RecordingContextLink(personalClaimID: "personal-claim", externalClaimID: "external-claim",
                             relation: "agreement", explanation: "说明", personalQuote: "我的原话",
                             externalQuote: "节目原话", pairing: pairing, responseIDs: [],
                             personalReviewVersion: personalReview, externalReviewVersion: externalReview)
    }
}
