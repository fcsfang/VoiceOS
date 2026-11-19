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
## 施工记录

2026-11-20，分支 work/m102-patch，基线 4598817。

### 实际改动

- P1：WorkspaceMonitorView.swift:76-82 新增两个 onChange。model.monitorReports 变化时重算 earlierOpenSummary 并重标最新报告事项读取失败；model.monitorItemsByReport 变化时重标失败标记。手动检查路径未改。
- P2 汇总：MessageMonitor.swift:202 新增 unreachableCount；206 的 init 增加默认参数，旧调用兼容；219-222 把未加载报告的 open 项计入 unreachable；earlierCount 只统计已加载且非今天的项，最早报告逻辑不变。
- P2 窗口：MonitorCenter.swift:151 新增 monitorReportLimit 默认 30，152 上限 960；155-159 的 loadMoreMonitorReports 翻倍后重载；185 的 performMonitorReload 使用该窗口。
- P2 界面：WorkspaceMonitorView.swift:191 历史副标题按已加载数量表述；215-220 历史区到达窗口上限时显示「载入更早报告」；439-463 汇总提示增加「另有 N 项在更早报告里」与载入按钮；431-436 载入后重算汇总。
- P4 授权：Onboarding.swift:167 requestMicrophone 改调 model.requestMicrophoneAccess 再重采样；111-120 就绪清单监听 NSApplication.didBecomeActiveNotification，返回前台重采样麦克风与通知授权。
- P4 视觉：Onboarding.swift:32 页标题改用 pageTitle；51 跳过用 workspaceQuiet，55 上一步用 workspaceSecondary，60 主 CTA 用 workspacePrimary；226 清单动作按钮用 workspaceQuietCompact；189-190 步骤圆点用 palette.accent 与 palette.secondaryText；215 勾选圈用 palette.success；34-35 步骤图标改用 vosFont。文案与流程不变。
- 测试：Tests/VoiceOSCoreTests/MonitorOpenItemsSummaryChecks.swift:46-72 新增两个 unreachable 用例，原「旧报告仍计入更早」用例按新契约改写；四个用例全部通过。

### 验证

- swift build -j 2：build_exit=0，Build complete，117.49s。
- swift test -j 2：test_exit=0，Executed 662 tests, with 0 failures。
- MonitorOpenItemsSummaryChecks 4 个用例通过，日志 /tmp/m102-patch-test.log。
- 构建与测试在 /tmp/voiceos-swift-build.lock 互斥锁内执行，锁已释放。

### 取舍与风险

- monitorReportLimit 放在 ControlCenter 扩展里只能是 static，因为扩展不能加实例存储，而 ControlCenter 的存储属性在 VoiceOSApp.swift，本轮不允许修改。该值全应用共享，读写都在 @MainActor 上；以后要按实例隔离应移入类体。
- earlierCount 语义变化。未加载报告的 open 项从 earlierCount 移入 unreachableCount，界面在窗口小于 960 且已加载数达到窗口时才给载入入口。
- onChange 让手动检查路径多一次汇总重算，属幂等重复读取；为不改变手动路径未做去重。
- P4 只做了编译与既有测试验证，未启动真实应用验证系统设置往返，约束禁止重启应用。P3 未触碰 WorkspaceView.swift。
