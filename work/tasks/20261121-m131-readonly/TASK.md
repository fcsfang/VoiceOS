# 131-B 只读库来源标题与应用同源

## 背景

`ReadOnlyLibrary.displayTitle(_:)` 直接返回 manualTitle、原始 AI 标题或存储名。CLI/agent 消费者因此拿到未处理的字符串，例如「行动反馈 · 2026-10-14T12:28:35Z」或带 markdown、句末标点、超过 24 字的 AI 标题。应用侧 `SourceRecord.displayTitle` 已经过 `MaterialTitleText.normalizedGenerated` 与 `MaterialNaming.displayName`。两边应给出同一个标题。基线 b0ba3ac。

## 改法

- manualTitle 去首尾空白后非空则原样返回，不改写用户原文。
- automatic.title 先过 `MaterialTitleText.normalizedGenerated`，返回非 nil 即采用；空或仅标点的标题落回下一步。
- 其余情况返回 `MaterialNaming.displayName(name)`。只读库不读转写，不做正文派生，保持请求轻量。
- 未套 `MarkdownDocument.plainTitle`。应用漏斗中它包在 `SourceRecord.displayTitle` 外层，只剥存储名开头的 `#`；本任务给出的期望值是 `MaterialNaming.displayName(name)`，别名回退保持这一形状，AI 标题已由 `normalizedGenerated` 去 markdown。手工标题开头带 `#` 的存量记录与 `SourceRecord.displayTitle` 行为一致，不额外改写。
- 其余行为、CLI 输出结构、SQL 查询不动。

## 测试

`Tests/VoiceOSCoreTests/ReadOnlyLibraryChecks.swift` 新增 `testDisplayTitleMatchesApplicationPresentationFunnel`：

- presentation_json 含带首尾空白的 manualTitle，返回去空白后的原文。
- automatic.title 带 markdown 与句号且超过 24 字，返回截断加省略号的收紧文本。
- 无 presentation、name 为「行动反馈 · 2026-10-14T12:28:35Z」，返回 `MaterialNaming.displayName` 现算的人间化文本，不写死时区。
- 普通 name 原样返回。
- 断言走 `library.actions` 的 `sourceTitle`，即 CLI 消费者看到的字段。

## 风险

- automatic.title 不再按 `transcriptVersionID` 是否过期做门控：只读库本就不读转写版本，旧标题现在会被采用并收紧。若存量 presentation 的 automatic 对应旧转写，标题可能与应用的正文派生标题不同。记录在此，供后续决定是否读 `transcriptVersionID`。
- 按约定未运行 swift build / swift test，由主会话集成验证。