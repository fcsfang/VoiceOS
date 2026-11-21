# 147-A 副文本机制统一（第一批：八个高频文件）

## 背景
设计 token 发现：同一「次要文字」角色有两种机制并存——SwiftUI 层次色 `.foregroundStyle(.secondary)`（全仓约 380 处）与调色板 token `palette.secondaryText`（约 240 处），同角色在不同页面呈现不同对比与冷暖；`.tertiary` 与 `palette.tertiaryText` 亦然。本单元统一第一批八个高频文件的次要/第三级文字到调色板 token。

## 文件清单（只允许动这些）
- Sources/VoiceOSApp/WorkspaceActivityViews.swift（约 34 处）
- Sources/VoiceOSApp/WorkspaceTopicReadingView.swift（约 27 处）
- Sources/VoiceOSApp/WorkspaceView.swift（约 27 处）
- Sources/VoiceOSApp/VoiceOSApp.swift（约 23 处）
- Sources/VoiceOSApp/ThoughtPanoramaView.swift（约 21 处）
- Sources/VoiceOSApp/DiscussionView.swift（约 18 处）
- Sources/VoiceOSApp/WeeklyReviewView.swift（约 17 处）
- Sources/VoiceOSApp/KnowledgeReviewView.swift（约 16 处）

## 规则
- `.foregroundStyle(.secondary)` → `.foregroundStyle(palette.secondaryText)`；`.foregroundStyle(.tertiary)` → `.foregroundStyle(palette.tertiaryText)`。
- 每个改动的视图作用域里必须有 `palette`：文件/子视图已有 `@Environment(\.workspacePalette) private var palette` 就直接用；子结构体没有就为该结构体补这一行。若某 View 结构体无法加环境（静态辅助、菜单内容等），跳过并记录文件:行。
- 保留 `.secondary` 的场景（不要改）：系统控件的层次样式语义（菜单项 Label、ProgressView 内部、`.foregroundStyle(.secondary)` 作为 ShapeStyle 语义传给系统组件时若替换会破坏系统配色），以及 `.foregroundStyle(.secondary.opacity(...))` 之类的组合表达式（单独判断，能等价替换为 `palette.secondaryText.opacity(...)` 才改）。
- 不改文案、字号、字重、布局与业务；只换颜色来源。
- 同一行若已用 `palette.` 前缀或 `.foregroundStyle(palette.…)` 则不动。

## 验证
- 改动前后对每个文件 `grep -c "foregroundStyle(.secondary)"` 记录数量变化；最终该文件剩余应为 0 或有跳过理由。
- `xcrun --sdk macosx swiftc -parse <files>` 真实退出码 0。
- 不跑 swift build/test（波次批处理）。
- 回报里列每个文件改动数与跳过站点。

## 回报
提交哈希、每文件替换数与剩余/跳过项（文件:行 + 理由）、parse 退出码、diff --stat。