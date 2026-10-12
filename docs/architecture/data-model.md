# VoiceOS 数据模型 v0.1

日期：2026-10-10。状态：工程草稿；完整概念模型尚未冻结；Source/Asset/Job/Transcript 输入子集已有版本化 SQLite 实现，见[实施记录](../engineering/m1-file-input.md)。依据：[PRD](../product/prd.md)；配套：[架构](system-architecture.md)、[状态机](state-machines.md)、[ADR](../adr/README.md)。

## 1. 身份、版本与时间

推荐带类型的关系表、公共对象目录和不可变版本记录；不把全部实体塞入无约束 JSON/EAV。结构化状态用 SQLite，媒体用独立文件；嵌入向量/搜索索引可重建。下文是可供建表和接口评审的数据字典，不是最终 DDL。

| 通用概念 | 字段草案 | 约束 |
|---|---|---|
| Object | id: UUID、kind: 枚举、current_version_id: UUID?、version: 整数、created_at、updated_at | 内部 ID 全局独立，建议 UUID v4；不使用提醒事项 ID 或标题充当身份；更新比较 version |
| ObjectVersion | id、object_id、schema_version、version_no、payload、origin、created_at | 同对象 version_no 唯一；payload 按对象类型验证；原版本不覆写，明确删除时允许清理内容 |
| 来源身份 | origin: user/ai/external/system、speaker: user/external/unknown、speaker_label? | 系统记录者不等于内容作者；未知说话人不猜成用户 |
| 时间 | occurred_at?、observed_at、timezone、raw_time_expression? | 绝对时间用 UTC，保留 IANA 时区；未知发生时间为空，观测时间不能替代发生时间 |
| 有效性 | current/superseded/frozen/invalidated/deleted、reason? | 与认知认可/证据及业务执行状态分别保存；读时还要检查冻结根/删除屏障 |
| 来源约束 | data_policy_id、policy_version；版本级来源依赖 | 对实际发送的每个内容片段检查来源闭包；只看对象的自带标签不够 |

公共 Object 是引用与删除屏障入口，不承载所有业务字段。类型表外键指向 Object；ObjectVersion 保存该类型的历史快照。`current_version_id` 必须属于同一对象；ID 重用、跨类型改名、悬空当前版本均拒绝。所有历史 payload 遵守同样的读取、上传与删除限制。

内容摘要用于完整性与重复传输核对；相同字节的两次用户表达仍可能是两个真实事件，不能仅按 hash 合并身份。所有变更记 command/job/operation 身份，保证重交付同一命令不重复产生逻辑记录。

## 2. 原始表达与来源

| 实体 | 关键字段 | 关系与约束 |
|---|---|---|
| ThoughtEvent | id、entry_mode: A/B/import、occurred_at?、capture_timezone、conversation_id?、source_ids | 一次表达可包含多来源，并生成多个观点/问题/行动；B 用户发言也可成为事件 |
| Source | id、event_id?、kind: recording/audio/video/text/external_excerpt、speaker、source_locator?、save_state、completeness、data_policy_id | 一个来源可被多个产物引用；source_locator 是出处，不是已保存副本；unknown/partial 明确显示 |
| Asset | id、source_id、role: original/derived、relative_path、media_type、byte_length、sha256、duration_ms?、track_id?、seal_state | 封存原件不可覆盖；路径只在受管目录内；转码新 Asset，保留原件；删除时检查共享引用 |
| Transcript | id、source_id、kind: verbatim/cleaned、language、text、segments、backend/config_version、input_asset_id | 忠实转写和清理稿分别版本化；文本修正不改音频；每个片段有真实或未知时段 |
| SourceSpan | id、source_version_id、transcript_version_id?、asset_id?、start_ms?/end_ms?、text_start?/text_end?、quote? | 至少一种可回溯定位；区间不越界；未知时间为空，不能造秒数；文本 offset 明确采用 Unicode 标量索引 |

`ThoughtEvent → Source` 为一对多；Source 的事件归属可以为空，例如先导入、后引用的外部资料。清理稿和用户修正保留对应 Revision。说话人/音轨无法分离时，标 unknown 并让产物归属待核对；保存不依赖成功分离。

