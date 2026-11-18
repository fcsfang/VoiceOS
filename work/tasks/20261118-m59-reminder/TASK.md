# 波 59 任务书（2026-11-18）：提醒同步逐项隔离

## 背景（只读发现 2026-11-18 凌晨）

审计第 4 条「提醒同步整批中止」确认未修，且危害比原描述大：

- `Sources/VoiceOSCore/RecordingExpressionReminders.swift:19` 的逐表达式循环，任一 `:27`（reserved/unknown link 无 external_id）/`:38`（回读核对失败）/`:40`（readReminder 抛错）即中止整批。成功项会移除、失败项可重试，但没有逐项失败记录；队头坏项让后续补录永久挨饿。`:27` 自锁：补 external_id 的 `refreshAuthorizedReminders` 在调用方 `VoiceOSApp.swift:3534` 排在本函数之后，本函数一抛，回读永远不跑，link 永远补不上。
- `Sources/VoiceOSCore/RemindersAccess.swift:60-70` 激活循环同样一抛中止，`:94` 把逐任务失败压成布尔，具体任务与原因丢失，坏任务每轮阻断其后所有新任务，且不出现在任何异常列表。
- `VoiceOSApp.swift:3517` 的 `try` 让表达式补录失败连带跳过字段抽取与 `refreshAuthorizedReminders`（回读是完成状态主要来源，实测 80 条完成中 79 条来自回读），`:3541-3543` 的 catch 只写固定文案不带原因。
- 波 53 只覆盖了 `flushPendingReminderSyncs` 的 catch 分支；`VoiceOSApp.swift:3425` 的 conflict/missing link 跳过分支与跨清单 entry 仍无原因（m53-pg 收口项）。

对照范式：`reconcileReminders`（`RemindersAccess.swift:82-84`）与 `flushPendingReminderSyncs`（`VoiceOSApp.swift:3413-3438`）已是逐条 catch + failed 汇总，可推广。

## 完成判据

1. 表达式补录逐 actionID 捕获失败并继续；失败原因与时间可显示（复用现有「提醒事项需要核对」区块或等价最小状态），成功项照旧移除、不重复；external_id 为空的 link 不再自锁（记录原因、继续后续项，且回读阶段照常执行）。
2. 激活循环逐 action 捕获，收集 (actionID, reason)；不再压成布尔；坏任务不阻断其后新任务；既有回读不受影响。
3. VoiceOSApp 自动同步三阶段（补录、字段抽取、回读）各自独立 do/catch，失败原因进入状态文案或处理页，回读始终执行。
4. 待同步跳过分支（conflict/missing link、跨清单 entry）也记录失败原因（m53-pg 收口）。
5. 测试（新增 ≤4 个用例，隔离临时库、假端口，不碰真实 EventKit）：一坏多好时后续项继续并成功；失败原因落盘可见且可清除；前置阶段失败不阻断回读阶段；成功项不重复处理。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0。

## 文件所有权

- `Sources/VoiceOSCore/RecordingExpressionReminders.swift`
- `Sources/VoiceOSCore/RemindersAccess.swift`
- `Sources/VoiceOSCore/RemindersStore.swift`（最小增量）
- `Sources/VoiceOSApp/VoiceOSApp.swift`（提醒同步区域）
- 提醒异常展示相关视图（最小增量；`WorkspaceProcessingView.swift` 只允许在既有「提醒事项需要核对」区块加行，不得重排其他小节）
- 对应测试
- 不碰主题组织、消息监测（`MessageMonitor*`、`QQMonitorHelper`、`WebsiteMonitor`、`WorkspaceMonitorView` 等）、全景、知识核查、分段理解。

## 约束

- 16GB：共用全局构建锁 `/tmp/voiceos-swift-build.lock`，任何时刻只跑一个 swift build/test。
- 绝不写实时库；测试隔离临时库。
- 构建/测试只认真实退出码，管道不得吞掉。
- 分支 `work/m59-rm`，完成后提交并回报，不 push、不合并、不重启应用。
- 与并行单元 B 都改 `VoiceOSApp.swift`：只做提醒同步区域的增量插入，保持 hunk 小，减少合并冲突。

