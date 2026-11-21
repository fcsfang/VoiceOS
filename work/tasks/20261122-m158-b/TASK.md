# 158-B 搜索建议预计算（WorkspaceView）

## 背景
性能发现：搜索页 `searchSuggestions` 每次击键都对全部记录取 `displayTitle`（正则 + ISO 解析 + 日期格式化）再做前缀匹配，且结果列表对每条命中做 O(hits×claims) 的成员检查。目标：把「标题预计算」与「按 id 的 claims 索引」移到数据代际缓存。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/WorkspaceView.swift

## 改动
1. 复用 157/158 的代际（`model.recordsRevision`；claims 变化用 `secondaryRevision`，若 157 未落地则沿用其中已定义的代际字段）。
2. **建议缓存盒**（文件私有，@State 持有）：
   ```swift
   private final class SearchSuggestionCache {
       struct Key: Equatable { let records: Int; let claims: Int }
       var key: Key?
       var entries: [(id: String, title: String, open: () -> Void)] = []
   }
   ```
   条目在 key 变化时构建一次：对每条 record 计算一次 `displayTitle`（与现在的选择/排序规则一致），保留原 open 语义所需的引用。
3. `searchSuggestions` 改为在缓存 entries 上做前缀/包含匹配（保持原匹配规则与排序、条数上限、去重逻辑逐字一致）。
4. 结果列表的 `claims` 成员检查若为嵌套过滤，把 claims 按 source/claim id 预建成 Set 或字典后再查（仅当语义严格等价的场景；不等价则不改并说明）。
5. 行为（建议内容、顺序、点击动作）必须与改动前一致。

## 约束
- 不改渲染、排序与过滤语义；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、缓存键与命中路径、匹配规则逐字对照、parse 退出码、diff --stat。