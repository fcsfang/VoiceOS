# 波 102：视觉系统统一（UI 不再像拼装）

## 背景

用户二次反馈：「现在的 UI 还是很杂乱，不像是精心设计过的」。前一阶段解决的是信息取舍（哪些该出现），本波解决视觉语言：同类元素必须长一样，主次必须一眼可辨。

实机审视（pid 17625，2026-11-20）确认的具体病征：

1. 按钮不成体系。`立即检查`、`去设置`、`授权麦克风`、`记录行动意图`、`暂停提醒事项连接` 全是系统默认灰胶囊，一律像禁用；没有主/次/文字按钮层级。
2. 标题不修边幅。URL 材料把 `https://github.com/...` 当 30pt 标题并截断；时间、状态、计数散落在标题周围，字号权重各写各的。
3. 卡片各行其道。圆角 9/12/16 混用，有的有边框有的没有；计数（如「核心要点 1」）直接黏在标题文本里。
4. 侧栏底部裸露「转写疑点 187 · 其他 2」，徽标（行动 6、AI 交付 6 份待读、N 条待办）样式不统一。

## 共享层（已在 main，529b9d4）

- `WorkspaceButtonStyle`：`.workspacePrimary` / `.workspaceSecondary` / `.workspaceQuiet` / `.workspaceDestructive`（及 compact 变体）。主按钮整页至多一个。
- `WorkspaceBadge`：neutral / accent / warning / danger / success 胶囊。
- `WorkspacePageHeading`：eyebrow + 标题 + 说明 + 右侧动作。
- `WorkspaceSectionHeading`：标题 + 计数 + 右侧动作。
- `WorkspaceCard`：统一 surface、16 圆角、hairline、20 内边距。
- `WorkspaceTitleFit.present(_:)`（Core，含测试）：裸 URL 标题拆为可读名称与来源行。

## 单元与文件所有权

| 单元 | 文件 | 范围 |
| --- | --- | --- |
| 102-A 首页 | `Sources/VoiceOSApp/RecentContentHome.swift` | 时间线行、阅读栏标题、卡片节奏（主线程完成） |
| 102-B 材料详情 | `Sources/VoiceOSApp/WorkspaceSourceView.swift` | 页头、URL 标题、卡片、按钮、徽标 |
| 102-C 材料/行动/设置 | `Sources/VoiceOSApp/WorkspaceView.swift` | 三页页头、列表行、筛选页签、设置按钮、侧栏底部 |
| 102-D 消息监测 | `Sources/VoiceOSApp/WorkspaceMonitorView.swift`、`MonitorCenter.swift` | 页头、运行条、报告卡片、设置段按钮 |
| 102-E 主题/全景 | `Sources/VoiceOSApp/WorkspaceTopicReadingView.swift`、`ThoughtPanoramaView.swift` | 页头、按钮、卡片、空状态 |

## 硬约束

- 不改行为、不改标识符（accessibilityIdentifier）、不改键盘与折叠默认值、不动数据层。
- 只用现有令牌（palette、WorkspaceText、WorkspaceMetrics）与新组件；不新增颜色、字号体系。
- 16GB 内存：任一时刻只允许一个 swift build/test，统一用 `/tmp/voiceos-swift-build.lock` 互斥；构建/测试只认真实退出码。
- 不写实时库 `~/Library/Application Support/VoiceOS`；不重启应用；不 push、不合并 main。
- 每个单元在自己的 worktree 分支 `work/m102-<unit>`，写 `work/tasks/20261120-m102-<unit>/TASK.md`，代码 + 记录两次提交。

## 验证

- 每单元：`swift build -j 2` 与 `swift test -j 2` 真实退出码 0，记录测试总数。
- 集成：主线程合并四个分支后一次构建 + 测试，再出 dist、重装、逐页截图验收。