## 结果

### 改了什么

- `Sources/VoiceOSCore/RecordingExpressionReminders.swift`：补录循环逐 actionID 包 do/catch，失败记录原因后继续下一项；成功项照旧移除且不重复；`external_id` 为空的关联改为记录「缺少外部标识，等待回读补全」并继续，不再抛错中止整批。
- `Sources/VoiceOSCore/RemindersAccess.swift`：激活循环逐 action 捕获并持久化 (actionID, reason)，收集失败数后以汇总错误返回，不再压成布尔；坏任务不阻断其后任务；`refreshAuthorizedReminders` 无论激活成败都执行 reconcile，并在回读前清理已解决的失败记录。
- `Sources/VoiceOSCore/RemindersStore.swift`：新增 `ReminderSyncFailureStage`/`ReminderSyncFailure`，`ReminderSyncAnomalySummary` 增加 `failures`；`sendTaskToReminders` 的未确认错误附上底层原因，落盘为具体原因。
- `Sources/VoiceOSCore/Database.swift` + `Tests/VoiceOSCoreTests/TestSchema.swift`：迁移 75 建 `reminder_sync_failures(action_id, stage, reason, failed_at, PRIMARY KEY(action_id, stage))`，`user_version` 上限同步到 75。迁移 74→75 只建表，重试幂等。
- `Sources/VoiceOSApp/VoiceOSApp.swift`：`flushPendingReminderSyncs` 对跨清单 entry 与 conflict/missing 跳过分支也写入失败原因（波 53 收口）；`automaticReminderRefresh` 拆成补录、字段抽取、回读三阶段各自独立 do/catch，任一阶段失败只记录原因，回读始终执行，状态文案带最近原因。
- `Sources/VoiceOSApp/WorkspaceProcessingView.swift`：既有「提醒事项需要核对」区块内增加失败条目行（任务、阶段与时间、原因、查看任务），区块条件与计数包含失败数；未重排其他小节。
- `Tests/VoiceOSCoreTests/ReminderSyncIsolationChecks.swift`：3 个新用例，隔离临时库与假端口，不碰真实 EventKit。

### 失败原因如何落盘与清除

- 落盘：`reminder_sync_failures` 按 (action_id, stage) 一行，`stage` 为 `expression`（补录）或 `activation`（新任务发送）。每次失败 UPSERT 覆盖为最新原因与时间，重试不会堆行。
- 可见：`reminderSyncAnomalies()` 返回的 summary 带 `failures`（任务标题、阶段、原因、时间），渲染在「提醒事项需要核对」区块。
- 清除：成功后立即删除该行；每个刷新周期由 `clearResolvedReminderSyncFailures()` 清理已解决记录（激活失败在关联回读为 linked 后清除；补录失败在该 actionID 不再出现在任何已完成表达的 `reminderUpdates` 后清除）。
- 本地完成队列（`PendingReminderSync.lastFailureReason`）继续承载完成/撤销写回失败；跨清单与 conflict/missing 跳过原因也写入该字段，在「本地变更待同步提醒事项」区块显示。
- 迁移包不携带该表：与 `reminder_access` 一样属于设备本地瞬态状态，恢复后由下一次同步重新建立。

### 测试证据

- 全局锁下运行 `swift build -j 2` / `swift test -j 2`：build_exit=0，test_exit=0；共 569 项测试，0 失败（基线 566 + 新增 3）。
- 新增用例覆盖：一坏多好时后续补录继续并成功；失败原因跨重开落盘可见、成功后清除；激活失败不阻断后续发送且既有回读照常完成。

### 遗留

- 激活失败的任务已留下 reserved/unknown 关联，不会被再次派发；失败行在关联回读为 linked 后自动清除，若外部任务始终未出现，则以「提醒事项需要核对」的 missing 异常持续可见，符合「不自动重建」原则。
- 自动同步状态文案只显示最近一条阶段原因；逐条原因以处理页区块为准。
- 未在真机 EventKit 上重放（按任务约束不碰真实提醒事项）；验证为锁定的完整测试套件与假端口用例。
