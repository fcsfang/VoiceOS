import Foundation
import SwiftUI
import VoiceOSCore

enum BilingualPhase: Equatable {
    case idle, loading, ready, failed(String)
}

struct BilingualView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    let excerpt: BilingualExcerpt
    let translations: [String?]
    let phase: BilingualPhase
    let generate: () -> Void
    let continueBatch: () -> Void
    let retryParagraph: (BilingualParagraph) async -> Bool
    let allowCloud: () -> Void
    let correctTranscript: () -> Void
    let dismiss: () -> Void
    @State private var retrying: Set<Int> = []
    @State private var retryFailures: [Int: String] = [:]

    private var currentSource: SourceRecord { model.records.first { $0.id == source.id } ?? source }
    private func sendPreview(_ plan: BilingualExcerpt) -> String {
        let characters = plan.paragraphs.reduce(0) { $0 + $1.text.count }
        let target = BilingualClient.configuredModelName.map { "已配置模型（" + $0 + "）" } ?? "已配置模型"
        return "将发送前 \(plan.paragraphs.count) 段、约 \(characters) 字到" + target + "，可能产生费用。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("译文对照").vosFont(WorkspaceText.sectionTitle)
                Spacer()
                Button("关闭", action: dismiss)
            }
            Label("AI 译文，仅供参考", systemImage: "exclamationmark.triangle")
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
            if excerpt.truncated {
                Text(Bilingual.truncationNotice).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            }
            Divider()
            content
        }.padding(24).frame(width: WorkspaceMetrics.modalMedium, height: 720)
            .onChange(of: excerpt.paragraphs) { _, _ in retrying = []; retryFailures = [:] }
    }

    @ViewBuilder private var content: some View {
        if !model.modelConfigured {
            VStack(alignment: .leading, spacing: 12) {
                Text("先在设置中选择文本模型").foregroundStyle(.secondary)
                Button("配置文本模型…") { model.chooseTextModel() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if currentSource.localOnly {
            VStack(alignment: .leading, spacing: 12) {
                Text("这份材料仅本机保存；允许云端处理后才能生成译文。").foregroundStyle(.secondary)
                Button("允许云端处理", action: allowCloud).buttonStyle(.borderedProminent).disabled(model.changingPolicy)
                Text("只改变这份文字的处理许可，原始录音仍仅本机。").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if currentSource.needsTranscriptionReview {
            VStack(alignment: .leading, spacing: 12) {
                Text("请先完成全文转写校正，再生成译文。").foregroundStyle(.secondary)
                Button("去更正转写", action: correctTranscript)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let plan = excerpt.isEmpty ? Bilingual.paragraphs(from: currentSource.transcript ?? "", spans: currentSource.spans) : excerpt
            switch phase {
            case .idle:
                VStack(alignment: .leading, spacing: 12) {
                    Text("按需把原文分段翻译成中文；原文、资料库与其他内容不会改变。")
                        .foregroundStyle(.secondary)
                    Text(sendPreview(plan)).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                    Button("生成译文", action: generate).buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在生成译文…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    WorkspaceNoticeText(message: "生成译文失败：" + message, severity: .danger)
                    Button("重试", action: generate)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .ready:
                VStack(alignment: .leading, spacing: 12) {
                    if excerpt.truncated {
                        Text(sendPreview(excerpt)).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        Button("继续下一批", action: continueBatch).buttonStyle(.borderedProminent)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(excerpt.paragraphs) { paragraph in
                                let translated = translations.indices.contains(paragraph.id) ? translations[paragraph.id] : nil
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(paragraph.text).vosFont(WorkspaceText.body).foregroundStyle(.secondary).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let translated {
                                        Text(translated).vosFont(WorkspaceText.body).lineSpacing(5).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Text("这段没有返回译文。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                                        HStack(spacing: 10) {
                                            Button(retrying.contains(paragraph.id) ? "正在重试…" : "重试这一段") { retry(paragraph) }
                                                .disabled(retrying.contains(paragraph.id))
                                            if let failure = retryFailures[paragraph.id] {
                                                Text(failure).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                                            }
                                        }
                                    }
                                }
                                if paragraph.id != excerpt.paragraphs.last?.id { Divider() }
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
    }
    private func retry(_ paragraph: BilingualParagraph) {
        guard !retrying.contains(paragraph.id) else { return }
        retrying.insert(paragraph.id)
        retryFailures[paragraph.id] = nil
        Task {
            let succeeded = await retryParagraph(paragraph)
            retrying.remove(paragraph.id)
            if !succeeded { retryFailures[paragraph.id] = "这一段仍没有拿到译文，可稍后再试。" }
        }
    }
}

struct BilingualClient {
    private let endpoint: URL
    private let model: String
    private let apiKey: String
    private let transport: any ModelHTTPTransport

    init(transport: any ModelHTTPTransport = DirectModelHTTPTransport()) throws {
        guard let path = UserDefaults.standard.string(forKey: "voiceos.textModelConfigPath.v1") else {
            throw VoiceOSError("先在设置中选择文本模型")
        }
        let settings = try Self.settings(from: URL(fileURLWithPath: path))
        endpoint = settings.0.appendingPathComponent("responses")
        apiKey = settings.1
        model = settings.2 ?? "gpt-6.1-sol"
        self.transport = transport
    }

    static var configuredModelName: String? {
        guard let path = UserDefaults.standard.string(forKey: "voiceos.textModelConfigPath.v1"),
              let loaded = try? settings(from: URL(fileURLWithPath: path)) else { return nil }
        return loaded.2 ?? "gpt-6.1-sol"
    }

    func translate(_ paragraphs: [BilingualParagraph]) async throws -> [String?] {
        let prompt = Bilingual.requestPrompt(paragraphs: paragraphs, target: Bilingual.target)
        let payload: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 16384,
            "input": [["role": "user", "content": prompt]]
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let reply = try await transport.send(request)
        guard reply.status == 200 else { throw VoiceOSError("文本模型返回 HTTP \(reply.status)") }
        let text = try Bilingual.translationText(from: reply.body)
        return Bilingual.combine(text, paragraphCount: paragraphs.count)
    }

    private static func settings(from file: URL) throws -> (URL, String, String?) {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch { throw VoiceOSError("无法读取文本模型配置") }
        guard data.count <= 16384, let text = String(data: data, encoding: .utf8) else { throw VoiceOSError("文本模型配置无效") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            guard let root = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                  let providers = root["provider"] as? [String: Any],
                  let openAI = providers["openai"] as? [String: Any],
                  let options = openAI["options"] as? [String: Any],
                  let address = (options["baseURL"] as? String).flatMap(URL.init(string:)),
                  let key = options["apiKey"] as? String, !key.isEmpty, key != "REPLACE_LOCALLY" else {
                throw VoiceOSError("文本模型配置缺少连接信息")
            }
            return (address, key, options["model"] as? String)
        }
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "=", maxSplits: 1)
            guard fields.count == 2 else { throw VoiceOSError("文本模型配置无效") }
            values[fields[0].trimmingCharacters(in: .whitespaces)] = try JSONDecoder().decode(String.self, from: Data(fields[1].utf8))
        }
        guard let address = values["OPENAI_BASE_URL"].flatMap(URL.init(string:)),
              let key = values["OPENAI_API_KEY"], !key.isEmpty, key != "REPLACE_LOCALLY" else {
            throw VoiceOSError("文本模型配置缺少连接信息")
        }
        return (address, key, values["OPENAI_MODEL"])
    }
}
