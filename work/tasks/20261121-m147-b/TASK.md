# 147-B 副文本机制统一（第二批：反思/任务启动/讨论/更正/双语/记录想法，8 文件）

## 背景
同 147-A：`.foregroundStyle(.secondary)` 与 `palette.secondaryText` 两套机制并存。本批统一这 8 个文件；规则与 147-A 相同。

## 文件清单（只允许动这些）
- Sources/VoiceOSApp/ReflectionQuestionsView.swift（约 14 处）
- Sources/VoiceOSApp/TaskInitiationView.swift（约 13 处）
- Sources/VoiceOSApp/ReflectionGraphView.swift（约 13 处）
- Sources/VoiceOSApp/WorkspaceDiscussionView.swift（约 12 处）
- Sources/VoiceOSApp/CorrectionImpactView.swift（约 12 处，需为缺 palette 的子结构体补 `@Environment(\.workspacePalette) private var palette`）
- Sources/VoiceOSApp/ReflectionTimelineView.swift（约 11 处）
- Sources/VoiceOSApp/BilingualView.swift（约 11 处）
- Sources/VoiceOSApp/TextCaptureView.swift（约 10 处）

## 规则（与 147-A 一致）
- `.foregroundStyle(.secondary)` → `.foregroundStyle(palette.secondaryText)`；`.foregroundStyle(.tertiary)` → `.foregroundStyle(palette.tertiaryText)`。
- 每个改动作用域必须能解析到 `palette`；缺的子结构体补环境值。
- 跳过：系统控件层次语义（菜单 Label、ProgressView 等）、`.secondary.opacity(...)` 等组合表达式无法等价替换者、以及 `palette.secondaryText.opacity(...)` 已有写法。
- 不改文案、字号、字重、布局与业务。

## 验证
- 每文件改动前后 `grep -c "foregroundStyle(.secondary)"` 对账；剩余应为 0 或有跳过理由。
- `xcrun --sdk macosx swiftc -parse <files>` 真实退出码 0；不跑 swift build/test。
- 回报：提交哈希、每文件替换数与跳过项（文件:行 + 理由）、parse 退出码、diff --stat。