SourceSpan 的 quote 是受权限/删除约束的内容副本，不是无约束审计字段。Asset 元数据和原文也不能通过日志、文件名或导出目录绕过限制。

## 3. 认知、行动与反馈

| 实体 | 关键字段 | 语义约束 |
|---|---|---|
| Claim | id、statement、ownership、evidence_state、validity、qualifications、span_ids | 归属、证据、有效性三轴独立；用户明确表达自动暂存，AI 新结论保留候选 |
| Question | id、question、status: open/exploring/resolved/closed、span_ids、resolution_refs | resolved 要有解决依据；关闭不自动证明答案正确 |
| Goal | id、description、status: proposed/active/paused/achieved/cancelled、success_conditions、span_ids | 目标达成需独立依据；完成一个 Task 不自动 achieved |
| Project | id、goal_id?、name、status、plan_revision_id | 可组织一组任务，也可无 Goal；计划版本与认知修订关联 |
| PlanRevision | id、goal_id?/project_id?、input_refs、ordered_task_ids、activation_decisions、reason、previous_plan_id? | 记录自主拆解/重排依据与计划版本；明确承诺不能被弹性计划覆盖 |
| Opportunity | id、description、status: candidate/parked/activated/closed、conditions、span_ids、activated_task_id? | 模糊愿望不外写；激活创建新的 Task，通过关系保留由来 |
| Task | id、goal_id?、project_id?、title、business_state、schedule、completion_origin?、last_observation_id? | 独立任务允许两外键为空；business_state 与 Operation/同步状态分开 |
| Outcome | id、task_id?、event_id?、kind: external_completion/user_report/system_observation、fact、observed_at、evidence_refs | 已核对外部完成是行动事实，非观点验证；未观察到的效果不能编成结果 |
| Reflection | id、event_id、outcome_ids、claim_refs、text、span_ids | 用户后续表达/反思独立记录；普通任务无需强制产生 Reflection |
| Relation | id、from_version_id、to_version_id、type、basis_span_ids、proposer、review_state、validity | 支持/限定/反驳/延续/主题相关/任务来源等显式类型；无依据关联是候选；主题关系不自动成为派生依赖 |
| Revision | id、object_id、from_version_id、to_version_id?、reason、actor、evidence_refs、command_id | reason 区分 user_development/evidence_update/ai_error/transcription_error；AI 纠错不能标为用户成长 |
| Conversation / Turn | 会话 id、entry_command_id、state；回合 id、speaker、source_refs、content_version、context_refs | 仅显式用户命令进入 B；AI 回答和用户认可不合并；退出会话不认可全部内容 |
| EnglishExpressionFeedback | id、source_span_ids、original_text、suggested_text、explanation、comparison_refs、modality | 保存原句与建议；历史比较引用具体版本；无发音后端时 modality=text，禁止发音评分字段 |
| FeedbackItem | id、trigger_refs、content_version、dedup_key、value_reason、state、delivery_channel、notification_policy_version | 默认 channel=control_center；认知通知开关独立于任务提醒；忽略不创建待回应任务 |
| NotificationPolicy | id、cognitive_notifications_enabled、paused_until?、delivery_windows、attention_budget、version | 默认认知通知关闭；窗口/预算数值待 H06；重新开启不自动倾倒全部旧反馈 |

Claim 候选枚举：ownership=`user_tentative/user_confirmed/external/ai_candidate/unresolved`；evidence_state=`unknown/unverified/supported/challenged/conditional`。认可必须引用用户原话或显式命令；沉默、阅读、收藏、完成任务均不是认可事件。`supported` 保存支持出处和条件，不表示绝对正确。

Task.business_state=`planned/active/completed/cancelled/deferred`。本地请求外部任务完成时，先记 desired 和待核对 Operation；外部完成未核对前，业务视图不能声称已同步。一个任务可以有多个先后 Operation，一个 Operation 只代表一次逻辑变更，未确认不复制 Task。

### 时间与计划字段

