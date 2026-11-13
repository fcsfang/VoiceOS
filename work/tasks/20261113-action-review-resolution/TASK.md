---
status: open
started: 2026-11-13
updated: 2026-11-13
branch: work/action-review-resolution
pr: 137
owner: coordinator
---

# 行动关系待核对的人工核对入口

## 目标

用户报告工作区「这些待办需要核对」里的两条材料一直卡着（AI Hub 那一段录音的两份导入）。目标：让用户能真正核对并解除暂停，而不是永远显示「打开材料核对」却没有出路；同时不撒谎（不自动完成、不改写 AI 原始判断）。

## 根因（副本与代码路径证据）

- 这两条材料其实是同一个连续表达 `EF343CF0` 的两份副本，卡住的待办只有一条：`E015DBA2`。
- 该表达的旧行动复核里有一条「不确定是否与旧记录重复」的判断，旧侧是早期提取的机会 `98A6FE91`（已冻结、无提醒关联），新侧是当前任务。按既有设计，候选被暂停外部同步，等待人工核对。
- 人工核对从来不存在：`重新识别` 对未改动文字会按摘要复用已完成的处理结果，模型不会重跑；`批量重新识别` 明确排除这类项；`更正原文` 只在文字真错时诚实。暂停同时挡住提醒同步与「交给 AI」。
- 另有第二种死结形状：表达 `392461F3` 只有旧协议的 `taskReviewPending=true`、没有任何候选数据，名下行动永久暂停、无法解决。

## 决定

- 用户的核对判断单独落一张表；存储里的 AI 判断一个字节不改。判断按表达内容摘要绑定：以后重新理解产生新判断，旧判断自然失效、重新核对。
- 派生一份唯一生效状态（核对台账），面板、批量重新识别、提醒同步、AI 委托四道门控全部读它；应用里重复的判定副本删除。
- 两种核对答案：「两件事」保留两条记录、新记录继续有效；「同一件事」旧记录接回身份（保留完成状态、提醒关联与修订历史），新记录停用并冻结。旧记录已有接续历史时不提供合并，只提供「两件事」并说明原因。
- 旧协议形状给一个整段表达的「已核对当前理解」，同样按摘要绑定。
- 数据库 52→53，迁移与恢复、导出导入同步覆盖；迁移包格式升到 48。

## 范围

- 新增 `Sources/VoiceOSCore/ActionReviewLedger.swift`、`ActionReviewResolution.swift`：台账、两张用户判断表、幂等核对命令、合并动作与存储校验。
- `WorkspaceSnapshot`、`WorkspaceActionPause`、`PausedActionBatchPlan`、`SourceReidentification`、`RemindersStore`、`RecordingExpressionReminders`、`AssistantExecution`：统一读台账；AI 委托门控从整段表达收紧为逐行动。
- `Database.swift` 迁移；`Store.recover` 与 `PortablePackage` 校验/导入导出。
- 应用层：`VoiceOSApp.swift` 发布台账并新增两个命令；新增 `ActionReviewResolutionView.swift`；任务页、处理面板待办行、材料页整体理解处放置控件。
- 新增 `Tests/VoiceOSCoreTests/ActionReviewResolutionChecks.swift`；四处既有测试随 schema 与派生状态更新。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 104 项 0 失败（main 基线 95，本分支新增 9 项）。
- 实时库副本实跑（`/tmp/voiceos-review-*`，三份独立副本，实时库未写入）：
  - 选「两件事」：`BEFORE pairs=7 requiresReviewTarget=true pausedTasks=["E015DBA2…"]` → `AFTER requiresReviewNew=false requiresReviewOld=false pausedTasks=[]`；任务仍在、旧记录留史。
  - 选「同一件事」：`AFTER survivor=98A6FE91… dismissed=E015DBA2…`，存活记录标题与类型换成这次理解，关闭记录冻结。
  - 旧协议表达：`BEFORE canAcknowledge=true` → `AFTER acknowledged=true canAcknowledge=false requiresReviewTarget=false`。
  - 三份副本重开校验通过（user_version=53）；存储的表达 JSON 与实时库逐字节一致（sha256 对比）。
- 界面实机（隔离实例，新构建，副本资料库）：处理面板出现「行动关系待核对」控件（旧记录、这次识别、依据原话、两件事/同一件事）；点击「两件事」后数据库落入 `different` 记录，页面跳到任务页，任务恢复常态且「交给 AI」恢复可用。
- 未对实时库写入；提醒事项无外部写入（合并只更新本地期望标题）。

## 链接

- 设计与仲裁：`/tmp/arena-action-review/`（GROUNDING、两套候选、SYNTHESIS；临时目录）。

## 待确认

- 「同一件事 / 两件事」的语义与文案由用户在界面上最终确认；本分支只提供判断，不对实时库做任何预设。

## 进展

- 2026-11-13 根因确认、两案设计仲裁、实现、测试与副本/界面验证完成；分支从 main 独立开出，未合入。
