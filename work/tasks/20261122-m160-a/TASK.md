# 160-A 认知地图图数据缓存（ReflectionGraphView.swift）

## 背景
性能发现：认知地图每次 body 求值都重算 nodes/edges/positions——`nodes` 对每个表达做 `model.records.first` 线性查找（O(expressions × records)），缩放滑杆与图谱搜索每动一次都重算。三者只依赖 focus 内容与记录数据，可在代际内缓存。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/ReflectionGraphView.swift

## 改动
1. 文件私有缓存类：
   ```swift
   private final class AtlasGraphCache {
       struct Key: Equatable { let records: Int; let secondary: Int; let reflection: String }
       var key: Key?
       var nodes: [AtlasNode] = []
       var edges: [AtlasEdge] = []
       var positions: [String: CGPoint] = [:]
   }
   ```
   `ReflectionTimelineView` 持有 `@State private var graphCache = AtlasGraphCache()`。
2. `graph(focus)`（及调用 nodes/edges/positions 的位置）改为：key = `(model.recordsRevision, model.secondaryRevision, reflectionKey)`；key 命中直接用缓存；未命中时依次计算 nodes/edges/positions 并写入（positions 已确认只依赖 focus 与 nodes，不含视口/缩放）。
3. 缩放滑杆、视口尺寸、选中与检查器状态不参与 key；这些交互只做渲染变换或局部视图，不再触发三件套重算。
4. 若存在 `focus == nil` 或加载中的路径，保持原样不缓存。
5. 行为必须一致：节点/边内容、布局坐标、排序、选中与点击行为逐字保留。

## 约束
- 只改这一个文件；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、缓存键与命中路径、哪些交互因此不再重算、parse 退出码、diff --stat。