`schedule` 至少区分 `date_only` 和 `instant`，保存 `local_date? / due_at? / timezone / raw_expression / anchor_event_time / commitment_kind / origin`。用户明确承诺期限与 AI 弹性安排分别标 `user_commitment/ai_flexible`；推断未知时不造日期。“明天”以表达时刻/时区解释，不在重试时重新计算；整天日期不转 UTC 后改变当地日历日期。修改明确承诺期限遵循重要执行边界，弹性重排按 P01 持续授权。

下一步激活数量为可配置计划策略，并在回归中检查负担与漏建；不在数据模型硬编码所有目标必须有 N 个任务。

## 4. 派生依赖、权限与运行记录

| 实体 | 关键字段 | 约束 |
|---|---|---|
| Dependency | input_version_id、output_version_id、role: content/interpretation/action_basis、job_id? | 记录真正使用了哪些依据；有方向，无派生环；不以主题相关代替；内容依赖用于权限传播 |
| InvalidationRoot | root_version_id、reason、epoch、created_at、scan_state | 写根与 epoch 的事务先于后台扫描；扫描未完也需沿链过滤可信读取/执行 |
| DataPolicy | id、local_only、allowed_categories、allowed_destinations、version | 文本/历史许可不自动含音频；转写/摘要/embedding/历史版本受来源限制；收紧立即阻止待发送 |
| ActionGrant | id、scope_binding_id、operation_classes、standing/specific、effect_fingerprint?、version、state | 普通操作使用持续授权；具体高影响授权绑定对象/字段/预期版本，不能复用给变更后的计划 |
| ScopeBinding | id、adapter、selected_external_scope、device_binding、state、observed_permission | OS 权限与应用清单范围分开；未设实际范围不执行；设备迁移不当作有效外部连接 |
| CommandReceipt | command_id、command_kind、input_fingerprint、result_refs、state | 同一命令重交付返回同结果；同 ID 不同内容拒绝，不把新用户表达当重交付 |
| ContextBundle | id、purpose、destination、selected_version/span_refs、policy_epoch、knowledge_epoch、budget/truncation、expires_at? | 精确记录实际上下文；只含允许发送的内容；发送/提交前重验，冻结后不能沿用缓存 |
| ProcessingJob | id、stage、input_versions、config_version、state、attempt_count、lease_owner/until/epoch、knowledge_epoch | 同阶段/输入版本/参数身份去重；新输入新 job；晚到回调不能覆盖当前版本 |
| JobAttempt / ModelCallAttempt | id、job_id、attempt_no、provider/model/prompt/schema_version、input_refs/hash、start/end、status、usage?、billing_state | attempt 唯一；费用 unknown 与零分开；技术日志不存 API key 或不必要原文 |
| Operation | id、task_id、intent_version、type、scope_id、correlation_marker、desired_fields、expected_base、grant_version、state、lease、input_refs | 首次调用前持久化标记，可由操作 ID 派生；内部意图与 outbox 同事务；unknown 禁止重放创建 |
| OperationAttempt | id、operation_id、attempt_no、sent_at?、adapter_result、observation_refs | 已知失败才允许新发送；核对与发送是不同动作；结果未知不改写为未发送 |
| ExternalMapping | id、task_id、adapter、scope_binding_id、external_id?、operation_marker?、base_fields、last_observation_id?、status | 内部身份独立；已确认单一关联才建有效映射；外部 ID/可编辑标记不能独自证明全局稳定身份 |
| ExternalObservation | id、mapping_id?、read_at、result: present/missing/ambiguous/permission_blocked/error、fields?、external_modified_at? | 失败读取不是删除；missing 不是 completed；保留最后核对时间；外部时间可为空 |
| DeletionJob / Tombstone | job id、对象/来源范围、state、清理清单；tombstone object_id、epoch、deleted_at | tombstone 不含原文，先阻断再清理；晚到输出查屏障，不复活删除对象 |
| ExportManifest / ExportPin | format_version、snapshot_seq、entity/file counts/hashes、media_mode、omissions；pin snapshot/asset refs、expires_at | 清单描述实际内容；媒体未打包可恢复结构但必须显示原件不可用；pin 保护在途一致快照 |

