# 130-A 搜索索引改用显示标题，AI 标题可搜

## 背景

搜索索引把材料标题写成原始存储名 `s.name`，界面却显示 `SourceRecord.displayTitle`。只读查库实测：搜「多智能体协作」「个人目标」这类 AI 标题 0 命中；搜「10月14日」0 命中，只能搜到看不见的 ISO 串。用户看到什么，就该搜到什么。基线 c0c6522。

## 改法（零 schema）

- `rebuildSearchIndex()` 取 `sources()` 建 id → 标题映射。标题按 WorkspaceView 行标题同一条链生成：`MaterialNaming.displayName(MarkdownDocument.plainTitle(source.displayTitle))`。AI 标题、手动标题、录音日期、正文派生标题与人间化存储名因此与列表完全一致。
- 原始 `s.name` 并入 body（转写聚合之前），ISO 时间戳与文件名继续可检索，兼容旧查询。
- `searchIndexShape` 改为 `cjk-spaced-v1-titled-<TimeZone.current.identifier>`。存量库首次查询因 shape 不符自动全量重建；时区变化也会重建。
- `ensureSearchTriggers()` 的 sources 触发列加入 `presentation_json`。重命名与生成标题都写这一列，索引下一次查询刷新。其余列（followup_json、policy_version、行动状态与性质）仍不置脏。
- `WorkspaceView` 材料搜索结果直接使用 `hit.title`，去掉二次 `displayTitle(...)` 包裹。claim/topic/action 行不动。

## 测试

`Tests/VoiceOSCoreTests/SearchIndexChecks.swift` 新增：

- 有 automatic.title 的材料按显示标题关键词可搜到，`hit.title` 即显示标题。
- 「行动反馈 · ISO」按 `MaterialNaming` 生成的人间化日期（如「10月14日」）可搜到，期望值由 `MaterialNaming.displayName` 现算，不写死时区。
- 原始 ISO 串仍可由 body 命中。
- `renameRecording` 后不手动重建，下一次查询即命中新标题（验证脏触发器与 shape）。
- 既有脏语义测试改为：`followup_json` 与 `policy_version` 不置脏，`presentation_json` 置脏。

## 风险

- 标题列现在是人间化文本；任何直接读 `search_index.title` 的旧消费者会看到显示态而不是存储名。已核对 App 只在 WorkspaceView 渲染，CLI 未走搜索。
- 重建多了 `sources()` 一次全表读（当前 89 条），重建本就在查询前按脏/形状/指纹触发，频率不变。
- 存量 `presentation_json` 需能解码成 `RecordingPresentation`；所有写入路径均经 JSONEncoder，未发现部分写入。
- 按约定未运行 swift build / swift test，由主会话集成验证。