# 长表达认知提交与控制中心入口

日期：2026-10-12。状态：最终提案校验、原子认知提交、Responses兼容驱动和原生入口已实现并编译；真实云端、界面运行时、长来源历史关联及完整MVP未验收。

## 最终认知与行动

聚合响应可携带finalClaims，每条固定原话证据身份，核心生成父来源/逐字稿/span引用。潜在行动必须先通过整篇判断：accept或ambiguous恰好各映射一次最终行动，reject/duplicate不得释放任务；ambiguous只能为不自动发送的opportunity。行动quote必须来自对应潜在行动原话，说明、归属、任务权限及数量继续受既有校验约束。不能把聚合总结当出处。

schema30新增segmented_cognitive_commits及segmented_derivation生产者类型。完整父原文只用于本地出处快照，不作为新模型输入；旧4000字模型入口与回执校验不变。每个聚合只可原子派生一次原有claims/actions/questions；派生记录独立于付费聚合回执，billingState为not_applicable，不伪装成新调用。事务失败无部分实体，可复用已经完整登记的聚合结果重新做本地提交；结果未知不会再次调用模型。

重新读取、取消/更正后或迁移后的已提交身份不会重生成或激活旧实体。来源更正沿已有认知失效机制冻结；迁移把派生上下文、认知、行动和问题冻结。finalClaims或认知派生数据使用v30包，其余范围保持v24–v29兼容。历史校验核对整篇响应、规范提案、实体原始内容、原话版本、政策epoch及生产者顺序。

现有问题上下文上限12000 scalars保留；超出该范围且含typed question的最终结果拒绝部分提交，不能删掉问题换取成功。跨原span行动quote仍服从旧出处限制。后续需完善长来源问题/关联预算，这属于工程缺口，不是缩减产品愿景。

## 文本驱动与入口

ResponsesSegmentExtractionPort/ResponsesSegmentAggregationPort复用既有授权HTTPS地址、直接传输及外层解析。一次调用一个POST，无工具、重试或轮询，store=false、truncation=disabled。聚合仅发送预算内账本一次及回执身份，不重复发送完整长原文；分段发送本段文字。代理声明strict不代替本地结构与出处校验，未知字段、伪造身份、不完整/拒绝及错误用量不能当成功。

结构格式按[官方Structured Outputs约束](https://developers.openai.com/api/docs/guides/structured-outputs#supported-schemas)设置required、additionalProperties=false及nullable字段；中转服务兼容性仍待真实验证，不保证实际支持这些字段。本轮使用OpenAI Docs技能核对，未读取或修改真实密钥文件，也未产生API费用。

控制中心为超过4000字的个人audio/user_text提供“分段理解长表达”。须已配置文本模型、来源允许文本云端且归属为本人。入口明确入队，复用相同来源/逐字稿/政策的既有记录；配置变更不自动新建批次。关闭窗口或更换选择不重发。退出时未落结果的预留恢复unknown；重启后需明确续接未预留部分，不自动扫描旧资料。

处理记录展示分段状态，可停止后续处理。新批次在发送前已发布到界面，使停止入口可见。认知已提交后单独显示“认知记录已保存、历史关联待接入”，不把仍queued的父批次或部分链显示成完整成功。原始音视频仍不上传。已授权普通任务沿现有提醒事项规则处理，没有新增逐任务审批。

## 轻量验证与接续

编译通过；49项相关检查通过（长认知/原子回滚、防重放、原模型/问题及模拟HTTP），入口编排与配置另有6项检查通过。长测试采用合成更正后的逐字稿，不是自然录音质量证据；HTTP为本地注入transport，无实际网络请求。

日志位于runtime/queue-fixes-20261012/segmented-*-targeted.log和segmented-entry-build.log。按用户要求，本轮未重复完整回归、真实SIGKILL、签名构建、原生操作核对或真实云端测试；需在阶段末集中验证。此前422项全量结果属于旧版本，不能作为schema30全量结论。

下一步优先衔接长来源历史关联及录制处理请求的长文字路径，再统一做真实界面与自然样本验收。完整首版仍需产品AC和认知—行动—反馈闭环证明。
