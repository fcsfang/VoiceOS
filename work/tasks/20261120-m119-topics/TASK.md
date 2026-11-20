# 波 119：主题判据与主题页收口

基线 `work/m119-topics`，工作树 `.worktrees/m119-topics`。改动四个文件：新增 `Sources/VoiceOSCore/TopicLevel.swift` 与 `Tests/VoiceOSCoreTests/TopicLevelChecks.swift`；修改 `Sources/VoiceOSApp/WorkspaceView.swift` 与 `Sources/VoiceOSApp/WorkspaceTopicReadingView.swift`。未动数据库与 organize 流程。

## 背景与目标

用户反馈主题页零碎到几乎不用。只读查询真实库：102 个主题中 37 个只有 1 份材料、18 个只有 2 份；达到「≥3 份材料且跨 ≥3 个日期」的仅 23 个；全部为 AI 自动命名，用户自建 0。已与用户定义：主题是反复回到的关切；不满足判据的是线索，不再进入主题页主列表。

## 判据

- `theme`：材料数 ≥ 3 且不同日期数 ≥ 3；或手动创建/改名（`ai_named == 0`，即 `isAIOrganized == false`）。
- `clue`：其余，即材料 < 3，或材料 ≥ 3 但全部集中在 1-2 天。
- 常数在 `TopicLevel.minimumMaterials` 与 `TopicLevel.minimumDistinctDays`，便于以后调整。

## 派生方式

- 材料与日期来自已加载的 `model.workspaceTopicSources[topic.id]` 与 `model.sourcePageIndex.recordsByID` 中的 `SourceRecord.createdAt`，两者在主题页均可用，未触发降级。
- 日期用 `ConversationReflectionFocus.date` 解析，按 `Calendar.current.startOfDay` 去重成不同日期数。
- 最近活跃取最近一份材料的日期；主题没有可解析材料日期时回落 `topic.updatedAt`。
- 无法解析的 `created_at` 会被跳过，可能少算日期；这是当前数据下唯一的降级方向，未改为仅按材料数分级。

## 主题页两区

- 主列表只列 `theme`，按最近材料日期倒序，同日期按标题排序；卡片标题旁保留现有「N 份材料 · N 个小主题」。
- 下方「线索（N）」折叠区列出 `clue`：标题、材料数、最近日期，并写一行「线索会随材料积累成为主题」。
- 主题页搜索过滤同时覆盖主题与线索；搜索非空时线索区自动展开，命中线索可直接找到。全局搜索索引原本就收录全部 `reflection_questions`，未改。
- 空态：没有任何主题但存在线索时提示「还没有达到主题判据的关切」；搜索无匹配时保留「没有匹配的主题」。
- 主题详情对 `clue` 显示 `WorkspaceBadge`「线索」和一行「尚未达到主题判据：至少 3 份材料且跨 3 个日期」；`theme` 不加装饰。
- 页面标题「主题」与 `topics.search` identifier 未改；不做写操作，不加升格按钮。

## 验证

共享锁循环，工作目录 `.worktrees/m119-topics`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码：

- `build_exit=0`
- `test_exit=0`
- `Executed 673 tests, with 0 failures (0 unexpected) in 47.393 (47.458) seconds`
- 代码提交 `058a2b0 feat(topics): 按判据区分主题与线索并收口主题页`

## 未做与取舍

- 未启动应用做目视验收；验证止于全量构建与测试。
- 手动主题当前为 0，判据已支持 `ai_named == 0`，但没有真实样本可验。
- 搜索过滤状态下线索区由 `filter.isEmpty` 强制展开，折叠按钮无法收起；清空搜索后恢复手动态。
- 日期按本机日历日去重；跨时区或无法解析的时间戳可能少算一天。
- 全景等其他消费仍读取全部主题，本次只收口主题页；主题页主列表以外的入口未改。
- 升格按钮与线索积累提示的后续交互留待后续波次。