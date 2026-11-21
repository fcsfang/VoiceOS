# 162-B 线索/未归组列表视口恢复（WorkspaceView）

## 背景
144 波给材料/行动/主题/搜索/主题材料/主题回顾六个列表加了「按保留的键盘选中行恢复视口」；主题页的「线索」与「尚未归入主题的材料」两个可聚焦列表仍有 onChange scrollTo 但缺 onAppear 恢复。

## 改动
- 两个列表容器（`handleClueListKey`/`handleUnlinkedListKey` 所在链）在 `.onChange(…scrollTo)` 之后各加 `.onAppear { restoreKeyboardScroll(proxy: proxy, id: …KeyboardFocus.id) }`，复用既有 helper。

## 验证
`xcrun --sdk macosx swiftc -parse Source/VoiceOSApp/WorkspaceView.swift` 退出码 0；行为验证随 162 集成构建与真机（截图通道恢复后）。