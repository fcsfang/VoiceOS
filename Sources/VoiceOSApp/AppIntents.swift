import AppIntents
import AppKit
import Foundation

@MainActor
protocol VoiceOSIntentEndpoint {
    func captureVoiceOSIntent(text: String, title: String?) async -> Bool
}

enum VoiceOSIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case failed
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "VoiceOS 尚未就绪，请先打开应用一次"
        case .failed: return "未能存入 VoiceOS，请重试"
        }
    }
}

struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "保存一段文字到 VoiceOS"
    static let description: IntentDescription = IntentDescription("把一段文字存入 VoiceOS 收件箱，只在本机保存。")
    static let openAppWhenRun: Bool = true
    @Parameter(title: "文字")
    var text: String
    @Parameter(title: "标题")
    var title: String?
    init() {}
    init(text: String, title: String? = nil) {
        self.text = text
        self.title = title
    }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let endpoint = await MainActor.run { NSApp.delegate as? VoiceOSIntentEndpoint }
        guard let endpoint else { throw VoiceOSIntentError.notReady }
        guard await endpoint.captureVoiceOSIntent(text: text, title: title) else { throw VoiceOSIntentError.failed }
        return .result(dialog: "已存入 VoiceOS")
    }
}
