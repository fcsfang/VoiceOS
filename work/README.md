# 项目记录

`work/` 保存项目级待办、状态、进展，以及每个任务的细节。它不是产品里的任务数据，也不是历史设计文档。

## 项目级文件

- `TODO.md` 待办和优先级。回答接下来做什么。
- `STATUS.md` 当前状态、进行中、阻塞和风险。回答现在到哪了。
- `PROGRESS.md` 已合并改动和里程碑，只追加。回答已经发生了什么。

这三个文件由主会话维护。并行任务只写自己的任务目录，避免同时改同一份状态。需要改项目级文件时，把内容交给主会话。

## 任务目录

- `tasks/<YYYYMMDD>-<slug>/TASK.md` 任务卡。目标、范围、改动、决策、当前状态、下一步、验证和链接。
- `tasks/<YYYYMMDD>-<slug>/CHECKPOINTS.md` 该任务的检查点日志，只追加。
- `TASK-TEMPLATE.md` 任务卡模板。
- `CHECKPOINTS-TEMPLATE.md` 检查点模板。

新任务复制两个模板到 `tasks/<date>-<slug>/`，改名为 `TASK.md` 和 `CHECKPOINTS.md`，然后按 [Agent 工作流](../docs/agents/WORKFLOW.md) 推进。任务完成后不移动目录，只把 `status` 改为 `done` 或 `abandoned`。

## 查找

```bash
rg -n '^(status|updated|branch|pr):' work/tasks/*/TASK.md 2>/dev/null || true
rg -n '^status: (planning|in_progress|blocked|in_review)$' work/tasks/*/TASK.md 2>/dev/null || true
```

## 规则

- 项目级文件由主会话更新。任务目录由任务 owner 更新。
- 任务卡随任务更新，检查点只追加。
- 一个任务一个目录，不设共享索引。
- PR 的最后一个提交把任务状态改为 `done`；CI 和验证通过后合并。
- 不提交密钥、个人资料、原始日志和生成产物。
