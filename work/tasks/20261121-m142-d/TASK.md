# 142-D 首页点击行为、禁用按钮 hover、选读文本主题色、速记面板主题（RecentContentHome / WorkspaceDesign / SelectableText / WorkspaceTheme / QuickNote）

## 背景
只读发现（状态 + token 两路）确认：首页点击条目会把时间线强行居中并夺焦、禁用按钮仍有 hover 底色、全文选读的 AppKit 文本视图写死系统色、速记浮窗是唯一不套主题的窗口。目标最小修复，不改主题色值。

## 文件清单（只允许动这五个文件）
- Sources/VoiceOSApp/RecentContentHome.swift
- Sources/VoiceOSApp/WorkspaceDesign.swift
- Sources/VoiceOSApp/SelectableText.swift
- Sources/VoiceOSApp/WorkspaceTheme.swift
- Sources/VoiceOSApp/QuickNote.swift

## 逐条

### 1. 首页时间线只在键盘选择时滚动居中
- RecentContentHome.swift：`onChange(of: selectedID)`（约 183 行）目前无条件 `timelineFocused = true` 并 `proxy.scrollTo(id, anchor:.center)`。加 `@State private var keyboardDrivenSelection = false`：`handleTimelineKey` 在赋值 selectedID 前置 true；行 Button 动作（鼠标点击，约 164 行）置 false。onChange 中仅在 keyboardDrivenSelection 时 scrollTo；timelineFocused 赋值保留（点击让列表获得键盘焦点是期望行为）。鼠标点击后把 keyboardDrivenSelection 复位，避免下一次程序性赋值误滚动。

### 2. 禁用按钮不再有 hover 底色
- WorkspaceDesign.swift `WorkspaceButtonBody`（约 556-579 行）：每个 hover 分支改成 `hovered && isEnabled`；`.onChange(of: isEnabled)`（或等价）在变为禁用时把 hovered 置 false。opacity 0.4 的禁用表现保持不变。

### 3. 全文选读跟随主题文字色
- WorkspaceTheme.swift 的 `WorkspacePalette` 新增 `var textNSColor: NSColor`，用与 `adaptive` 相同的动态外观闭包返回 text 的两套色值（浅色 0x1F1F1D/0x1A1A1C/0x242F26 等与 `text` 属性一一对应，按 theme switch；可直接把现有 `text` 的 light/dark 值抽成私有 `textValues` 元组供两者共用，避免重复色值）。
- SelectableText.swift：新增 `var textColor: NSColor = .labelColor`，两处 `textView.textColor = .labelColor` 改用参数。
- 调用点 WorkspaceSourceView.swift:867 左右传入 `palette.textNSColor`。**注意：只允许修改 WorkspaceSourceView 的这一处调用参数**（本单元对 WorkspaceSourceView 的唯一许可）。

### 4. 速记浮窗套主题
- QuickNote.swift `QuickNoteView.body`（约 72-89 行）：加 `.foregroundStyle(palette.text)` 与 `.background(palette.canvas)`（覆盖整窗），输入区沿用文件内现有工作区字段样式；不改布局结构、不改业务。若面板背景由 NSPanel 决定，也给 hosting view 外层加同色背景避免边框露色。

## 约束
- 不改主题色值（用户已定稿三个主题）；不改业务逻辑与文案；不改清单外文件。
- 不跑 swift build/test（波次批处理）。改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，以真实退出码为准（不经管道）。
- 完成后在本工作树提交，尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`；不推送。

## 验证
- `swiftc -parse` 退出码 0。
- `git diff --stat` 只触及清单内文件（WorkspaceSourceView 仅一行参数）。
- 回报：提交哈希、逐条完成情况、textNSColor 实现方式、任何判定不成立的条目及证据。