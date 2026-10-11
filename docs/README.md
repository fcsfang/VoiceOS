# VoiceOS 文档索引

更新日期：2026-10-11。

## 当前文档

| 文档 | 状态 | 用途 |
|---|---|---|
| [产品愿景 v1.1](VoiceOS：产品愿景与概念设计文档%20v1.1/VoiceOS_产品愿景与概念设计文档_v1.1.md) | 产品基线 | 产品主要依据，含十张配套图表；正文优先于图示 |
| [PDF 阅读版](VoiceOS：产品愿景与概念设计文档%20v1.1.pdf) | 原始资料 | 固定排版的阅读副本 |
| [项目计划](planning/project-plan.md) | 执行计划 | 文档阶段、审查门槛和下一步 |
| [决策登记表](product/decision-register.md) | 已确认方向 + 待定清单 | 分开记录产品决策、用户待确认事项与技术假设 |
| [原始资料校验清单](planning/vision-baseline.json) | 基线证据 | 原始愿景资料的 SHA-256 摘要；用于核对是否被修改 |
| [PRD v0.1](product/prd.md) | 审查修订稿，P01–P04/P06 已确认 | 首版范围、31 条需求、状态和权限边界、三条端到端验收 |
| [需求验收对照表](testing/acceptance-matrix.md) | 测试设计草稿，未执行 | 22 个案例，覆盖全部需求与关键失败边界 |
| [产品审查问题](product/review-questions.md) | P01–P04/P06 已确认，P05 授权先测 | 答复、产品细节、建议与取舍 |
| [技术验证初步报告](research/technical-validation-2026-10-10.md) | 第三阶段进行中，部分探针完成 | 实测范围、证据、官方来源、备选与下一步 |
| [可靠性补充报告](research/reliability-validation-2026-10-10.md) | 合成实验完成，真实接口待测 | 恢复、核对去重、备份迁移与结果边界 |
| [提醒事项探针说明](research/reminders-probe-guide.md) | 已进行单项真实创建/改名/完成/重开验证 | 实际权限、选定清单和回读验证步骤 |
| [GPT 首轮试验方案](research/cloud-evaluation-plan.md) | 配置已接入，累计六次尝试、三次成功，完整对照未完成 | 两模型十样本、费用配置和语义评分 |
| [GPT 合成样本](research/cognitive-evaluation-cases.json) | 十条参考案例，SEM-01/03/04 有成功生成，完整对照未完成 | 归属、意图、纠错、历史关联与英语边界 |
| [API 与提醒事项实测](research/api-reminders-validation-2026-10-10.md) | 正常提醒事项路径完成，API 试验部分完成 | 三次生成尝试、单项真实写入/改名/完成/重开证据 |
| [API 配置使用说明](research/api-setup-guide.md) | 本地配置已整理并验证连接 | OpenCode 配置转换、密钥隔离和复现入口 |
| [现有短音视频验证](research/existing-media-validation-2026-10-10.md) | M0/W01 部分推进，非软件验收 | 现有视频音轨/一分钟中文音频复制、提取、完整解码与本地转写 |
| [现有媒体保存恢复验证](research/media-recovery-validation-2026-10-10.md) | 24 项探针判定通过，产品 AC 未执行 | SIGKILL、已知完整导入自动续作、文件/DB 窗口、隔离与重复恢复 |
| [系统架构 v0.1](architecture/system-architecture.md) | 可审查工程草稿 | 模块、接口、闭环、上下文与生命周期 |
| [数据模型 v0.1](architecture/data-model.md) | 可审查工程草稿 | 实体/数据字典、版本、权限、事务、备份迁移与删除 |
| [状态机与恢复](architecture/state-machines.md) | 可审查工程草稿 | 保存/处理/外部操作分层、失败窗口与纠错阻断 |
| [架构审查与需求映射](architecture/review.md) | 覆盖检查，输入子集已实现 | 31 条需求对应机制与 AC、验证门槛、产品边界复核 |
| [ADR 索引](adr/README.md) | 开发切片部分采用，其余待验证 | 重大技术备选、取舍、证据与退出路径 |
| [M1 文件输入实施记录](engineering/m1-file-input.md) | 已实现的开发预览，非完整 MVP | 同一应用核心、15 项测试、26 项媒体恢复检查与未完成范围 |
| [M2 逐字稿基础](engineering/m2-transcript-provenance.md) | 已实现的增量切片，非完整 M2 | 来源时间、原稿保留、更正历史、格式升级与验证 |
| [云端测试增量](research/cloud-evaluation-update-2026-10-10.md) | 六次尝试，三次成功，因超时停止 | 嵌套结构、归属与机会边界、未知结果/费用 |
| [M2 认知基础](engineering/m2-cognitive-foundation.md) | 本地工程切片，非完整 M2 | 持久上下文、调用回执、候选出处、原子冻结及迁移 |
| [M2 权限与模型端口](engineering/m2-source-policy-model-port.md) | 本地模拟已验证，真实云端待接入 | 文本权限版本、发送/提交核对、usage 与历史迁移 |
| [开发指南](engineering/development-guide.md) | 可复现工程入口 | 应用构建、数据位置、导出/恢复和测试 |
| [实施路线图 v0.1](planning/implementation-roadmap.md) | 实施中，M1 输入子集已实现 | 六个里程碑、24 个工作包、31 条需求对应实现责任 |
| [详细测试计划 v0.1](testing/test-plan.md) | 可审查计划，产品案例未执行 | 22 个 AC 执行步骤、14 个 FI 子场景、判定/指标/自然试用 |
| [夹具目录](testing/fixture-catalog.md) | 文本规格，媒体与产品数据夹具待制作 | 中英/正负关联/权限输入、参考依据及三条闭环 |
| [报告模板](testing/test-report-template.md) | 模板，非执行报告 | 环境/版本、实际结果、证据、未测、费用和清理边界 |

