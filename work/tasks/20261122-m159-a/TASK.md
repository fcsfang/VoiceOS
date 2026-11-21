# 159-A 行动详情派生值缓存与静态格式器（WorkspaceActivityViews.swift）

## 背景
性能发现：行动详情页每次 body 求值都做多次跨表扫描（claims.first 找引用→records.filter 出 sources；assistantExecutions 过滤+排序出 executions；correctedClaim/latestAnalysis 再扫 claims/executions），反馈行每条还分配 DateFormatter。目标：按数据代际缓存派生值，并把行内日期格式器静态化。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/WorkspaceActivityViews.swift

## 改动
1. **派生缓存**（文件私有类 + WorkspaceTaskView 内 @State 持有）：
   ```swift
   private final class TaskDetailDerivedCache {
       struct Key: Equatable { let records: Int; let secondary: Int; let actionID: String; let actionVersion: Int; let isQuestion: Bool }
       var key: Key?
       var sources: [SourceRecord] = []
       var executions: [AssistantExecutionRecord] = []
       var correctedClaim: CandidateClaim?
       var latestAnalysis: AssistantExecutionRecord?
   }
   ```
   key 由 `model.recordsRevision`、`model.secondaryRevision`（157 已落地）、action.id/version 与 isQuestion 组成。key 变化时重算并写入；`sources`/`executions`/`correctedClaim`/`latestAnalysis` 四个计算属性改为从缓存读取（保留原谓词与排序语义逐字一致）。
2. **subtasks/nextActions**：若为 `model.actionRecords.filter { $0.parentID == action.id ... }` 形式，按 (records, secondary, actionID) 缓存；若逻辑复杂（含排序/派生），按代码结构决定并回报。
3. **静态日期格式器**：grep 本文件 `DateFormatter()` 在行渲染路径的分配（反馈行、历史行等），改为文件私有 `enum ActionDateFormatting` 的静态实例（locale/日期格式逐字一致），或改用 Date.FormatStyle 等价输出（必须逐字一致）。
4. 行为、排序、文案、动作与可访问性标识不变。

## 约束
- 只改这一个文件；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、缓存键与命中路径、subtasks/nextActions 处理方式、格式器清单、parse 退出码、diff --stat。