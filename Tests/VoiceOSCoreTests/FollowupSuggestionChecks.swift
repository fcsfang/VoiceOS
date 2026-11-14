import XCTest
@testable import VoiceOSCore

final class FollowupSuggestionChecks: XCTestCase {
    private func source(_ id: String, title: String) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: "saved", kind: "external_text",
                     createdAt: "2026-11-14T00:00:00Z", bytes: 1, duration: nil, jobState: nil,
                     transcript: title, error: nil, relativePath: "assets/" + id, transcriptVersionID: "t-" + id,
                     transcriptionBackend: nil, spans: [], localOnly: false, policyVersion: 1,
                     origin: "external", speaker: "unknown", feedbackActionID: nil, feedbackActionVersion: nil,
                     feedbackKind: nil, feedbackRelation: nil, timeZone: "Asia/Shanghai", presentation: nil)
    }

    private func claim(_ id: String, statement: String, sourceID: String = "s1", spanID: String? = nil,
                       validity: String = "current") -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: statement, ownership: "user_tentative",
                       evidenceState: "unverified", validity: validity,
                       references: [ClaimReference(sourceID: sourceID, transcriptVersionID: "t-" + sourceID,
                                                   spanID: spanID ?? "span-" + id)],
                       reviewVersion: 1, reviewState: "pending")
    }

    func testNoClaimsReturnsEmpty() {
        XCTAssertTrue(FollowupSuggestions.suggest(claims: [], sources: [source("s1", title: "阅读摘录")]).isEmpty)
    }

    func testSingleClaimReturnsTwoQuestionsWithSourceTitle() {
        let suggestions = FollowupSuggestions.suggest(
            claims: [claim("c1", statement: "检索质量决定笔记价值")],
            sources: [source("s1", title: "阅读摘录")])
        XCTAssertEqual(suggestions.map(\.title), ["问成立条件", "找反例"])
        XCTAssertEqual(Set(suggestions.map(\.id)).count, 2)
        XCTAssertTrue(suggestions.allSatisfy { $0.claimID == "c1" })
        XCTAssertTrue(suggestions.allSatisfy { $0.sourceTitle == "阅读摘录" })
        XCTAssertTrue(suggestions[0].prompt.contains("检索质量决定笔记价值"))
    }

    func testThreeDistinctClaimsCoverAllAngles() {
        let suggestions = FollowupSuggestions.suggest(
            claims: [claim("c1", statement: "检索质量决定笔记价值"),
                     claim("c2", statement: "每周复盘能发现遗漏"),
                     claim("c3", statement: "先写结论再补证据")],
            sources: [source("s1", title: "阅读摘录")])
        XCTAssertEqual(suggestions.map(\.title), ["问成立条件", "找反例", "定下一步"])
        XCTAssertEqual(suggestions.map(\.claimID), ["c1", "c2", "c3"])
    }

    func testSimilarStatementsKeepFirstOnly() {
        let suggestions = FollowupSuggestions.suggest(
            claims: [claim("c1", statement: "检索质量决定笔记价值"),
                     claim("c2", statement: "检索质量决定笔记价值！"),
                     claim("c3", statement: "每周复盘能发现遗漏")],
            sources: [source("s1", title: "阅读摘录")])
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions.map(\.claimID), ["c1", "c3"])
    }

    func testContainedStatementIsTreatedAsDuplicate() {
        let suggestions = FollowupSuggestions.suggest(
            claims: [claim("c1", statement: "检索质量决定笔记价值"),
                     claim("c2", statement: "我认为检索质量决定笔记价值")],
            sources: [source("s1", title: "阅读摘录")])
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertTrue(suggestions.allSatisfy { $0.claimID == "c1" })
    }

    func testAtMostThreeSuggestions() {
        let claims = (1...5).map { claim("c\($0)", statement: "第 \($0) 条不同的判断是这样表述的") }
        let suggestions = FollowupSuggestions.suggest(claims: claims, sources: [source("s1", title: "阅读摘录")])
        XCTAssertEqual(suggestions.count, 3)
        XCTAssertEqual(suggestions.map(\.claimID), ["c1", "c2", "c3"])
    }

    func testClaimsWithoutResolvedSourceOrWithFrozenValidityAreSkipped() {
        let suggestions = FollowupSuggestions.suggest(
            claims: [claim("c1", statement: "来源已经不在讨论里", sourceID: "missing"),
                     claim("c2", statement: "历史判断已经冻结", validity: "frozen"),
                     claim("c3", statement: "检索质量决定笔记价值")],
            sources: [source("s1", title: "阅读摘录")])
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertTrue(suggestions.allSatisfy { $0.claimID == "c3" })
        XCTAssertTrue(suggestions.allSatisfy { $0.sourceTitle == "阅读摘录" })
    }

    func testNoUsableClaimsReturnsEmpty() {
        let suggestions = FollowupSuggestions.suggest(
            claims: [claim("c1", statement: "来源已经不在讨论里", sourceID: "missing"),
                     claim("c2", statement: "历史判断已经冻结", validity: "frozen")],
            sources: [source("s1", title: "阅读摘录")])
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testClaimWithQuoteOutranksSourceOnlyClaim() {
        let suggestions = FollowupSuggestions.suggest(
            claims: [claim("c1", statement: "只有来源没有原话", spanID: ""),
                     claim("c2", statement: "原话与来源都在")],
            sources: [source("s1", title: "阅读摘录")])
        XCTAssertEqual(suggestions.map(\.claimID), ["c2", "c1"])
    }
}
