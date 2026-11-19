# 波 94 任务 B（2026-11-19）：任务详情页日期与提醒入口重构

## 用户诉求

「打开一条提醒一眼看清哪天该做、是否已写入 Apple 提醒事项。」
入口层有三处缺陷：日期标签不看链路状态，外写失败或未知时显示与成功相同的日期；「等待同步到所选清单」是固定文案，与「请先同步」互相卡死；改期进入 blocked 后没有下一步入口。到期与提醒区块还排在预计时长、承诺澄清之后。
目标：任务详情页标题下先给出日期来源（已回读 / 仅本地期望）与一句同步原因和下一步，可写入时提供直达按钮，blocked 可重新设置期限，整个区块前置。

## 改动（Sources/VoiceOSApp/WorkspaceActivityViews.swift，行号为改动后）

1. 助手计算属性 `331-362`：
   - `reminderLink`、`linkedReminderDue`：当前任务的提醒关联与已链接的回读期限；
   - `reminderObservedSummary`（优先 `intent.reminderFields.observed` 摘要，其次 linked `remoteDueDate`）、`reminderDesiredSummary`（desired 字段摘要）；
   - `ReminderEntryState`（linked / needsReview / notConnected / fieldsPending / fieldsUnchecked / readyToWrite）与 `reminderEntryState`：入口层同步状态集中判定，视图不再逐条散判布尔；
   - `canWriteReminder`（任务 open、intentActor 为 user、连接启用且已选清单）、`canEditReminderSettings`（linked 且连接清单一致，与 `loadReminderSettings` 的守卫对齐）。
2. 页面主体 `404-460`（原 433-460 区段整体上移到标题之后、预计时长与澄清之前）：
   - 日期标签区分来源：observed 或 linked remoteDue 显示「已回读 · <摘要>」；仅 desired 显示「仅本地期望 · <摘要>」+「未确认写入提醒事项」；两者都有时以已回读为主，期望不同才以 secondary 行显示「本地期望 · … · 未确认写入」；
   - 已链接且期限已过时保留警示行「已逾期 …」；地点提醒行随块前移；
   - 「日期与提醒」编辑器按钮只在 linked 且连接与清单可用时出现（此前无链接也显示，点开必然落入「请先同步」）；
   - 状态按 `reminderEntryState` 分派一句原因与下一步：未连接（指向「处理」页的「模型与提醒事项」）、后台核对中、字段未核对（附最近原因）、可写入（「立即写入提醒事项」→ `model.sendReminder`）、待核对（「核对提醒同步」→ `model.refreshTaskReminders`）；
   - 本地完成/撤销未外写的 pending 行与「稍后核对」原样保留。
3. 删除原 433-460 区段的旧实现（28 行）；divider 与样式未变；动作行 `HStack {` 位置不变。
4. 改期区块 `797-801`：`operation.state == .blocked` 且 validity 为 current 时给出说明「上次改期没有派发；重新设置期限会建立新的写前核对，旧记录保留。」与「重新设置期限」按钮（`scheduleAction = action`，与「改到某天」同一路径与禁用条件）。
5. `sendReminderNow()` `1082-1091`：复用 `model.sendReminder`（内部先抽取提醒字段，再 `sendTaskToReminders`，一次创建尝试、以回读为准）；未生成关联时把 `model.status` 放入既有主操作失败横幅并提供重试。

## 判据落点

- 一眼看清：标题下先看到日期来源（已回读 / 仅本地期望）与一句同步状态和下一步，再是预计时长、承诺澄清等次要面板。
- 不再卡死：未链接任务在连接可用时可直接「立即写入提醒事项」；字段未核对给出最近原因并可重试；已链接的核对入口保留。
- blocked 有路可走：提供「重新设置期限」，不重发旧记录（旧 operation 保留，新建独立写前核对）。
- 行为保持：数据流、标识、键盘不变；未新增迁移；未新增测试（基线 639 项不动）。

## 真实退出码

- `swift build -j 2` → `build_exit=0`（Build complete! 115.79s）
- `swift test -j 2` → `test_exit=0`，Executed 639 tests, with 0 failures (0 unexpected) in 45.635s
- 构建与测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁，测试结束后 rmdir；锁目录已释放）。

## 遗留风险

- 未在运行中的应用里做视觉核验（约束：不重启应用）；本波只验证真实构建与测试退出码。
- 「立即写入提醒事项」依赖既有守卫（连接启用、已选清单、intentActor 为 user、来源允许外写）；不满足时按钮隐藏并给出解释文案。`sendTaskToReminders` 的失败原因经 `model.status` 进入既有失败横幅；store 侧会保留 unknown 关联，之后由「核对提醒同步」只读回读，不自动重建。
- 未连接提醒事项的下一步指向「处理」页的「模型与提醒事项」，因任务详情页没有直达连接设置的入口（`openSettings` 属于处理视图内部）。
- 已回读标签优先取 `intent.reminderFields.observed`，其次 link.remoteDueDate；若关联被删除而 observed 摘要仍保留，会继续显示最后一次已回读记录（与旧行为一致）。
- 逾期警示只针对 linked 的回读期限；仅本地期望的日期不判断逾期（未确认写入）。
- blocked 分支只对 validity 为 current 的操作给出入口；冻结历史仍只读保留。
