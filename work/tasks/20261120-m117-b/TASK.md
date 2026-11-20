# 波 117-B 取消与关闭按钮的 Esc 路径与空浮层说明

基线 `work/m117-b`（基于 main c8fb253），工作树 `.worktrees/m117-b`。只改九个视图文件。

## 目标

一批 sheet 的取消/关闭按钮没有 `.keyboardShortcut(.cancelAction)`，键盘与 VoiceOver 用户没有确定的 Esc 退出路径。`ThoughtPanoramaView` 的两个浮层在没有快照时只显示标题和关闭按钮，读屏几乎听不到内容。

## 逐文件清单

- `Sources/VoiceOSApp/ConfirmTaskView.swift:20` 取消。
- `Sources/VoiceOSApp/ReminderSettingsView.swift:95` 取消。
- `Sources/VoiceOSApp/ReminderScheduleViews.swift:68` ActionScheduleEditor 取消；`:114` ReminderScheduleConfirmationView 暂不修改。
- `Sources/VoiceOSApp/WorkspaceSourceView.swift:1623` WorkspaceTranscriptEditor 取消；`:1668` ClaimCorrectionView 取消；`:1709` 原有取消，未动。
- `Sources/VoiceOSApp/TextCaptureView.swift:242` 模板命名取消；`:286` 链接导入取消。
- `Sources/VoiceOSApp/ThoughtPanoramaView.swift:689` 覆盖面板关闭；`:443` 问题与联系浮层在 snapshot 为空时显示「还没有可显示的内容」；`:693` 覆盖面板在 state 为 nil 时显示同样空态。
- `Sources/VoiceOSApp/ActionClarifyQueueView.swift:67` 关闭。
- `Sources/VoiceOSApp/DiscussionView.swift:19` 关闭；`:197` 引用预览 sheet 的完成按钮，基线约 `:195`。
- `Sources/VoiceOSApp/DiscussionHistoryView.swift:21` 关闭历史讨论图标按钮。

## 约束核对

- `.keyboardShortcut(.cancelAction)` 只加在取消、关闭与等效退出动作上。暂不修改、完成都是弹层的退出路径，未加在确认、保存、删除主操作上。
- 未新增 `.interactiveDismissDisabled`。既有的三处保持原样：`ConfirmTaskView` 的 `savingAction`、`ReminderSettingsView` 的 `reminderFieldEditing`、`TextCaptureView` 的 `draft.saving`。
- 未改 identifier、文案与视觉布局。两处空态复用 `WorkspaceEmptyState`，文案沿用「还没有…」。
- alert 内 `Button(role: .cancel)` 由系统提供 Esc，未重复添加。`ReminderSettingsView` 的「关闭并清空通知」是破坏性主操作，未加快捷键。

## 验证

共享锁循环，工作目录 `.worktrees/m117-b`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码：

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 46.928 (46.996) seconds`
- 代码提交 `dbb08dd fix(ui): 取消与关闭按钮支持 Esc，空浮层补空态说明`

## 未做与取舍

- 未重启应用，未做 UI 真机验证。Esc 路径由 SwiftUI `.keyboardShortcut(.cancelAction)` 提供，验证止于全量构建与测试。
- `DiscussionView.swift:197` 的「完成」是引用预览 sheet 的唯一退出按钮，基线行号约 `:195`，按任务意图补 Esc。
- 覆盖面板空态下仍保留一个空 `ScrollView`，未重构布局，避免改动视觉结构。
- deslop 检查：diff 无新增注释、防御性代码或嵌套。