# VoiceOS 技术决策记录

日期：2026-10-10。ADR-001/002/003/004/005/006/007/008 的开发切片为 **partially_adopted**，已采用部分及证据记录在各文档；完整方案其余部分仍 proposed，未全部冻结。产品约束来自愿景及 PRD，技术推荐不等于新增产品批准。常规可逆工程选择可在授权范围内推进；改变已确认产品方向才提交产品确认。

| ID | 议题 | 推荐 | 验证依赖 |
|---|---|---|---|
| [001](001-execution-host.md) | 引擎与控制中心宿主 | 单 Mac 应用、Swift Core、SwiftUI | H03/H09：录制、生命周期、稳定权限身份 |
| [002](002-storage-retrieval.md) | 存储与检索 | SQLite + 独立媒体 + 可重建检索投影 | H07/H08：中文/跨时间检索、真实恢复 |
| [003](003-durable-execution.md) | 处理与外部操作恢复 | 持久 jobs/outbox、版本检查、未知结果核对 | H05/H08/H09：故障、晚到回调、外部竞态 |
| [004](004-reminders-adapter.md) | 提醒事项连接 | 同宿主 EventKit 适配器、应用清单范围 | H09：权限撤销、延迟、冲突、重开 |
| [005](005-cognition-speech.md) | GPT 与转写路由 | 可替换 GPT，能力满足时优先本地转写 | H01/H02/H04：语义、质量、费用与上传控制 |
| [006](006-portability.md) | 备份、迁移与删除 | 版本化可读导出 + 一致本地备份 | H08：资产快照、升级、删除与恢复边界 |

| [007](007-expression-action-extraction.md) | 用户表达与行动提取 | 显式文字身份、一次理解与原子行动、范围内有限自主执行 | H01/H05：转述/否定/期限质量、纠错与重复意图 |

每份记录包含问题、约束、备选、推荐、代价、证据、验证条件和退出路径。状态将使用 proposed / partially_adopted / accepted / superseded；改动日期与理由留在记录中。accepted 表示有足够证据采用技术方案，不自动表明整个产品验收通过。

跨设备同步、正式应用签名/分发、最低 macOS、秘密存储实现及通知具体预算尚未定案；进入对应实现前补决策，不用本表推定已支持。

- [008 行动反馈](008-action-feedback.md)：复用用户文字来源与独立反馈关联表，原文和关联原子保存。

- [009 本地检索](009-versioned-local-retrieval.md)：原文检索与语义实验分离、可替换端口与读时版本屏障。

- [010 相关性持久调用](010-durable-relevance-attempts.md)：独立调用与完整输入历史，未知不重发，迁移冻结执行；该切片 accepted。

- [011 原生本地语义召回](011-native-semantic-recall.md)：CoreML float32、显式模型资源、可重建投影与排序候选，开发切片 accepted。

- [012 静默反馈](012-quiet-relevance-feedback.md)：回执投影、跨查询去重、偏好版本与迁移，采用范围限W18初始切片。

- [013 个人口述](013-durable-personal-dictation.md)：AVAudioRecorder、持久身份与原件封存，部分采用；设备/权限/睡眠待测。

- [014 本地会话历史](014-local-conversation-history.md)：共用来源/上下文、个人回合、结束、原子冻结与迁移；W17基础部分采用，AI与界面待实现。

- [015 持久讨论回复](015-durable-discussion-replies.md)：完整本地快照、同轮防重发、AI角色与晚到屏障；限回复基础切片。

- [016 AI段落候选](016-discussion-candidate-derivation.md)：本地复制、独立AI身份、触发点与引用分开。
- [017 混合成果输入](017-discussion-outcome-input.md)：完整角色历史与原文/AI双重出处。
- [018 持久混合成果](018-durable-discussion-outcomes.md)：结束范围单次提取、原子回流、历史与迁移；真实自然样本和完整 AC-11 尚待验证。

