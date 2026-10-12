# 整篇行动判断的本地校验门槛

日期：2026-10-12。状态：结构校验及持久片段消费入口已实现；聚合模型调用、聚合回执及最终认知提交尚未实现。schema28/导出规则不变。

## 已实现

`SegmentAggregationReview`固定父批次和完整账本摘要，列出全部已审阅证据身份及每个possibleAction的accept/reject/ambiguous/duplicate判断。说明必须非空且不超过1000 scalars；依据必须包括本行动且全部存在于原话账本，不能重复或伪造。

`validatePersistedSegmentAggregationReview`从全部completed/current片段尝试重新生成账本，再核对当前来源/权限/端口及响应身份。不能用任意本地提案绕过持久回执消费门槛。取消或更正后的旧review被拒绝。

每条原话证据必须恰好覆盖一次，包括否定、条件和更正；每个潜在行动必须恰好判断一次，不能遗漏、重复或添加身份。证据与判断顺序按原账本规范化，响应排列变化不改变结果摘要。

duplicate必须指向另一个潜在行动，并引用目标证据；允许明确链式重复，但必须最终指向accept保留项。自指、环、不存在的目标、以reject/ambiguous结尾及非duplicate携带目标一律拒绝。这里只校验关系，不按标题猜测自然重复。

账本含incompleteBoundary时拒绝整篇判断。模型口头声称已经解决不能替代精确边界上下文的独立验证；本切片尚未接入该机制。

## 限制与下一步

`ValidatedSegmentAggregation`仅为本地规范校验结果，不是成功聚合调用回执、行动许可或认知完成。不会保存聚合尝试、创建claims/questions/actions或写入提醒事项。全部片段完成后的父批次继续queued。

全部证据ID被列出不能证明模型正确理解了否定或条件。accept标签也不能直接成为立即执行任务；后续聚合调用及原子提交必须沿既有产品授权校验，使用自然样本检验语义质量。此处没有缩减已有AI操作授权或新增逐任务审批。

下一切片先做聚合预留与回执身份、未知不重发、取消/漂移/迁移冻结；之后才接最终认知实体和长来源关联。备选是直接使用模型行动列表，容易遗漏原暂存任务或产生重复链；采用显式覆盖和关系校验，增加响应结构约束，以获得可审计的整篇判断。

## 验证

422项完整回归通过。新增7项针对遗漏/重复/伪造、后段证据覆盖、乱序稳定、自指/环/无效根、依据/说明及未完句阻塞。现有持久片段测试补充真实存储入口校验、取消后拒绝和认知/行动实体为0的检查。

样本为确定性合成文字，没有真实聚合模型调用，也没有自然语义质量评分。本切片没有增加数据库事务边界，之前片段三个实际SIGKILL证据保持适用；没有新增原生UI入口。

日志：`runtime/queue-fixes-20261012/segment-aggregation-validation-tests.log`。相关[持久片段记录](m4-segment-extraction.md)和[总契约](m4-segmented-expression-processing-contract.md)。

签名构建及严格codesign校验通过；[脱敏验证证据](../research/evidence/segment-aggregation-validation-2026-10-12.json)。
