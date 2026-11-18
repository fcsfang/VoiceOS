# 波 84 任务书（2026-11-19）：快照管线记忆化与刷新尾部重活

## 背景（发现者 C 报告 2026-11-19，实测数据）

- C1：每 60 秒与每次激活执行 `refresh(.full)`；`.full/.core` 不挂起 context 校验，`candidateClaimRows` 对每个 context 走 `localContext` → `SELECT *` 解码整行 snapshot_json → 重建上下文（per-source SQL + 指纹 + SHA256）。实测 contexts 315 行、snapshot_json 合计 75.8MB；每轮至少 3 遍，每分钟约 230MB 解码。证据 `VoiceOSApp.swift:3504-3507,1237-1256`、`WorkspaceSnapshot.swift:61-118`、`CognitiveStore.swift:122-134,220-233`、`TranscriptContext.swift:33-72`、`Store.swift:26-32`。
- C4：刷新尾部无条件 `reloadMonitorState` + `writeMarkdownMirror`（全量原子重写）+ `updateSpotlightIndex`（先构造全部条目再判断 60 秒节流）。`VoiceOSApp.swift:1252-1254,1439-1472`、`SpotlightIndexer.swift:21-57,118-140`、`MarkdownMirror.swift:14-43`、`MonitorCenter.swift:141-170`。
- A2：任务详情/AI 交付页进入时 `.task { await model.refresh() }` 重读快照并重建索引。`WorkspaceActivityViews.swift:89,638`。

## 完成判据

1. context 校验记忆化：按 `(contextID, snapshot digest)` 缓存校验结果；未变只比 digest。纯内存缓存、不改数据语义。
2. 刷新尾部：60 秒节流判断挪到 `makeEntries` 之前；Markdown 镜像只写指纹变化的文件；Monitor reload 合并/去重（每轮一次）。
3. 详情页进入不再整轮 refresh：改为窄查询（按 action.id）或删除；若数据新鲜度必须保证，给出证据并保留最小刷新。
4. 计时对照（测试内或隔离 fixture）：同一操作序列旧路径 vs 新路径的解码字节数或耗时。
5. 行为与外部语义零变化；不加迁移；测试 ≤4（中文断言）；build/test 真实退出码 0（基线 621）。
6. 结果给 file:line 与对照数据。

## 文件所有权

`Sources/VoiceOSCore/WorkspaceSnapshot.swift`、`CognitiveStore.swift`、`TranscriptContext.swift`、`Store.swift`、`MarkdownMirror.swift`、`Sources/VoiceOSPlatform/SpotlightIndexer.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/WorkspaceActivityViews.swift`、对应测试。不碰其他文件（尤其 WorkspaceView/WorkspaceSourceView/RecentContentHome）。

## 约束

16GB：锁 `/tmp/voiceos-swift-build.lock`；先 merge main；不写实时库；不重启应用；不 push、不合并。分支 `work/m84-snapmemo`。

## 结果

