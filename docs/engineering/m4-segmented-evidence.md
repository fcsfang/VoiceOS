# 分段证据账本的本地校验

> 本文保留该基础切片的版本与验证记录。当前已接入schema28的[持久片段提取](m4-segment-extraction.md)，包括unknown恢复和暂存结果；整篇聚合仍未实现。

日期：2026-10-12。状态：本地准备/规范校验已实现，模型尝试预留、持久暂存及整篇聚合未实现。schema27和包版本规则不变。

## 目的与边界

后段否定、更正或补充条件不能从聚合输入中消失。需要有可校验的原话位置、完整段覆盖和实际序列化预算，而非只给模型一组任务标题。

`SegmentEvidenceInput`是已解码的本地提案输入，不是成功的模型回执。账本本身不证明模型已处理每段，不构成执行许可，也不创建claims/questions/actions/outbox。未来执行器必须从经过身份核对的持久片段结果构建inputs，不能以任意调用方提供的inputs替代回执验证。

## 结构与不变量

提案类型为statement/question/possibleAction/condition/negation/correction/quotation/incompleteBoundary。这是提取/聚合中间分类，不修改产品认知或行动类型。每条有说明、逐字quote、全局半开scalar范围及原spanID列表；不存在autoSend字段。

每段恰好一份输入；空提案输入合法，但必须保留段ID覆盖。缺段、重复段、未知段一律拒绝。输入列表乱序可按计划顺序规范化；同段内提案顺序保留。规范证据ID绑定scope摘要、segmentID、段内序号和提案内容。

quote必须完整落在所属段范围、逐字匹配父逐字稿，并在完整Character边界起止。原spanIDs必须等于引用覆盖的全部原span及其顺序，不能省略跨span的后半部分。返回引用只复制原识别片段的包含时间，不生成当前quote精确时间。

账本保留潜在行动和后段否定/更正等全部提案；incompleteBoundary给出`requiresBoundaryResolution=true`。这不是语义正确性的证明；未来聚合门槛必须检查该标记并解决边界或保持阻塞。

预算检查使用实际`payloadJSON`的Unicode scalar数，包含段覆盖、引用、提案和边界标记。说明超过1000 scalars拒绝；完整JSON超过父scope证据预算也拒绝，不截断quote、删提案或省略否定。预算失败时本方法不存储输入；未来持久执行器必须已保存片段结果，才能保留失败证据并标记父批次blocked。

`prepareSegmentedEvidenceLedger`要求批次queued并重新校验当前完整scope及两个模型身份。`validateSegmentedEvidenceLedger`再次从给定原输入构建整个规范账本并比较，不能只相信调用方提供的payload或摘要。更正、撤权、取消、冻结使旧账本不可用。

## 验证与后续

7项新增测试覆盖后段否定保留/排序、空段与完整覆盖、缺失/重复/未知段、伪造quote、越界、跨span遗漏、emoji拆分、预算不足、未完句标记，以及准备无模型/行动副作用和篡改账本/取消拒绝。404项完整回归通过。这里的语义文字为确定性夹具，未执行真实模型，也未评分自然否定识别。

下一切片仍是持久片段attempt预留/结果、全局producer顺序与unknown不重发。只有全部经过回执身份验证的片段完成后，才消费本账本构建聚合请求；完整聚合前不把possibleAction直接转为产品任务。详见[整体执行契约](m4-segmented-expression-processing-contract.md)。

最新签名构建和严格签名校验通过；[脱敏证据](../research/evidence/segmented-evidence-validation-2026-10-12.json)区分工程夹具和未执行范围。
