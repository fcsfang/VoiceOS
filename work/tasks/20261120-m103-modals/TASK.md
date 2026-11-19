# 波 103-D · 八个弹窗接入 Workspace 组件体系

目标：把八个弹窗与浮条从系统控件外观收拢到 WorkspaceDesign 的词表（按钮三档、页头、卡片、字段表面、宽度 token）。行为、identifier、文案不变，只改八个指定文件。

## 改动

- EnglishPracticeView：去记录英文表达、发送文本反馈改 `workspacePrimary`；准备并核对文字改 `workspaceSecondary`；`WorkspaceHeading` 换 `WorkspacePageHeading`；主弹窗宽度 700 换 `WorkspaceMetrics.modalMedium`。
- FeynmanPractice：小弹窗页标题从 26pt 降到 `WorkspaceText.sectionTitle`，保留 eyebrow；对照原话改 `workspacePrimary`；结果卡从 `controlRadius(8)` 手绘改 `WorkspaceCard(padding: 14)`。
- FullRecordingView：裸 `sectionTitle` 页标题换 `WorkspacePageHeading`；长说明从 body 改 caption secondary；停止处理改 `workspaceDestructive`，关闭改 `workspaceQuiet`；两个主按钮改 `workspacePrimary`；宽度 600 换 `WorkspaceMetrics.modalSmall`。
- TextCaptureView：保存按钮改 `workspacePrimary`，去掉旧 tint；头部导入文字文件、从链接导入正文改 `workspaceSecondary`；标题、模板名称、网页链接输入框统一为 workspace 字段表面（surface + border + 内边距 + `controlRadius`）；保存为模板、管理模板、从链接导入三个子弹窗改 `WorkspaceSectionHeading` + `WorkspaceCard`，宽度 420/480 换 `WorkspaceMetrics.modalSmall`、520 换 `WorkspaceMetrics.modalMedium`。
- QuestionViews：保存状态改 `workspacePrimary`，取消改 `workspaceSecondary`；历史版本两按钮改 `workspaceSecondaryCompact`/`workspaceQuietCompact`；原始 ISO 时间戳改 `formatted(date: .abbreviated, time: .shortened)`；宽度 620 换 `WorkspaceMetrics.modalSmall`。
- QuestionAnswerSection：让 VoiceOS 回答改 `workspacePrimary`；追问与重试改 `workspaceSecondary`；阅读结果改 `workspaceSecondary`，重新回答改 `workspaceQuiet`；三处配置文本模型改 `workspaceQuiet`，不再用 vosFont 覆盖按钮字号。
- SelectionActions：存为问题改 `workspaceSecondary`，复制与回听改 `workspaceQuiet`；浮条圆角 12（`WorkspaceMetrics.panelRadius`），阴影对齐 WorkspaceToast（黑色 0.12、半径 12、y 4）。
- ReminderSettingsView：新增 `WorkspaceSectionHeading("稍后提醒")`，预设按钮改 `workspaceSecondaryCompact`；日期时刻、通知、优先级、地点用 hairline 分组；说明文字统一 meta secondary；取消改 `workspaceSecondary`，保存改 `workspacePrimary`；宽度 590 换 `WorkspaceMetrics.modalSmall`。

## 验证

- `git status` 只显示这八个文件，没有越界修改。
- 八个文件中已无 `.borderedProminent` 与 `.tint(`。
- `swift build -j 2`：`build_exit=0`，`Build complete! (114.47s)`。
- `swift test -j 2`：`test_exit=0`，`Executed 661 tests, with 0 failures (0 unexpected) in 45.364 (45.421) seconds`。
- 构建与测试全程持有 `/tmp/voiceos-swift-build.lock`。

## 未做

- 没有启动应用做视觉走查（硬约束：不重启、不写实时库）。
- 没有 push、合并或开 PR。
- 未改动行为、identifier、文案，未触碰八个文件之外的文件。