# 波 114-C 扫描与重试转写的忙碌反馈

基线 `work/m114-c`，工作树 `.worktrees/m114-c`。只改 `Sources/VoiceOSApp/RecordingInbox.swift` 与 `Sources/VoiceOSApp/WorkspaceSourceView.swift`。

## 目标

自动入口的「检查新素材」「重试未完成素材」在扫描期间没有任何反馈，点击像没反应；资料详情的「重试本地转写」连点会重复发起，且缺少处理页已有的忙碌禁用条件。两处都补上真实的忙碌状态：按钮变灰、显示进度与文案，重复触发被挡住。

## 根因

- `RecordingInbox.scanning` 是 `private` 普通属性，`RecordingInboxView` 读不到。`scan()` 自身有 `guard !scanning` 与 `rescanRequested` 合并，但视图层无法感知扫描是否在跑。
- `WorkspaceSourceView` 的重试按钮只写了 `Button("重试本地转写") { Task { await model.retry(source) } }`，没有 `disabled`，也没有点击后的进行中状态；`ControlCenter.retry(_:)` 模型层也没有 guard。

## 逐条修法

1. `Sources/VoiceOSApp/RecordingInbox.swift:70`：`private var scanning` 改为 `@Published private(set) var scanning`。类型本来就是 `@MainActor` 的 `ObservableObject`，这是最小暴露方式，不新增状态、不改 `scan()` 的 guard 与 `rescanRequested` 补扫语义。
2. `Sources/VoiceOSApp/RecordingInbox.swift:547-553`：两个按钮加 `.disabled(inbox.scanning)`；扫描中在同一 `HStack` 里显示小号 `ProgressView` 与「正在检查新素材…」。按钮保持可见，只变灰，不清空布局。
3. 自动 watcher、唤醒与轮询都走同一个 `scan()`，因此自动检查期间按钮也会变灰。文案不区分来源，用户看到的是统一的「正在检查新素材…」。
4. `Sources/VoiceOSApp/WorkspaceSourceView.swift:319`：新增局部状态 `@State private var retryingTranscription=false`。父视图用 `.id(id)` 固定当前材料，状态随材料切换重建，不会串到另一份素材。
5. `Sources/VoiceOSApp/WorkspaceSourceView.swift:750-764`：重试按钮改为带 label 的 `Button`，点击时先做一次性 guard 再置位；按钮显示小号 `ProgressView` 与「正在重试…」。禁用条件对齐 `WorkspaceProcessingView.swift:413/429` 的 `model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil`，并叠加本视图的 `retryingTranscription`。
6. 未改任何 accessibility identifier，未动卡片视觉，未动转写三态（111-A 的范围）。

## 验证

共享锁循环，工作目录 `.worktrees/m114-c`，`swift build -j 2` 与 `swift test -j 2` 串行。只认真实退出码。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 50.393 (50.462) seconds`
- 代码提交：`fbe8e3b fix(ui): 扫描与重试转写期间禁用按钮并显示进度`

## 未做与取舍

- 未做真实 UI 驱动：本轮约束是不重启应用，验证止于全量构建与测试，没有在跑着的 app 里点按钮看变灰。
- `ControlCenter.retry(_:)`（`Sources/VoiceOSApp/VoiceOSApp.swift` 约 `:4070`）模型层仍无 guard，本轮不在可改范围。视图层的 `retryingTranscription` 只挡住当前材料详情页的连点；处理页或其他入口同时触发时仍可能重复调用。建议后续在模型层补一个与处理页一致的 guard。
- `scan()` 在 `activeFolderID != nil`（正在整理素材）时会走 `requestScan(after: 10)` 提前返回，不置 `scanning`。此时点「检查新素材」仍看不到新的 spinner，但收件箱上方本来就有 `model.fullRecordingBusy` 的进度行，反馈不算缺失；补扫在 10 秒后自动执行。
- `retryFailures()` 自己会再调 `scan()`；若当前扫描未结束，既有 guard 会把请求合并为 `rescanRequested`，指示器持续到当前扫描结束，行为与改前一致。
- 未 push、未合并，记录未删。