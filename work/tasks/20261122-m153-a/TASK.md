# 153-A 提醒设置与排期面板的行对齐（ReminderSettingsView / ReminderScheduleViews）

## 背景
设置页的「标签列 + 右对齐控件列 + 发丝线」语言已确认有效。提醒设置弹层（170 行）与排期面板（145 行）目前是 Toggle/Picker/DatePicker 逐行堆叠、控件左对齐、组间用裸 Divider，属同一反模式的小型版本。本单元把两个文件的控件对齐成行原语，不改任何逻辑。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/ReminderSettingsView.swift
- Sources/VoiceOSApp/ReminderScheduleViews.swift

## 可用原语（WorkspaceDesign.swift）
- `WorkspaceSettingsRow(title:subtitle:showsDivider:trailing:)`：标签列 + 右对齐控件列（行水平 padding 20、垂直 12、minHeight 46）。
- `WorkspaceSettingsValueRow`、`WorkspaceListDivider`、`WorkspaceNoticeText` 既有。
- 弹层内不套 `WorkspaceSettingsCard`（弹层本身已有表面）；用行原语 + 组标题 + 发丝线组织。

## 改动规则
1. **弹层内边距**：外层 `.padding(24)` 改为 `.padding(.vertical, 24)`（左右由行原语的 20 提供；标题/说明/底部按钮行单独加 `.padding(.horizontal, 24)`），保证所有行在同一左边缘。
2. **ReminderSettingsView 分组**（保持原顺序与条件）：
   - 组「日期与通知」：安排日期（Toggle 右侧）、日期（DatePicker 右侧）、具体时刻（Toggle 右侧）、发送通知（Toggle 右侧）、提醒我（DatePicker 右侧）、仅日期固定 09:00 与默认通知时间（作为「具体时刻」行的 subtitle）、优先级（Picker 右侧）。
   - 组「稍后提醒」：原预设按钮行保持一行（右侧或左侧均可，按视觉平衡），作为组内容行。
   - 组「地点提醒」：地点提醒（Toggle 右侧）、地点名称（TextField 右侧或整行）、提醒方式（segmented 右侧）、说明作为 subtitle。
   - 组标题使用 `Text(...).vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)`（沿用文件内现有标题样式），组间 `WorkspaceListDivider()`。
   - `action.title` 与「保存前会重新核对…」保留为顶部说明（非行）。
3. **ReminderScheduleViews**：同样把「日期/优先级/重复」等控件改为行对齐；它是面板视图，如已有 WorkspaceCard 外壳则保留外壳，只统一行。
4. **字段表面**：TextField 统一 `.workspaceFieldSurface()`；TextEditor 若有则 `.workspaceEditorSurface()`。
5. 底部「取消 / 保存到提醒事项」、所有 alert、disabled 条件、快捷键、`.environment(\.timeZone,…)`、`.interactiveDismissDisabled` 逐字保留。

## 约束
- 不改逻辑、文案、动作、alert 与可访问性标识；只改布局容器与对齐。
- 不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、两组件的行映射、保留原样项、parse 退出码、diff --stat。