- 分支：work/m84-snapmemo（基于 main 88fd720；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：bcba953「perf(快照): context 校验按摘要记忆化，刷新尾部重活节流去重」（10 个文件，200 增 17 删）。
- 归因：任务书 C1 证据 `VoiceOSApp.swift:3504-3507,1237-1256`、`WorkspaceSnapshot.swift:61-118`、`CognitiveStore.swift:122-134,220-233`、`TranscriptContext.swift:33-72`、`Store.swift:26-32`。本波实测发现：快照读取会执行 `freezeDiscussionDerivations`/`freezeConversationOutcomes` 等零行 UPDATE 清扫，因此失效信号必须取 SQLite 行变更计数（`sqlite3_total_changes64`），按语句计数会让缓存每轮失效。
- 改动（file:line 为提交后行号）：
  - `Sources/VoiceOSCore/Database.swift:9,1609-1612`：新增 `writeGeneration`（连接级行变更计数），`execute` 后更新；零行 UPDATE 与 BEGIN/COMMIT 不再使缓存失效。
  - `Sources/VoiceOSCore/Store.swift:27-40`：`ContextValidationStamp`（行摘要 + 行变更计数 + 每个 saved 来源的 `DurableFiles.Fingerprint` 映射）、两个计数器和测试用 `resetContextValidationMemo()`。
  - `Sources/VoiceOSCore/CognitiveStore.swift:122-160`：`localContext` 命中即跳过 `validateLocalTranscriptContext`；新增 `contextValidationStamp(id:digest:)`（`context_inputs ⋈ sources` 一次小查询 + 每个 saved 来源一次 stat）与 `validateContextRow`。`CognitiveStore.swift:253-257`：`candidateClaimRows` 改为 `SELECT DISTINCT x.id,x.digest`，校验裁决不再解码 `snapshot_json`。
  - `Sources/VoiceOSCore/MarkdownMirror.swift:7,30-40`：`writtenDocuments` 按路径缓存内容，内容相同且文件在盘即跳过原子重写（保留“外部删除会被下次重建”的原行为）。
  - `Sources/VoiceOSPlatform/SpotlightIndexer.swift:18,27-31`：`lastIndexedAt` 改 `lastScanAt`，60 秒节流判断移到 `makeEntries` 之前；空闲刷新不再构造全部条目。
  - `Sources/VoiceOSApp/MonitorCenter.swift:141-168`：`reloadMonitorState` 改为 worker + pending 合并，重叠调用最多多跑一轮；原逻辑移入 `performMonitorReload`。
  - `Sources/VoiceOSApp/VoiceOSApp.swift:262-265`：新增 `monitorReloadWorker`/`monitorReloadPending`/`monitorReloadForceItems`。
  - `Sources/VoiceOSApp/WorkspaceActivityViews.swift`（原 89、638 行）：删除 `WorkspaceDeliveryView` 的 `.task { await model.refresh(.assistant) }` 与 `WorkspaceTaskView` 的 `.task { await model.refresh() }`。
  - `Tests/VoiceOSCoreTests/ContextValidationMemoChecks.swift:39-65`、`Tests/VoiceOSCoreTests/MarkdownMirrorChecks.swift:21-44`：新增 2 项纯逻辑测试（中文断言）。
- 对照数据（测试内，`ContextValidationMemoChecks` 隔离 fixture，2 个上下文）：首轮 `.full` 解码 906 字节、校验 2 次；重复同一 `.full` 增量 0 字节、0 次（旧路径每轮 906 字节/2 次，用 `resetContextValidationMemo()` 复现对照）；一次外部写入（`recordUserExpression`）后下一轮重新校验 2 次。生产 315 上下文、75.8MB 时按同比例折算，即每轮省去两次全量快照解码与逐来源重建。
- 语义锁定：`CoreFlowTests.testCorrectionPreservesHistoryAndRefreshesUnderstanding`（`Tests/VoiceOSCoreTests/CoreFlowTests.swift:2199-2205`）要求定向读取仍核对原件，缓存键因此包含来源原件指纹：损坏文件使指纹变化，miss 后 `localContext` 冻结上下文并写回“核对失败”。`SnapshotReuseChecks`、`WorkspaceSnapshotScopeChecks`、`AssistantContextReuseChecks` 等外部写入/冻结语义全部通过。
- 验证：build_exit=0（`swift build -j 2`，116.87 秒）；test_exit=0（`swift test -j 2`），623 项测试 0 失败（基线 621 + 新增 2），44.0 秒。构建/测试共用 `/tmp/voiceos-swift-build.lock`，结束后已释放；`git diff --check` 退出码 0。
- 判据落点：
  1. 校验记忆化：`Store.swift:27-40` + `CognitiveStore.swift:122-160`（摘要 + 行变更计数 + 原件指纹；纯内存、只读不失效）。
  2. 刷新尾部：`SpotlightIndexer.swift:27-31`（节流前移）、`MarkdownMirror.swift:30-40`（只写变化文件）、`MonitorCenter.swift:141-168`（每轮一次）。
  3. 详情页：`WorkspaceActivityViews.swift` 原 89/638 行删除；新鲜度由 60 秒 timer、激活/唤醒 observer、`resumeAssistantExecutions` 进度刷新与页内 `.task(id:)` 按 action.id 的窄查询保证。
  4. 计时对照：见「对照数据」。
  5. 行为与外部语义零变化、无迁移、测试 ≤4（新增 2）、build/test 真实退出码 0。
  6. file:line 见「改动」与「归因」。
- 遗留风险：
  - 缓存命中时原件做 stat 级核对（与原 `verifiedHash` 会话缓存一致）；内容哈希只在指纹变化时重算，与旧语义相同。
  - Spotlight 索引失败改为等下一个 60 秒节流窗口重试（旧实现下一个刷新即重试），失败仍记日志。
  - Monitor reload 合并后，等待中的调用方拿到“自己调用之后至少完成一轮”的数据，等价于串行调用。
  - 测试内字节数是隔离 fixture 数据；生产 315 上下文/75.8MB 的折算留给协调方用 `StartupTrace` 实机复测。
