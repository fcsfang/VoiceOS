import AppIntents
import AppKit
import Foundation

@MainActor
protocol VoiceOSIntentEndpoint {
    func captureVoiceOSIntent(text: String, title: String?) async -> Bool
    func openTodayActions() -> Bool
    func openSearch() -> Bool
    func toggleDictation() async -> Bool?
}

enum VoiceOSIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case libraryOpening
    case dictationNotReady
    case failed
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "VoiceOS 尚未就绪，请先打开应用一次"
        case .libraryOpening: return "资料库正在打开，请稍后再试"
        case .dictationNotReady: return "当前不能开始口述，请检查麦克风与资料库状态"
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
        guard let endpoint else { throw VoiceOSIntentError.libraryOpening }
        guard await endpoint.captureVoiceOSIntent(text: text, title: title) else { throw VoiceOSIntentError.failed }
        return .result(dialog: "已存入 VoiceOS")
    }
}

struct OpenTodayActionsIntent: AppIntent {
    static let title: LocalizedStringResource = "打开行动列表"
    static let description: IntentDescription = IntentDescription("在 VoiceOS 打开行动列表，包含今天与逾期的任务。")
    static let openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let endpoint = await MainActor.run { NSApp.delegate as? VoiceOSIntentEndpoint }
        guard let endpoint else { throw VoiceOSIntentError.notReady }
        guard await endpoint.openTodayActions() else { throw VoiceOSIntentError.notReady }
        return .result(dialog: "已打开行动列表")
    }
}

struct OpenSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "在 VoiceOS 搜索"
    static let description: IntentDescription = IntentDescription("在 VoiceOS 打开搜索，查找标题、原话、理解或行动。")
    static let openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let endpoint = await MainActor.run { NSApp.delegate as? VoiceOSIntentEndpoint }
        guard let endpoint else { throw VoiceOSIntentError.notReady }
        guard await endpoint.openSearch() else { throw VoiceOSIntentError.notReady }
        return .result(dialog: "已打开 VoiceOS 搜索")
    }
}

struct ToggleDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "开始或停止口述"
    static let description: IntentDescription = IntentDescription("在 VoiceOS 开始或停止一次口述，录音只在本机处理。")
    static let openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let endpoint = await MainActor.run { NSApp.delegate as? VoiceOSIntentEndpoint }
        guard let endpoint else { throw VoiceOSIntentError.dictationNotReady }
        guard let started = await endpoint.toggleDictation() else { throw VoiceOSIntentError.dictationNotReady }
        return .result(dialog: started ? "口述已开始" : "口述已停止")
    }
}
