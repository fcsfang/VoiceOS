# 波 116-C 材料、代办与监测来源的连点与并发写保护

基线 `work/m116-c`（基于 main 764552b），工作树 `.worktrees/m116-c`。只改 `Sources/VoiceOSApp/MaterialManagementView.swift`、`AssistantExecutionView.swift`、`WorkspaceMonitorView.swift`、`MonitorCenter.swift`。

## 目标

材料管理、代办取消/重新执行、监测来源启停/改起点/添加内置来源在忙碌时没有禁用，快速连点会重复执行，或对同一条来源记录并发写库，最终状态取决于写入先后。

## 逐条修法

### 1. 材料管理（`MaterialManagementView.swift`）

- 核对结论：`.disabled(busy)` 已在 `:23` 包住 full/compact 的全部按钮与菜单（自 6559b456 起），任务卡所述“未禁用”在当前基线不成立，未重复添加。
- `:93` `update(_:)` 开头补 `guard !busy else { return }`。`.disabled(busy)` 要等下一帧重绘才生效，动作里同步置位前的第二次点击仍可能进来；guard 用同步状态挡住。
- `:94` 起 `busy=true`、完成后 `busy=false` 的既有流程未动。`manageMaterial` 的模型层 guard 不在本单元可改范围，留作后续项。

### 2. 代办取消/重新执行（`AssistantExecutionView.swift`）

- alert 两个动作按钮（`:263-275`）点击后先 `guard !saving`，同步 `saving = true`，再启动 `Task`；await 返回后 `saving = false`，按钮同时加 `.disabled(saving)`。
- 复用视图既有 `saving` 状态（关联成果、带着成果继续讨论、顶部取消/重新执行按钮已读它），不新增状态；页脚 `assistantBusy` spinner 语义未动。
- `VoiceOSApp.swift` 的 `cancelAssistant` / `retryAssistant` 模型层 guard 不在可改范围，留作后续项。

### 3. 监测来源（`WorkspaceMonitorView.swift`、`MonitorCenter.swift`）

- `MonitorOperationGate` 在既有 push/qq 两槽之外扩展：`sourceBusy: Set<String>` 按来源一行一个槽，`addingBuiltinSources` 管添加内置来源，`pendingSourceWrites` 按来源保存 enabled/start 的最新值。push/qq 两槽语义未动。
- `setMonitorSourceEnabled`、`setMonitorWebsiteStart`、`setMonitorQQStart` 统一走 `drainMonitorSourceWrites`（`MonitorCenter.swift:492`）：先入队最新值；抢到该来源的槽就成为 drain 独占者，`defer` 复位；抢不到立即返回，值留在队列由当前 drain 者处理。
- drain 每次写前从 store 重读该来源，再合并 start 与 enabled 写出；QQ 起点继续调用 `alignMonitorCursorToStart`。启停与改起点排队时不会互相覆盖，最后一次操作生效，同一来源任意时刻只有一条写路径。
- `ensureBuiltinMonitorSources`（`:417-418`）加 `beginBuiltinSources()` guard 与 `defer` 复位；onAppear 自动补种和按钮重复触发不会再并发插入。
- 视图：`:708` 添加内置来源按钮按 `addingBuiltinSources` 禁用；`:732` 每行启用开关与 `:754` 起点 DatePicker 按 `sourceBusy.contains(source.id)` 禁用。标识符与文案未改。

## 忙碌设计与取舍

- 按来源一个槽而不是全局一个槽：不同来源互不阻塞，同一来源串行。
- 开关以最后值为准，不丢弃重复点击：快速拨动后最终状态等于最后一次选择；模型队列兜住禁用尚未重绘的窗口。
- drain 期间 `sourceBusy` 保持到最后一次写与 reload 完成，UI 不会提前恢复可点。
- 每次写前重读来源，避免旧视图快照的 configJSON/enabled 覆盖刚写入的另一次操作。代价是每次写多一次 `monitorSources()` 读取；该操作由人手触发，频率低，可接受。

## 验证

共享锁循环，工作目录 `.worktrees/m116-c`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码。首次运行等待共享锁 10 分钟超时（m116-b 持锁），按任务要求整段重跑一次：

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 45.348 (45.410) seconds`（与 115-C 同为 669，无测试增减）
- 代码提交 `cf53b67 fix(ui): 材料与代办操作防连点，监测来源写入按来源串行`

## 未做与取舍风险

- 未重启应用、未做 UI 真机验证；验证止于全量构建与测试。
- `manageMaterial`、`cancelAssistant`、`retryAssistant` 的模型层 guard 不在本单元可改文件内，未做。
- 来源删除按钮未纳入忙禁用：删除走确认弹层，与在途启停写仍可能竞争，任务范围未列，留作后续。
- 若来源在排队期间被删除，drain 跳过该行且不写库，不额外报错。
- 排队调用不向调用方返回最终结果，只保证不并发写与最后值生效；错误统一经 `monitorStatus` 呈现。