第二阶段草稿已交付，P01–P04 和 P06 默认方案已获确认；P05 授权先选小规模试验，预算及体验指标待测后校准。第三阶段整体未通过；第四/第五阶段草稿已交付。M1 已实现原生控制中心、文件保存/转写/查询和首批迁移能力；固定开发宿主已建立，麦克风/睡眠、完整数据屏障和认知/行动仍待验证与实现。完整首版仍须全部 22 个 AC 及 A/B/C。

## 审查方式

推荐顺序：愿景 → 决策登记表 → PRD → 验收对照 → 技术验证 → 架构与数据模型 → 实施与测试计划。

“产品基线”来自用户已确认的愿景；“草稿”可供评审但未冻结；“待确认”有明确问题但未获答复；“待验证”需要实际技术证据。未来旧方案使用“已替代”并指向新版本。文档版本变化不自动代表用户批准了新产品规则。

PRD 负责用户行为和验收，架构负责模块与运行机制，数据模型负责实体及历史，ADR 负责重大技术取舍。细节在所属文档维护，避免全部复制进 AGENTS.md。

- [M2 文本模型真实驱动](engineering/m2-responses-driver.md)：现有密钥单次合成调用、严格解析、用量与迁移证据。

- [M2 控制中心理解](engineering/m2-control-center-understanding.md)：显式文本执行、用量/出处呈现、持久防重发与原生界面验证。

- [M2 候选审阅与更正](engineering/m2-claim-review.md)：认可/拒绝、独立证据、版本历史与原子恢复。

- [M2 明确行动与机会池](engineering/m2-actions-opportunity.md)：任务/探索意图、状态反馈、认知版本依赖和迁移验证。

- [M3 提醒事项创建与完成反馈](engineering/m3-reminders-feedback.md)：原生清单范围、未知结果核对、外部编辑保留与反馈历史。

- [M3 持续连接与自动回读](engineering/m3-continuous-reminders.md)：本机持久清单授权、事件合并、停止和迁移不携带连接权限。

- [M3 用户表达与行动提取](engineering/m3-expression-actions.md)：明确文字身份、真实模型提取、普通任务自主创建与完成回流。

