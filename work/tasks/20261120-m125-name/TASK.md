# 波 125-B：材料名里的原始 ISO 时间戳人间化

基线 `work/m125-name`，工作树 `.worktrees/m125-name`。目标：用户可见的材料名不再出现 `行动反馈 · 2026-10-14T12:28:35Z` 这类机器时间，改为按本地时区显示的 `行动反馈 · 10月14日 20:28`。存储格式保持不变。

## 约束

- 存储名仍由 `Sources/VoiceOSCore/UserExpression.swift:35` 写入 `前缀 + ISO8601`。历史数据、`hasPrefix("行动反馈")` 判断和唯一性都依赖现状，不改写入路径。
- 显示层统一走 `MaterialNaming.displayName`，无法识别的名字原样返回。
- 不运行 `swift build` / `swift test`，集成交给主会话。

## 改动

- 新增 `Sources/VoiceOSCore/MaterialNaming.swift`：识别 `行动反馈 · ` 与 `我的表达 · ` 两个前缀，把其后的完整 ISO8601 时间转为传入时区（默认 `.current`）的 `M月d日 HH:mm`（中文、公历、24 小时制、两位分钟）。支持 `Z`、毫秒、`+08:00` 偏移。解析失败、时间后还有内容、或不是这两个前缀的名字一律原样返回。
- `Sources/VoiceOSApp/WorkspaceView.swift:157`：`displayTitle` 改为先 `MarkdownDocument.plainTitle(raw)` 再 `MaterialNaming.displayName(...)`。搜索材料行（`:1644`）、搜索建议（`:1719`）、材料行等原有调用点随漏斗生效。
- 其余直接显示存储名的位置接入 `MaterialNaming.displayName`：`RecordingTitleEditor.swift:20`、`WorkspaceSourceView.swift:483`、`:545`、`:853`、`QuestionViews.swift:90`、`VoiceOSApp.swift:4920`、`:4933`、`:4974`（检索文档名为 `sources.name`）。

## 未接入与理由

- `VoiceOSApp.swift:2256`、`:2262` 用 `record.name` 生成导出目录，属于文件系统路径，不改。
- `ReflectionTimelineView.swift:49`、`RecentContentHome.swift:651`、`VoiceOSCore/RecentContent.swift:196` 用名字做搜索匹配或 `hasPrefix` 判断，不是显示文本，不改。
- 视图名、模板名、QQ 群名、监测栏目名、实体名、Markdown 文档名属于其他领域，不套用。
- `RecordingTitleEditor` 的 `TextField` 编辑的是 `contentTitle` 而不是存储名，初始值不改。

## 测试

新增 `Tests/VoiceOSCoreTests/MaterialNamingChecks.swift`，固定 `Asia/Shanghai`：两个前缀 × `Z` / 毫秒 / `+08:00`；跨时区换算与跨日；乱码、普通名字、无时间后缀的前缀名原样返回。

## 验证

- `xcrun swiftc` 单文件编译 `MaterialNaming.swift` 加驱动脚本，六种时间形式与边界用例全部通过（不触碰完整构建）。
- `git diff --check` 干净。
- 未运行应用做视觉核对，未 push、未合并。

## 风险

- 其他显示路径若直接读 `sources.name` 而绕过本波清单，仍可能看到原始时间戳；CLI/导出侧不改。
- 显示文案只到分钟，同秒重复的历史条目在显示上无法区分；数据库内仍以完整 ISO 名区分。