import XCTest
@testable import VoiceOSCore

private struct NoteResponseTransport: ModelHTTPTransport {
    let body: [String: Any]
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let envelope: [String: Any] = ["status": "completed", "id": "note-response-1",
            "output": [["type": "message", "role": "assistant", "status": "completed",
                        "content": [["type": "output_text", "text": text]]]]]
        return ModelHTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: envelope))
    }
}

final class MaterialNotePortChecks: XCTestCase {
    private func member(_ sourceID: String, _ title: String, version: String? = nil,
                        transcript: String, spans: [(String, String)]) -> MaterialNoteMember {
        MaterialNoteMember(sourceID: sourceID, title: title, transcriptVersionID: version, transcript: transcript,
                           spans: spans.map { MaterialNoteSpan(id: $0.0, text: $0.1) })
    }

    private func port(_ body: [String: Any]) throws -> ResponsesMaterialNotePort {
        try ResponsesMaterialNotePort(baseURL: URL(string: "https://api.openai.com/v1")!,
                                      apiKey: "fixture", model: "fixture-model",
                                      transport: NoteResponseTransport(body: body))
    }

    func test合法JSON解码并保留段落与引文顺序() async throws {
        let members = [
            member("a", "材料甲", version: "ta-v1", transcript: "本来我想把笔记工具做小，后来发现入口比功能更重要。",
                   spans: [("a1", "本来我想把笔记工具做小"), ("a2", "后来发现入口比功能更重要")]),
            member("b", "材料乙", version: "tb-v1", transcript: "先做减法，再考虑加。", spans: [("b1", "先做减法，再考虑加。")])
        ]
        let body: [String: Any] = [
            "title": "入口为什么比功能重要",
            "lead": "一次关于笔记工具取舍的回顾",
            "sections": [
                ["heading": "先做减法", "paragraphs": [
                    ["text": "本来想把工具做小，后来发现入口更关键。",
                     "quotes": [["sourceID": "a", "quote": "入口比功能更重要"],
                                ["sourceID": "b", "quote": "先做减法"],
                                ["sourceID": "b", "quote": "不存在的引文"]]],
                    ["text": "减法不是少做，而是先想清楚顺序。", "quotes": [] as [[String: Any]]]
                ]],
                ["heading": NSNull(), "paragraphs": [
                    ["text": "短内容也可以只有一段。",
                     "quotes": [["sourceID": "a", "quote": "本来我想把笔记工具做小"]]]
                ]]
            ]
        ]
        let note = try await port(body).writeNote(MaterialNoteRequest(members: members))
        XCTAssertEqual(note.title, "入口为什么比功能重要")
        XCTAssertEqual(note.lead, "一次关于笔记工具取舍的回顾")
        XCTAssertEqual(note.sections.count, 2)
        XCTAssertEqual(note.sections[0].heading, "先做减法")
        XCTAssertNil(note.sections[1].heading)
        XCTAssertEqual(note.sections[0].paragraphs.map(\.text),
                       ["本来想把工具做小，后来发现入口更关键。", "减法不是少做，而是先想清楚顺序。"])
        let anchors = note.sections[0].paragraphs[0].anchors
        XCTAssertEqual(anchors.map(\.quote), ["入口比功能更重要", "先做减法"], "不存在的引文在生成时剔除，其余保持模型顺序")
        XCTAssertEqual(anchors.map(\.spanID), ["a2", "b1"] as [String?])
        XCTAssertEqual(anchors.map(\.transcriptVersionID), ["ta-v1", "tb-v1"] as [String?])
        let tail = note.sections[1].paragraphs[0].anchors
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tail.first?.spanID, "a1")
    }

    func test引文锚定精确命中空白归一化与跨片不命中() {
        let wrapped = member("a", "材料甲", transcript: "本来我想把笔记工具做小，\n后来发现入口比功能更重要。",
                             spans: [("a1", "本来我想把笔记工具做小，\n后来发现入口比功能更重要。")])
        XCTAssertEqual(MaterialNoteAnchoring.anchor(quote: "后来发现入口比功能更重要", in: wrapped), "a1")
        XCTAssertEqual(MaterialNoteAnchoring.anchor(quote: "后来发现入口　比功能更重要", in: wrapped), "a1",
                       "全角空格不影响命中")
        XCTAssertEqual(MaterialNoteAnchoring.anchor(quote: "本来我想把笔记工具做小，后来发现", in: wrapped), "a1",
                       "转写换行与引文空格归一化后命中")
        let split = member("a", "材料甲", transcript: "跨片前半后半引文",
                           spans: [("s1", "跨片前半"), ("s2", "后半引文")])
        XCTAssertNil(MaterialNoteAnchoring.anchor(quote: "跨片前半后半引文", in: split), "跨时间片的引文不锚定")
        XCTAssertNil(MaterialNoteAnchoring.anchor(quote: "  \n ", in: wrapped), "纯空白引文不锚定")
    }

    func testanchored剔除未知来源与不存在引文并回填spanID() {
        let members = [
            member("a", "材料甲", version: "ta-v1", transcript: "入口比功能更重要。", spans: [("a-span", "入口比功能更重要。")]),
            member("b", "材料乙", version: "tb-v1", transcript: "先做减法。", spans: [("b-span", "先做减法。")])
        ]
        let note = MaterialNote(title: "标题", lead: "导语", sections: [
            MaterialNote.Section(heading: "其一", paragraphs: [
                MaterialNote.Paragraph(text: "第一段", anchors: [
                    MaterialNote.Anchor(quote: "入口比功能更重要", sourceID: "a"),
                    MaterialNote.Anchor(quote: "先做减法", sourceID: "z"),
                    MaterialNote.Anchor(quote: "这句话不存在", sourceID: "a")
                ]),
                MaterialNote.Paragraph(text: "第二段", anchors: [
                    MaterialNote.Anchor(quote: "先做减法", sourceID: "b")
                ])
            ])
        ])
        let anchored = MaterialNoteAnchoring.anchored(note, members: members)
        XCTAssertEqual(anchored.title, "标题")
        XCTAssertEqual(anchored.lead, "导语")
        XCTAssertEqual(anchored.sections[0].heading, "其一")
        XCTAssertEqual(anchored.sections[0].paragraphs[0].text, "第一段")
        let kept = anchored.sections[0].paragraphs[0].anchors
        XCTAssertEqual(kept.count, 1, "未知来源与不存在的引文被剔除")
        XCTAssertEqual(kept.first?.quote, "入口比功能更重要")
        XCTAssertEqual(kept.first?.sourceID, "a")
        XCTAssertEqual(kept.first?.spanID, "a-span")
        XCTAssertEqual(kept.first?.transcriptVersionID, "ta-v1")
        let second = anchored.sections[0].paragraphs[1].anchors
        XCTAssertEqual(second.first?.spanID, "b-span")
        XCTAssertEqual(second.first?.transcriptVersionID, "tb-v1")
    }

    func test身份包含provider模型与固定版本() throws {
        let port = try ResponsesMaterialNotePort(baseURL: URL(string: "https://api.openai.com/v1")!,
                                                 apiKey: "fixture", model: "fixture-model")
        XCTAssertEqual(port.identity.provider, "responses:api.openai.com")
        XCTAssertEqual(port.identity.model, "fixture-model")
        XCTAssertEqual(port.identity.promptVersion, "material-note-v1")
        XCTAssertEqual(port.identity.schemaVersion, "note-v1")
    }
}