- [M3 回读超时与取消](engineering/m3-reminders-read-lifecycle.md)：有限回调等待、主动取消、晚到忽略与串行调度恢复。

- [M3 行动结果与反思](engineering/m3-action-feedback.md)：可选用户反馈、历史行动版本关联、原文回溯与迁移恢复。

- [当前验收状态与后续顺序](testing/acceptance-status-2026-10-10.md)：22 个案例的已验证子集、未完成变体和下一切片。

- [M3 控制中心恢复](engineering/m3-package-restore-ui.md)：包预览、目标保护、独立窗口与已有库重开。

- [M4 本地检索与质量实验](engineering/m4-local-retrieval.md)：版本出处屏障、规模/负例结果及语义入口的未通过边界。

- [M4 语义候选质量比较](engineering/m4-semantic-retrieval-quality.md)：24 个主题的固定样本、中文专用向量/本地重排对比、离线复现和后续质量门槛。

- [M4 独立样本与相关性快照](engineering/m4-relevance-boundaries.md)：长原文分段、直接相关/类比区分、新样本与千条规模、查询/权限/出处检查。

- [M4 相关性持久调用](engineering/m4-durable-relevance.md)：117 项测试、三处真实强退、v1–v10 旧包恢复；调用状态与出处有效性独立，迁移后不自动执行。

- [M4 相关性实际驱动](engineering/m4-relevance-driver.md)：既有 API 配置、严格 ID 输出、一次真实合成调用与持久回执迁移，124 项测试通过。

- [M4 控制中心相关性判断](engineering/m4-relevance-control-center.md)：关键词候选选择、显式发送、出处返回与取消/旧结果屏障；128 项测试及实际界面合成验证通过。

- [M4 原生本地语义召回](engineering/m4-native-semantic-recall.md)：固定 BGE/CoreML 资源、完整窗口出处、136 项测试与实际界面/链路验证。

- [M4 静默相关原文](engineering/m4-quiet-feedback.md)：持久忽略/减少/暂停、完整输入屏障、146项测试、四次强退及旧v1–v11恢复；非完整主动反馈。

- [M1 个人口述增量](engineering/m1-personal-dictation.md)：显式开始/停止、持久捕获身份、片段核对、154项测试及六次强退；实际设备权限与睡眠仍待验证。

- [首次真实麦克风测试](engineering/m1-microphone-device-test.md)：原件封存、本地空转写、重启及音频迁移通过；首次手动停止12.1204秒；后续10秒设备自动停止已验证，环境音不证明自然语音质量。

- [M4 本地会话基础](engineering/m4-conversation-foundation.md)：170项测试、六次强退、两次新格式迁移与实际v1–v13恢复；尚未接入AI回复/界面。
- [模式B实施契约](engineering/m4-dialogue-contract.md)：P07已确认逐轮语音＋文字，回合、引用、权限与回流验收。
- [GPT-Live与订阅接入](research/gpt-live-subscription-access-2026-10-11.md)：官方宿主语音、Live项目API与订阅文本接口的区别，账户权限未验证。

- [M4 持久讨论回复](engineering/m4-durable-discussion-replies.md)：184项测试、三次强退、实际v1–v14恢复；AI回复保持独立身份，实际讨论模型与界面待接入。

- [M4 文本讨论驱动](engineering/m4-discussion-driver.md)：190项测试、两次真实合成调用、迁移冻结；控制中心讨论界面待接入。

- [M4 逐轮讨论控制中心](engineering/m4-discussion-control-center.md)：191项测试、实际文字回复与结束屏障、两次本地环境音测试和口述关联；成果回流/自然语音质量未完成。

- [M4 个人发言回流](engineering/m4-discussion-user-return.md)：196项测试、一次实际个人原话整理、条件/否定、任务结果反馈及来源返回讨论；AI讨论候选回流仍待实现。

- [M4 讨论AI候选回流](engineering/m4-discussion-candidates.md)：205项测试、三次强退、四个新包往返及旧v1–v15恢复；显式保留AI身份，引用/触发点分开，完整混合成果仍开放。

