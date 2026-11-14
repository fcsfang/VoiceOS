import Foundation
import VoiceOSCore

public enum WebArticle {
    public static func fetch(url: URL) async throws -> ExtractedArticle {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw VoiceOSError("仅支持 http 或 https 链接")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VoiceOSError("网页返回 \(http.statusCode)，无法导入")
        }
        guard data.count <= 4 * 1024 * 1024 else { throw VoiceOSError("网页超过 4MB，无法导入") }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw VoiceOSError("网页编码无法识别")
        }
        guard let article = ArticleExtractor.extract(html: html, baseURL: url) else {
            throw VoiceOSError("网页正文太少，无法导入")
        }
        return article
    }
}
