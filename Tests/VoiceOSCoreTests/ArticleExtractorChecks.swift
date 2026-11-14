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
}
