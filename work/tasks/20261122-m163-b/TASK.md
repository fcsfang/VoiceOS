# 163-B 认知地图缓存纳入 focus 代际（ReflectionGraphView.swift）

## 背景（评审 CONFIRMED）
`AtlasGraphCache` 键为 (recordsRevision, secondaryRevision, reflectionKey)。`reload()` 会替换 focus（如「主题与问题」里接回主题/切换来源后 dismiss 触发的 reload），但主题链接写入只写 store、不刷新 model，两代际不变，缓存继续返回旧图谱（新关联永不出现，手动刷新同样无效，直到 60s 全量刷新）。修复：把 focus 代际纳入缓存键。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/ReflectionGraphView.swift

## 改动
1. 新增 `@State private var focusGeneration = 0`；凡成功给 `focus` 赋新值处（`reload()` 成功后、其它加载路径）自增。
2. `AtlasGraphCache.Key` 增加 `focusGeneration: Int`，`graphData` 用于键比较。
3. 其余缓存语义不变（loading 时不读写缓存、focus 为 nil 不缓存）。
4. 行为：同一 reflectionKey 下重载出新 focus 时，图谱/检查器立即使用新 nodes/edges/positions；未重载时仍享受缓存。

## 约束
- 只改这一个文件；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、focus 赋值点与自增位置、parse 退出码、diff --stat。