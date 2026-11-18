# 波 68 任务书（2026-11-18）：引用上下文与证据正文入分析与界面

## 背景（只读发现 2026-11-18，待波 66/67 合并后启动）

- QQ 消息的 `replyToMessageId`/`replyContext` 已写入 meta（qq_read_range.py:160-164），但分析输入只传 content（MessageMonitorRunner.swift:254-257），证据 UI 只读 meta 的 url/title（MonitorCenter.swift:167-196）。被回复引用的通知前文对模型与用户都不见。
- 证据对象缺消息类型与正文片段：QQ 证据无 URL 时没有任何可核对下一步；网页证据只有标题。
- 波 67 已补 26→forward、2→other 的类型映射与占位；本波把 meta 真正用起来。

## 完成判据

1. 分析输入（NotificationAnalysisInput 的消息项）拼入定长引用上下文：若 meta 含 replyContext，附「（回复：<上下文摘要，截断 80 字>）」；合并转发/语音等 kind 附类型占位。不改变既有提示词版本号之外的语义；若提示词版本需要升级，升为 message-monitor-daily-v2 并在恢复摘要中保持一致。
2. 证据 UI：展开区每条证据显示消息类型（文本/图片/文件/合并转发/语音/网页）与正文片段（截断 120 字，可选中）；QQ 证据显示「QQ 群消息 · 发送人 · 时间」；有 replyContext 时显示一行「引用：…」；网页证据保留「在浏览器打开原文」。
3. 证据数据补字段：MonitorItemEvidence（MonitorCenter.swift）增加 kind 与正文片段（来自 monitor_messages 的 kind/content），由既有查询就地补，不新增表。
4. 既有行为不回归：证据缺失（消息已删）仍显示来源名并可识别「原文未找到」。
5. 测试（≤3 个，纯逻辑）：分析输入拼接引用上下文与类型占位；证据片段截断；缺消息时的降级显示数据。中文断言。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0；基线以合并波 66/67 后的 main 为准（先 merge main）。

## 文件所有权

- `Sources/VoiceOSCore/MessageMonitorRunner.swift`（分析输入拼接）
- `Sources/VoiceOSCore/ResponsesNotificationAnalysisPort.swift`（如需 v2 提示词）
- `Sources/VoiceOSApp/MonitorCenter.swift`（证据字段与拼装）
- `Sources/VoiceOSApp/WorkspaceMonitorView.swift`（证据展示；仅在波 66 合并后的结构上增量）
- 对应测试
- 不碰 QQ 脚本（波 67 领地）、提醒同步、主题组织、全景、知识核查、分段理解；不加迁移。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`；先 merge main。
- 不写实时库；测试隔离临时库。
- 分支 `work/m68-context`，提交回报；不 push、不合并。

## 结果

- 分支：`work/m68-context`（从 main `44e0506` 创建；构建前 merge main，已是最新）
- 提交：`eaee8fc` feat(消息监测): 引用上下文与证据正文进入分析与界面；本结果随后一次 docs 提交
- 验证：`swift build -j 2` exit 0（Build complete 107.95s）；`swift test -j 2` exit 0，607 项测试 0 失败（基线 604 + 本波 3）
- 文件清单：
  - `Sources/VoiceOSCore/MessageMonitorRunner.swift`
  - `Sources/VoiceOSCore/ResponsesNotificationAnalysisPort.swift`
  - `Sources/VoiceOSApp/MonitorCenter.swift`
  - `Sources/VoiceOSApp/WorkspaceMonitorView.swift`
  - `Tests/VoiceOSCoreTests/NotificationAnalysisChecks.swift`
  - `Tests/VoiceOSCoreTests/MonitorEvidenceChecks.swift`
- 判据落点：
  1. `MessageMonitorRunner.notificationInput(for:)` 在正文末尾拼定长标记：图片/文件/合并转发/语音附「（类型：…）」，meta 含 replyContext 时附「（回复：<content 截断 80 字>）」；`analysisInput` 统一走该函数。提示词升级为 `message-monitor-daily-v2`，instructions 说明标记含义并要求 evidence_quote 只引用消息正文；真实端口的身份 pin 在 `NotificationAnalysisChecks` 同步为 v2。仓库没有其他 monitor 身份常量（恢复摘要排除清单与审计不涉及该端口）。
  2. 证据展开区每条显示「类型 · 正文片段」（片段截断 120 字并可选中）；QQ 行「QQ 群消息 · 发送人 · 时间」；有 replyContext 显示「引用：发送人：内容」；网页证据保留标题行与「在浏览器打开原文」。
  3. `MonitorItemEvidence` 增加 kind/excerpt/replyQuote/missing，由 `MonitorEvidenceBuilder` 从既有 `monitorMessages(sourceID:externalIDs:)` 查询结果拼装，meta 只在 Core 解析一次；无新表、无迁移。
  4. 期望 externalID 有任一条查不到时生成 `missing` 记录，UI 显示来源名与「原文未找到」；栏目级引用（externalID 为空）仍显示来源名，不误标缺失。
  5. `MonitorEvidenceChecks` 3 项：分析输入的类型占位与 80 字引用截断、证据 120 字截断与引用行、缺消息降级数据；中文断言。
- 遗留风险：
  - 只有 replyContext 存在时才有引用摘要；replyToMessageId 指向但库未提供 replyContext 的消息仍无前文。
  - 「语音」标签对应脚本 2→other 映射；未来 other 收纳其他类型时标签会不准。
  - 模型若违反提示引用标记文本仍能通过归一化原文校验。
  - App 侧拼装调用点（MonitorCenter）不在测试目标内，Core builder 由测试锁定。
