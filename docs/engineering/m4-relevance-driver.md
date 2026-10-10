# M4：相关性文本模型驱动

日期：2026-10-11。状态：实际单次合成调用通过，语义控制中心尚未接入。沿用既有配置与 `gpt-6.1-sol`，产品方向不变。

驱动实现 `RelevanceModelPort`，沿用既有 HTTPS 服务白名单、凭据校验和禁止跳转的直接 HTTP 传输。每次只发一个 POST，不提供工具、后台任务、轮询、模型回退或重试。查询与候选文本在发送前再次检查明确云端许可、来源限制、完整摘要及 4000 Unicode 标量预算。最多八个候选，不截断原文或悄悄过滤仅本地来源。

候选仅发送 id/origin/text，不发送原件、文件名、路径、时间或调用凭据。候选本身的 ID 有来源和文字版本身份，但系统仍在本地保留完整出处。请求上限 24000 字节，输出上限 1024 token；超限拒绝请求。提示沿用前阶段验证过的具体对象/情境原则，改为单查询候选输入，身份为 `relevance-single-v1`；前阶段批量合成评分不能直接当作这一生产格式的准确率。

按 [official OpenAI documentation 的 Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)，使用 `text.format` 的严格 JSON Schema。结果只有 candidate_ids，枚举限定于本次候选。解析仍检查未知字段、非字符串、重复、虚构 ID 和三项数量上限，支持空结果；未完成、拒绝或工具输出不作为选择结果。结构正确不等于语义正确。

理解驱动与相关性驱动共用严格 Responses 外层解析器，目的各自的输出字段独立校验。可判定的 HTTP/解析拒绝记录 rejected；已知 token 用量保留，服务器错误正文不写入记录。没有可判定响应的传输异常保持 unknown，费用未知，不自动重发。迟到结果、取消及来源变化仍受核心持久协调器约束。金额依据实际账单，不能从 token 数宣称已支付某个费用。

## 本轮证据

- 124 项自动化测试通过，零失败；既有理解测试仍通过，新增相关性请求/解析、权限阻断、HTTP 单次失败、配置复用和持久解析拒绝用量测试。
- 一次实际合成调用 completed：604 输入 + 70 输出 token。三条原文中只返回与遗忘曲线/主动回忆直接相关的原文；做饭记录与引用中的指令未返回。没有生成 Claim/Action 或外部写入。
- 二次重开输出一致，未再调用；实际回执导出/恢复通过，三条完整输入保留，恢复后的 completed 历史为 frozen。
- 在最新代码上重跑三处 SIGKILL、schema 11→12 与 v1–v10 实际旧包恢复，全部通过；应用构建及签名校验通过，23 个愿景文件未改。

本轮没有上传个人历史或原始音频。该例只证明受控路径和一个正负/指令样例，不能推定真实历史检索质量。证据：[相关性驱动摘要](../research/evidence/relevance-driver-2026-10-11.json)。运行日志在 `runtime/relevance-live-2026-10-11` 与 `runtime/relevance-durability-2026-10-11-r2/driver-*.log`；最新强退与旧包结果在 `runtime/relevance-durability-2026-10-11-r3/summary.json`。

## 复现与下一步

`voiceos-check relevance-cloud-fixture <全新合成目录> <本地配置文件>` 是开发验证入口，只读取配置并建立三条合成来源，不打开现有个人库。该命令会产生一次实际费用；同一目录拒绝再次执行。配置由 `LocalTextModel.loadRelevance` 解析 JSON 字符串，不执行 shell 文本；不需要另一个 API key。

下一步把受控相关性操作接入可看出处、可取消的控制中心，再引入经过验证的本地语义召回适配器。查询更新必须取消旧请求；显示结果时还要验证当前 queryID、来源文字/授权版本，不能把核心函数内部的原 queryID 当作界面当前查询。模型分发、真实长期历史质量、自动关系反馈、麦克风/睡眠与完整产品验收仍未关闭。本阶段没有新的用户决策阻塞。
