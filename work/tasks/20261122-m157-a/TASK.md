# 157-A 行动页计算按代际缓存（WorkspaceView / VoiceOSApp）

## 背景
性能发现：行动页每次 body 求值都重算 `myTodoActions`（全量过滤）、`ActionTimeSurface.build`（遍历全部日程与提醒链接、逐行动解析 ISO 日期）、`ActionRowReads`（两遍提醒链接 + 全部执行）、`sourcePageIndex.nextStepCounts`（扫描全部行动），方向键每按一次还要再来一遍。数据不变时应复用。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/VoiceOSApp.swift
- Sources/VoiceOSApp/WorkspaceView.swift

## 改动
1. **代际**：`ControlCenter` 增加 `@Published private(set) var secondaryRevision = 0`。先 grep `actionRecords =`、`reminderLinks =`、`assistantExecutions =`、`scheduleIntents =`、`claims =` 的全部赋值点，将自增放在覆盖这些字段装配的 apply 函数末尾（通常是 applySecondarySnapshot；若 actionRecords 在 applyCoreSnapshot 装配则在两处各自自增同一计数器，确保任何一次装配都会推进）。
2. **缓存盒**（WorkspaceView.swift 文件私有）：
   ```swift
   private final class ActionPageCache {
       struct Key: Equatable { let records: Int; let secondary: Int; let minute: Int; let filter: String }
       var key: Key?
       var todoActions: [ActionRecord] = []
       var timeSurface: ActionTimeSurface?
       var rowReads: ActionRowReads?
       var nextStepCounts: [String: Int] = [:]
   }
   ```
   WorkspaceView 持有 `@State private var actionPageCache = ActionPageCache()`。
3. **actions 视图**：进入 body 时构建 key（recordsRevision、secondaryRevision、`Int(Date().timeIntervalSince1970/60)`、actionFilter）；key 变化时清空缓存。然后：
   - `todoActions` 从缓存取，缺失时计算 `myTodoActions` 并写入。
   - `rowReads` 从缓存取，缺失时构造并写入。
   - `nextStepCounts` 从缓存取，缺失时读 `model.sourcePageIndex.nextStepCounts` 并写入。
   - `timeSurface` 同 key（含 filter）缓存；仅当 filter 属于全部/我的待办时构建，nil 语义保持。
4. **键盘路径**（约 2700 与 2799 行 `ActionTimeSurface.build`）：若调用处使用与 body 相同的 actions/links/schedules 且 key 命中，复用缓存 surface；若其 actions 是过滤后的子集，不强行复用（在回报中说明）。行为与排序必须与缓存预热前后完全一致。
5. 其它派生值（focusedActions 集合、todoOrder 排序等）本轮不动。

## 约束
- 不改渲染结果、排序、过滤语义与动作；只加代际与缓存。
- 不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报中列出 secondaryRevision 自增点与 grep 证据、缓存命中路径、键盘路径复用与否及理由、parse 退出码、diff --stat。