import XCTest
@testable import VoiceOSCore

extension CoreFlowTests {
    func testOldTopicSummaryWithoutDomainDecodesAsNil() throws {
        let json = #"{"summary":"在谈充电匹配","questions":[],"sourceVersions":{},"policyVersions":{},"responseID":"r1"}"#
        let summary = try JSONDecoder().decode(TopicOrganizationSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.domain)
    }

    func testTopicDomainNormalizationAcceptsOnlyKnownNames() {
        XCTAssertEqual(TopicDomain.normalized("爱情"), "爱情")
        XCTAssertEqual(TopicDomain.normalized(" 职业 "), "职业")
        XCTAssertNil(TopicDomain.normalized("工作"))
        XCTAssertNil(TopicDomain.normalized(""))
        XCTAssertNil(TopicDomain.normalized(nil))
    }

    func testSkeletonTopicDecodesDomainWhenPresent() throws {
        let json = #"{"topicID":"t1","title":"如何安排职业转型","summary":"在谈转型","viewpointIDs":["v1"],"domain":"职业"}"#
        let topic = try JSONDecoder().decode(TopicSkeletonTopic.self, from: Data(json.utf8))
        XCTAssertEqual(topic.domain, "职业")
    }
}
