import XCTest
@testable import VoiceOSCore

final class FollowupSuggestionChecks: XCTestCase {
    private struct MatrixCase {
        let name: String
        let claims: [CandidateClaim]
        let sources: [SourceRecord]
        let titles: [String]
        let claimIDs: [String]
        var sourceTitle: String? = nil
        var promptContains: String? = nil
        var uniqueIDCount: Int? = nil
    }

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

    func testSuggestionMatrix() {
        let sources = [source("s1", title: "阅读摘录")]
        let cases: [MatrixCase] = [
            MatrixCase(name: "no claims", claims: [], sources: sources, titles: [], claimIDs: []),
            MatrixCase(name: "single claim gets two questions",
                       claims: [claim("c1", statement: "检索质量决定笔记价值")],
                       sources: sources,
                       titles: ["问成立条件", "找反例"], claimIDs: ["c1", "c1"],
                       sourceTitle: "阅读摘录", promptContains: "检索质量决定笔记价值", uniqueIDCount: 2),
            MatrixCase(name: "three distinct claims cover all angles",
                       claims: [claim("c1", statement: "检索质量决定笔记价值"),
                                claim("c2", statement: "每周复盘能发现遗漏"),
                                claim("c3", statement: "先写结论再补证据")],
                       sources: sources,
                       titles: ["问成立条件", "找反例", "定下一步"], claimIDs: ["c1", "c2", "c3"]),
            MatrixCase(name: "similar statements keep first only",
                       claims: [claim("c1", statement: "检索质量决定笔记价值"),
                                claim("c2", statement: "检索质量决定笔记价值！"),
                                claim("c3", statement: "每周复盘能发现遗漏")],
                       sources: sources,
                       titles: ["问成立条件", "找反例"], claimIDs: ["c1", "c3"]),
            MatrixCase(name: "contained statement is a duplicate",
                       claims: [claim("c1", statement: "检索质量决定笔记价值"),
                                claim("c2", statement: "我认为检索质量决定笔记价值")],
                       sources: sources,
                       titles: ["问成立条件", "找反例"], claimIDs: ["c1", "c1"]),
            MatrixCase(name: "at most three suggestions",
                       claims: (1...5).map { claim("c\($0)", statement: "第 \($0) 条不同的判断是这样表述的") },
                       sources: sources,
                       titles: ["问成立条件", "找反例", "定下一步"], claimIDs: ["c1", "c2", "c3"]),
            MatrixCase(name: "unresolved or frozen claims are skipped",
                       claims: [claim("c1", statement: "来源已经不在讨论里", sourceID: "missing"),
                                claim("c2", statement: "历史判断已经冻结", validity: "frozen"),
                                claim("c3", statement: "检索质量决定笔记价值")],
                       sources: sources,
                       titles: ["问成立条件", "找反例"], claimIDs: ["c3", "c3"],
                       sourceTitle: "阅读摘录"),
            MatrixCase(name: "no usable claims",
                       claims: [claim("c1", statement: "来源已经不在讨论里", sourceID: "missing"),
                                claim("c2", statement: "历史判断已经冻结", validity: "frozen")],
                       sources: sources, titles: [], claimIDs: []),
            MatrixCase(name: "quote outranks source only claim",
                       claims: [claim("c1", statement: "只有来源没有原话", spanID: ""),
                                claim("c2", statement: "原话与来源都在")],
                       sources: sources,
                       titles: ["问成立条件", "找反例"], claimIDs: ["c2", "c1"]),
        ]
        for c in cases {
            let suggestions = FollowupSuggestions.suggest(claims: c.claims, sources: c.sources)
            XCTAssertEqual(suggestions.map(\.title), c.titles, c.name)
            XCTAssertEqual(suggestions.map(\.claimID), c.claimIDs, c.name)
            if let sourceTitle = c.sourceTitle {
                XCTAssertTrue(suggestions.allSatisfy { $0.sourceTitle == sourceTitle }, c.name)
            }
            if let promptContains = c.promptContains {
                XCTAssertTrue(suggestions[0].prompt.contains(promptContains), c.name)
            }
            if let uniqueIDCount = c.uniqueIDCount {
                XCTAssertEqual(Set(suggestions.map(\.id)).count, uniqueIDCount, c.name)
            }
        }
    }
}
