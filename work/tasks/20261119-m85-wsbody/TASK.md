# 波 85 任务书（2026-11-19）：工作台全库扫描与每帧格式化

## 背景（发现者 A 报告 2026-11-19）

- A3：每次 body 求值重算注意力计数与导航角标：对 records、followups、knowledgeReviews、assistantExecutions、processingIntents 多次过滤排序，`workspaceUnfinishedIntents` 对每个 intent 再扫 records；`transcriptReviewPoints` 每条记录 filter+Set；`MonitorItemTally` 每次新建。`WorkspaceView.swift:212-224,547,582-583`、`WorkspaceProcessingView.swift:111-194`、`RecordingPresentation.swift:318-327`、`MonitorCenter.swift:586-589`。这是所有页面的共同底噪。
- A4：行动页每 body 重算 nextStepCounts/ActionRowReads/visibleActions/两次 ActionTimeSurface.build/focusRefreshKey 拼串；每行新建 DateFormatter。`WorkspaceView.swift:1106-1431,1926-1998`、`ActionTimeSurface.swift:72-101`、`ActionRowStatus.swift:58-65`。
- A5：主题页每 body 全量过滤 topicSources/Claims/Actions + 每卡片再过滤 + adjacentTopics 求交。`WorkspaceView.swift:310-325,563-566`、`WorkspaceTopicReadingView.swift:33-93,265-314,384-392,474-476`。
- A13：材料页每 body 跑 5-6 次 materialRows。`WorkspaceView.swift:874-899,928-987,1828-1836`。
- A10：监测 tick 先读库再判断是否该跑。`MonitorCenter.swift:556-580,141-168`。
- B3（体验）：材料行状态只有 6px 色点，无文字无 help。`WorkspaceView.swift:1850-1854,202-204`。

## 完成判据

1. 注意力/角标计数预计算进一次快照（SourcePageIndex 扩展或 ControlCenter 发布值），视图只读；不改变任何角标语义与文案。
2. 行动页：nextStepCounts、ActionTimeSurface、ActionRowReads、focusRefreshKey 每快照一次；DateFormatter/ISO8601DateFormatter 改静态。
3. 主题页：topic→sources/claims/actions 索引化，卡片读传入集合；key 用结构化 Hashable。
4. 材料页 materialRows 每 body 一次（或进快照）；监测 tick 先 decide 后 reload。
5. 材料行状态补短文本（「疑点 N」「在读」等）与 `.help`，不改数据。
6. 行为、文案、标识、键盘零变化；不加迁移；测试 ≤4（中文断言）；build/test 真实退出码 0（基线 621）。
7. 结果给 file:line 与计时对照。

## 文件所有权

`Sources/VoiceOSApp/WorkspaceView.swift`、`WorkspaceProcessingView.swift`、`WorkspaceTopicReadingView.swift`、`MonitorCenter.swift`、`Sources/VoiceOSCore/RecordingPresentation.swift`、`ActionTimeSurface.swift`、`ActionRowStatus.swift`、对应测试。不碰其他文件（尤其 VoiceOSApp.swift、WorkspaceSourceView.swift、RecentContentHome.swift）。

## 约束

16GB：锁 `/tmp/voiceos-swift-build.lock`；先 merge main；不写实时库；不重启应用；不 push、不合并。分支 `work/m85-wsbody`。

## 结果

- 分支：work/m85-wsbody（基于 main 88fd720；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：c9d81cd「perf(工作台): 页面 body 读取索引化，去掉全库扫描与逐帧格式化」。
- 归因：任务书 A3、A4、A5、A13、A10、B3。改动按原报告给出的 file:line 逐处替换；每一项都保留原筛选、排序与文案，并用测试内计时锁定旧路径与新路径的工作量相等。
- 改动（8 个文件，840 增 170 删）：
  - `Sources/VoiceOSCore/RecordingPresentation.swift:363,376,391,435,506,527`：新增 `WorkspaceTranscriptReviewPoint`、`pairedContextSourceID`、`MaterialReadingPage`、`TopicReadingData`、`TopicAdjacency` 与 `UnfinishedProcessingIntents`，把材料行、主题卡片、相邻主题与未完成意图的判定收进纯函数。
  - `Sources/VoiceOSCore/RecordingContext.swift:67-74,138-155,206,210`：`SourcePageIndex` 每次快照预计算疑点材料、材料注意力门槛、下一步计数、行动修订键与主题加载键；暴露已校验的表达索引。
  - `Sources/VoiceOSCore/ActionTimeSurface.swift:5-25,106-107`：`ActionTimeFormatting` 提供静态 ISO 与日期键格式化器，时间面不再逐 due 日期新建。
  - `Sources/VoiceOSApp/WorkspaceProcessingView.swift:69,125,179,271,274,326-328,411,470,479,494,513,522,602,628`：`WorkspaceAttentionSnapshot` 一次取齐疑点、未完成意图、失败跟进、失败知识核查、失败助理执行、分段失败与主题/监测注意力；处理页各段只读该快照，未完成意图改字典查。
  - `Sources/VoiceOSApp/WorkspaceView.swift:24,46,222,577-582,893,914,919,985,1005,1052,1077,1084,1109,1316,1409,1854,1983-1986`：材料页每 body 只建一次 `MaterialReadingPage` 并复用页签计数；主题页一次构建 `TopicReadingData` 传给卡片与回顾；行动页下一步计数与焦点键读索引，时间面每 body 只建一次；主题加载键改为结构化 `Hashable`；材料行状态点补文字与 `.help`；日期格式化器改静态。
  - `Sources/VoiceOSApp/WorkspaceTopicReadingView.swift:10,32-34,39,56-58,85,268-273,304,387,393,465,477`：卡片读传入的材料、观点、行动集合，小主题过滤、相邻主题求交、结果与证据回查改索引读。
  - `Sources/VoiceOSApp/MonitorCenter.swift:6,576-583,645`：监测 tick 先读一行最新报告做 `MonitorSchedule.decide`，只有需要检查时才跑整轮 `reloadMonitorState`；时间文本格式化器改静态。
  - `Tests/VoiceOSCoreTests/WorkspaceBodyReadChecks.swift:83,187,292`：新增 3 项纯逻辑测试，覆盖材料页、主题卡片与注意力/行动索引的一致性和计时。
