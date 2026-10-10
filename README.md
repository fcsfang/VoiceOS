# VoiceOS

VoiceOS 是语音优先的多模态个人智能系统：让自然表达形成可追溯的知识与行动，让后续结果回到原有思考，构成跨时间的认知—行动—反馈闭环。

近期采用后台智能引擎与轻量控制中心，长期演进为完整独立应用。产品愿景以 [v1.1 正文](docs/VoiceOS：产品愿景与概念设计文档%20v1.1/VoiceOS_产品愿景与概念设计文档_v1.1.md)为主要依据。

## 当前阶段

2026-10-10：产品/工程文档草稿已交付，M1 文件输入开发预览已实现：Mac 控制中心、音视频导入、可靠保存/重开、本地逐字稿、关键词查询、导出及开发工具空库恢复。M2 已增加来源片段、逐字稿更正与版本历史，持久上下文、候选出处与更正冻结基础已建立；来源文本权限版本与模型响应端口已建立；41 项核心测试通过；此前 26 项媒体恢复和 7 项认知故障检查通过。真实文本驱动与控制中心理解入口已接入，合成资料的执行、出处、用量及重复发送保护已验证；完整 MVP 和 22 项产品验收尚未完成。

## 本地应用

运行 `python3 scripts/app/build.py` 后，双击 `dist/VoiceOS.app`。当前仅在本机处理媒体，默认数据位于 `~/Library/Application Support/VoiceOS`。详见[开发指南](docs/engineering/development-guide.md)、[M1 实施记录](docs/engineering/m1-file-input.md)、[逐字稿记录](docs/engineering/m2-transcript-provenance.md)、[认知基础记录](docs/engineering/m2-cognitive-foundation.md)与 [权限/端口记录](docs/engineering/m2-source-policy-model-port.md)与 [真实驱动记录](docs/engineering/m2-responses-driver.md)与[控制中心理解记录](docs/engineering/m2-control-center-understanding.md)。

## 阅读入口

- [文档索引](docs/README.md)：各文档状态与推荐阅读顺序。
- [项目计划](docs/planning/project-plan.md)：阶段、交付物及审查条件。
- [决策登记表](docs/product/decision-register.md)：已确认方向、待确认边界与技术验证事项。
- [PRD v0.1](docs/product/prd.md)：首版范围、31 条需求、行为边界和验收要求。
- [验收对照表](docs/testing/acceptance-matrix.md)：22 个待执行案例与需求映射。
- [产品审查问题](docs/product/review-questions.md)：P01–P04/P06 已确认，P05 授权先测。
- [技术验证初步报告](docs/research/technical-validation-2026-10-10.md)：本地中文转写、音频文件、持久化探针与官方接口调查。
- [可靠性补充报告](docs/research/reliability-validation-2026-10-10.md)：跨资源中断、外部未知结果、可迁移包与原生探针准备。
- [GPT 首轮试验方案](docs/research/cloud-evaluation-plan.md)：模型对照、十条合成样本与费用控制；本轮因服务错误提前停止。
- [API 与提醒事项实测](docs/research/api-reminders-validation-2026-10-10.md)：配置已落地，单项任务回流通过；模型服务存在超时和 503。
- [API 配置使用说明](docs/research/api-setup-guide.md)：本地设置、运行入口和实测边界。
- [现有短音视频验证](docs/research/existing-media-validation-2026-10-10.md)：27 秒视频音轨及一分钟中文音频的复制/提取/解码/本地转写。
- [现有媒体保存恢复验证](docs/research/media-recovery-validation-2026-10-10.md)：24 个真实文件故障案例，核验原子登记、自动续作和重复恢复。
- [系统架构 v0.1](docs/architecture/system-architecture.md)：模块、接口、完整闭环和生命周期推荐。
- [数据模型 v0.1](docs/architecture/data-model.md)：实体、版本、权限、事务、导出恢复和删除约束。
- [状态机与恢复](docs/architecture/state-machines.md)：保存、处理、外部操作、冲突和旧结果阻断。
- [架构审查](docs/architecture/review.md)：31 条需求映射、未关闭验证门槛与下一阶段。
- [技术决策草案](docs/adr/README.md)：六项推荐方案及备选、代价、采用条件。
- [实施路线图](docs/planning/implementation-roadmap.md)：六个里程碑、24 个工作包与全部需求映射。
- [详细测试计划](docs/testing/test-plan.md)：22 个 AC 的执行步骤、14 项故障子场景、质量与试用判定。
- [测试夹具目录](docs/testing/fixture-catalog.md)：合成输入、参考依据、权限变体与三条闭环。
- [测试报告模板](docs/testing/test-report-template.md)：运行身份、实际证据、失败/未测和指标格式。
- [工程协作规则](AGENTS.md)：四条必要边界。

个人录音、运行数据、密钥和临时产物不进入 Git。单 Mac 原生宿主/Swift Core/SQLite 已采用用于此开发切片，完整模型与其他选型未冻结；下一步推进来源/修订/认知契约，继续补麦克风、睡眠、GPT 与外部闭环验证。
