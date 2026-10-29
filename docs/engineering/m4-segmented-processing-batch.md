# 分段处理持久批次基础

> 本文保留该基础切片的版本与验证记录。当前已接入schema28的[持久片段提取](m4-segment-extraction.md)，包括unknown恢复和暂存结果；整篇聚合仍未实现。

日期：2026-10-12。状态：批次范围、入队、取消、预检、恢复和迁移已实现；分段模型执行及聚合未实现。schema27；有批次数据导出v27/schema27，没有批次保持原v24/v25/v26规则。

## 数据与入口

`segmented_processing_batches`独立于原`processing_intents`，保存批次ID、稳定命令ID/语义指纹、父来源/逐字稿/权限版本、完整scope JSON及摘要、状态、错误与时间。原模型回执和4000字入口未放宽。scope固定无损计划、提取/聚合端口身份和证据预算，不含凭证或音频。

`enqueueSegmentedProcessingBatch`要求资料库ready且命令非空，首次写入前规范校验当前范围。无await的SQLite事务原子入队；未提交检查点回滚，已提交检查点出错仍保留原回执。同一语义范围的重新准备ID不影响命令指纹；同命令改原话/端口/预算/引用则拒绝。同一命令的旧scope重放返回原历史回执，取消/更正后不激活它。

`cancelSegmentedProcessingBatch`仅将queued转cancelled，原件与逐字稿保留；重复取消或终态读取无副作用。当前只有queued/blocked/cancelled/frozen四态，不预先声称支持running或completed。

`checkSegmentedProcessingBatch`是执行前预检，核对当前来源、原件、权限、逐字稿及两个端口，漂移把queued转blocked；blocked/cancelled/frozen不自动恢复。当前没有模型执行器或原生批次入队入口，queued只表示持久等待，不能显示成实际执行中。

## 历史与恢复

读历史时从记录的旧逐字稿和旧权限epoch校验；不使用今天的新逐字稿判断旧批次是否损坏。快照字段必须与父来源/版本及目录字段一致，全部片段必须等于历史原文的规范分段结果。即使重算scope、命令和manifest摘要，伪造引用/文字仍拒绝。

启动先校验合法历史，再预检queued的当前来源。有效且尚未发送的批次保持queued；更正、撤权、原件损坏等转blocked。当前无模型预留状态，因此没有unknown恢复路径；该路径必须与未来片段attempt一起实施，不能提前套用自动重试。

迁移新批次统一frozen，保留原scope/历史。先验证导入的原始状态属于已支持集合，再冻结，不能靠冻结掩盖无效状态。manifest仅v27可携带新表。无批次时维持旧包范围；schema26资料库增量升级到27。迁移不读取实时模型配置或外部提醒事项授权。

## 验证

新增9项测试覆盖语义重放、取消无产品实体、命令/端口漂移、更正后历史、撤权重启、四个事务窗口、旧schema及包兼容、冻结恢复、深层篡改和非法迁移状态。强退探针使用SIGKILL验证入队/取消提交前后四个边界，并重复恢复/重放核对身份。

```sh
swift test
python3 scripts/probes/segmented-processing-recovery.py
.build/debug/voiceos-check segmented-batch-fixture <新的隔离库>
.build/debug/voiceos-check segmented-batch-read <隔离库>
```

真实本人音轨逐字稿的测试可通过`segmented-batch-enqueue-local <隔离库> <明确sourceID> <稳定commandID>`执行：固定本地no-dispatch身份，仅入队不发送模型。此命令不适用于云端模型配置，也不授予云端权限。

## 后续

按[分段执行契约](m4-segmented-expression-processing-contract.md)实现独立片段预留和暂存结果；复用统一producer sequence，完整聚合前不创建claims/actions/questions或outbox。再覆盖unknown、晚到结果、取消/更正/撤权冻结和v27之后的迁移扩展，最后接真实文本模型及自然质量样本。

本轮未证明长录音认知语义质量、自然行动闭环或完整MVP。重大取舍见[ADR026](../adr/026-segmented-processing-batch.md)。

执行结果：397项回归通过，四个实际SIGKILL窗口稳定恢复/重放；最新签名构建及严格校验通过。真实40分钟5280字符来源在隔离库保存2段批次，v27恢复保持同一批次ID并冻结；完整性为true，模型/原处理队列/行动记录均为0。见[脱敏执行证据](../research/evidence/segmented-batch-validation-2026-10-12.json)和[强退证据](../research/evidence/segmented-processing-recovery-2026-10-12.json)。
