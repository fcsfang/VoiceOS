# 分段提取的持久尝试与结果暂存

日期：2026-10-12。状态：通用文本端口、预留/结果暂存、串行片段执行、未知不重发、持久证据读取与迁移已实现；只用本地确定性端口验证，真实云端驱动、整篇聚合和原生入口未实现。

## 范围与版本

schema28新增`segmented_extraction_attempts`，父批次新增unknown/rejected终态。有片段尝试时导出v28/schema28；只有批次保持v27，原数据范围保持v24/v25/v26。原整份逐字稿回执不复用为片段回执，4000字入口未放宽。

片段结果只保存中间证据，不创建当前claims/questions/actions或提醒事项outbox。父批次全部段完成后仍queued，表示等待尚未实现的聚合；不显示整个认知闭环completed。

## 调用身份与持久记录

`SegmentExtractionRequest`包含独立attemptID、batchID、scopeDigest、父来源/来源版本/逐字稿版本/政策epoch、origin/speaker/localOnly、一个原样片段及全局引用、固定端口身份。没有音频字节、文件URL、凭证或整份父逐字稿的隐藏附件。端口必须直接发一次文本请求，不隐式重试或调用工具。

尝试表保存完整输入JSON/摘要、结果JSON/摘要、已知usage、state、validity、时间、错误及producer_sequence。`UNIQUE(batch_id,segment_id)`防止同一片段重复预留；每个资料库一次仅有一个片段提取在途。与原model_attempts共享producer顺序，预留事务无await，分配时取两表最大值；历史/迁移再校验两表顺序不冲突。不同模型管道的完成时间不替代预留顺序。

`runNextSegmentExtraction`预检当前完整scope与实际端口身份，然后按计划顺序跳过已完成/current片段，选择首个未预留片段。预留事务提交后才调用端口。reserved、unknown、rejected或frozen旧结果不能当作成功或再次发送。无新片段或批次终态返回nil；nil不是整篇完成证明。

## 响应、冻结及失败窗口

完成响应必须status=completed、用量非负，所有提案使用原话/完整字形及完整span交集，复用本地账本的同一验证函数。空提案是合法完整响应，需要独立回执；没有响应是unknown，二者不同。

结果与usage在事务中暂存；拒绝、不完整或伪造quote记rejected，并使父批次rejected。普通传输异常记unknown并停止后续段。已观测到但因事务异常未保存结果的用量，在仍能运行的进程中保留；真实强退丢失的内存用量仍未知。提交后的检查点异常不重写完成回执。

取消父批次立即冻结已暂存和在途尝试。更正、撤权或原件隔离与现有认知失效事务共用，queued父批次立即blocked，全部子尝试冻结。已发请求的迟到响应仍保存结果和usage，但validity=frozen，不改变cancelled/blocked终态。Task取消后已收到的完整响应同样冻结，未收到响应仍unknown，不重发。

启动将reserved转unknown，并把仍queued父批次转unknown；已完成片段保持回执，只有未预留段可续作。取消/冻结等父终态不能被恢复覆盖。恢复不自动启动任何模型调用。

## 整篇证据消费门槛

`preparePersistedSegmentedEvidenceLedger`必须读取全部完整/current的持久尝试，按段ID构造输入后，再验证当前父scope、归属、政策和两个端口。任一段未完成、被拒绝、未知或冻结就拒绝整篇消费。调用方任意提供的本地inputs不能替代这一回执门槛。

证据预算和未完句标记仍由账本约束。预算不足不删提案，也不补发片段；本阶段的证据准备会报告错误并保留已有尝试，聚合执行器尚未实现，不能据queued状态推定已处理预算阻塞。

## 迁移与深层校验

v28包含新尝试表。导入先验证原状态/validity，再把尝试全部冻结，reserved转unknown；父批次统一frozen。旧格式不能携带新尝试或片段终态。

校验重建父历史范围和规范片段请求；输入摘要、父版本/权限/端口必须一致。完成结果验证响应状态、quote、span、usage及结果摘要；两表producer sequence不可冲突。即使重算manifest和内层摘要，伪造权限、原话或顺序仍拒绝恢复。来源更正后的旧历史仍按旧逐字稿与政策epoch合法保存。

## 验证

415项完整回归通过，新增11项覆盖完整/空响应、未知/拒绝不续发、并发去重、迟到取消、改稿/撤权、Task取消、端口漂移、预留恢复、结果事务边界、迁移冻结、全局顺序和三类重算摘要的篡改。

实际SIGKILL覆盖segmentExtractionReserved、segmentExtractionUncommitted、segmentExtractionCommitted。前两者恢复unknown且不重发；已提交结果恢复后只续未预留段。重复读取和重放身份稳定，认知/行动实体均为0。

真实40分钟5280字符来源的两个片段使用明确本地夹具身份，夹具固定返回空提案：验证了父来源输入、两次持久完成、v28包恢复冻结及完整性。没有测试自然语义提取、否定识别或模型质量；不得把空夹具回执当作自然语音已理解。

```sh
swift test
python3 scripts/probes/segment-extraction-recovery.py
.build/debug/voiceos-check segment-extraction-fixture <新的隔离库>
.build/debug/voiceos-check segment-extraction-read <隔离库>
```

最新签名构建与严格校验通过。[执行证据](../research/evidence/segment-extraction-validation-2026-10-12.json)、[强退证据](../research/evidence/segment-extraction-recovery-2026-10-12.json)。私人逐字稿和媒体留在忽略的runtime，未提交。

## 下一阶段

实现持久聚合预留、全部潜在行动的accept/reject/ambiguous/duplicate覆盖、跨段未完句门槛及最终原子认知提交；随后接长来源关联、真实文本端口和自然样本。完整聚合前继续不释放片段行动。备选/取舍见[ADR027](../adr/027-durable-segment-extraction.md)。
