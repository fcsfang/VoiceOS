# 波 116-B 备份与后台模型任务按钮忙态、重试去重

基线 `work/m116-b`，工作树 `.worktrees/m116-b`。只改 `Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`。

## 目标

重试备份按钮没有运行标志，可能与自动每日备份重叠且点击后无反馈；设置页三个后台模型任务按钮（重新整理主题、重试思想与下一步、重新识别 AI 委托）点击后没有按钮级反馈；模型层 `ControlCenter.retry(_:)` 无并发保护，可能重复调用 `retryTranscription`。

## 逐条修法

### 1. 备份忙态与互斥（`VoiceOSApp.swift:466`、`:1414-1431`；`WorkspaceView.swift:1847-1850`）

- 新增 `@Published var backupRunning = false`。
- 守卫放在共享的 `backupLibrary(at:)`（`:1414`）：`guard !backupRunning else { return }`，随后置位。两个入口都走这个函数：手动 `retryBackup()`（`:1302-1305`）与 `start()` 里的自动每日备份（`:1216`），守卫只有一处来源。
- 复位在 detached 任务的 `defer` 里（`:1421`），经 `MainActor.run` 回到主线程；成功、抛错、提前返回都会复位，自动备份不会把按钮永久卡住。
- 视图：忙时文案「正在备份…」，`.disabled(backupRunning || model.libraryRoot == nil)`，旁边 `ProgressView().controlSize(.mini)`。
- 与 `backupPruning` 的互斥：不互锁。备份按钮只看 `backupRunning`，清理按钮仍只看 `backupPruning`，`backupLibrary` 不等清理、`cleanupOldBackups` 不等备份，不存在双向等待；备份与清理并发执行是既有行为，本波没有改变。

### 2. 设置页后台模型任务忙态（`WorkspaceView.swift:1907-1911`、`:1933-1938`、`:1946-1951`）

- 重新整理主题与简报：由已有的 `organizingTopics` 驱动，忙时「正在重新整理…」+ spinner + 该行 disabled。
- 重新识别 AI 委托：由已有的 `assistantBusy` 驱动，忙时「正在重新识别…」+ spinner + 该行 disabled。
- 重试思想与下一步：由已有的 `followupBusy` 驱动，忙时「正在重试…」+ spinner + 该行 disabled。
- 三处都只锁本行按钮，页面其余控件不受影响；`accessibilityLabel` 与空闲态文案一字未改。
- `refreshFollowup`（`VoiceOSApp.swift:2377-2387`）原无 guard，连点会重复入队。新增 `followupEnqueueing: Set<String>`，按 `sourceID` 去重直到入队任务结束，`defer` 覆盖错误路径。标志是短生命周期的，不覆盖后续处理阶段。

### 3. 模型层 `retry(_:)` 并发保护（`VoiceOSApp.swift:4078-4086`）

- 新增 `retryingSourceIDs: Set<String>`；同一 record 在 `retryTranscription` 返回前再次调用直接返回，`defer` 保证异常路径也移除。
- 处理页单条/批量（`WorkspaceProcessingView.swift:413/429/777`）与来源页（`WorkspaceSourceView.swift:754`）共用这次去重。114-C 已加在来源页视图层的一次性标志保留，模型层是第二道保险。

### 4. 约束遵守

未改任何标识符、`accessibilityLabel` 与空闲态文案；新增只有忙态文案与 spinner；未改卡片视觉布局、未新增抽象或 token。

## 验证

共享锁循环，工作目录 `.worktrees/m116-b`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 45.813 (45.878) seconds`（与 115-C 同为 669，无测试增减）
- 日志保留：`/tmp/m116-b-build.log`、`/tmp/m116-b-test.log`
- 代码提交：`aad47d7 fix(ui): 备份与后台模型任务按钮忙态，模型层重试去重`

## 未做与取舍

- 未做真实 UI 驱动：本轮约束是不重启应用，验证止于全量构建与测试，没有在跑着的 app 里点按四个按钮看忙态。
- 备份与清理没有做互斥禁用：父任务只要求不与 `backupPruning` 互锁死，单向禁用属于额外行为改变，未加；两者并发操作 `Backups` 目录的既有风险保持原样。
- 自动每日备份期间重试备份按钮会显示「正在备份…」并禁用，这是共用 `backupRunning` 的直接结果，语义准确，未额外区分手动/自动。
- `refreshFollowup` 的按钮忙态用 `followupBusy`（处理中），入队窗口由 `followupEnqueueing` 静默去重；窗口很短，没有再单独的入队忙态文案。
- 未 push、未合并、记录未删。