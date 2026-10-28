# 开发任务记录

`work/` 保存开发任务的进展、决策和交接记录。它不是产品里的任务数据，也不是历史设计文档。

## 结构

- `tasks/<YYYYMMDD>-<slug>/` 每个任务的目录，目录里是 `TASK.md` 和 `PROGRESS.md`。
- `TASK-TEMPLATE.md` 任务卡模板。
- `PROGRESS-TEMPLATE.md` 检查点模板。

新任务复制两个模板到 `tasks/<date>-<slug>/`，改名为 `TASK.md` 和 `PROGRESS.md`，然后按 [Agent 工作流](../docs/agents/WORKFLOW.md) 推进。任务完成后不移动目录，只把 `status` 改为 `done` 或 `abandoned`。

## 查找任务

```bash
rg -n '^(status|updated|branch|pr):' work/tasks/*/TASK.md 2>/dev/null || true
rg -n '^status: (planning|in_progress|blocked|in_review)$' work/tasks/*/TASK.md 2>/dev/null || true
```

## 规则

- 任务卡随任务更新，检查点只追加。
- 一个任务一个目录，不设共享索引。
- PR 的最后一个提交把状态改为 `done`；CI 和验证通过后合并。
- 不提交密钥、个人资料、原始日志和生成产物。
