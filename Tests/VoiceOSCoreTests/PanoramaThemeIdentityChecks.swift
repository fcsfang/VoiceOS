import Foundation
import XCTest
@testable import VoiceOSCore

extension CoreFlowTests {
    private struct ThemeQuestion {
        let id: String
        let title: String
        let claims: [String]
        let source: String
        let quote: String
    }
    private struct ThemeRegion {
        let id: String
        let title: String
        let questions: [ThemeQuestion]
    }
    private func themeProposal(_ regions: [ThemeRegion], areas: [PanoramaArea] = []) -> PanoramaProposal {
        PanoramaProposal(
            regions: regions.map { PanoramaRegion(id: $0.id, title: $0.title, summary: "主题摘要 " + $0.id) },
            questions: regions.flatMap { region in
                region.questions.map { question in
                    PanoramaQuestion(id: question.id, regionID: region.id, title: question.title, summary: "问题摘要 " + question.id,
                        evidence: [.init(sourceID: question.source, transcriptVersionID: "t-" + question.source,
                            start: 0, end: question.quote.unicodeScalars.count, quote: question.quote, claimIDs: question.claims)])
                }
            },
            relations: [], unrepresentedSources: [], unrepresentedClaims: [], areas: areas)
    }
    private func themeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-theme-" + name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testPanoramaThemeSchemaReopensAt51() throws {
        let directory = try themeDirectory("schema"), url = directory.appendingPathComponent("voiceos.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        var created: Database? = try Database(url)
        XCTAssertEqual(try created?.query("PRAGMA user_version").first?["user_version"], "51")
        created = nil
        let reopened = try Database(url)
        XCTAssertEqual(try reopened.query("PRAGMA user_version").first?["user_version"], "51")
        for table in ["panorama_themes", "panorama_theme_batches", "panorama_theme_appearances"] {
            XCTAssertEqual(try reopened.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table]).count, 1)
        }
    }

    func testPanoramaThemeAdoptsExistingDraftIDs() throws {
        let regions = (1...44).map { index in
            ThemeRegion(id: "r\(index)", title: "检索条件\(index)",
                questions: [.init(id: "q\(index)", title: "如何保留条件\(index)？", claims: ["c\(index)"], source: "s\(index)", quote: "原话\(index)")])
        }
        let prior = PanoramaThemeMap.make(proposal: themeProposal(regions))
        let result = try PanoramaThemeIdentity.rewrite(themeProposal(regions), attemptID: "adopt", current: nil, prior: prior)
        XCTAssertEqual(result.proposal.regions.map(\.id), (1...44).map { "r\($0)" })
        XCTAssertTrue(result.matches.allSatisfy { $0.kind == .matched }, "全部 44 个草稿主题都应沿用原身份")
    }

    func testPanoramaThemeRephrasedTitleSameClaimsMerges() throws {
        let prior = PanoramaThemeMap.make(proposal: themeProposal([
            .init(id: "p1", title: "检索条件", questions: [.init(id: "q1", title: "如何保留完整条件？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")])
        ]))
        let candidate = themeProposal([
            .init(id: "n1", title: "检索条件的保留", questions: [.init(id: "q2", title: "条件怎么留住？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")])
        ])
        let result = try PanoramaThemeIdentity.rewrite(candidate, attemptID: "rephrase", current: nil, prior: prior)
        XCTAssertEqual(result.proposal.regions.first?.id, "p1")
        XCTAssertEqual(result.matches.first?.kind, .matched)
    }

    func testPanoramaThemeGenericTitleDisjointClaimsDoesNotMerge() throws {
        let prior = PanoramaThemeMap.make(proposal: themeProposal([
            .init(id: "p1", title: "检索条件", questions: [.init(id: "q1", title: "如何核对？", claims: ["c1"], source: "s1", quote: "原话甲")])
        ]))
        let candidate = themeProposal([
            .init(id: "n1", title: "检索条件", questions: [.init(id: "q2", title: "如何核对？", claims: ["c2"], source: "s2", quote: "原话乙")])
        ])
        let result = try PanoramaThemeIdentity.rewrite(candidate, attemptID: "generic", current: nil, prior: prior)
        let regionID = try XCTUnwrap(result.proposal.regions.first?.id)
        XCTAssertNotEqual(regionID, "p1")
        XCTAssertTrue(regionID.hasPrefix("theme-"))
        XCTAssertEqual(result.matches.first?.kind, .new)
    }

    func testPanoramaThemeAmbiguousTopTwoRefusesBoth() throws {
        let prior = PanoramaThemeMap.make(proposal: themeProposal([
            .init(id: "p1", title: "检索条件", questions: [.init(id: "q1", title: "如何保留条件？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")]),
            .init(id: "p2", title: "检索条件", questions: [.init(id: "q2", title: "如何保留条件？", claims: ["c1", "c3"], source: "s1", quote: "原话甲")])
        ]))
        let candidate = themeProposal([
            .init(id: "n1", title: "检索条件", questions: [.init(id: "q3", title: "如何保留条件？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")])
        ])
        let result = try PanoramaThemeIdentity.rewrite(candidate, attemptID: "ambiguous", current: nil, prior: prior)
        let regionID = try XCTUnwrap(result.proposal.regions.first?.id)
        XCTAssertTrue(regionID.hasPrefix("theme-"))
        XCTAssertNotEqual(regionID, "p1")
        XCTAssertNotEqual(regionID, "p2")
        XCTAssertEqual(result.matches.first?.kind, .new)
    }

    func testPanoramaThemeSplitKeepsOneToOne() throws {
        let prior = PanoramaThemeMap.make(proposal: themeProposal([
            .init(id: "p1", title: "检索条件", questions: [.init(id: "q1", title: "如何保留条件？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")])
        ]))
        let candidate = themeProposal([
            .init(id: "n1", title: "检索条件", questions: [.init(id: "q2", title: "如何保留条件？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")]),
            .init(id: "n2", title: "另一个方面", questions: [.init(id: "q3", title: "另外一个问题？", claims: ["c9"], source: "s9", quote: "原话乙")])
        ])
        let result = try PanoramaThemeIdentity.rewrite(candidate, attemptID: "split", current: nil, prior: prior)
        let ids = result.proposal.regions.map(\.id)
        XCTAssertEqual(ids[0], "p1")
        XCTAssertTrue(ids[1].hasPrefix("theme-"))
        XCTAssertEqual(Set(ids).count, 2, "只有一个候选继承旧主题")
    }

    func testPanoramaThemeMergeKeepsOneToOne() throws {
        let prior = PanoramaThemeMap.make(proposal: themeProposal([
            .init(id: "p1", title: "检索条件", questions: [.init(id: "q1", title: "如何保留条件？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")]),
            .init(id: "p2", title: "检索范围", questions: [.init(id: "q2", title: "如何保留条件？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")])
        ]))
        let candidate = themeProposal([
            .init(id: "n1", title: "检索条件", questions: [.init(id: "q3", title: "如何保留条件？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")])
        ])
        let result = try PanoramaThemeIdentity.rewrite(candidate, attemptID: "merge", current: nil, prior: prior)
        XCTAssertEqual(result.proposal.regions.first?.id, "p1", "两个旧主题中只有一个继承")
    }

    func testPanoramaThemeRewriteUpdatesQuestionsAndAreas() throws {
        let quote = "格式核对需要完整原文。"
        let candidate = themeProposal([
            .init(id: "r", title: "检索条件", questions: [.init(id: "q", title: "如何核对？", claims: [], source: "s1", quote: quote)])
        ], areas: [.init(id: "area", title: "全部区域", summary: "", regionIDs: ["r"])])
        let result = try PanoramaThemeIdentity.rewrite(candidate, attemptID: "rewrite", current: nil, prior: nil)
        let regionID = try XCTUnwrap(result.proposal.regions.first?.id)
        XCTAssertNotEqual(regionID, "r")
        XCTAssertEqual(result.proposal.questions.first?.regionID, regionID)
        XCTAssertEqual(result.proposal.areas.first?.regionIDs, [regionID])
        let transcript = ContextTranscript(sourceID: "s1", sourceVersionID: "v1", transcriptVersionID: "t-s1",
            origin: "user", speaker: "user", localOnly: false, text: quote,
            spans: [.init(textStart: 0, textEnd: quote.unicodeScalars.count)])
        let input = PanoramaInput(manifest: .init(digest: "d", sourceIDs: ["s1"], claimIDs: [], unitIDs: ["u"]),
            units: [.init(id: "u", sourceIDs: ["s1"], dependencyIDs: [], producerID: "p", completionDigest: "c")],
            sources: [.init(transcript: transcript, title: "材料", occurredAt: "2026-11-05", policyVersion: 1)],
            claims: [], exclusions: [])
        _ = try VoiceOSStore.validatePanorama(result.proposal, input: input)
    }

    func testPanoramaThemeRewriteIsIdempotent() throws {
        let prior = PanoramaThemeMap.make(proposal: themeProposal([
            .init(id: "p1", title: "检索条件", questions: [.init(id: "q1", title: "如何保留完整条件？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")])
        ]))
        let candidate = themeProposal([
            .init(id: "n1", title: "检索条件的保留", questions: [.init(id: "q2", title: "条件怎么留住？", claims: ["c1", "c2"], source: "s1", quote: "原话甲")])
        ])
        let first = try PanoramaThemeIdentity.rewrite(candidate, attemptID: "idem", current: nil, prior: prior)
        let second = try PanoramaThemeIdentity.rewrite(first.proposal, attemptID: "idem",
            current: PanoramaThemeMap(proposal: first.proposal, attemptID: "idem", phase: .completed), prior: prior)
        XCTAssertEqual(first.proposal.regions.map(\.id), second.proposal.regions.map(\.id))
        XCTAssertEqual(first.proposal.questions.map(\.regionID), second.proposal.questions.map(\.regionID))
        XCTAssertEqual(first.matches.map(\.themeID), second.matches.map(\.themeID))
    }

    func testPanoramaThemeUnitsPhaseNotEligible() {
        let proposal = themeProposal([
            .init(id: "r1", title: "检索条件", questions: [.init(id: "q1", title: "如何核对？", claims: [], source: "s1", quote: "原话甲")])
        ])
        let receipt = PanoramaReceipt(responseID: "r", model: "m", createdAt: "2026-11-05T00:00:00Z")
        let review = PanoramaReview(questions: [], relations: [], coverageAccepted: false, reason: "")
        let input = PanoramaInput(manifest: .init(digest: "", sourceIDs: [], claimIDs: [], unitIDs: []),
            units: [], sources: [], claims: [], exclusions: [])
        let coverage = PanoramaCoverage(submittedSourceIDs: [], submittedClaimIDs: [], representedSourceIDs: [],
            representedClaimIDs: [], unrepresentedSources: [], unrepresentedClaims: [])
        func snapshot(_ workflow: PanoramaWorkflow?) -> PanoramaSnapshot {
            .init(id: "attempt", createdAt: "2026-11-05T00:00:00Z", input: input, proposal: proposal, coverage: coverage,
                generation: receipt, verification: receipt, review: review, workflow: workflow)
        }
        let units = PanoramaWorkflow(phase: .units, verifiedUnitIDs: [], totalUnitCount: 1, receipts: [])
        XCTAssertFalse(PanoramaThemeMap.isEligible(snapshot(units), attemptState: "failed"))
        XCTAssertFalse(PanoramaThemeMap.isEligible(snapshot(nil), attemptState: "failed"))
        XCTAssertTrue(PanoramaThemeMap.isEligible(snapshot(nil), attemptState: "completed"))
        let completed = PanoramaWorkflow(phase: .completed, verifiedUnitIDs: [], totalUnitCount: 1, receipts: [])
        XCTAssertTrue(PanoramaThemeMap.isEligible(snapshot(completed), attemptState: "failed"))
        let draft = PanoramaWorkflow(phase: .synthesis, verifiedUnitIDs: [], totalUnitCount: 1,
            receipts: [.init(stage: "draft.synthesize", scopeID: "all", receipt: receipt)])
        XCTAssertTrue(PanoramaThemeMap.isEligible(snapshot(draft), attemptState: "failed"))
    }
}
