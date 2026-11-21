# 162-A 材料详情页读取合并（WorkspaceSourceView.swift）

## 背景
性能发现：打开一份材料时，页面通过 8 个独立 `.task(id:)` 各自发起一次 store 读取（pauseRead、discussionRead、contextRead、source.id、transcript entities、chapters、source.id 第二处、extractionFlag）。每次进入与相关 data key 变化都会并发起多次往返；部分 key 内嵌实时数组（如 discussionList），数据一变就重跑全部。目标：合并为一次组合读取任务，行为与错误处理不变。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/WorkspaceSourceView.swift

## 改动
1. 先 grep 8 处 `.task(id:` 的完整实现，列出每处：读取的 store 方法、赋值的 @State、错误处理方式（try?/catch 赋值 error/状态枚举）、key 组成。
2. 新增一个组合 key 结构体（Hashable），包含现 8 个 key 的全部输入；删除 8 个 `.task(id:)`，改为一个 `.task(id: combinedKey)`：
   - 内部用 `async let` 并发执行彼此独立的读取（保持各读取的错误处理与赋值语义逐字一致；有先后依赖的保持顺序）。
   - 每个读取完成后按原逻辑更新对应 @State（含 loading 状态、error 文案与重试 token 语义）。
   - 取消语义与原逐 task 一致：`.task(id:)` 切换 key 时旧任务取消；组合任务需在 await 边界检查 `Task.isCancelled` 或依赖子读取自然的取消行为，避免把旧结果写入新 key（对会写状态的读取，记录发起时的 key 并在写入前比较，防串写）。
3. 不改变任何 UI、loading 门控、错误展示与重试按钮行为。
4. 若某两个读取实际共享同一 store 调用且可合并为一次（例如同一 source 的两个同参读取），合并之并在回报中说明。

## 约束
- 只改这一个文件；不改 store 层；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、8→1 的映射表（读取/赋值/错误处理如何保留）、防串写策略、可合并的读取、parse 退出码、diff --stat。