# 145-B 首页/主题/材料/行动的自绘表面动效（RecentContentHome / WorkspaceTopicReadingView / WorkspaceSourceView / WorkspaceActivityViews）

## 背景
动效发现第二组：HomeCard、主题瓦片、材料行、行动子任务图标等自绘表面在悬停/选中时瞬切，而行尾菜单已用 0.12s 淡入。本单元用已合入的 `WorkspaceMotion`（hover 0.12 / selection 0.12，easeOut）统一，调用点保留 `reduceMotion ? nil : ...` 门控。

## 文件清单（只允许动这四个）
- Sources/VoiceOSApp/RecentContentHome.swift
- Sources/VoiceOSApp/WorkspaceTopicReadingView.swift
- Sources/VoiceOSApp/WorkspaceSourceView.swift
- Sources/VoiceOSApp/WorkspaceActivityViews.swift

## 逐条

### 1. RecentContentHome
- `HomeCard`（约 1030-1050 行）：`hovered` 驱动的背景变化加 `.animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)`。
- 文件内其余手写 `easeOut(duration: 0.12)` 换 `WorkspaceMotion.hover`（门控保留）。

### 2. WorkspaceTopicReadingView
- 主题瓦片（`WorkspaceTopicTile` 与阅读卡片 `readingCard`）的 hover 背景、选中描边/焦点环切换：hover 用 hover 词表，selected/highlighted 用 selection 词表（各自加 `.animation(..., value:)`）。
- 文件内手写 0.12/0.15 时长按用途换词表。

### 3. WorkspaceSourceView
- 材料头部行、相关材料行、原文版本行等自绘 hover（`hovered ? palette.hover` 之类）加 hover 动效；回听列表选中背景加 selection 动效。
- 文件内手写 0.12 换 `WorkspaceMotion.hover`。

### 4. WorkspaceActivityViews
- 子任务/下一步完成圈与行尾菜单的 hover（约 706/718/957 行附近）：加 hover 动效（这些图标从透明/无底变有底）。
- 文件内手写 0.12 换 `WorkspaceMotion.hover`。
- 不改禁用逻辑、命中区尺寸与文案。

## 约束
- 只改动画/词表引用，不改视觉参数、布局与业务；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 每条先 grep 核实现状；机制不符的跳过并记录证据。

## 回报
提交哈希、逐条完成/跳过及原因、parse 退出码、diff --stat。