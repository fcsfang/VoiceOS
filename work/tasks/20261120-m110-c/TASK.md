# 波 110-C：动画门控、语义色与列宽随字号

单元 110-C，按 ui-ux-pro-max SwiftUI 规则修复。行为、文案、identifier 不变。

## 改动清单

### 动画门控（WorkspaceView.swift）

三处悬停淡入各加 `@Environment(\.accessibilityReduceMotion) private var reduceMotion`，动画改为 `reduceMotion ? nil : .easeOut(duration:0.12)`：

- `RecentSearchChip` 删除按钮悬停。
- `MaterialMenuRow` 菜单悬停。
- `WorkspaceActionRowChrome` 菜单悬停。

同文件 grep `withAnimation`/`.animation(` 后仅此三处，无其余未门控动画。

### 语义色

- `VoiceOSApp.swift` `ImportBatchReportView` 结果图标 `Color.green : Color.orange` → `palette.success : palette.warning`。
- `VoiceOSApp.swift` `ActionFeedbackView` 错误文本 `.red` → `palette.danger`。
- `VoiceOSApp.swift` `PackageRestoreView` 与 `BackupLibraryRestoreView` 完成提示 `.green` → `palette.success`。
- `QuickNote.swift` `QuickNoteView` 保存错误 `.red` → `palette.danger`。

调色板注入点只有一处：`WorkspaceView.swift:408` 对 `styledContent` 注入 `workspacePalette`。`ActionFeedbackView`、`PackageRestoreView`、`BackupLibraryRestoreView` 的 sheet/页面都挂在该子树内，因此直接加 `@Environment(\.workspacePalette)`。`ImportBatchReportView` 的 sheet 挂在 App scene 根部、`QuickNoteView` 是独立 `NSHostingView` 根，二者都在注入之外，按任务要求改用 `WorkspacePalette(theme: WorkspaceTheme(rawValue: UserDefaults.standard.string(forKey: "voiceos.workspaceTheme") ?? "") ?? .graphite)` 兜底；环境键本身默认值是 graphite，不会崩溃。

### 固定列宽随字号

- `ReflectionQuestionsView.swift:86` `frame(width: 240)` → `240 * vosLayoutScale(textScale)`，新增 `@Environment(\.vosTextScale)`。
- `ReflectionChangeView.swift:40` `frame(width: 210)` → `210 * vosLayoutScale(textScale)`，新增 `@Environment(\.vosTextScale)`。

`vosLayoutScale` 把倍率夹在 1.0–1.3，默认字号下宽度不变。`ReflectionQuestionsView:171` 另有一处 210 的固定宽度包住分段 Picker，不是可变长文本，未在任务清单内，保持原样。

## 构建与测试（真实退出码）

单一构建锁 `/tmp/voiceos-swift-build.lock`，未超时。

- `swift build -j 2`：build_exit=0。
- `swift test -j 2`：test_exit=0。
- `Executed 669 tests, with 0 failures (0 unexpected) in 50.858 (50.931) seconds`。

日志：`/tmp/m110-c-build.log`、`/tmp/m110-c-test.log`。

## 未做的事

- 不写实时库、不重启应用、不 push、不合并。
- 未做实机视觉验收：本单元只改动画门控、状态色与列宽，行为与文案不变，以构建与测试为验证依据。