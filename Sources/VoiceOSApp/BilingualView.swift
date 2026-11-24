import Foundation
import SwiftUI
import VoiceOSCore
import VoiceOSPlatform

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
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            HStack {
                Text("译文对照").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("关闭", action: dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
            }
            Label("AI 译文，仅供参考", systemImage: "exclamationmark.triangle")
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
            if excerpt.truncated {
                Text(Bilingual.truncationNotice).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            WorkspaceListDivider()
            content
        }.padding(24).frame(width: WorkspaceMetrics.modalMedium, height: 720)
            .workspaceModalSurface()
            .onChange(of: excerpt.paragraphs) { _, _ in retrying = []; retryFailures = [:] }
    }

    @ViewBuilder private var content: some View {
        if !model.modelConfigured {
            VStack(alignment: .leading, spacing: 12) {
                Text("先在设置中选择文本模型").foregroundStyle(palette.secondaryText)
                Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceSecondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if currentSource.localOnly {
            VStack(alignment: .leading, spacing: 12) {
                Text("这份材料仅本机保存；允许云端处理后才能生成译文。").foregroundStyle(palette.secondaryText)
                Button("允许云端处理", action: allowCloud).buttonStyle(.workspacePrimary).disabled(model.changingPolicy)
                Text("只改变这份文字的处理许可，原始录音仍仅本机。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if currentSource.needsTranscriptionReview {
            VStack(alignment: .leading, spacing: 12) {
                Text("请先完成全文转写校正，再生成译文。").foregroundStyle(palette.secondaryText)
                Button("去更正转写", action: correctTranscript).buttonStyle(.workspaceSecondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let plan = excerpt.isEmpty ? Bilingual.paragraphs(from: currentSource.transcript ?? "", spans: currentSource.spans) : excerpt
            switch phase {
            case .idle:
                VStack(alignment: .leading, spacing: 12) {
                    Text("按需把原文分段翻译成中文；原文、资料库与其他内容不会改变。")
                        .foregroundStyle(palette.secondaryText)
                    Text(sendPreview(plan)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    Button("生成译文", action: generate).buttonStyle(.workspacePrimary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在生成译文…").foregroundStyle(palette.secondaryText)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    WorkspaceNoticeText(message: "生成译文失败：" + message, severity: .danger)
                    Button("重试", action: generate).buttonStyle(.workspaceSecondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .ready:
                VStack(alignment: .leading, spacing: 12) {
                    if excerpt.truncated {
                        Text(sendPreview(excerpt)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        Button("继续下一批", action: continueBatch).buttonStyle(.workspacePrimary)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(excerpt.paragraphs) { paragraph in
                                let translated = translations.indices.contains(paragraph.id) ? translations[paragraph.id] : nil
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(paragraph.text).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let translated {
                                        Text(translated).vosFont(WorkspaceText.body).lineSpacing(5).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Text("这段没有返回译文。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                                        HStack(spacing: 10) {
                                            Button(retrying.contains(paragraph.id) ? "正在重试…" : "重试这一段") { retry(paragraph) }
                                                .buttonStyle(.workspaceQuietCompact)
                                                .disabled(retrying.contains(paragraph.id))
                                            if let failure = retryFailures[paragraph.id] {
                                                Text(failure).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                                            }
                                        }
                                    }
                                }
                                if paragraph.id != excerpt.paragraphs.last?.id { WorkspaceListDivider() }
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
        guard let config = TextModelConfiguration.load(),
              let address = URL(string: config.baseURL) else {
            throw VoiceOSError("先在设置中选择文本模型")
        }
        guard TextModelHostPolicy.isAllowed(address) else {
            throw VoiceOSError("文本服务地址未通过授权校验；请在设置中重新保存")
        }
        guard let key = TextModelKeychain.apiKey(), !key.isEmpty else {
            throw VoiceOSError("钥匙串中的模型密钥不可用；请在设置中重新保存模型配置")
        }
        endpoint = address.appendingPathComponent("responses")
        apiKey = key
        model = config.model
        self.transport = transport
    }

    static var configuredModelName: String? {
        guard let config = TextModelConfiguration.load(),
              let address = URL(string: config.baseURL), TextModelHostPolicy.isAllowed(address),
              let key = TextModelKeychain.apiKey(), !key.isEmpty else { return nil }
        return config.model
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
}
