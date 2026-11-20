# 波 114-B 字号环境覆盖应用级 sheet 与速记面板

基线 `work/m114-b`，工作树 `.worktrees/m114-b`。只改 `Sources/VoiceOSApp/VoiceOSApp.swift` 与 `Sources/VoiceOSApp/QuickNote.swift`。

## 目标

用户选择的阅读字号（`vosTextScale` 与 `dynamicTypeSize`）原本只在 `WorkspaceView` 内部注入。应用级 sheet（新手引导、导入结果、记录想法 `TextCaptureView`）和独立速记面板拿不到，「特大 1.45」在最高频的捕获入口不生效。

## 注入点证据

- 唯一注入点：`WorkspaceView.swift:405-411` 的 `styledContent`，`.environment(\.vosTextScale, model.textSize.scale)` 与 `.dynamicTypeSize(model.textSize.dynamicType)` 挂在 `chrome` 链上。
- 应用级 sheet：`VoiceOSApp.swift:4577-4587`，`WorkspaceView(model:).onboarding(model:)` 再挂两个 `.sheet`（`ImportBatchReportView`、`TextCaptureView`）。`.onboarding` 的 presenter 在 `Onboarding.swift:240-267` 内部用 `.sheet`。这些 sheet 挂在注入点之外，拿到 `VOSTextScaleKey` 默认值 `AppTextSize.standard.scale`（1.12），`dynamicTypeSize` 为系统默认。
- 速记面板：`QuickNote.swift:34` 自建 `NSHostingView(rootView: QuickNoteView(...))`，是独立根，同样拿默认值。
- 字号来源：`ControlCenter.textSize` 是 `@Published`，持久化键为 `voiceos.textSize.v1`（读 `VoiceOSApp.swift:819`，写 `setTextSize` `:820-822`）。`AppTextSize.scale` 与 `.dynamicType` 见 `WorkspaceTextScale.swift:16-31`。

## 逐条修法

1. `VoiceOSApp.swift:4623-4630` 新增 `View.vosTextEnvironment(_ size: AppTextSize)`，一次写入 `vosTextScale` 与 `dynamicTypeSize`，调用点为 `:4626`。
2. `VoiceOSApp.swift:4588` 在 `Window("VoiceOS")` 内容链末端、两个 `.sheet` 之后调用 `.vosTextEnvironment(model.textSize)`。`model` 是 App 的 `@StateObject`（`:4573`），scene 层可见。环境修饰符包住 sheet 呈现，sheet 内容继承，新手引导、导入结果、记录想法三个 sheet 与主窗口由同一次注入覆盖。`WorkspaceView` 内部注入保留，同值重复无害。
3. `QuickNote.swift:87` 在 `QuickNoteView` 根链调用 `.vosTextEnvironment(model.textSize)`。数据源用传入 `ControlCenter` 的 `@Published textSize`，与主界面同源；面板开着时改字号会即时更新。未重复读 UserDefaults：键名已查证为 `voiceos.textSize.v1`，但 `model.textSize` 就是该键的实时值。
4. 未改字号令牌、标识符、文案；未改 `WorkspaceView` 内部注入。

## 验证

共享锁循环，工作目录 `.worktrees/m114-b`。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 43.979 (44.039) seconds`

## 未做与取舍

- 未驱动真实 UI：约束是不重启应用，验证止于全量构建与测试。sheet 与速记面板中字号是否实际放大未做截图核对。
- `WindowGroup("独立资料库")`（`VoiceOSApp.swift:4614`）不在本轮范围，未注入，该窗口仍用默认字号。
- sheet 内的 `workspacePalette` 同样在应用级注入之外。`ImportBatchReportView` 与 `QuickNote` 已有 UserDefaults 主题兜底，`TextCaptureView` 仍取默认 palette。不在本轮范围。
- 未 push、未合并。