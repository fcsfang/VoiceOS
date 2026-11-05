---
status: planning
started: 2026-11-06
updated: 2026-11-06
branch: -
pr: -
owner: coordinator
---
# 启动提醒核对的成本

## 目标

启动时核对 98 条已链接的提醒事项仍有约 20 秒 CPU。它已经不影响空闲状态（#118 修复后最后 120 秒为 1.3%），但拖慢首次可用。要在保持外部写入最多一次、补偿与冲突语义不变的前提下，降低这次核对。

## 根因证据

- 启动路径：`start()` 在 `WorkspaceView.swift:188` → `VoiceOSApp.swift:594-651`，其中 `:634` 立即请求提醒刷新；`automaticReminderRefresh`（`:2128-2173`）调用 `refreshAuthorizedReminders`。
- 逐条 EventKit：`RemindersAccess.swift:76-83` 对 98 条链接逐条 `readReminder`；`NativeReminders.swift:76-102` 的 `find` 每次 `store.reset()`、对**整个日历** `fetchReminders`，并在 MainActor 上快照所有返回项。98 条链接意味着 98 次重置、98 次全日历拉取与 98×98 项转换，全部串行。
- 逐条整库：`RemindersStore.swift:163-224` 的 `applyReminder` 每条链接都 `actions(includeHistory: true)`；`ActionStore.swift:60-63` 会走动态屏障并为每个 current 上下文调 `localContext`，重新读取来源、校验转写、SHA-256 全上下文（`TranscriptContext.swift:28-71`）。`ReminderFields.swift:233-238` 还会再加载一次并重写 `intent_json`，即使字段没变。98 条链接因此可能是 98 到 196 次整库校验与哈希。
- 数据库也没有 `reminder_observations`/`reminder_links` 的索引；每条链接一个事务，`synchronous=FULL`。
- 现有 10 秒样本没有抓到这段：主线程几乎全在 `mach_msg`，39.9% 是聚合值，未归因。下一步必须从启动即开始采样并加计数器。

## 选项

- A 合并为一次 EventKit 读取（推荐结构性修复）：加一个默认回退的批量读取端口，`NativeReminders` 实现为一次 reset、一次整日历 fetch、一次 MainActor 快照；`reconcileReminders` 在内存里按现有谓词分发给每条链接，再逐条走原有访问守卫与 `applyReminder`。写入语义、观察、冲突与补偿不变。风险是一次快照的时效、批量失败需回退、以及 98 次 apply 在一个 actor 轮次内可能长时间占用。
- B 延迟首次核对：仅把刷新推迟到启动后，不能减少总成本，且激活通知会在启动时再次触发；单独采用不达标。
- C 每次核对只加载一次行动索引，并抑制无变化的 `intent_json` 写入；必须在 A 的单次批量读取之后、apply 循环没有 await 时使用，且保留每次核对恰好一次动态屏障。可与 A 叠加。

## 建议

先做 A，默认回退保证现有端口与测试不变；测量后若剩余仍多秒，再叠加 C。不要只做 B。移动校验到后台不是杠杆：`VoiceOSStore` 已是 actor，数据库与校验不在主线程；主线程成本是 EventKit 快照，A 才能减少。

## 测量计划

- 只在 APFS 克隆上运行；用 `VOICEOS_DATA_DIR` 指向克隆，模型配置指向不可用本地端点，前后核对 `model_attempts` 增量为 0。
- 在临时分支加计数器：每次核对的链接数、`find` 调用与耗时、每次拉取项数、apply 耗时、行动加载次数、校验上下文数、哈希字节、链接更新、`intent_json` 写入、新观测、外部写入调用。
- 启动即 `sample <pid> 30 1`，并每 5 秒记录 CPU 240 秒；对比前后首次 120 秒。
- 成功标准：首次 120 秒 CPU 明显低于 39.9%（目标 <10%），核对在数秒内完成，每次核对一次 EventKit 读取，未变化的克隆上零外部写入、零新观测、零冲突，`last_checked_at` 仍更新，最后 120 秒仍约 1.3%。加一个计数批端口测试：N 条链接一次批量读取，核对期间无 create/updateDue/updateFields。
- `swift test -j 4` 全绿；若触碰日程/补偿函数，重跑提醒日程的 TLA+ 检查。

## 待你决定

1. 启动时一次快照是否足够，还是必须看到核对过程中刚发生的完成。
2. 启动是否应只读：现在 `refreshAuthorizedReminders` 可以创建待提醒任务，表达式同步也会改标题与到期日。
3. 没变化时是否仍要每次更新 `last_checked_at`；若不要求，可省掉 98 个逐链接事务。
4. 20 秒期间是否显示进度或允许跳过首次核对。

## 非目标

- 不改外部写入的最多一次语义、补偿、冲突与观察插入规则。
- 不在锁屏状态下做实机界面核对。

## 链接

`RemindersAccess.swift`、`NativeReminders.swift`、`RemindersStore.swift`、`ReminderFields.swift`、`ActionStore.swift`、`TranscriptContext.swift`、`ReminderRefreshCoordinator.swift`；任务卡由只读调查产出。
