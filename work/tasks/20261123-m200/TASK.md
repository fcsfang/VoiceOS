# 200 全仓提示词禁令清点与删改

来源：用户要求「不要带禁令，全面筛选一遍」。只读工作流清点全部模型提示词（452 条条款，75 条 fence），按三类处置：fence 删除/软化；contract 保留（正确性契约）；honesty 保留（事实诚实）。

## 已删/软化的 fence（按文件）
- ResponsesAssistantPort：分析骨架与「一两个角度」、命令式结论禁令、工作计划禁令、工具日志禁令、首行一级标题、reason「简洁」→ 正面表述（交付标题回退为 action 标题）。
- ResponsesDiscussionPort：机械绑定/机械重复禁令、每次必须给验证建议 → 可选、简洁/不要被带偏/不强制提问/不输出工具调用 → 删除，保留引文与建议归属契约。
- ResponsesTopicOrganizationPort：新建主题「至少两份材料」门槛、标题句式模板、排除清单、句数/「简洁」、不要按…归域 → 正面化；保留 domain 枚举、id 规则、观点全覆盖、合并并集、引文逐字与状态诚实。
- ResponsesNotificationAnalysisPort：2–4 句 → 长度随内容；内部字段名禁令 → 正面表述。
- ResponsesRecordingTitlePort：10–20/24 字、1–2 句、1–5 段、选材偏好、空泛词禁令 → 删除；保留校验器硬限（title≤40、summary≤240、quotes≥1）并写成技术上限。
- ResponsesOutcomePort：最多 32 项、简洁 → 删除；保留「不为了数量限制合并不同交付物」等契约。
- ResponsesTaskInitiationPort：3–7 步、只放一个问题、8000 字、一句 → 删除；纯文本与事实诚实保留。
- ResponsesRecordingFollowupPort：必须理解连续表达、少量、展示词禁令、发音/流利度评分禁令 → 正面化或删除；引文与成长诚实保留。
- ResponsesRecordingExpressionPort：相同主题不充分等否定判据 → 正面判据；复核轮指引正面化。
- ResponsesExpressionAssociationPort：同词不强行关联 → 正面判据；「简短」删除。
- ResponsesKnowledgeReviewPort：术语陌生不判错 → 正面化；不改变立场/不改原文/不创建任务 → 精简为不冒充立场；不编造来源保留。
- ResponsesEnglishPracticePort：评分禁令删除。
- ResponsesRelevancePort：相关判据改为定义式正面表述。
- ResponsesReminderFieldPort：「简短」删除。
- ResponsesSegmentPorts：「简短」「最短」改为正面。
- ReflectionChangeView：追问内容指令 → 正面目标。

## 有意保留（契约/诚实，非 fence）
- MaterialNote v3：正文归属（他者不并入我）、inferred 必填、quotes 逐字+sourceID+JSON、矛盾保留、不编造因果/事实、标题是真实关切。其中「正文不加建议/诊断」属归属结构，等 v4 批注层落地时再重构（现在删会把 AI 判断混进作者正文，见审计风险）。
- Topic：观点全覆盖、id 与 domain 枚举、合并并集、quote 锚定、状态诚实。
- Assistant：意图判断语义、不声称外部动作、调研必须真实检索与引用。
- 各端口：引文逐字、覆盖、不虚构完成/成长/认可。
- RecordingTitle：校验器硬限（title≤40/summary≤240/quotes≥1）。
- organize_podcast.py / organizer_quality.py：交付物划分与保真条款属数据语义契约（任务合并/转写保真），保留。
- Relevance：最多三条（与 schema 一致）。

## 行为变化提示
- Assistant 交付不再要求首行一级标题：标题回退为 action 标题。
- Topic 骨架不再有「至少两份材料」门槛：主题数量可能增多。
- 其余为提示词措辞变化，不影响解析（JSON/schema 未动）。

## 验证
parse_exit=0（全部改动文件）；集成构建 105 + 全量测试。
