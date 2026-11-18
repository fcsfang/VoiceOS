import XCTest
@testable import VoiceOSCore
@testable import VoiceOSPlatform

final class QQConversationsChecks: XCTestCase {
    func testFixtureFiltersPrivateChatsDeduplicatesAndSortsNewestFirst() throws {
        let fixture = """
        {"version":1,"action":"conversations","count":5,"conversations":[{"conversation_id":"group:1001","conversation_name":"示例班级群","kind":"group","latest_timestamp":1763424000000,"latest_time":"2026-11-18T09:00:00+08:00","message_count":12},{"conversation_id":"c2c:2002","conversation_name":null,"kind":"c2c","latest_timestamp":1763500000000,"latest_time":"2026-11-19T00:00:00+08:00","message_count":3},{"conversation_id":"group:1002","conversation_name":"另一个群","kind":"group","latest_timestamp":1763510000000,"latest_time":"2026-11-19T02:00:00+08:00","message_count":7},{"conversation_id":"group:1001","conversation_name":"示例班级群（重复）","kind":"group","latest_timestamp":1763000000000,"latest_time":"2026-11-17T09:00:00+08:00","message_count":1},{"conversation_id":"dataline:pc","conversation_name":null,"kind":"dataline","latest_timestamp":1763520000000,"latest_time":"2026-11-19T04:00:00+08:00","message_count":2}]}
        """
        let rows = try QQMonitorHelper.decodeConversations(Data(fixture.utf8))
        XCTAssertEqual(rows.map(\.id), ["group:1002", "group:1001"], "只保留群会话、去重并按最新消息倒序")
        XCTAssertEqual(rows[0].name, "另一个群")
        XCTAssertEqual(rows[1].name, "示例班级群", "重复项保留第一次出现的名称")
        XCTAssertEqual(rows[1].messageCount, 12)
        XCTAssertNotNil(rows[0].latestAt)
    }

    func testInvalidConversationPayloadIsRejectedInChinese() {
        XCTAssertThrowsError(try QQMonitorHelper.decodeConversations(Data("{}".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("QQ 群列表"),
                          "无效群列表应给出中文诊断：\(error.localizedDescription)")
        }
    }

    func testSourceConfigParsesStartMarkerAndRejectsPrivateChat() throws {
        let qq = try MonitorSourceConfigParser.qq(
            #"{"conversation_id":"group:1028551617","conversation_name":"南航16院2025级硕士生","start_at":"2026-11-18T09:00:00+08:00"}"#)
        XCTAssertEqual(qq.conversationID, "group:1028551617")
        XCTAssertEqual(qq.conversationName, "南航16院2025级硕士生")
        XCTAssertEqual(qq.startAt, "2026-11-18T09:00:00+08:00")
        XCTAssertThrowsError(try MonitorSourceConfigParser.qq(#"{"conversation_id":"c2c:2002"}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("group:群号"))
        }
        let website = try MonitorSourceConfigParser.website(
            #"{"column_url":"https://cs.nuaa.edu.cn/10851/list.htm","start_at":"2026-11-18"}"#)
        XCTAssertEqual(website.columnURL, "https://cs.nuaa.edu.cn/10851/list.htm")
        XCTAssertThrowsError(try MonitorSourceConfigParser.website(#"{"column_url":"ftp://example.com/list"}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("http"))
        }
    }

    func testStartMarkerParsesDayAndTimestamp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = MonitorSourceConfigParser.parseStart("2026-11-18", calendar: calendar)
        XCTAssertEqual(MonitorSourceConfigParser.dayString(day!, calendar: calendar), "2026-11-18")
        let timestamp = MonitorSourceConfigParser.parseStart("2026-11-18T09:30:00+08:00", calendar: calendar)
        XCTAssertNotNil(timestamp)
        XCTAssertEqual(MonitorSourceConfigParser.dayString(timestamp!, calendar: calendar), "2026-11-18")
        XCTAssertNil(MonitorSourceConfigParser.parseStart(nil))
    }
}
