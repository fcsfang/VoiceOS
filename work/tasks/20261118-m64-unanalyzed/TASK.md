# 波 64 任务书（2026-11-18）：已采集未分析消息的补分析

## 背景（实机复现 2026-11-18 10:31）

用户开启云端分析授权后点「立即检查」，报告失败，原因文本：

> 检查未完成：上次检查的原文标识已被新的采集覆盖，无法只重分析；请等待下一次每日检查

链路还原：今早 08:10 自动检查采集 38 条官网通知后因未授权停在分析前；10:31 手动检查重新采集（URL 去重，无新行），覆盖了游标里的 `last_run_message_ids`（现为空），`retryAnalysis` 因找不到上次分析的原文标识而失败。结果：已采集的 38 条永远无法分析，只能等下一次采集产生新行才顺带分析，这正是单元 B 自报遗留的 `retryAnalysis` 风险，现已实锤为用户可见死胡同。

同时违反任务书两条硬性要求：「模型失败不能丢掉已采集原文」「推送失败不能让下一次跳过未送达的报告」。

## 完成判据

1. schema 76：`monitor_messages` 增加 `analyzed_report_id TEXT`（NULL = 未分析），迁移幂等；Database 版本上限与 TestSchema 同步为 76。不要改既有列语义。
2. 分析输入改为「未分析消息」：runner 每次检查对启用来源取 `analyzed_report_id IS NULL` 的消息作为分析输入（与本次新采集的合并，不重复），不再依赖游标里的 `last_run_message_ids`。
3. 分析成功（applyMonitorAnalysis 落库）后，在同一事务把本次输入消息的 `analyzed_report_id` 标为当前报告 id；分析失败则保持 NULL，下一次检查或「立即检查」重试。
4. 无新采集但有未分析消息时，报告仍要重新分析并更新今日报告（state/headline/items），不是「无新增待办」；全部消息已分析且无新采集时，才是「检查完成，无新增待办」。
5. retryAnalysis 改为按未分析消息工作（去掉对游标的依赖）；旧游标字段保留但不再据此决策。
6. 测试（≤4 个用例，隔离临时库）：采集后分析失败 → 再次运行分析同一批并成功、报告更新、消息标记为已分析；分析成功后再次运行不重复分析同一消息；新的未分析消息与旧的合并分析；全已分析且无新增 → 无新增待办。中文断言消息。
7. `swift build -j 2` / `swift test -j 2` 真实退出码 0；当前 main 592 项测试（波 63 合并后数字随之变化，以合并后的基线为准）。

## 文件所有权

- `Sources/VoiceOSCore/Database.swift`（迁移 76）
- `Sources/VoiceOSCore/MessageMonitor.swift`（查询与标记）
- `Sources/VoiceOSCore/MessageMonitorRunner.swift`（输入选择与事务）
- `Tests/VoiceOSCoreTests/MessageMonitorRunnerChecks.swift` 或新 Checks 文件、`Tests/VoiceOSCoreTests/TestSchema.swift`
- 不碰 UI（WorkspaceMonitorView/MonitorCenter 与波 63 正在改的区域）、提醒同步、官网抓取、主题组织、全景、知识核查、分段理解。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`。
- 绝不读写 ~/Library/Application Support/VoiceOS；测试隔离临时库。
- 分支 `work/m64-unanalyzed`，提交回报；不 push、不合并、不重启应用。
- 迁移号与并行分支协调：当前无其他迁移在途；若发现 76 被占，顺延并说明。

## 结果

- 分支：work/m64-unanalyzed（基于 main 0164625；构建前 merge main，结果为「已经是最新的」，期间无波 63 合入）。
- schema 76：monitor_messages 增加 analyzed_report_id TEXT（NULL=未分析）；迁移幂等（列存在检查 + IF NOT EXISTS 索引 + 版本号在同一事务落账）；Database 版本上限与 TestSchema 同步 76。已确认全仓库无其他分支占用 76。
- 分析输入改为启用来源中 analyzed_report_id IS NULL 的消息：采集写入后取一次未分析集合，本次新采集与历史积压自然合并、不重复；不再读取游标 last_run_message_ids 做决策（字段保留，advanceMonitorCursor 照旧写入）。
- 分析成功在 applyMonitorAnalysis 同一事务内把本次输入消息标记 analyzed_report_id=当前报告 id；分析失败保持 NULL，下一次检查或「立即检查」重试。图片/附件占位消息同等对待（按 kind != text/article 标记 needsReview，输入选择一致）。
- 无新采集但有未分析消息：照常执行分析并更新今日报告（state/headline/summary/items）；全部已分析且无新采集时才是「检查完成，无新增待办」。retryAnalysis 同样按未分析消息工作并标记。
- 测试：新增 4 个用例（分析失败后再次检查补分析同一批并成功且消息标记；成功后不重复分析；新旧未分析消息合并送分析；全已分析无新增 → 无新增待办），中文断言，隔离临时库；全套 596 项 0 失败，8 个原有监控用例全部保持通过。
- 验证：merge_exit=0 build_exit=0 test_exit=0（swift build -j 2 / swift test -j 2，全局锁 /tmp/voiceos-swift-build.lock）。
- 遗留风险：迁移后历史库所有旧消息 analyzed_report_id 均为 NULL，升级后首次检查会把全部历史原文一次性送分析（40000 字符分批与合并语义不变）；这是本次死胡同里 38 条消息可补分析的代价，若日后需要收敛可再做历史回填策略，但不能回填掉本次未分析的原文。
