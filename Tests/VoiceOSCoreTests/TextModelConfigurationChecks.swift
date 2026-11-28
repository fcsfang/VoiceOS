import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

extension CoreFlowTests {
    func test内部模型配置编解码与默认值() {
        let config = TextModelConfiguration(baseURL: "https://api.example.com/v1")
        XCTAssertEqual(config.model, LocalTextModel.defaultModel)
        XCTAssertEqual(config.noteEffort, "high")
        XCTAssertEqual(config.topicEffort, "high")
        XCTAssertEqual(config.reviewEffort, "high")
        let data = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(TextModelConfiguration.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func test内部模型配置旧数据缺少核对强度时按high解码() {
        let legacy = #"{"baseURL":"https://api.example.com/v1","model":"gpt-6.2-sol","noteEffort":"xhigh","topicEffort":"medium"}"#
        let decoded = try! JSONDecoder().decode(TextModelConfiguration.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.model, "gpt-6.2-sol")
        XCTAssertEqual(decoded.noteEffort, "xhigh")
        XCTAssertEqual(decoded.topicEffort, "medium")
        XCTAssertEqual(decoded.reviewEffort, "high")
    }

    func test内部模型配置校验拒绝空地址与非URL() {
        XCTAssertNil(TextModelConfiguration(baseURL: "  ").validated())
        XCTAssertNil(TextModelConfiguration(baseURL: "not a url").validated())
        XCTAssertEqual(TextModelConfiguration(baseURL: " https://api.example.com/v1 ").validated()?.baseURL,
                       "https://api.example.com/v1")
        XCTAssertEqual(TextModelConfiguration(baseURL: "https://api.example.com/v1/").validated()?.baseURL,
                       "https://api.example.com/v1")
    }

    func test内部设置构建套件前先校验地址() {
        let settings = LocalTextModel.Settings(address: URL(string: "https://api.example.com/v1")!, key: "k",
                                               model: "gpt-6.2-sol", noteEffort: "xhigh", topicEffort: "medium")
        XCTAssertEqual(settings.model, "gpt-6.2-sol")
        XCTAssertEqual(settings.noteEffort, "xhigh")
        XCTAssertEqual(settings.topicEffort, "medium")
        XCTAssertThrowsError(try LocalTextModel.loadSuite(settings: settings))
    }

    func test文本服务地址策略只接受授权主机的精确端点() {
        XCTAssertTrue(TextModelHostPolicy.isAllowed(URL(string: "https://api.openai.com/v1")!))
        XCTAssertTrue(TextModelHostPolicy.isAllowed(URL(string: "https://api.chiyi.cc/v1")!))
        XCTAssertFalse(TextModelHostPolicy.isAllowed(URL(string: "http://api.openai.com/v1")!))
        XCTAssertFalse(TextModelHostPolicy.isAllowed(URL(string: "https://api.example.com/v1")!))
        XCTAssertFalse(TextModelHostPolicy.isAllowed(URL(string: "https://api.openai.com/v2")!))
        XCTAssertFalse(TextModelHostPolicy.isAllowed(URL(string: "https://api.openai.com/v1/extra")!))
        XCTAssertFalse(TextModelHostPolicy.isAllowed(URL(string: "https://api.openai.com/v1?x=1")!))
        XCTAssertFalse(TextModelHostPolicy.isAllowed(URL(string: "https://api.openai.com:443/v1")!))
        XCTAssertFalse(TextModelHostPolicy.isAllowed(URL(string: "https://user@api.openai.com/v1")!))
    }
}
