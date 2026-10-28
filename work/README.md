# 开发任务记录

`work/` 保存开发任务的进展、决策和交接记录。它不是产品里的任务数据，也不是历史设计文档。

## 结构

- `active/<YYYYMMDD>-<slug>/` 进行中的任务。
- `completed/<YYYYMMDD>-<slug>/` 已完成或放弃的任务。
- `TASK-TEMPLATE.md` 任务卡模板。
- `PROGRESS-TEMPLATE.md` 检查点模板。

新任务复制两个模板到 `active/<date>-<slug>/`，改名为 `TASK.md` 和 `PROGRESS.md`，然后按 [Agent 工作流](../docs/agents/WORKFLOW.md) 推进。

## 列出进行中的任务

```bash
rg -n '^(status|updated|branch|pr):' work/active/*/TASK.md
rg -n '^(status|started|branch|pr):' work/completed/*/TASK.md
```

## 规则

- 任务卡随任务更新，检查点只追加。
- 一个任务一个目录，不设共享索引。
- 合并前把目录移到 `completed/`，状态改为 `done`。
- 不提交密钥、个人资料、原始日志和生成产物。