- [019 成果生产者顺序](019-model-producer-sequence.md)：无await唯一预留顺序、迁移严格保留，旧包确定回溯基线；共享成果执行已接入；完整 AC-11 尚待验证。
- [ADR-020 英文反馈记录](020-english-feedback-records.md)：独立保存原句、建议与练习比较，避免污染认知候选和行动。

- [021 表达关联持久身份](021-durable-expression-association.md)：独立快照与尝试、当前表达派发去重、未知不重发；新增schema22/v21的持久忽略及安全卡片投影。

- [022 问题生命周期边界](022-question-lifecycle-boundary.md)：独立状态与认知认可/证据分离；持久身份/修订、当前答案依赖修复及来源/讨论/静默入口已接入，自动推断与自然质量仍开放。

- [023 表达处理意图](023-expression-processing-intent.md)：已采用只读的文字/权限/端口范围快照；持久队列、保存入口与自动执行待实施。

- [ADR024：转写前录音处理请求](024-recording-processing-request.md) — 已实现，复用原模型队列，明确录制选择可恢复、迁移冻结。

- [ADR025：长逐字稿无损计划](025-transcript-segmentation.md) — 本地来源计划及原生预览已采用；父批次/片段模型执行仍待验证。

- [ADR026：分段持久父批次](026-segmented-processing-batch.md) — schema27/包v27、入队取消和历史恢复已采用；模型执行仍待实施。

- [ADR027：持久片段提取](027-durable-segment-extraction.md) — schema28/包v28、独立预留暂存及全局顺序已采用；真实云端与整篇聚合仍待实施。

- [ADR028：整篇认知本地派生](028-segmented-cognitive-projection.md) — schema30复用认知实体事务，付费回执与派生身份分开；真实接口及完整长关联待验收。

- [ADR029：稳定开发签名](029-stable-development-signing.md) — 使用既有Apple Development身份；一次代码更新/重启后原清单回读通过，正式分发另行审查。

- [ADR-032 精简片段与聚合请求](032-compact-segment-extraction.md)：独立v3候选，持久完整身份、云端只发送本段归属与原文；旧请求不升级。

- [ADR033：提醒事项状态冲突恢复](033-reminder-status-resolution.md) — schema32/含记录的包v32；显式采用新鲜外部状态，保留历史基线并恢复后续自动完成回流。

- [ADR034：提醒事项时间观测与三方基础](034-reminder-time-observation-and-merge.md) — schema33/含时间的包v33；保留日期/时刻/未知语义，纯策略尚未接实际改期执行。

- [ADR035：持久本地排期意图](035-durable-action-schedule-intents.md) — schema34/含排期包v34；独立版本/锚点/归属与三方预览，实际外部改期仍待实现。

- [ADR036：普通弹性排期持久操作](036-safe-reminder-schedule-operations.md) — schema35/操作包v35；条件保存、写后回读、unknown只读恢复。
- [ADR037：具体效果确认与本地期限编辑](037-effect-bound-schedule-confirmation.md) — schema36/许可包v36；一次用户许可、不可变撤回及重要期限执行屏障。

- [ADR038：期限字段归属与后续重排](038-reminder-due-provenance.md) — schema37/依据包v37；连续应答/观测依据、人工与未知间隔保护。

- [ADR039：纠错行动影响只读投影](039-correction-action-impact-projection.md) — W16第一切片；明确纠错根、实际版本依赖与外部现状核对，具体补偿仍待实现。

- [ADR040：明确纠错后的期限补偿](040-corrective-reminder-due-compensation.md) — schema38/补偿包v38；连续已确认AI链恢复、具体效果许可/撤回、一次尝试及unknown只读核对；原生验收仍待完成。

- [ADR041：完整处理与成果复用输入的纠错追溯](041-correction-processing-dependencies.md) — 共用错误根解析、不可变处理依赖、未引用背景与多级复用、全依赖来源绑定；schema38不变。

- [ADR042：运行时线成为产品基线](042-runtime-line-becomes-main.md) — 运行时线 schema 49 成为 main；旧 main 保存为 `archive/main-migration-20261028`；两条线不再并行。
