# 153-B 主应用表单弹层的行对齐与字段表面（VoiceOSApp.swift 四个 sheet）

## 背景
设置页语言推广后，主应用内四个表单弹层（ActionCreationView / ActionFeedbackView / PackageRestoreView / BackupLibraryRestoreView）仍用裸 TextField（系统边框）与左对齐控件，与全站字段表面和行节奏不一致。只改这四个结构体的布局与字段表面。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/VoiceOSApp.swift

## 允许改动的结构体（其余一律不动）
- `ActionCreationView`（约 4645 行）
- `ActionFeedbackView`（约 4681 行）
- `PackageRestoreView`（约 4750 行）
- `BackupLibraryRestoreView`（约 4814 行）

## 改动规则
1. 所有 TextField 改 `.workspaceFieldSurface()`；TextEditor 改 `.workspaceEditorSurface()`；保留原 `.onSubmit`/`.focused`/`.disabled` 与顺序。
2. 用 `WorkspaceSettingsRow(title:subtitle:showsDivider:trailing:)` 对齐「标签在左、控件在右」的行（分段 Picker、Toggle、按钮）；输入型字段保持整行宽度（标签用行标题或字段 placeholder，二选一按可读性），字段上方说明保留。
3. 弹层主体左右 padding 由行原语提供（外层 24 → 垂直 24；标题与底部按钮行单独水平 24），保证同一左边缘。
4. 组与组之间可用 `WorkspaceListDivider()`；弹层内不套卡片。
5. 底部页脚按钮、快捷键、disabled 条件、错误/反馈文本、alert、所有模型调用逐字保留。

## 约束
- 只动上述四个结构体；不改逻辑、文案、动作、可访问性标识。
- 不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、每个结构体的改动摘要、parse 退出码、diff --stat。