# 波 111-C 消息监测读取失败与空态分离

基线 main fa18612，工作树 `.worktrees/m111-c`，分支 `work/m111-c`。只改 `Sources/VoiceOSApp/WorkspaceMonitorView.swift` 与 `Sources/VoiceOSApp/MonitorCenter.swift`。

## 修法

1. 三态加载。视图新增 `MonitorLoadState`（loading/loaded/failed），`monitorLoaded` 改为 `state == .loaded` 的派生值。`reloadMonitorState` 改为返回 Bool（`@discardableResult`），成功才置 `.loaded`，失败置 `.failed`。失败时在今日报告、历史报告、来源状态上方显示 `WorkspaceNoticeText`（danger）与「重新读取」按钮（`monitor.load.retry`），重试直接调用 `reloadMonitorState()`。空态文案只在 `.loaded` 且确实无数据时出现；`.failed` 时三个区块改为「暂时无法读取…」，不再冒充从未检查过。
2. 重试保留缓存。`retryMonitorLoad()` 不重置 `.loading`，不清空 `monitorReports`、`monitorItemsByReport`、`monitorEvidence`，也不整页回 spinner。失败重试后已载入的报告与事项继续渲染。
3. 事项重试不限最新报告。`itemsView` 的 `.failed` 分支对所有报告显示「重新读取」并调用 `loadItems(report)`；最新报告沿用原 identifier `monitor.report.retryItems`，其余报告追加 `.<report.id>`。各报告缓存仍按 report id 独立。
4. 未动视觉样式与卡片，未改任何既有 accessibility identifier。

## 证据行号（基线 fa18612 位置到现状）

- `WorkspaceMonitorView.swift:71-78`（基线）onAppear 无条件 `monitorLoaded = true`，改为 `WorkspaceMonitorView.swift:77-81` 按 `reloadMonitorState()` 返回值置三态。
- `WorkspaceMonitorView.swift:174-187`（基线）失败被渲染成「还没有报告…」，改为 `WorkspaceMonitorView.swift:205-222` 区分 loading/loaded/failed，空态只在 loaded 出现。
- `MonitorCenter.swift:238-240`（基线）失败只写 `monitorStatus`，改为 `MonitorCenter.swift:224-251` `performMonitorReload` 返回 Bool，`MonitorCenter.swift:195-223` 对外返回结果。
- `WorkspaceMonitorView.swift:323-333`（基线）只有最新报告可重试事项，改为 `WorkspaceMonitorView.swift:371-382` 任一展开报告都可重试。
- 失败提示与重试入口在 `WorkspaceMonitorView.swift:171-202`。

## 验证

共享锁循环，工作目录为工作树。首次运行返回 `LOCK_TIMEOUT`（锁被占用），按指示整段重跑一次。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 47.972 (48.036) seconds`

## 未做与取舍

- 未改 `VoiceOSApp.swift`（不在允许范围），`ControlCenter` 的存储属性不能新增，合并重载的成败放进扩展内 file-private static `monitorLastReloadSucceeded`，并发时取最后一轮结果。
- 成功重试不清空 `monitorStatus`，运行栏可能短暂残留上次失败文案；失败提示本身按状态消失。
- `.failed` 且有缓存时，「载入更早报告」仍按 `monitorLoaded` 隐藏，需一次成功重试后恢复。
- 未做真实 UI 驱动验证。本轮约束是不重启应用，验证止于全量构建与测试。