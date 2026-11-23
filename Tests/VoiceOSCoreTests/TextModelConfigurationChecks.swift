import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

extension CoreFlowTests {
    func test内部模型配置编解码与默认值() {
        let config = TextModelConfiguration(baseURL: "https://api.example.com/v1")
        XCTAssertEqual(config.model, LocalTextModel.defaultModel)
        XCTAssertEqual(config.noteEffort, "high")
        XCTAssertEqual(config.topicEffort, "high")
        let data = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(TextModelConfiguration.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func test内部模型配置校验拒绝空地址与非URL() {
        XCTAssertNil(TextModelConfiguration(baseURL: "  ").validated())
        XCTAssertNil(TextModelConfiguration(baseURL: "not a url").validated())
        XCTAssertEqual(TextModelConfiguration(baseURL: " https://api.example.com/v1 ").validated()?.baseURL,
                       "https://api.example.com/v1")
    }

    func test内部设置构建套件前先校验地址() {
        let settings = LocalTextModel.Settings(address: URL(string: "https://api.example.com/v1")!, key: "k",
                                               model: "gpt-6.2-sol", noteEffort: "xhigh", topicEffort: "medium")
        XCTAssertEqual(settings.model, "gpt-6.2-sol")
        XCTAssertEqual(settings.noteEffort, "xhigh")
        XCTAssertEqual(settings.topicEffort, "medium")
    }
}
