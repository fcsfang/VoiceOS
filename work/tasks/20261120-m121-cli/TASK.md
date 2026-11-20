# 波 121：只读待办 CLI 与 voiceos skill

基线 `work/m121-cli`，工作树 `.worktrees/m121-cli`。目标是把「读待办」做成 agent 可用的只读 CLI，并附一个 voiceos skill，让本地 agent 能读取待办、挑选、再去执行。写回留到 122 波。

代码提交 `76cd53b feat(cli): 只读待办 CLI 与 voiceos skill`。

## 背景

`VoiceOSStore.init` 建目录、锁文件、跑迁移，`recover()` 写库，app 运行时持独占 flock，第二个 store 打不开。高层读 API 还带隐藏写：`actions()` 可能冻结 validity，`actionScheduleIntents()` 会 UPDATE，`actionFeedback()` 走 transcripts JOIN 会少算。因此 CLI 绕过 store，直接 CSQLite 只读打开，聚合直接查 `action_feedback`。

## 命令面

```
voiceos-cli actions list [--state open|completed|dismissed|someday] [--validity current|frozen]
                         [--kind task|opportunity|ai_suggestion] [--limit 1...1000] [--offset n]
voiceos-cli actions show <id> [--include-feedback] [--include-feedback-text] [--include-note] [--topics]
voiceos-cli status
```

全局参数 `--root <dir>`（默认 `$VOICEOS_ROOT`，否则 `~/Library/Application Support/VoiceOS`）、`--json`（兼容，无实际作用）、`--pretty`。stdout 只输出 JSON（sortedKeys、withoutEscapingSlashes、单行）；错误 JSON 写 stderr。退出码：0 成功，1 参数或内部错误，2 未找到，3 资料库不可用。

## JSON 结构

- `actions list`：`{"actions":[...],"count":n}`。项字段 `id title kind state validity nature version parentID createdAt completedAt feedbackCount lastFeedbackAt sourceTitle reminderState due`；`due` 为 `kind`（none/dateOnly/instant）、`localDate`、`utc`、`timeZone`、`source`（localSchedule/reminderObservation）、`isOverdue`。
- `actions show <id>`：详情对象，含列表全部字段加 `schedule reminder revisions source`；`--include-feedback` 加 `feedback`（id/kind/label/createdAt），`--include-feedback-text` 再加 `text`，`--include-note` 加 `note`，`--topics` 加 `topics`。
- `status`：`userVersion walPresent sources actionsOpen actionsCompleted actionsDismissed actionsSomeday actionsCurrent actionsFrozen feedback topics`。
- 可选字段为 nil 时不出现在 JSON 里（Codable encodeIfPresent）。

## 实现与取舍

1. 只读连接：`SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX`、`busy_timeout(5000)`、`PRAGMA query_only=ON`、整个命令包一个 `BEGIN` 读事务，`deinit` 回滚并关闭。打开与 schema 错误抛 `ReadOnlyLibraryError`（exit 3）；查询期错误抛 `VoiceOSError`（exit 1）。
2. 只接受 `user_version=76`，否则 exit 3「资料库格式不兼容」；显式列名，无 `SELECT *`。
3. due 语义对齐 `ActionTimeSurface`：最新 current 排期优先（即使 `.none`），否则最新 reminder observation；`isOverdue` 与界面同一套日期换算。解析失败的 due 按无期限处理，不中断列表。
4. `sourceTitle` 顺序：`presentation_json.manualTitle`（去空白后非空）> `automatic.title` > `sources.name`。
5. 反馈聚合直接 `COUNT`/`MAX(created_at)`；详情反馈用 LEFT JOIN，缺当前转写不掉行；原文只在 `--include-feedback-text` 输出。
6. topics 反查 `reflection_questions.organization_json` 的 `sections[].actionIDs`，默认关闭。
7. 列表无隐式过滤，排序 `created_at,id` 与应用内一致；`--state open --validity current` 由调用方显式给出。
8. 可执行产品名 `voiceos-cli`（target `VoiceOSCLI`），避免与现有 `VoiceOS`/`voiceos` 在大小写不敏感卷冲突。
9. skill 仓库位置：任务书写 `Skills/voiceos/SKILL.md`，仓库既有约定是 `.claude/skills/<name>/SKILL.md`（verify-voiceos 同此），故放在 `.claude/skills/voiceos/SKILL.md`，并安装到 `~/.claude/skills/voiceos/SKILL.md`。

## 测试与退出码

- `Tests/VoiceOSCoreTests/ReadOnlyLibraryChecks.swift`：用模块内 `Database` 在临时目录建真实 76 版空库（0→76 全量迁移）再插夹具，覆盖过滤、分页、反馈聚合、due 本地优先与逾期、show 默认隐去反馈原文与备注、schema 不符抛错、只读连接拒绝写（query_only）。
- 未手写最小 DDL：claims→model_attempts→contexts、transcripts→jobs/assets 的外键与 CHECK 链手写成本高且容易随迁移漂移。
- `swift build -j 2`：`build_exit=0`。
- `swift test -j 2`：`test_exit=0`，`Executed 681 tests, with 0 failures (0 unexpected) in 49.013 (49.081) seconds`。

## 真实库抽样（只读，日志 /tmp/m121-cli-*.log）

- `status` exit 0：userVersion 76，sources 88，actionsOpen 424、actionsCompleted 88、actionsDismissed 18、actionsSomeday 0、actionsCurrent 301、actionsFrozen 229，feedback 22，topics 102，walPresent true（app 运行中，WAL 在）。`actionsOpen` 与 `open ∩ current` 是不同口径：`sqlite3` 对照 `open AND current=213`，actions 总数 530。
- `actions list --state open --validity current --limit 3` exit 0，返回 3 行。抽查 `3C202E13-0A5A-4149-9602-FC64D66541E0`：`sqlite3 "file:...?mode=ro"` 对照 title、kind=opportunity、state=open、validity=current、nature=narration、version=1、createdAt=2026-10-16T04:10:41Z 全部一致；feedback 0、无 current 排期、无 reminder link，与 CLI 省略的 due/reminderState 一致。
- `actions show <id>` exit 0：出处解析到 source name `2026-10-15_23-55-01_音轨1.wav`，title 取 presentation manualTitle。
- 退出码实测：`actions show does-not-exist`=2，参数错误=1，空目录 `--root`=3；错误 JSON 均在 stderr。

## 未做

- 写回通道（完成、改期、反馈、备注）不在本波，122 波上线前不可写。
- 未做 CLI 子进程级测试；参数解析与退出码由真实库手跑覆盖。
- 未默认过滤 open/current；列表默认返回全部，交给调用方显式筛选。
- show 的反馈默认完全不输出，比任务书「默认 id/kind/label/createdAt」更保守。
- 未新增 JSON schema 版本字段。
