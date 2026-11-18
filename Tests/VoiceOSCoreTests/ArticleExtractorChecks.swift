import XCTest
import Foundation
import VoiceOSPlatform

final class ArticleExtractorChecks: XCTestCase {
    private let base = URL(string: "https://example.com/read")!

    func testStripsHiddenBlocksAndReadsTitle() throws {
        let html = """
        <html><head><title>标题 &amp; 副题</title><style>.hidden { display: none }</style></head>
        <body>
        <script>var secret = "脚本内容不应出现";</script>
        <noscript>无脚本提示</noscript>
        <svg><text>图形文字</text></svg>
        <iframe src="https://example.com/frame">框架文字</iframe>
        <p>第一段正文说明这篇文章的主题、背景与主要观点，用于验证正文抽取、段落保留和标签清理是否稳定可靠。</p>
        <p>第二段正文继续补充细节，确保总长度明显超过八十个字，覆盖隐藏区块剥离与正文换行保留的场景。</p>
        </body></html>
        """
        let article = try XCTUnwrap(ArticleExtractor.extract(html: html, baseURL: base))
        XCTAssertEqual(article.title, "标题 & 副题")
        XCTAssertTrue(article.text.contains("第一段正文"))
        XCTAssertTrue(article.text.contains("第二段正文"))
        XCTAssertFalse(article.text.contains("脚本内容"))
        XCTAssertFalse(article.text.contains("无脚本提示"))
        XCTAssertFalse(article.text.contains("图形文字"))
        XCTAssertFalse(article.text.contains("框架文字"))
        XCTAssertFalse(article.text.contains("display: none"))
    }

    func testDecodesCommonEntities() throws {
        let html = """
        <html><body><p>&amp; &lt; &gt; &quot; &#39; &#20320; 都应在正文中解码后出现。</p>
        <p>填充正文用于通过长度检查，说明实体解码覆盖命名实体和数字实体，并且确认解码后不会残留分号编码。</p>
        <p>第三段补充正文，确保整体长度超过八十个字，覆盖命名实体和数字实体的解码路径。</p></body></html>
        """
        let article = try XCTUnwrap(ArticleExtractor.extract(html: html, baseURL: base))
        XCTAssertTrue(article.text.contains("& < > \" ' 你"))
        XCTAssertFalse(article.text.contains("&amp;"))
    }

    func testPreservesParagraphBreaks() throws {
        let html = """
        <p>第一段正文内容，用于确认段落之间保留换行而不是合并成一行，同时确保正文长度足够通过八十个字的检查。</p>
        <p>第二段正文内容，用于确认抽取结果按段落分行，读者仍然能看出原文结构，而不是一段连续的文本。</p>
        """
        let article = try XCTUnwrap(ArticleExtractor.extract(html: html, baseURL: base))
        let lines = article.text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("第一段正文"))
        XCTAssertTrue(lines[1].hasPrefix("第二段正文"))
    }

    func testRejectsBodyUnderEightyCharacters() {
        let html = "<html><head><title>短</title></head><body><p>只有这一行很短的正文。</p></body></html>"
        XCTAssertNil(ArticleExtractor.extract(html: html, baseURL: base))
    }

    func testFallsBackToHostWhenTitleIsMissing() throws {
        let html = """
        <html><body><p>没有标题的正文也需要一个来源标题，这里填充足够多的文字，确保正文长度超过八十个字并且能够被抽取出来。</p>
        <p>第二段继续补充内容，让正文长度稳定超过阈值，覆盖标题回退到来源域名的场景。</p></body></html>
        """
        let article = try XCTUnwrap(ArticleExtractor.extract(html: html, baseURL: base))
        XCTAssertEqual(article.title, "example.com")
    }

    func testDropsNavigationAndBreadcrumbLinkLines() throws {
        let html = """
        <html><head><title>关于2026级研究生学业奖学金评审工作的通知</title></head>
        <body>
        <div class="top_nav"><a href="/">后台管理</a> <a href="/">首页</a> <a href="/jgsz/list.htm">机构设置</a> <a href="/yjyjj/list.htm">研院简介</a> <a href="/lsyg/list.htm">历史沿革</a> <a href="/xrzl/list.htm">现任领导和分工</a></div>
        <div class="pc_nav"><a href="/yjyjg/list.htm">研院机构和职责</a> <a href="/lxfs/list.htm">联系方式</a> <a href="/yzxx/list.htm">院长信箱</a> <a href="/zsgz/list.htm">招生工作</a></div>
        <div class="crumbs"><a href="/">首页</a> &gt; <a href="/2145/list.htm">通知公告</a></div>
        <div class="pageR_article"><div class="infoA"><div class="con">
        <p>各学院、各位研究生：根据学校奖学金评审工作安排，现就2026级硕士研究生学业奖学金评审有关事项通知如下。</p>
        <p>请各学院于2026年11月25日前完成材料审核与结果公示，并将汇总表报送研究生院，逾期不再受理。</p>
        </div></div></div>
        <div class="article_attach"><a href="/attach/2026/baomingbiao.docx">附件：报名表.docx</a></div>
        </body></html>
        """
        let article = try XCTUnwrap(ArticleExtractor.extract(html: html, baseURL: base))
        XCTAssertFalse(article.text.contains("后台管理"), "站点导航行应整行丢弃")
        XCTAssertFalse(article.text.contains("机构设置"), "站点导航行应整行丢弃")
        XCTAssertFalse(article.text.contains("院长信箱"), "站点导航行应整行丢弃")
        XCTAssertFalse(article.text.contains("通知公告"), "面包屑行应整行丢弃")
        XCTAssertTrue(article.text.contains("各学院、各位研究生"), "正文段落应保留")
        XCTAssertTrue(article.text.contains("2026年11月25日"), "正文段落应保留")
        XCTAssertTrue(article.text.contains("附件：报名表.docx"), "单链接附件行应保留")
    }

    func testKeepsSingleLinkLine() throws {
        let html = """
        <p>请下载并填写以下材料，于2026年11月25日前交至研究生院培养办公室，联系人王老师，联系电话025-84892400，电子版发送至邮箱 yjsy@nuaa.edu.cn。</p>
        <p><a href="/attach/2026/baomingbiao.docx">报名表.docx</a></p>
        """
        let article = try XCTUnwrap(ArticleExtractor.extract(html: html, baseURL: base))
        XCTAssertTrue(article.text.contains("报名表.docx"), "单链接行即使锚文本占满整行也应保留")
        XCTAssertTrue(article.text.contains("联系人王老师"), "正文段落应保留")
    }

    func testKeepsPlainTextLinesWithoutAnchors() throws {
        let html = """
        <p>本通知不包含任何链接，正文中的百分号 60% 与尖括号说明 &lt;示例&gt; 都应原样保留，不被链接主导行过滤误伤。</p>
        <p>第二段继续补充说明，确保正文总长度稳定超过八十个字，覆盖无锚文本行经过哨兵清理后原样输出的路径。</p>
        """
        let article = try XCTUnwrap(ArticleExtractor.extract(html: html, baseURL: base))
        XCTAssertTrue(article.text.contains("60%"), "无锚文本行的普通文字应保留")
        XCTAssertTrue(article.text.contains("<示例>"), "实体解码后的尖括号应保留")
    }
}
