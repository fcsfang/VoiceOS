# 144-C 阅读/引用/首页的动效一致性（WorkspaceReadingViews / QuoteHoverPreview / RecentContentHome）

## 背景
动效发现：展开/收起同时存在 0.15s、0.16s、0.2s 三种时长且部分 disclosure 无动画；引用悬停预览瞬间弹出无过渡；首页「跳到列表」四处跳转四种时长而键盘选中滚动是瞬时的。本单元用 144-B 在 WorkspaceDesign 定义的 `WorkspaceMotion` 词表统一（该词表在并行单元提供，本工作树暂时不存在是正常的，直接按契约引用，不要另建定义）：
- `WorkspaceMotion.hover`（0.12 easeOut）
- `WorkspaceMotion.expand`（0.16 easeOut）
- `WorkspaceMotion.scroll`（0.18 easeOut）

## 文件清单（只允许动这三个）
- Sources/VoiceOSApp/WorkspaceReadingViews.swift
- Sources/VoiceOSApp/QuoteHoverPreview.swift
- Sources/VoiceOSApp/RecentContentHome.swift

## 逐条

### 1. WorkspaceReadingViews 展开/收起
- 约 130 行 `withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16))` 改用 `WorkspaceMotion.expand`。
- grep 本文件所有 `withAnimation`/`.animation(`：展开/收起类统一用 expand 词表（reduceMotion 门控保留）；发现 disclosure 箭头旋转或内容插入没有任何动画的，补 `withAnimation(reduceMotion ? nil : WorkspaceMotion.expand)`（仅限同一披露区内）。
- 不改内容与布局。

### 2. QuoteHoverPreview 淡入淡出
- 约 38-60 行：`if revealed { panel.offset(...) }` 无过渡。给 panel 加 `.transition(.opacity)`，并在 `revealed` 变化处用 `withAnimation(reduceMotion ? nil : WorkspaceMotion.hover)` 驱动（本文件若已有 `@Environment(\.accessibilityReduceMotion)` 复用，没有就加）；`zIndex` 逻辑与 hover 进出保持原样。

### 3. RecentContentHome 跳转/滚动
- 约 532 行起「跳到列表」「跳到时间线」等 section 跳转：统一 `withAnimation(reduceMotion ? nil : WorkspaceMotion.scroll) { proxy.scrollTo(...) }`；本文件其它 `easeOut(duration:` 手写时长按用途归类到 scroll 或 expand（展开「最近想法」属 expand）。
- 键盘选中滚动保持瞬时（不加动画，避免连按 ↓ 拖沓）；只统一「显式跳转控件」的时长。

## 约束
- 只改动画/过渡与词表引用，不改视觉参数、布局与业务。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：提交哈希、逐条完成情况、parse 退出码、diff --stat。