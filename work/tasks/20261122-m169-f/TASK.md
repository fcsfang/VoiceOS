# 169-F 编排评审修复（单飞竞态/取消归属/原子保存/锚点契约/核对门控）

## 来源
169-C1/C2 只读评审（9 代理，六条候选去重后五类全部 CONFIRMED）。

## 修复
1. 单飞非原子：把每次生成包进按 sourceID 登记的非结构化任务（run registry），并发调用改为加入在飞任务；`.generating` 在任何 await 之前同步写入。请求取消不再杀掉生成任务。
2. 取消归属：取消分支只在自身仍拥有该 run 时写 `.idle`；新请求在旧 run 清理后重新判定，被吞窗口消除。
3. 快照校验与保存非原子：新增 `saveMaterialNote(...ifMembersStillMatch:)`，成员快照比对与 INSERT 在同一个 actor 回合内完成；不匹配返回 nil，编排置失败「材料在生成期间有变化，请重试」。
4. 锚点契约：`anchored` 对「引文存在于成员转写、但不落在任何单个时间片」的锚点保留，`spanID = nil`；只有转写中不存在的引文才剔除（对齐 169-A 契约）。
5. 许可收紧：门控新增 `needsTranscriptionReview` 检查，未完成全文核对的 Qwen 转写不允许交给云端生成笔记（与既有 requireReviewedTranscriptions 屏障一致）。

## 验证
- 改动文件 parse 真实退出码；集成构建见波 169 记录。
- 测试：门控矩阵新增行；锚点测试新增跨片保留用例。