派生权限针对**实际内容数据流**，执行依据冻结针对**决策依据**。二者不能用普通 Relation 全量传染：相关但没用到 A 的 B 不受 A 权限牵连；含 A 摘要的 C 必须受 A 限制。混合来源输出需记录每项来源，无法证明分离时按更严格限制。

外部 Observation 的完成事实可保留为历史，即使任务的原推断后来被纠错；它不能作为旧错误观点的新证据。受限/删除源内容仍需从该事实附带的原文和描述中清理，不能借“审计”留下隐含副本。

## 5. 事务与唯一性契约

1. 保存：Source.saved、Asset 封存引用和首个 job 同事务；外部文件窗口按[状态机 §2](state-machines.md#2-source-保存状态)恢复。
2. 产物：检查输入版本、权限/知识 epoch、租约及删除根后，ObjectVersion、类型字段、Dependency、Revision/后续 job 一起提交。唯一产物槽 `(job_id, stage, output_slot)` 使相同 stage 重交付不重复；模型新分析作为新版本，不能默默覆盖。
3. 规划：PlanRevision、Task 与 queued Operation 同事务。外部 API 不在 SQLite 事务里执行，不能锁数据库等待网络。
4. 回流：Observation、唯一 mapping、Operation.confirmed 和相应 Task/Outcome 同事务。失败后先核对，再完成内部提交。仅在新观测到完成状态迁移时生成完成 Outcome，按 mapping + 本地观测迁移身份去重；重复刷新不造新结果。外部重开/再次完成可记录新迁移，不推断离线期间未观测到的过程。
5. 纠错：Revision、冻结根和 epoch 先原子提交；受影响对象的读/发/写均检查有效依据，后台再列影响清单和重新推导。
6. 删除：范围、tombstone、epoch、取消 jobs/待发项先提交，再清 payload/版本/引用片段/索引/缓存/受管文件；可重复恢复清理。

类型引用存在且类型相符；时间范围合法；同一来源版本的段落 offset 不混用新文本；有效映射单任务/适配器/实际清单至多一条，发现多项先 ambiguous。外部对象不能施加本地唯一约束，不能将此规则解释为保证外部没有重复。

## 6. 导出、备份与恢复

推荐 v0.1 可读逻辑包：`manifest.json` + 按类型 UTF-8 JSONL + 可选 `assets/`。记录格式版本、原对象 ID、版本/修订、来源/关系/权限、文件长度/hash及省略媒体清单。恢复工具按已知 schema 验证，拒绝重复 ID、悬空引用、越界片段、未知不兼容格式、目录逃逸和损坏。hash 证明完整性核对，不等于加密或真实性认证。

凭据不导出。恢复保留产品授权/限制的记录，但新设备的 OS 权限、外部 scope 绑定及待发 operations 暂停，重新核对真实连接后才允许继续；不用迁移导入批量重建任务。已有正常持续授权无需逐条重问。索引重建不改变原历史的含义。

首版先支持恢复到空库：临时目录/库预检并完成一致性核对，成功后一次切换；失败保留现库和清晰报告。合并两个现存历史库、跨设备实时同步另立方案，不隐含支持。结构化包缺媒体时显示 reference_only，不伪装音频已恢复；包含媒体的包逐文件验证。

本地灾难备份候选采用 SQLite 一致备份接口取得 DB 快照，再按该快照的封存资产集合打包，不直接复制活跃 WAL 主文件。在途 ExportPin 阻止相关资产被物理清除；删除请求仍立即建立屏障，并取消涉及对象的在途导出，再解除 pin/完成清理。快照创建与 pin 登记在受控写入边界完成，不能事后发现文件已删才声称一致。

首版建议按需导出/备份；自动备份频率、加密与保留期待 H08/P06 工程验证。历史备份和已导出的副本不会被当前数据库删除自动追回；产品必须显示边界和清理入口。迁移按版本链预检/执行/回滚，不用直接改旧 JSON 假装已升级。

## 7. 删除和长期演进

删除某来源时清理其原件、逐字稿、引用片段和含其内容的历史/派生产物。多来源结果如能从保留来源独立重建，则先移除旧 payload、生成新版本；不能证明独立则退出可读记忆/执行。删除清理不能只改当前版本，留下修订原文可查询或上传。

默认不删除外部笔记/提醒事项；必要时只保留不含被删内容的最小解除关联记录。当前受管数据清理与外部/用户备份副本分开报告，不承诺擦除所有磁盘残留。删除后的 tombstone、技术故障记录只留必要非内容元数据；其保留期也需验证。

Core 持有这些身份/版本契约；未来完整应用、思源或不同任务系统作为适配器使用它们。模型、UI、索引改变不会重新给历史分配 ID；派生重分析保留新模型/提示版本及来源。正式 schema 与升级工具在路线图阶段安排，实现前按[审查表](review.md)检查本稿的约束能否执行。

2026-10-10 开发切片增量：schema 10/逻辑包 9 已实现显式用户文字 origin=user/speaker=user、保留原文资产与文字版本；user_tentative 归属和 nullable action 提案与行动同事务提交，auto_send 默认 0，普通明确提取任务经本机连接/来源权限核对有限激活。外部完成仍独立反馈，不认可观点。恢复原提取/行动关系、旧格式 1–8 和旧 schema 9 已核对；完整目标、语音身份与长期闭环未完成。实际字段/边界见[表达行动记录](../engineering/m3-expression-actions.md)与[ADR-007](../adr/007-expression-action-extraction.md)。

## 2026-10-11 已实现的相关性调用增量

存储 schema 12 / 迁移包 v11 新增 `relevance_attempts` 与 `relevance_inputs`，独立于生成观点的模型调用。前者保存查询、完整有界快照、模型/提示/结构版本、调用状态、输入有效性、最多三个候选 ID、用量与摘要；后者按 ordinal 引用每个来源、文字版本及权限版本。

调用结果状态 reserved/completed/rejected/unknown 与输入有效性 current/frozen 分离。来源更正、权限变化及隔离冻结完整输入；恢复包时所有记录 frozen，未完成调用 unknown。历史权限按策略修订链核验，历史文字按不可变版本核验，不能用当前文字替换旧出处。完整性摘要不代替来源和引用校验。该切片不产生 Relation/Claim/Action，实际云端相关性适配器仍待实现；见[ADR-010](../adr/010-durable-relevance-attempts.md)。

## 静默反馈实施增量（2026-10-11）

Schema13/迁移v12新增`cognitive_feedback_ignores`（原调用、候选及查询/原文稳定指纹）和`cognitive_feedback_preferences`（顺序版本、normal/reduced/paused与命令身份）。卡片内容从有效相关性回执投影，不复制原文、不改变观点/证据/行动；读取与打开均复核全部输入。忽略不代表放弃兴趣，关闭不代表认可。恢复保留偏好及忽略、冻结回执；详见[ADR-012](../adr/012-quiet-relevance-feedback.md)。

## 口述来源语义增量（2026-10-11）

Schema14/迁移v13保留21表，但新增`microphone-v1:<sourceID>`个人口述身份语义。用户声明本人表达，origin/speaker为user，第三方材料继续external导入。bytes0/零摘要仅允许未封存receiving/interrupted，无资产/任务；封存后按同一来源、原件及输入版本持久保存。元数据迁移提示暂存片段未包含，带媒体导出阻止遗漏未封存片段。旧读者拒绝此版本；详见[ADR-013](../adr/013-durable-personal-dictation.md)。

## 2026-10-11 会话基础实施边界

W17新增conversations和conversation_user_turns，格式v14/schema15；每个个人回合引用受管来源及持久上下文，不复制原件。会话版本仅计用户回合与显式结束；当前尚无AI回合，后续AI历史/调用必须补充独立契约，不能用本表冒充已实现。原子冻结、上下文预算、恢复限制与证据见[实施记录](../engineering/m4-conversation-foundation.md)和[ADR-014](../adr/014-local-conversation-history.md)。

2026-10-12 问题实际存储：schema24/v23包中claims.content_kind为nullable版本化类型，旧nil保留旧摘要；questions独立固定ID连接claim，保存原始seed及摘要、当前状态/版本，question_revisions保存用户命令、前后状态和版本、有界原话/答案上下文及权限epoch。同事务新建typed问题与claim；不回填旧未分类。迁移保留修订并冻结操作；出处关联卡片投影问题当前记录，AI相似提案不成为问题等价或解决依据。细节见[生命周期契约](../engineering/m4-question-lifecycle-contract.md)。

问题状态依赖修订（2026-10-12）：当前resolved引用最新解决修订的答案；明确重开后旧答案仅属历史，不再使open/exploring/closed冻结。canReopen为读取时的能力投影，不保存新权限；仅答案失效且原问题仍有效时可显式重开。所有历史出处和版本仍保留并核对，恢复包不恢复该能力。

2026-10-12 讨论类型增量：成果proposal新增可选contentKind，实时v2响应必填；旧nil编码省略，result摘要和旧身份不变。typed question沿用独立questions登记，AI reply-only context_anchor只定位，实际依据仍在成果replyEvidence。seed固定原scalarBudget（最大12000），旧8000不改；revision提交核对seed的原引文、上下文和权限身份。表及包仍schema24/v23，334项测试与三处成果/六处状态强退恢复通过。

## W14 状态冲突恢复实施增量（2026-10-13）

schema32 新增 `reminder_status_resolutions`，不可变记录 link、observation、action_revision、恢复前同步基线、恢复后行动版本、授权版本及命令摘要。`reminder_links.action_version` 保留创建时值，不改写历史观测校验；最新恢复版本作为后续完成同步基线。恢复只改变本地状态，用户修订、记录及 link 状态同事务。含恢复记录的包 v32 校验历史基线和观测/修订绑定，恢复不带连接权限；其他库按既有内容选择兼容包版本。见 [ADR033](../adr/033-reminder-status-resolution.md)。时间字段与完整三方调和仍待实现。

## W14 时间回读实施增量（2026-10-13）

schema33 `reminder_time_observations(id,due_json)` 引用不可变外部观测，记录类型化 `none/dateOnly/instant`。没有行表示该观测的期限未知；旧历史不回填。时间单独变化同样生成新观测并与时间行原子保存。含时间行包 v33 保留当地日期与明确时区，验证日期/引用；恢复仍不携带连接授权。`ReminderScheduleProposal` 和 `ReminderScheduleMerge` 为内存提案/纯决策，不是已实现的 ScheduleRevision 或 Operation；安全外写仍待实现。见 [ADR034](../adr/034-reminder-time-observation-and-merge.md)。

## W14 本地排期实施增量（2026-10-13）

schema34 `action_schedule_intents` 追加独立排期链：固定 action_version/schedule_version、due、用户承诺/AI 弹性归属、actor、表达/规划文本、固定 anchor_event_time/anchor_time_zone、可选 base_observation_id 与重推的 base_authority、历史 access_version、validity 与命令摘要。与行动状态版本分开，来源/状态变化阻止旧意图执行。含排期包 v34 校验连续历史、承诺保护、观测依据与基线归属，恢复全部 frozen，不恢复实时连接。它是实际本地 desired，区别于已执行 Operation 或完整 PlanRevision。见 [ADR035](../adr/035-durable-action-schedule-intents.md)。

schema35 `reminder_schedule_operations` 绑定唯一 intent、link、expected observation、历史 access version、before/desired、命令摘要；保存 reserved/unknown/confirmed/observed/conflict/blocked、attempted、save acknowledgement、可选结果 observation、validity 和核对时刻。派发前持久 unknown，已尝试意图不可重发；观察到目标日期不自动证明 AI 作者。含操作包 v35 核验意图/基线/尝试边界/结果引用，恢复 frozen，不恢复授权；不修改行动状态版本。普通弹性排期已接条件保存与回读，重要效果确认和字段所有权仍待实现。见 [ADR036](../adr/036-safe-reminder-schedule-operations.md)。
