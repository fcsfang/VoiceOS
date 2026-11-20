# 波 120-A：主题策展的数据层（升为主题、合并主题）

基线 `work/m120-curate`，工作树 `.worktrees/m120-curate`。改四个文件：`Sources/VoiceOSCore/ReflectionQuestions.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/WorkspaceView.swift`，新增 `Tests/VoiceOSCoreTests/TopicCurationChecks.swift`。未改数据库版本与 schema。

## 目标

主题页已按判据分为主题与线索（119）。用户需要两种策展动作：把线索升为手动主题；把同族主题或线索合并。本单元落数据层事务、ControlCenter 包装与主题详情入口，不改 AI 归组流程。

## 数据层

### promoteReflectionQuestion(id:)

- 事务内 `UPDATE reflection_questions SET title_source_id=?, ai_named=0, version=version+1, updated_at=? WHERE id=?`；不存在时抛 `找不到这个长期问题`。
- 与父任务给定语句的唯一差异：`ai_named == 1` 时先把当前标题写成用户表达，插入 `reflection_question_sources`，并把 `title_source_id` 指过去。理由不是交互偏好，而是恢复校验：`validateStoredReflectionQuestions` 要求手动主题的标题来源必须是 `user_text/user/user` 且原文等于标题；AI 主题的标题是模型生成，只翻 `ai_named` 会让下次 `recover()` 直接失败。`organization_json` 保留，阅读卡不丢。
- 已经是手动主题时重复调用只 bump `version` 与 `updated_at`，不重复造标题来源。

### mergeReflectionQuestion(id:into:)

- 先拒绝 `id == targetID`，再确认两者都存在。
- 单个 `BEGIN IMMEDIATE` 事务内按外键顺序处理：
  1. `reflection_question_entries`：`UPDATE question_id=target, sequence=sequence+target最大序号`。记录随主题迁移而不是删除；偏移量避开 `UNIQUE(question_id,sequence)`。
  2. `reflection_question_sources`：逐行 `INSERT OR IGNORE` 到目标（新 UUID，按 `PRIMARY KEY(question_id,source_id)` 去重），再删除来源链接。
  3. `assistant_executions.question_id`：改挂目标。该外键父任务未列出，但不迁移会阻止删除主题行。
  4. `topic_claim_confirmations`：`command_id` 全表唯一，复制行会在源行仍在时撞唯一约束并被 `INSERT OR IGNORE` 静默丢弃（测试抓到的真实缺陷）。改为逐行就地 `UPDATE topic_id=target`；目标已确认同一 claim 时删除来源行。
  5. `reflection_topic_feedback`：`question_id` 唯一。目标已有反馈行时保留目标、删除来源行；否则把来源行改挂目标。
  6. 删除来源 `reflection_questions` 行；`organization_json` 随行删除，阅读卡按需重建。
  7. 目标 `version=version+1, updated_at=?`。
- 事务原子；成功后再次对同一来源调用会抛 `找不到这个长期问题`。目标的 `ai_named` 不变：并入 AI 主题仍是 AI 主题，并入手动主题仍是手动。

## App 入口

- `ControlCenter.mergeTopic(_:into:)` 与 `promoteTopic(_:)`（`VoiceOSApp.swift:5188`、`:5193`）调用 store 后 `await refresh()`，与 `renameReflectionQuestion` 同一条刷新路径，`workspaceTopics`、`workspaceTopicSources` 与首页快照一起重载。
- 主题详情「调整主题」菜单（`WorkspaceView.swift:1053`）：线索多一项「升为主题」；所有主题都有「合并到其他主题…」（纯主题也允许同族整理）。
- 合并弹层（`WorkspaceView.swift:2805`）列出除自身外的全部主题，显示标题与材料数，选中后显示「会把「A」的材料并入「B」并删除「A」」，确认才调用；成功后关闭弹层、回到主题列表并 toast；失败走既有 `fail()` 错误条。
- 没有新增或修改任何既有 identifier；升格菜单只在线索上出现，避免对已手动主题做无意义操作。

## 测试

`TopicCurationChecks` 三个行为测试：

- promote：用底层 db 造 `ai_named=1` 主题，断言升格后 `isAIOrganized == false`、`version` 从 1 到 2、标题来源换成原文等于标题的用户表达、`validateStoredReflectionQuestions` 通过；不存在 id 抛错。
- merge：两个手动主题，来源额外挂材料，双方各有记录；合并后断言来源主题消失、目标材料集合含两边标题来源与补充材料、记录顺序为 `["乙的记录","甲的记录"]`、A 上确认的 claim 出现在 B、A 的反馈在 B 无反馈时迁到 B、来源链接与确认残留清零、B 版本加一、两个校验器通过。
- merge：目标已有反馈时保留目标、删来源；重复合并已消失的来源、自我合并、目标不存在分别抛预期错误。

第一次全量运行时正是第二个测试暴露了 `command_id` 唯一约束问题；修复后定向 `TopicCurationChecks` 3/3 通过（0.150 秒）。

## 验证

共享锁循环，工作目录 `.worktrees/m120-curate`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码：

- `build_exit=0`
- `test_exit=0`
- `Executed 676 tests, with 0 failures (0 unexpected) in 43.791 (43.852) seconds`
- 与 119 的 673 个相比 +3，即新增的三个 TopicCurationChecks
- 日志保留：`/tmp/m120a-build.log`、`/tmp/m120a-test.log`；定向日志 `/tmp/m120a-focus.log`
- 代码提交 `56c6b44 feat(topics): 主题手动升格与同族合并`

## 未做与取舍

- 未启动应用做目视验收：本轮约束是不重启应用，验证止于全量构建与测试。
- 合并不可撤销：没有撤销栈，删除来源主题靠弹层的二次确认语句承担风险提示。
- 目标主题的 `organization_json` 不在合并事务里重写；只 bump 版本，读取端按新链接算出 stale，等下一次 AI 整理刷新。避免在数据层伪造模型摘要。
- `reflection_question_entries` 选择迁移而非删除：保留用户手写记录，序号按目标最大值续排；若以后需要按来源区分记录来源，需另加列。
- `assistant_executions.question_id` 的迁移是额外必要项：不迁移会因外键阻止删除来源主题；已完成的 AI 交付因此跟随存活主题。
- promote 对已是手动的主题仍会 bump 版本，没有做成完全幂等的 no-op；菜单只在线索上暴露，重复触发窗口很小。
- 未 push、未合并、记录未删。