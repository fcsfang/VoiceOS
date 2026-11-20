# 波 114-A 推送与 QQ 操作的互斥与忙态

基线 `work/m114-a`，工作树 `.worktrees/m114-a`。只改 `Sources/VoiceOSApp/MonitorCenter.swift` 与 `Sources/VoiceOSApp/WorkspaceMonitorView.swift`。

## 目标

监测页的推送按钮连点会重复发起外部微信推送；QQ 检查、列群、加群是长时间运行的只读子进程，期间按钮没有反馈，也能重复触发。本轮给两类外部操作各加一把进程内互斥，并为六个入口补齐忙态文案与禁用。自动投递与手动推送共用同一把推送锁。

## 互斥设计

`ControlCenter` 的存储属性在 `VoiceOSApp.swift`，而本轮只允许改两个文件。Swift 扩展不能新增实例存储属性，所以互斥状态放在 `MonitorCenter.swift` 的 `MonitorOperationGate`，与既有的 `monitorReportLimit` 静态分页状态同一办法。

- `MonitorOperationGate` 是 `@MainActor` 的 `ObservableObject`，用 `@Published` 暴露两把独立锁：`push`（`.report` 或 `.test`）与 `qq`（`.diagnose`、`.list`、`.add`）。推送与 QQ 可以并行，同类操作互斥。
- 取得锁与释放锁分别用 `beginPush`/`endPush`、`beginQQ`/`endQQ`。释放时比对取得时的枚举值，晚到的释放不会清掉别人的锁。
- `ControlCenter.monitorOperations` 是进程内单例。应用只有一个 `ControlCenter` 实例，测试不构造它。
- 所有取得锁的入口在第一个 `await` 之前同步取得，在 `defer` 中释放。错误、早返回与取消路径都会经过 `defer`。
- 自动投递 `deliverLatestMonitorIfNeeded` 走 `pushMonitorReport`，与手动推送同一把 `.report` 锁。自动推送结束即释放，不会把设置页按钮卡灰。

## 逐条修法

### 推送互斥

| 入口 | 位置 | 修法 |
| --- | --- | --- |
| `pushMonitorReport` | `MonitorCenter.swift:611-615` | 配置校验后、首个 `await` 前取得 `.report`；忙时写「正在推送，请稍候…」并返回 false；`defer` 释放 |
| `sendMonitorPushTest` | `MonitorCenter.swift:651-655` | 同样取得 `.test`；忙时写「正在发送测试，请稍候…」 |
| `pushLatestMonitorReport` | 未加锁 | 只取最新报告后转调 `pushMonitorReport`，在叶子函数加锁避免嵌套重入 |
| 自动投递 | `deliverLatestMonitorIfNeeded` | 不加锁，继续走 `pushMonitorReport`，自动与手动共享 `.report` |

### QQ 互斥与反馈

| 入口 | 位置 | 忙态 |
| --- | --- | --- |
| `diagnoseMonitorQQ` | `MonitorCenter.swift:537-538` | `.diagnose`；原状态文案改为在取得锁之后写 |
| `loadQQMonitorConversations` | `MonitorCenter.swift:516-517` | `.list` |
| `addQQMonitorSource` | `MonitorCenter.swift:475-476` | `.add` |

`addQQMonitorSource` 另加幂等检查。`monitor_sources` 没有唯一索引，函数先读现有来源，按 `conversationID` 比对。群已在监测来源中就直接返回成功并提示去「来源状态」改起始时间，不重复插入。

### 视图忙态

视图用 `@ObservedObject private var operations = ControlCenter.monitorOperations` 观察锁（`WorkspaceMonitorView.swift:9`）。六个按钮在对应操作进行时显示 `ProgressView` 与忙态文案，并把原有业务禁用条件与 `operations` 条件合并：

| 按钮 | identifier | 忙态文案 |
| --- | --- | --- |
| 报告页立即推送 | `monitor.report.push` | 正在推送… |
| 发送测试 | `monitor.settings.push.test` | 正在发送测试… |
| 设置页立即推送 | `monitor.settings.push.pushNow` | 正在推送… |
| 检查 QQ 依赖 | `monitor.settings.qq.diagnose` | 正在检查… |
| 列出群 | `monitor.settings.qq.list` | 正在列出群… |
| 添加所选群 | `monitor.settings.qq.addSelected` | 正在添加… |

标识符、卡片结构与错误提示位未改。

## 验证

共享锁 `/tmp/voiceos-swift-build.lock`，工作目录 `.worktrees/m114-a`。

- `swift build -j 2`：`build_exit=0`
- `swift test -j 2`：`test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 43.798 (43.858) seconds`

## 未做与取舍

- 未做真实 UI 驱动：约束是不重启应用，验证止于全量构建与测试。
- `WorkspaceProcessingView.swift:294` 的「重试推送」不在允许改动的两个文件内，按钮没有忙态。模型层锁仍保证它不会与其它入口重复外发。
- 加群去重按 `conversationID`，比「会话加起点」更严格。同一群换起点再添加会被拒绝，并指向既有来源改起点，避免同一群出现两个来源重复读取。当前 UI 不支持一个群配置两个起点。
- 手动推送占住 `.report` 时，自动投递调用 `pushMonitorReport` 直接返回 false，不排队。手动推送的目标是同一份最新报告，投递结果不受影响。若并发的是较早报告，自动投递本轮跳过，当天报告保持未推送，同日手动「立即检查」或手动推送可补上，应用不会自行排队重试。这是有意取舍，避免自动任务等待网络。
- 推送忙时，程序入口写「正在推送，请稍候…」覆盖当前状态文案。按钮已被禁用，正常点击不会走到这里。QQ 忙时入口直接返回，不写文案。
- 静态锁在进程内共享。若未来出现第二个 `ControlCenter` 实例，两个实例也会共用这两把锁。当前应用只有一个实例。
- 未 push、未合并。