- [M4 混合成果输入契约](engineering/m4-discussion-outcome-input.md)：213项测试，最后AI回应/未知状态/原文与AI双重引文、跨轮任务负例；实际提取和界面尚未实施。

- [M4 持久混合讨论成果](engineering/m4-durable-discussion-outcomes.md)：226项测试、三处强退、12次回归、四个新包往返和实际旧v1–v16恢复；原生出处历史通过，真实提取驱动与跨入口共享身份仍开放。

- [M4 跨入口成果复用准备](engineering/m4-discussion-outcome-reuse.md)：233项测试，已有身份与可新增个人目标分离，完整输入不删减；持久复用执行尚待接入。

- [成果生产者持久顺序](adr/019-model-producer-sequence.md)：237项测试，现已扩展至 v19/schema20；旧 v1–v18 包继续按版本表恢复。

- [持久成果复用更新](engineering/m4-discussion-outcome-reuse.md)：244项测试，原审阅/完成任务保持、只新增未整理回合任务，三个强退/三个迁移往返及原生UI通过；生产驱动待接入。

- [M4 实际混合成果驱动](engineering/m4-discussion-outcome-driver.md)：253项测试、两次合成云端提取/两次迁移，条件/否定、原拒绝保持、指代机会；提取按钮尚待接入。

- [M4 讨论成果控制中心](engineering/m4-discussion-outcome-control-center.md)：显式单次提取、关闭重开、角色出处、任务与本地反馈、未知和迁移历史界面验证。

- [M4 讨论任务提醒闭环](engineering/m4-discussion-outcome-reminders.md)：专用清单自动创建、外部完成v4回流、原v2反思保留及迁移不携带连接。
- [M4 英文表达反馈契约](engineering/m4-english-feedback-contract.md)：个人英文原句、出处建议、跨练习比较与纠错/权限屏障；端口、持久记录和界面已有实现，成功云端质量及视觉验收待补。
- [英文表达文本模型端口](engineering/m4-english-feedback-contract.md)：Responses 严格结构化输出、原句/历史引文校验和文本授权屏障；已接入持久英文反馈记录与轻量控制中心入口；自然质量仍待真实验证。
- [ADR-020 英文反馈记录](adr/020-english-feedback-records.md)：独立英文反馈表、schema 19→20 迁移、v19 包恢复与未知终态边界。
- [英文反馈首轮云端探针](research/evidence/english-feedback-cloud-2026-10-11.json)：合成文本单请求在 TLS 阶段失败，未重试、未保存反馈，质量验收未开始。

- [近期开发质量复查](engineering/quality-review-2026-10-11.md)：并发、授权版本、恢复和英文反馈校验修复；纠正启动证据与完成范围。

- [英文历史界面与模型边界补齐](engineering/m4-english-history-completeness.md)：实际长历史/冻结/完整文字预览验证，晚到拒收保留用量，275 项回归；自然英语质量未验收。

- [新表达静默关联实施契约](engineering/m4-expression-association-contract.md)：当前原话锚点、双引文/理由、权限版本和预算基础已实现；290项回归、三处真实强退和三次包恢复；持久执行已接入，自动触发与卡片仍待接入。

- [表达关联静默卡片](engineering/m4-expression-association-contract.md)：294项测试、五处强退、持久忽略和原生双引文/出处/暂停恢复验证；schema22/v21包，自动触发与自然质量仍开放。

- [表达关联文本驱动与来源结果页](engineering/m4-expression-association-contract.md)：304项测试，六端口统一配置；显式个人文字理解后自动关联授权历史，完整原话/双方出处/持久状态可核对。生产质量、正式问题状态和保存即自动闭环仍开放。

- [完整关联驱动故障集成](research/evidence/expression-association-full-driver-2026-10-11.json)：召回至接纳的五处强退/五次恢复，以及真实本机BGE召回→合成判断→单次重放；生产模型与自然质量不在本轮证据范围内。