- 量化对照（测试内计时，5 轮交替取中位数；两侧工作计数由断言锁定相等）：
  - 材料页一次构建（320 份材料、5 个过滤器，含全部页签计数）：直算 24.07 ms → 6.01 ms，约 4.0 倍。
  - 主题卡片集合（240 份材料、200 条观点、60 条行动、6 个小主题）：逐卡片过滤 8.08 ms → 一次索引 1.75 ms（含索引构建），约 4.6 倍。
  - 注意力读取（500 份材料、120 条行动、200 个意图）：逐 body 扫库 28.54 ms → 快照读 0.70 ms，约 40.5 倍。
- 验证：build_exit=0（`swift build -j 2`，36.54 秒）；test_exit=0（`swift test -j 2`），624 项测试 0 失败（基线 621 加新增 3），36.02 秒。构建与测试共用 `/tmp/voiceos-swift-build.lock`，结束后已释放；`git diff --check` 退出码 0；未写实时库、未重启应用、未 push、未合并。
- 判据落点：
  1. 注意力/角标：记录侧疑点与材料门槛进 `SourcePageIndex`；未完成意图改 `recordsByID` 字典查；处理页与侧栏点读同一个 `WorkspaceAttentionSnapshot`。监测未处理数与 AI 交付未读数仍是各自内存数组的一次过滤，没有新增发布字段，因为 `ControlCenter` 在 `VoiceOSApp.swift`，由并行波 m84 持有。
  2. 行动页：`nextStepCounts`、`actionRevisionKey` 进快照；`ActionTimeSurface`、`ActionRowReads` 每 body 各一次；`focusRefreshKey` 读快照；`DateFormatter`/`ISO8601DateFormatter` 全部静态。
  3. 主题页：`TopicReadingData` 一次给齐材料、观点、行动与每小主题切片；卡片读传入集合；相邻主题改倒排索引求交；`topicLoadKey` 用 `TopicLoadKey: Hashable`。
  4. 材料页：`MaterialReadingPage` 每 body 一次，行与页签计数同源；监测 tick 先 decide 后 reload。
  5. 材料行状态：色点旁补「疑点 N」「在读」「已读」短文本，并加 `.help`；未读仍不显示状态点，数据与判定未改。
  6. 行为、文案、标识、键盘未改（除材料行状态文字）；无迁移；新增测试 3 项；build/test 真实退出码 0。
  7. file:line 与计时见上。
- 遗留风险：
  - `workspaceAttentionSnapshot` 仍每 body 构造一次；跨子系统的失败跟进、知识核查、助理执行与分段批次各自只扫自己的数组，没有并入发布值，原因是 `ControlCenter` 在 `VoiceOSApp.swift`。后续若 m84 合并后需要进一步缓存，可在发布值里接一次。
  - `ActionRowReads` 仍每 body 构造；它同时依赖核心快照的 `reminderLinks` 与后到的 `assistantExecutions`，放进 `SourcePageIndex` 会在两段快照之间陈旧。
  - `monitorOpenItemCount` 与 `unreadDeliveryCount` 仍是各自内存数组的一次过滤；`WorkspaceMonitorView` 的 `MonitorItemTally` 也按报告一次。
  - `planCandidates` 与行动列表键盘顺序在打开 sheet 或按键时各建一次 `ActionTimeSurface`，不在 body 热路径。
  - `WorkspaceExternalCompletionBatchSection` 仍按行动查 `reminderLinks` 并建分组，属处理页异常段。
  - 静态 `DateFormatter` 在首次使用时固定当前时区；应用运行中切换系统时区后，日期键格式化要到重启才跟上。ISO 格式化器保持默认 GMT，与原行为一致。
  - 测试计时是隔离 fixture 的 5 轮交替中位数，不能替代实机 sample；协调方可用同一「切页/返回」AX 口径复测材料、主题、行动与处理页。
