# 波 53 任务书（2026-11-17，草案）

## 背景（来自静默失败审计 2026-11-17）

审计结论第 2、3、5 条尚未处理，均集中在处理页与两条状态机：

- **个人表达意图**：`ExpressionProcessingQueue.swift:164/:203/:216/:253` 的 rejected/unknown/blocked 是终态，处理页（`WorkspaceProcessingView.swift:271-278`）只显示「未通过核对」或「处理条件已变化」，没有重试与忽略；`workspaceNeedsAttention` 因此长期为真；重新理解复用同一 commandID（`VoiceOSApp.swift:2315-2317`）拿回同一条终态。
- **录制处理请求**：`RecordingProcessingRequest.swift:96` 只扫描 waiting，blocked（写于 `:109/:113/:116/:139`）不再重评；用户把配置改回或修正逐字稿后也无法继续。
- **待同步提醒**：`VoiceOSApp.swift:3333` 的 `catch { continue }` 吞掉每条失败原因，手动核对只报「连接恢复后再试」（`WorkspaceProcessingView.swift` 待同步列表）。

## 完成判据

1. 意图状态机：`rejected/unknown` 允许显式「重新理解」（新命令号，不复用旧 commandID；旧记录保留可查），`blocked` 与 `rejected` 允许「忽略这次」（记录忽略原因与时间，不再计入注意力）。所有写入走 store 方法。
2. 录制处理请求：reconcile 对 blocked 请求按当前条件重评一次；处理页 blocked 行提供「重新核对并继续」（把 blocked 改回 waiting 走既有流程）。
3. 待同步提醒：每条同步失败的最近原因落盘（PendingReminderSync 字段或等价），待同步列表展示；手动核对失败时文案带具体原因。
4. 处理页三条来源（意图、录制请求、待同步提醒）的状态动作统一用既有 WorkspaceSection/Button 模式，不引入新面板；注意力计数只在「可操作」时计入。
5. 测试：意图 rejected→重新理解成功（新命令号、旧记录保留）、忽略后不再入注意力；blocked 请求改回 waiting 并被处理；同步失败原因落盘与清除。隔离临时库。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0。

## 单元与文件所有权

- 单单元 PG：`Sources/VoiceOSCore/ExpressionProcessingQueue.swift`、`Sources/VoiceOSCore/RecordingProcessingRequest.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`（命令段）、`Sources/VoiceOSApp/WorkspaceProcessingView.swift`、PendingReminderSync 所在文件与对应测试。
- 不碰主题组织、全景、知识核查、分段理解相关文件（波 50-52 已交付）。

## 结果

### 改了什么

- 意图状态机：`processing_intents` 增加 `ignored_at`/`ignore_reason`/`superseded_by`（迁移 73，列已存在时跳过，重复升级安全）。`rejected/unknown` 可「重新理解」，命令号为 `expression-reprocess:<意图ID>:<序号>`，旧记录保留并指向新记录；`rejected/blocked` 可「忽略这次」，原因与时间落盘后不再进入注意力。注意力判断收敛到记录自身的 `needsAttention/canReprocess/canIgnore`。
- 显式重试不再被一次性回执挡住：重试命令可新建理解尝试；已完成的理解保持复用，不重复生成 claim 与 action，关联阶段未知时可在新命令下重发。
- 录制处理请求：reconcile 同时重评 waiting 与 blocked；新增 `retryRecordingProcessingRequest` 把 blocked 改回 waiting 走既有流程，处理页 blocked 行提供「重新核对并继续」。
- 待同步提醒：`PendingReminderSync` 移入 VoiceOSCore，新增 `lastFailureReason`/`lastFailureAt`；每次同步失败记录最近原因并落盘，成功后随条目移除，再次失败覆盖为最新。处理页待同步列表展示最近原因，手动核对失败文案带具体原因。
- 处理页三条来源统一使用既有 `WorkspaceSection`/`WorkspaceRow`/`Button`，未引入新面板；被忽略或被取代的意图不再计入注意力与未完成列表。
- 数据库版本：`Database.swift` 顶部上限与 `TestSchema.currentVersion` 同步为 `73`。

### 测试证据

- `swift build -j 2`：`build_exit=0`。
- `swift test -j 2`：`test_exit=0`，544 个测试，0 失败；新增 `ProcessingFailureExitChecks` 5 个测试全部通过。
- 覆盖：rejected 重新理解（新命令号、旧记录保留、成功后完成）、unknown 重新理解、忽略后注意力为空且跨重开落盘、blocked 录制请求改回 waiting 后被消费完成、待同步失败原因覆盖/落盘/清除及旧 JSON 兼容。
- 构建与测试均在 `/tmp/voiceos-swift-build.lock` 全局互斥锁下运行，未并行。

### 遗留

- 旧版「本地完成待同步」弹窗（`WorkspaceView.swift`）未改动（不在本单元文件所有权内），最近原因只在处理页展示。
- 关联重试通过请求键前缀扩展实现，未改表结构；自动关联流程改为读取最新一次尝试。
- 本次迁移只追加列；迁移测试的降级夹具依赖 `PRAGMA table_info` 跳过已存在列。
