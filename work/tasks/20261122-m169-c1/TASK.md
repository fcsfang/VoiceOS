# 169-C1 Core 笔记生成端口、提示词与引文锚定

## 背景（产品方向文档第一阶段）
材料详情的核心产物升级为可重读的思考笔记（域模型已于 169-A 落地：`MaterialNote`/`saveMaterialNote` 等）。本单元交付 Core 侧生成契约与 Responses 实现，App 编排由 169-C2 消费。

## 文件清单（只允许动这些）
- 新建 Sources/VoiceOSCore/MaterialNotePort.swift
- 新建 Sources/VoiceOSCore/ResponsesMaterialNotePort.swift
- 新建 Tests/VoiceOSCoreTests/MaterialNotePortChecks.swift

## 契约（签名固定，供 C2 引用）
```swift
public struct MaterialNoteMember: Sendable {
    public let sourceID: String
    public let title: String                 // 材料显示标题
    public let transcriptVersionID: String?
    public let transcript: String
    public let spans: [MaterialNoteSpan]     // 时间片（id/起止毫秒/文本），可为空
}
public struct MaterialNoteSpan: Sendable { public let id: String; public let startMS: Int?; public let endMS: Int?; public let text: String }
public struct MaterialNoteRequest: Sendable {
    public let members: [MaterialNoteMember] // 按表达内顺序
    public let expressionDate: String?       // 可选上下文
}
public struct MaterialNoteAttemptIdentity: Sendable, Equatable {
    public let provider: String; public let model: String
    public let promptVersion: String         // "material-note-v1"
    public let schemaVersion: String         // "note-v1"
}
public protocol MaterialNotePort: Sendable {
    func writeNote(_ request: MaterialNoteRequest) async throws -> MaterialNote
    var identity: MaterialNoteAttemptIdentity { get }
}
public enum MaterialNoteAnchoring {
    /// 把引文锚定到成员的时间片；规范化空白后逐片查找，找不到返回 nil。
    public static func anchor(quote: String, in member: MaterialNoteMember) -> String?
    /// 遍历 note 全部段落锚点，回填 sourceID 校验/transcriptVersion/spanID；不存在的引文剔除。
    public static func anchored(_ note: MaterialNote, members: [MaterialNoteMember]) -> MaterialNote
}
```
- 提示词（中文，写出常量）：整理成一篇愿意重读的个人思考笔记。规则：第一人称；合并口头重复、调整顺序，但保留有辨识度的用词、关键细节、否定、条件与「本来…后来…」的转折；不添加性格判断、诊断、人生建议或行动计划；不编造因果；标题用用户能认出的短问句或短句（≤24 字），避免抽象术语堆叠；可给一行导语；仅在话题/层次/判断变化处分节，小标题短小；短内容可以只有一段；每个段落给出 0-3 条逐字引文 quotes（必须出自成员 transcript，附 sourceID），覆盖整次表达而非开头片段。
- Responses 实现：照 `ResponsesTopicOrganizationPort` 的构造与结构化输出方式（baseURL/apiKey/model/transport/deadline；JSON schema 对应 MaterialNote 形状：title/lead?/sections[{heading?,paragraphs[{text,quotes[{sourceID,quote}]}]}]）；schemaVersion "note-v1"。
- 测试（fixture transport 或纯解析）：1) 合法 JSON 解码并保留顺序；2) 引文锚定：精确命中、空白/换行归一化命中、跨片引文不锚定返回 nil；3) `anchored(_:members:)` 剔除未知 sourceID/不存在引文并回填 spanID；4) 身份 provider/model/promptVersion 正确。

## 约束
- 不写 App 层；不接网络测试；不改 169-A 文件；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse` 真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：最终签名、提示词常量位置、锚定规范化规则、parse 退出码、diff --stat。