# 147-D 副文本机制统一（第四批：零散文件 14 个）

## 背景
同 147-A。本批为余下所有含 `.foregroundStyle(.secondary)` 的零散文件（各 1-3 处）。

## 文件清单（只允许动这些）
- Sources/VoiceOSApp/ActionClarifyQueueView.swift（约 3 处）
- Sources/VoiceOSApp/TopicClaimConfirmViews.swift（约 2 处，按需补 palette）
- Sources/VoiceOSApp/RecentContentHome.swift（约 2 处）
- Sources/VoiceOSApp/PanoramaConstellation.swift（约 2 处，注意其自绘颜色上下文）
- Sources/VoiceOSApp/ClaimReviewHistoryView.swift（约 2 处，按需补）
- Sources/VoiceOSApp/ClaimNoteViews.swift（约 2 处，按需补）
- Sources/VoiceOSApp/WorkspaceDesign.swift（约 1 处，若在共享组件内且 palette 已在作用域则替换；若属系统语义则跳过）
- Sources/VoiceOSApp/TopicResurfacingCard.swift（约 1 处，按需补）
- Sources/VoiceOSApp/QuoteHoverPreview.swift（约 1 处）
- Sources/VoiceOSApp/QuickNote.swift（约 1 处）
- Sources/VoiceOSApp/QuestionAnswerSection.swift（约 1 处，按需补）
- Sources/VoiceOSApp/DiscussionHistoryView.swift（约 1 处）
- Sources/VoiceOSApp/ConfirmTaskView.swift（约 1 处，按需补）
- Sources/VoiceOSApp/ActionReviewResolutionView.swift（约 1 处，按需补）

## 规则（与 147-A 一致）
- `.foregroundStyle(.secondary)` → `.foregroundStyle(palette.secondaryText)`；`.tertiary` → `palette.tertiaryText`。
- 作用域缺 `palette` 的子结构体补 `@Environment(\.workspacePalette) private var palette`。
- 跳过系统控件层次语义与无法等价替换的组合表达式。
- 不改文案、字号、字重、布局与业务。

## 验证
- 每文件改动前后计数对账；`xcrun --sdk macosx swiftc -parse <files>` 真实退出码 0；不跑 swift build/test。
- 回报：提交哈希、每文件替换数与跳过项、parse 退出码、diff --stat。