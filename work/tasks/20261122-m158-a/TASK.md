# 158-A 主题页清单缓存（WorkspaceView / VoiceOSApp）

## 背景
性能发现：主题页 `visibleTopicListings` 每次 body 求值都把全部主题重新 `topicListing`（逐条解析每个关联材料的 createdAt、逐 source `Calendar.startOfDay`）并排序；主题搜索框每击键触发一次；打开主题与 topicReading 路径还会再算。目标：数据不变时复用已建清单。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/VoiceOSApp.swift
- Sources/VoiceOSApp/WorkspaceView.swift

## 改动
1. **代际**：检查 `model.workspaceTopics` 与 `workspaceTopicSources` 的装配位置（grep 赋值/计算来源）。若它们由快照派生，复用/扩展 157 已加的 `recordsRevision`（必要时在装配函数补自增）；若它们独立更新，新增 `@Published private(set) var topicsRevision` 并在装配处自增。不得漏掉任何影响清单的输入（主题标题/摘要/updatedAt、关联材料集合、材料 createdAt）。
2. **缓存盒**（WorkspaceView.swift 文件私有）：
   ```swift
   private final class TopicListingCache {
       struct Key: Equatable { let records: Int; let topics: Int }
       var key: Key?
       var listings: [TopicListing] = []
       var byID: [String: TopicListing] = [:]
   }
   ```
   WorkspaceView 持有 `@State private var topicListingCache = TopicListingCache()`。
3. **visibleTopicListings**：key 命中直接取缓存，否则构建全部 `topicListing`（保持原排序：latestActivity 降序、标题 localizedStandardCompare），同时生成 byID；`topicReading(_:)` 取 level 时也走 byID 而非再算。
4. `topicLoadKey` 里的 `sourcePageIndex.currentActionKeys` 若为 O(actions) 扫描，将其结果按 key（records/secondary 代际 + topicID 集合）缓存或直接使用缓存 listing 中已含的 action 版本信息（按代码结构选择，回报说明）。
5. 过滤（topicQuery 标题/摘要包含）仍在缓存清单上做廉价过滤。

## 约束
- 不改渲染结果、排序、过滤语义；只加代际与缓存。
- 不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、代际自增点与证据、缓存命中路径、topicLoadKey 处理方式、parse 退出码、diff --stat。