- [问题生命周期输入契约](engineering/m4-question-lifecycle-contract.md)：问题/答案连续原话、认知归属和审阅/授权版本；四项新增回归，308项全套通过。持久对象、分类和界面尚待接入。

- [认知类型与问题输入](engineering/m4-question-lifecycle-contract.md)：313项回归，schema23/v22包，旧包恢复及原生类型显示；跨提示升级不重发，正式问题状态仍开放。

2026-10-11 问题状态补齐：typed问题与候选同事务生成，独立状态和用户修订、连续答案出处、版本/命令防重及来源页已实现；321项回归、四处真实强退/四次恢复、关联驱动五处强退/五次恢复通过，schema24/v23包。普通认可保留问题身份，原话/答案/权限变化冻结；解决不等于事实验证。W18及相关顶层验收仍partial，自动自然语言状态转移、自然质量、主题级偏好和保存即自动闭环开放。见[问题契约](engineering/m4-question-lifecycle-contract.md)。

- [问题状态与关联卡片](engineering/m4-question-lifecycle-contract.md)：325项回归，历史出处问题的ID/版本/状态分组，AI身份与旧未分类保留，显式关闭后同步刷新且不重发关联判断。

- [问题答案依赖与重开修复](engineering/m4-question-lifecycle-contract.md)：327项回归，当前答案与历史答案分开依赖，显式重开后可重新研究/登记新答案；六处强退与恢复通过，原问题和迁移冻结不能借此解除。

2026-10-12 增量：讨论成果v2已接入显式内容类型与个人/AI问题状态入口，旧结果不重提取；334项回归、签名构建、三处成果与六处状态强退/恢复及原生讨论页核对通过。见[问题契约](engineering/m4-question-lifecycle-contract.md)与[脱敏证据](research/evidence/discussion-question-types-2026-10-12.json)。自然质量与完整MVP仍未通过。

2026-10-12 续接修复：单份表达与讨论回合显式整理可沿用成功理解后继续尚未预留的关联，未知/拒绝/失效不重发；跨模型配置关联去重。339项全套、六处真实强退/六次迁移及签名构建通过；本切片0云端/麦克风/外部写。见[契约](engineering/m4-expression-association-contract.md)与[证据](research/evidence/source-understanding-continuation-2026-10-12.json)。保存即自动处理及自然质量仍开放。

2026-10-12 自动衔接基础：单份个人文字处理意图的只读快照已实现，固定全文、版本、权限epoch及两个端口，不授予云端权限、不发请求。343项全套通过；[执行契约](engineering/m4-expression-processing-intent.md)与[ADR-023](adr/023-expression-processing-intent.md)明确下一步持久队列和保存入口；尚不能称保存即自动闭环。

2026-10-12 持久处理意图切片：schema25 / PortablePackage v24 新增 `processing_intents`，实现入队、取消、单项串行执行、认知/关联阶段回执、恢复 unknown、迁移冻结及原生“保存并处理本次文字”入口。新增队列回归覆盖一次执行、终态不重发、取消和包往返；完整强退矩阵、真实原生 UI 检查和完整回归仍在本轮后续验证。

处理意图强退探针已补齐：在入队 running、认知 reserved、关联 reserved 三个真实 SIGKILL 边界恢复为 unknown，第二次恢复不改变状态；无云端调用或提醒事项写入。见 [脱敏证据](research/evidence/expression-processing-recovery-2026-10-12.json) 和 [探针](../scripts/probes/expression-processing-recovery.py)。

2026-10-12 夜间校验：提交 `6975f4e` 补齐处理意图篡改迁移包拒绝、认知/关联在途取消后的迟到结果冻结及对应回归；提交 `3b2759e` 记录验证结果，提交 `67f57ac` 接入处理记录菜单和取消入口。入队后文字/授权漂移回归已补齐；350 项全套测试、签名构建和三处实际 SIGKILL 恢复通过。原生 UI 仍因 macOS 锁屏未能运行时核对，不能据此宣称完整 MVP 或自然语音质量已验收。
