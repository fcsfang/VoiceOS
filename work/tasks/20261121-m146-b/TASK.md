# 146-B 区块标题语义扫（第二组：活动 / 任务启动 / 反思图 / 问题 / 讨论 / 更正 / 主题阅读 / 各表单弹层）

## 背景
同 146-A：裸 `Text(...).vosFont(WorkspaceText.sectionTitle)` 缺 `.accessibilityAddTraits(.isHeader)`。本单元负责第二组文件；`WorkspaceDesign.swift` 与 `MarkdownText.swift` 的命中是组件内部已带 trait 与字号函数，不在清单内。

## 文件清单（只允许动这些，括号为待检查站点数）
- Sources/VoiceOSApp/WorkspaceActivityViews.swift（2）
- Sources/VoiceOSApp/TaskInitiationView.swift（2）
- Sources/VoiceOSApp/ReflectionGraphView.swift（2）
- Sources/VoiceOSApp/ReflectionChangeView.swift（2）
- Sources/VoiceOSApp/QuestionViews.swift（2）
- Sources/VoiceOSApp/DiscussionView.swift（2）
- Sources/VoiceOSApp/CorrectionImpactView.swift（2）
- Sources/VoiceOSApp/WorkspaceTopicReadingView.swift（1）
- Sources/VoiceOSApp/TranscriptSegmentationView.swift（1）
- Sources/VoiceOSApp/RecordingTitleEditor.swift（1）
- Sources/VoiceOSApp/OutcomeFollowupView.swift（1）
- Sources/VoiceOSApp/IncrementalReadingView.swift（1）
- Sources/VoiceOSApp/FeynmanPractice.swift（1）
- Sources/VoiceOSApp/EnglishPracticeView.swift（1）
- Sources/VoiceOSApp/ConfirmTaskView.swift（1）
- Sources/VoiceOSApp/ClaimReviewHistoryView.swift（1）
- Sources/VoiceOSApp/BilingualView.swift（1）
- Sources/VoiceOSApp/ActionClarifyQueueView.swift（1）

## 规则
- 对每个 `.vosFont(WorkspaceText.sectionTitle)` 的 `Text` 链，若链上还没有 `.accessibilityAddTraits(.isHeader)`，在 `vosFont(...)` 调用之后追加 `.accessibilityAddTraits(.isHeader)`。已带 trait 的跳过。
- 判定为「区块标题」的才加：独立成行的标题、弹层内小节标题、分组标题。行内计数、按钮标签的一部分或纯说明文字跳过并记录行号与理由。
- 只加 trait，不改文案、样式、布局与业务。

## 验证
- `grep -c "WorkspaceText.sectionTitle" 每文件` 与改动数对账；改动后逐文件人工核对每条链都有 trait 或记录跳过理由。
- `xcrun --sdk macosx swiftc -parse <files>` 真实退出码 0。
- 不跑 swift build/test（波次批处理）。

## 回报
提交哈希、每个文件改动站点数、跳过项（文件:行 + 理由）、parse 退出码、diff --stat。