# 波 102-P：审查波 100-101 确认缺陷补丁

## 来源

独立对抗审查工作流（2 维度 × 2 名反驳者）确认 4 条 major，待视觉波 102 合并后施工，避免与 `WorkspaceMonitorView.swift`、`WorkspaceView.swift` 的并行修改冲突。

## 缺陷与修法

### P1 监测页自动检查后状态不刷新（WorkspaceMonitorView.swift:388 等）

自动路径（定时器、唤醒、应用激活触发的 monitorTick）调用 `runMonitorCheck` 后不执行 `markLatestItemsFailure()` 与 `earlierOpenSummary` 重算；手动检查、重新检查、事项状态变更三条路径都有刷新。

修法：在页面上以 `model.monitorReports` 与 `model.monitorItemsByReport` 的变化为刷新信号（`.onChange`），任何来源完成检查都重算汇总与最新报告失败标记；跨午夜后首次检查同样因此刷新 todayKey。

### P2 超出最近 30 条报告的未处理事项不可达（MessageMonitor.swift:206-231）

`MonitorOpenItemsSummary` 把不在 `monitorReports(limit: 30)` 里的 open 事项计入 `earlierCount`，这些报告在 UI 中无入口，最早日期也可能取不到。

修法：汇总拆出 `unreachableCount`（reportID 不在已加载报告集的 open 项）。UI 显示「另有 N 项在更早报告里」并给「载入更早报告」按钮；MonitorCenter 增加报告加载窗口（默认 30，点击翻倍重载）。载入后汇总自然包含这些报告，展开最早报告可继续处理。

### P3 设置页麦克风授权不随系统设置返回而刷新（WorkspaceView.swift:1746）

`microphoneAuthorization` 只在进入设置页采样一次；去系统设置授权后返回仍显示「已拒绝」。

修法：设置页监听 `NSApplication.didBecomeActiveNotification` 重读 `AVCaptureDevice.authorizationStatus`，与提醒事项行的实时读取节奏一致。

### P4 引导页授权绕过共享状态（Onboarding.swift:157）

引导直接调用 `AVCaptureDevice.requestAccess` 并只写本地 @State，授权后设置页仍显示未授权。

修法：改调 `ControlCenter.requestMicrophoneAccess()`（更新共享状态），清单在 `didBecomeActive` 时重新采样。

## 约束

行为修复类，不改视觉与文案结构；构建/测试真实退出码；新增 P2 的汇总纯逻辑测试；不写实时库、不重启应用、合并走 worktree 分支。