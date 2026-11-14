import XCTest
@testable import VoiceOSCore

final class UnlinkedReferenceChecks: XCTestCase {
    private func claim(_ id: String, _ statement: String, sourceIDs: [String], validity: String = "current",
                       reviewState: String = "pending") -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: statement, ownership: "user_tentative",
                       evidenceState: "unverified", validity: validity,
                       references: sourceIDs.map { ClaimReference(sourceID: $0, transcriptVersionID: "t-" + $0, spanID: "span-" + $0) },
                       reviewVersion: 1, reviewState: reviewState)
    }

    private func candidates(_ claims: [CandidateClaim], topicTitle: String = "深度工作",
                            sectionTitles: [String] = ["注意力与专注", "休息/恢复"],
                            linked: Set<String> = [], sources: Set<String> = ["s1", "s2"]) -> [CandidateClaim] {
        UnlinkedReferences.candidates(topicTitle: topicTitle, sectionTitles: sectionTitles,
                                      linkedClaimIDs: linked, topicSourceIDs: sources, claims: claims)
    }

    func testSplitsTopicWordsOnChineseAndSlashSeparators() {
        let result = candidates([
            claim("c1", "深度工作很重要", sourceIDs: ["s1"]),
            claim("c2", "专注需要时间", sourceIDs: ["s1"]),
            claim("c3", "A 很重要", sourceIDs: ["s1"]),
        ], topicTitle: "A与深度工作", sectionTitles: ["专注、休息"])
        XCTAssertEqual(result.map(\.id), ["c1", "c2"], "单字片段被丢弃，其余片段按分隔符切分")
    }

    func testEnglishWordsIgnoreCaseAndMatchWholeWords() {
        let result = candidates([
            claim("c1", "DEEP WORK needs focus", sourceIDs: ["s1"]),
            claim("c2", "deep learning", sourceIDs: ["s1"]),
            claim("c3", "start work", sourceIDs: ["s1"]),
            claim("c4", "start", sourceIDs: ["s1"]),
        ], topicTitle: "Deep Work", sectionTitles: [])
        XCTAssertEqual(result.map(\.id), ["c1", "c3", "c2"], "英文按词匹配且忽略大小写，art 不命中 start")
    }

    func testLimitsEachSourceToThreeCandidates() {
        let result = candidates([
            claim("c1", "深度工作1", sourceIDs: ["s1"]),
            claim("c2", "深度工作22", sourceIDs: ["s1"]),
            claim("c3", "深度工作333", sourceIDs: ["s1"]),
            claim("c4", "深度工作4444", sourceIDs: ["s1"]),
        ], topicTitle: "深度工作", sectionTitles: [])
        XCTAssertEqual(result.map(\.id), ["c1", "c2", "c3"], "同一来源最多三条，陈述较短的优先")
    }

    func testExcludesLinkedClaimsAndClaimsOutsideTopicSources() {
        let result = candidates([
            claim("c1", "深度工作A", sourceIDs: ["s1"]),
            claim("c2", "深度工作B", sourceIDs: ["s3"]),
            claim("c3", "深度工作C", sourceIDs: ["s3", "s1"]),
            claim("c4", "深度工作D", sourceIDs: ["s2"]),
        ], topicTitle: "深度工作", sectionTitles: [], linked: ["c1"])
        XCTAssertEqual(result.map(\.id), ["c3", "c4"], "已关联与主题来源之外的原话被排除")
    }

    func testRequiresCurrentAndNotRejectedClaims() {
        let result = candidates([
            claim("c1", "深度工作A", sourceIDs: ["s1"], validity: "frozen"),
            claim("c2", "深度工作B", sourceIDs: ["s1"], reviewState: "rejected"),
            claim("c3", "深度工作C", sourceIDs: ["s1"]),
        ], topicTitle: "深度工作", sectionTitles: [])
        XCTAssertEqual(result.map(\.id), ["c3"], "只保留当前有效且未被拒绝的原话")
    }

    func testSortsByHitCountThenStatementLength() {
        let result = candidates([
            claim("c1", "专注", sourceIDs: ["s1"]),
            claim("c2", "深度工作与专注", sourceIDs: ["s2"]),
            claim("c3", "深度工作", sourceIDs: ["s1"]),
        ], topicTitle: "深度工作", sectionTitles: ["专注"])
        XCTAssertEqual(result.map(\.id), ["c2", "c1", "c3"], "命中主题词多的优先，再按陈述长度升序")
    }

    func testCapsTotalCandidatesAtFive() {
        let result = candidates([
            claim("c1", "深度工作1", sourceIDs: ["s1"]),
            claim("c2", "深度工作2", sourceIDs: ["s1"]),
            claim("c3", "深度工作3", sourceIDs: ["s1"]),
            claim("c4", "深度工作4", sourceIDs: ["s2"]),
            claim("c5", "深度工作5", sourceIDs: ["s2"]),
            claim("c6", "深度工作6", sourceIDs: ["s2"]),
        ], topicTitle: "深度工作", sectionTitles: [])
        XCTAssertEqual(result.map(\.id), ["c1", "c2", "c3", "c4", "c5"], "总数上限五条")
    }

    func testReturnsNothingWithoutTopicWordsOrSources() {
        let pool = [claim("c1", "深度工作", sourceIDs: ["s1"])]
        XCTAssertTrue(candidates(pool, topicTitle: "与", sectionTitles: []).isEmpty)
        XCTAssertTrue(candidates(pool, topicTitle: "深度工作", sectionTitles: [], sources: []).isEmpty)
    }
}
