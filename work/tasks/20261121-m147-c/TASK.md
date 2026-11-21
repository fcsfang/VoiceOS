# 147-C 副文本机制统一（第三批：助理/问题/英语/反思变更/提醒/费曼/分段/标注/录整段，14 文件）

## 背景
同 147-A/B。本批文件多为弹层与小页面，部分文件没有 palette 环境值，需要注入。

## 文件清单（只允许动这些）
- Sources/VoiceOSApp/AssistantExecutionView.swift（约 9 处）
- Sources/VoiceOSApp/QuestionViews.swift（约 8 处）
- Sources/VoiceOSApp/EnglishPracticeView.swift（约 8 处）
- Sources/VoiceOSApp/ReflectionChangeView.swift（约 6 处）
- Sources/VoiceOSApp/ReminderSettingsView.swift（约 5 处，需补 palette 环境值）
- Sources/VoiceOSApp/ReminderScheduleViews.swift（约 5 处，需补）
- Sources/VoiceOSApp/FeynmanPractice.swift（约 5 处）
- Sources/VoiceOSApp/TranscriptSegmentationView.swift（约 4 处，需补）
- Sources/VoiceOSApp/ReverifyControls.swift（约 3 处，按需补）
- Sources/VoiceOSApp/RecordingTitleEditor.swift（约 3 处，需补）
- Sources/VoiceOSApp/OutcomeFollowupView.swift（约 3 处）
- Sources/VoiceOSApp/Onboarding.swift（约 3 处，按需补）
- Sources/VoiceOSApp/IncrementalReadingView.swift（约 3 处，需补）
- Sources/VoiceOSApp/FullRecordingView.swift（约 3 处，按需补）

## 规则（与 147-A 一致）
- `.foregroundStyle(.secondary)` → `.foregroundStyle(palette.secondaryText)`；`.tertiary` → `palette.tertiaryText`。
- 作用域缺 `palette` 的子结构体补 `@Environment(\.workspacePalette) private var palette`。
- 跳过系统控件层次语义、无法等价替换的组合表达式。
- 不改文案、字号、字重、布局与业务。

## 验证
- 每文件改动前后计数对账；`xcrun --sdk macosx swiftc -parse <files>` 真实退出码 0；不跑 swift build/test。
- 回报：提交哈希、每文件替换数与跳过项、parse 退出码、diff --stat。