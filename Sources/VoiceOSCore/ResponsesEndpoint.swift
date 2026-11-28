import Foundation

/// 文本服务地址的唯一授权口径：HTTPS、指定主机、精确 `/v1`，不带用户信息、端口、查询或片段。
/// 端口构造与设置页「测试连接」共用这一处，避免两条路径对同一地址给出不同结论。
public enum TextModelHostPolicy {
    public static let allowedHosts: Set<String> = ["api.openai.com", "api.chiyi.cc"]
    public static func isAllowed(_ baseURL: URL) -> Bool {
        let host = baseURL.host ?? ""
        return baseURL.scheme == "https" && allowedHosts.contains(host)
            && baseURL.absoluteString == "https://" + host + "/v1"
            && baseURL.path == "/v1" && baseURL.query == nil && baseURL.fragment == nil
            && baseURL.user == nil && baseURL.password == nil && baseURL.port == nil
    }
}

/// Validated endpoint and wire request shared by all Swift Responses callers.
package struct ResponsesEndpoint: Sendable {
    package let url: URL
    package let model: String
    package let provider: String
    private let apiKey: String

    package init(baseURL: URL, apiKey: String, model: String) throws {
        guard TextModelHostPolicy.isAllowed(baseURL), let host = baseURL.host,
              !apiKey.isEmpty, apiKey.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              !model.isEmpty else {
            throw VoiceOSError("模型配置须使用已授权的 HTTPS 服务和有效本地凭据")
        }
        url = Self.url(for: baseURL)
        self.model = model
        provider = "responses:" + host
        self.apiKey = apiKey
    }

    /// Candidate address for display. Sending always requires the validated initializer.
    package static func url(for baseURL: URL) -> URL {
        baseURL.appendingPathComponent("responses")
    }

    package func request(body: Data, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
