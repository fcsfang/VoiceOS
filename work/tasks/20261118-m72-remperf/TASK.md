# 波 72 任务书（2026-11-18）：启动提醒对账的重复全表扫描与转写重读

## 背景（实机采样 2026-11-18，波 69/70 dist 安装后）

每次启动 VoiceOS，提醒对账（automaticReminderRefresh → refreshAuthorizedReminders → reconcileReminders）让进程持续约 2 分 48 秒高 CPU（实测 90-120%，实时库 131 条 reminder_links、527 条 actions、1057 条 claims）。

sample 归因：对每条 link 调 readReminder → applyReminder → observeReminderFields(actionID:) → actions(includeHistory:) 全量载入 actions → candidateClaims 扫描全部 claims（1057 行）→ 每个候选 claim 走 localContext(id:) → validateLocalTranscriptContext → prepareLocalTranscriptContext 读转写正文（sqlite pread + UTF-8 校验占满采样）。同一批不变数据在每条 link 上重复扫 131 次。

## 完成判据

1. 对账循环内不再逐 link 触发全量 actions/claims 加载与转写重读：refreshAuthorizedReminders/reconcileReminders 每轮只加载一次观察所需数据（或按 action 去重后只算一次），observeReminderFields 复用同一快照。
2. 行为不变：回读/激活/字段观察的结果与失败语义与现状一致（既有测试原样通过，尤其提醒同步相关 6+ 个用例与 verify-voiceos-reminder-schedule 覆盖的 at-most-one 外部写入语义）。
3. 新增测试（≤2）锁定批量化：多 link 指向同一 action 时，观察路径的底层加载次数为 1 轮而非 N 轮（用计数 port/包装 store 或 SQL 计数钩子断言；中文断言）。
4. 提供前后对照的量化证据：fixture 库（≥100 links、≥500 actions、含长转写）上 reconcile 的耗时或 DB 查询次数前后对比（用测试内计时或查询计数，写进结果；达不到数量级改善就如实报告）。
5. `swift build -j 2` / `swift test -j 2` 真实退出码 0（先 merge main，基线 610 项）。
6. 不改外部副作用顺序（写提醒事项的调用序列不变）；不动 App/Platform 层；不加迁移（如确需索引，报告里说明并等待确认后再加）。

## 文件所有权

- `Sources/VoiceOSCore/RemindersAccess.swift`
- `Sources/VoiceOSCore/RemindersStore.swift`
- `Sources/VoiceOSCore/ReminderFields.swift`
- `Sources/VoiceOSCore/CognitiveStore.swift`（仅必要的查询复用，不改变公开语义）
- 对应测试
- 不碰其他文件；不碰波 71 的三个 App 视图。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；测试用临时库 fixture；不重启应用；不 push、不合并。
- 分支 `work/m72-remperf`，提交回报。

## 结果

- 分支 `work/m72-remperf`。代码提交 `b3be6a7`（perf(提醒): 对账每轮只加载一次观察数据），本文件随第二个 docs 提交记录结果。
- 构建与测试：`swift build -j 2` 退出码 0。`swift test -j 2` 退出码 0，612 项测试 0 失败（基线 610 项加新增 2 项）。
- 前后对照（同一 fixture：120 条关联、500 个任务、20 份长转写、三轮对账）：基线 1361/1403/1340 ms，修改后 59.3/35.6/35.6 ms。中位数 1361 → 35.6 ms，约 38 倍。外部 `find` 每轮仍为 120 次，三轮共 360 次。
- 行为等价：`reconcileReminders` 每轮只在第一条确认回读时做一次 actions/claims 认知屏障与全量加载，后续关联复用同一快照。`observeReminderFields` 改用 `applyReminder` 已加载的同一 `ActionRecord`，两步原本就在同一同步区间，写入内容不变。外部写入顺序与次数不变。缺失或冲突关联仍不加载 actions。屏障加载失败仍按原路径逐条计入失败并返回原汇总错误。
- 快照不会读到本轮写旧的任务记录：`reminder_links.action_id` 有 UNIQUE 约束，一个 action 至多一条 link。字面上的“多 link 指向同一 action”无法构造，测试改为 20 条关联覆盖同一轮只加载一次。
- 判据落点。判据 1 与 2 见上。判据 3 由 `testReconcileLoadsObservationDataOncePerRound` 覆盖：20 条关联一轮只全量加载 1 次，第二轮累计 2 次。判据 4 是 `testReconcileLargeFixturePrintsTiming` 输出的 `M72_PERF` 行。判据 5 是上面两个真实退出码。判据 6 无外部写入顺序变化，未动 App/Platform，未加迁移。
- 未改 `CognitiveStore.swift`：现有查询接口已足够复用，未扩大改动面。
- 遗留风险：一轮对账的本地视图固定在首次确认回读时。若轮内其他任务在 await 期间修改来源授权或转写，冻结会推迟到下一轮，外部写入语义不受影响。
- 验证附注：`verify-voiceos-reminder-schedule` 的 TLA+ 模型在 Java 24 下通过。默认配置无违例，`--broken` 的四个变体各自违反预期不变量。覆盖的 `ReminderScheduleOperation` 函数未改动。
