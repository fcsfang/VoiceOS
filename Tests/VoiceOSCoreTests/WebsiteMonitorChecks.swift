import XCTest
@testable import VoiceOSCore
@testable import VoiceOSPlatform

final class WebsiteMonitorChecks: XCTestCase {
    private func dayText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func testListDatesParseFromBothColumnMarkups() {
        let csHTML = """
        <div class="page-con-item">
          <a href="/2026/1113/c10851a417793/page.htm">
            <div class="date"><p class="dd">13</p><p class="ym">2026-11</p></div>
            <div class="txt"><h2>【博士答辩】宗辰辰博士答辩公告</h2></div>
          </a>
        </div>
        <div class="page-con-item">
          <a href="/2026/1105/c10851a417000/page.htm">
            <div class="date"><p class="dd">05</p><p class="ym">2026-11</p></div>
            <div class="txt"><h2>关于研究生奖学金评审工作的通知</h2></div>
          </a>
        </div>
        """
        let gradHTML = """
        <ul>
          <li><a href='/2026/1117/c2145a418029/page.htm' target='_blank' title='关于公布中期考核结果的通知'>关于公布中期考核结果的通知</a><span>2026-11-17</span></li>
          <li><a href='/2026/1114/c2145a417893/page.htm' target='_blank' title='2026级硕士研究生学业奖学金评定结果公示'>2026级硕士研究生学业奖学金评定结果公示</a><span>2026-11-14 10:20</span></li>
        </ul>
        """
        let csLinks = MonitorListParser.articleLinks(html: csHTML,
                                                     baseURL: URL(string: "https://cs.nuaa.edu.cn/10851/list.htm")!)
        XCTAssertEqual(csLinks.count, 2, "计算机学院栏目应解析出 2 条条目")
        XCTAssertEqual(dayText(csLinks.first?.publishedAt), "2026-11-13",
                       "计算机学院栏目应把 dd/ym 拆分的日期合并为 2026-11-13")
        XCTAssertEqual(dayText(csLinks.last?.publishedAt), "2026-11-05",
                       "计算机学院栏目应解析出第二位条目的日期并补零为 2026-11-05")

        let gradLinks = MonitorListParser.articleLinks(html: gradHTML,
                                                       baseURL: URL(string: "https://www.graduate.nuaa.edu.cn/2145/list.htm")!)
        XCTAssertEqual(gradLinks.count, 2, "研究生院栏目应解析出 2 条条目")
        XCTAssertEqual(dayText(gradLinks.first?.publishedAt), "2026-11-17",
                       "研究生院栏目应解析条目后兄弟 span 中的日期")
        XCTAssertEqual(dayText(gradLinks.last?.publishedAt), "2026-11-14",
                       "研究生院栏目应解析带时分后缀的日期 2026-11-14 10:20")
    }

    func testArticleDateWinsOverListDateAndFallsBackWhenMissing() async throws {
        let listHTML = """
        <div class="page-con-item">
          <a href="/2026/1110/c10851a400001/page.htm">
            <div class="date"><p class="dd">10</p><p class="ym">2026-11</p></div>
            <div class="txt"><h2>关于研究生奖学金评审工作的通知</h2></div>
          </a>
        </div>
        <div class="page-con-item">
          <a href="/2026/1111/c10851a400002/page.htm">
            <div class="date"><p class="dd">11</p><p class="ym">2026-11</p></div>
            <div class="txt"><h2>关于公布答辩安排的通知公告</h2></div>
          </a>
        </div>
        """
        let articleWithDate = """
        <div class="article"><h3 class="title">关于研究生奖学金评审工作的通知</h3>
        <div class="infoA"><span>时间:2026-11-13</span><span>作者:</span></div>
        <div class="content">学院奖学金评审工作安排如下，请按时提交材料。</div></div>
        """
        let articleWithoutDate = """
        <div class="article"><h3 class="title">关于公布答辩安排的通知公告</h3>
        <div class="content">答辩安排见附件，本页面没有发布时间标记。</div></div>
        """
        let columnURL = URL(string: "https://cs.nuaa.edu.cn/10851/list.htm")!
        let monitor = WebsiteMonitor { url in
            if url.path.contains("list.htm") { return listHTML }
            if url.absoluteString.contains("a400001") { return articleWithDate }
            return articleWithoutDate
        }
        let entries = try await monitor.collect(columnURL: columnURL)
        XCTAssertEqual(entries.count, 2, "正文抓取不应改变条目数量")
        XCTAssertEqual(dayText(entries.first { $0.url.contains("a400001") }?.publishedAt), "2026-11-13",
                       "正文页能解析到发布时间时应优先于列表页日期")
        XCTAssertEqual(dayText(entries.first { $0.url.contains("a400002") }?.publishedAt), "2026-11-11",
                       "正文页没有发布时间时应回退到列表页日期")
    }
}
