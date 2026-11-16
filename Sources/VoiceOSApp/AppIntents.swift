import AppIntents
import AppKit
import Foundation

enum DictationOutcome: Sendable {
    case started
    case stopped
    case failed(String)
    case notReady
}

@MainActor
protocol VoiceOSIntentEndpoint {
    func captureVoiceOSIntent(text: String, title: String?) async -> Bool
    func openTodayActions() -> Bool
    func openSearch() -> Bool
    func toggleDictation() async -> DictationOutcome
}

enum VoiceOSIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case libraryOpening
    case dictationFailed(String)
    case failed
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "VoiceOS 尚未就绪，请先打开应用一次"
        case .libraryOpening: return "资料库正在打开，请稍后再试"
        case .dictationFailed(let reason): return "\(reason)"
        case .failed: return "未能存入 VoiceOS，请重试"
        }
    }
}

struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "保存一段文字到 VoiceOS"
    static let description: IntentDescription = IntentDescription("把一段文字存入 VoiceOS 收件箱，只在本机保存。")
    static let openAppWhenRun: Bool = true
    static var parameterSummary: some ParameterSummary {
        Summary("保存 \(\.$text) 到 VoiceOS") {
            \.$title
        }
    }
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
        guard let endpoint else { throw VoiceOSIntentError.notReady }
        switch await endpoint.toggleDictation() {
        case .started: return .result(dialog: "口述已开始")
        case .stopped: return .result(dialog: "口述正在停止，随后核对原件")
        case .failed(let reason): throw VoiceOSIntentError.dictationFailed(reason)
        case .notReady: throw VoiceOSIntentError.notReady
        }
    }
}

struct VoiceOSAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureTextIntent(), phrases: [
            "用 \(.applicationName) 记录一段文字",
            "把文字存入 \(.applicationName)"
        ], shortTitle: "记录文字", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenTodayActionsIntent(), phrases: [
            "在 \(.applicationName) 打开今天的行动",
            "用 \(.applicationName) 看今天要做什么"
        ], shortTitle: "今天的行动", systemImageName: "checklist")
        AppShortcut(intent: OpenSearchIntent(), phrases: [
            "在 \(.applicationName) 搜索",
            "用 \(.applicationName) 查找内容"
        ], shortTitle: "搜索", systemImageName: "magnifyingglass")
        AppShortcut(intent: ToggleDictationIntent(), phrases: [
            "用 \(.applicationName) 开始口述",
            "用 \(.applicationName) 停止口述"
        ], shortTitle: "口述", systemImageName: "mic")
    }
}
