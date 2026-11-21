# 143-A 弹层按钮词表统一（除 WorkspaceView/VoiceOSApp/WorkspaceDesign 之外的文件）

## 背景
设计 token 发现：全仓声明了统一按钮词表（workspacePrimary/workspaceSecondary 等，WorkspaceDesign.swift:515 起），但 53 个 `.keyboardShortcut(.cancelAction)` 按钮里 28 个没有工作区样式，5/24 个 defaultAction 也没有。它们渲染成原生 bezel/系统强调色按钮，同一弹层里常和已套用样式的按钮并排，观感突变。目标：只补/换样式，不改布局、文案、快捷键与业务。

## 文件清单（只允许动这些）
- Sources/VoiceOSApp/EnglishPracticeView.swift（21、97）
- Sources/VoiceOSApp/IncrementalReadingView.swift（53）
- Sources/VoiceOSApp/OutcomeFollowupView.swift（56）
- Sources/VoiceOSApp/DiscussionHistoryView.swift（22，WorkspaceIconButton 不需要改为文字样式，仅确认；若已是自定义样式则跳过）
- Sources/VoiceOSApp/TranscriptSegmentationView.swift（38）
- Sources/VoiceOSApp/FeynmanPractice.swift（30、72；注意 30 的取消与 31 的对照原话要成套）
- Sources/VoiceOSApp/CorrectionImpactView.swift（76、137）
- Sources/VoiceOSApp/ConfirmTaskView.swift（21 取消、28 确认）
- Sources/VoiceOSApp/ClaimReviewHistoryView.swift（40）
- Sources/VoiceOSApp/QuestionViews.swift（56）
- Sources/VoiceOSApp/ThoughtPanoramaView.swift（870、1044、1117 三处 xmark/关闭）

## 规则
- 取消/关闭/完成类（cancelAction）→ `.buttonStyle(.workspaceSecondary)`；纯图标按钮（如 xmark）保持现有图标按钮样式，若它已经用了 WorkspaceIconButton/自定义样式就不动，只把裸 Button 换成 `.buttonStyle(.workspaceQuiet)` 并保持图标。
- 默认/主操作（defaultAction、保存、确认类）→ `.buttonStyle(.workspacePrimary)`。
- 同一弹层的按钮风格要成套：如果主按钮已是 workspacePrimary，只补齐取消；如果两个都是裸 Button，两个一起补。
- 不改 `.disabled`、`.help`、`.accessibilityLabel`、顺序与文案。
- 用 grep 逐文件核对实际现状（行号可能有 ±3 漂移）；核实不成立或已套样式的跳过并记录。

## 约束
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：提交哈希、每个文件改动行、跳过项及证据、parse 退出码、diff --stat。