# 波 112-A 工具类子页空态下一步与读取失败分离

基线 1860671，工作树 `.worktrees/m112-a`，分支 `work/m112-a`。只改 `Sources/VoiceOSApp/` 下六个文件：`DiscussionHistoryView.swift`、`OutcomeFollowupView.swift`、`AssistantExecutionView.swift`、`ReflectionTimelineView.swift`、`ReflectionChangeView.swift`、`TaskInitiationView.swift`。

## 修法

1. 讨论历史的失败不再冒充空态。`loadError` 与打开讨论的 `error` 分开；`load()` 开头重置两项状态，失败只写 `loadError`，成功不清空已载入列表之外的空态判断。视图分支顺序改为 loading → 读取失败 → 空态 → 列表，失败区用 `WorkspaceEmptyState` 显示 `InlineFailurePresentation` 的「读取讨论历史失败：原因」并提供「重试」直接重跑 `load()`。打开某条讨论失败仍走底部错误行，文案改为「打开讨论失败：原因」。
2. `DiscussionHistoryView` 的空态没有动作按钮。该视图 init 只有 `model` 与 `close`，没有导航或继续讨论闭包，不臆造依赖；文案改为指向资料页选材料后点「讨论」这一真实入口。
3. 结果跟进、AI 代办、反思时间线、认识对照四个空态改用 `WorkspaceEmptyState`，文案统一为「还没有…」并写明下一步。结果跟进的下一步在行动页完成事项，AI 代办的下一步在行动页任务里点「交给 AI」，两者都没有页面导航闭包，因此不加按钮。认识对照用已有的 `closeView` 闭包提供「返回地图」。反思时间线分别针对搜索无结果、主题无记录、周期无记录给出下一步，周期无记录指向同页上方的范围控件。
4. 启动页删除「还没有可用的个人原话」这个禁用菜单项。无可带入材料时整个「从最近材料带入」菜单隐藏，原位置改为说明「还没有可带入的个人原话；先录制或保存一段由你说出的材料。」；有材料时菜单照常出现。
5. 六个文件的同类失败文案统一走 `InlineFailurePresentation`：委托、读取主题、代办、关联成果、保存报告、继续讨论、归档。空态统一「还没有…」，读取态保持「正在读取…」，终态不强行加按钮。
6. 未改任何 accessibility identifier，未改视觉 token 与布局常量。

## 证据行号（基线 1860671 到现状）

- `DiscussionHistoryView.swift:23-29`（基线）`loading` 之后直接 `previews.isEmpty`，失败时底部红字与空态同时出现；改为 `DiscussionHistoryView.swift:25-35` 的四态分支，失败区带「重试」。
- `DiscussionHistoryView.swift:68-76`（基线）打开失败只写原始状态；改为 `DiscussionHistoryView.swift:76-83` 统一失败文案。
- `DiscussionHistoryView.swift:78-91`（基线）加载函数把失败写进 `error`；改为 `DiscussionHistoryView.swift:85-97` 写 `loadError`，并用 `defer` 收口 loading。
- `OutcomeFollowupView.swift:23-26`（基线）`ContentUnavailableView("暂无…")` 无下一步；改为 `OutcomeFollowupView.swift:24-25`。
- `AssistantExecutionView.swift:152-156`（基线）空态标题不是「还没有…」且未指向真实入口；改为 `AssistantExecutionView.swift:154-155`。
- `AssistantExecutionView.swift:76,89,171,228,243,285` 的失败文案统一为 `InlineFailurePresentation`。
- `ReflectionTimelineView.swift:83-85`（基线）三种空态共用一段描述；改为 `ReflectionTimelineView.swift:84-89` 按搜索、主题、周期分别给下一步。
- `ReflectionChangeView.swift:48-51`（基线）空态无动作；改为 `ReflectionChangeView.swift:49-52`，新增「返回地图」。
- `ReflectionChangeView.swift:52`（基线）错误原样显示；改为 `ReflectionChangeView.swift:54`。
- `TaskInitiationView.swift:118-128`（基线）菜单内禁用按钮表达空态；改为 `TaskInitiationView.swift:118-132` 条件隐藏菜单并给说明。
- `TaskInitiationView.swift:477-479`（基线）归档失败只写原因；改为 `TaskInitiationView.swift:481-483` 带操作名前缀。

## 验证

共享锁循环，工作目录为工作树。首次取得锁，未出现 `LOCK_TIMEOUT`。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 44.968 (45.026) seconds`

## 未做与取舍

- 未驱动真实应用验证，本轮约束是不重启应用；验证止于全量构建与测试。
- 讨论历史、结果跟进、AI 代办的空态没有加动作按钮：三个视图都没有指向目标页面的闭包，加按钮就需要跨文件改 init 与调用方，超出本轮六个文件的范围。
- 认识对照空态的「返回地图」与页头按钮重复，但空态本身需要可见的下一步，保留这处重复。
- `TaskInitiationView.reloadSteps` 与 `reloadArchived` 仍用 `try?` 吞掉读取失败，因为没有对应的失败展示位，未在本轮扩围。
- 未新增或修改 accessibility identifier；未提交推送与合并。