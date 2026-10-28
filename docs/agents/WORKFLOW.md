# Agent 工作流

本文件规定开发任务如何开始、记录、交接和归档。规则适用于所有 agent，包括 Claude Code、Codex 和人工开发者。必须遵循的开发规则见 [AGENTS.md](../../AGENTS.md)。

## 冷启动阅读顺序

1. [AGENTS.md](../../AGENTS.md)。规则、授权边界和交付方式。
2. 本文件。任务生命周期、记录格式和交接要求。
3. 接手已有任务时，读 `work/tasks/<task>/TASK.md` 和 `PROGRESS.md`。
4. 按 [文档职责表](DOCUMENT-MAP.md) 只读当前问题需要的文档，不通读 `docs/`。
5. 读与改动直接相关的代码，以及 `.claude/skills/` 中对应的验证配方。

聊天记录不是工作状态。一个新的 agent 只靠仓库里的记录就能继续任务。

## 任务记录

每个任务放在 `work/tasks/<YYYYMMDD>-<slug>/`，两个文件。

- `TASK.md` 是任务卡，记录目标、范围、改动、非目标、决策、当前状态、下一步、验证和链接。
- `PROGRESS.md` 是检查点日志，只追加，不改写历史。

`status` 字段区分进行中、已完成和已放弃的任务。任务卡不移动目录，完成记录留在原处。

`owner` 写当前负责的会话或 agent 名称，不写人名。

`work/` 记录开发任务，不记录产品里的任务数据、录音、原始日志或生成产物。

## 生命周期

1. **对齐。** 用户给出目标和范围后，从 `work/TASK-TEMPLATE.md` 和 `work/PROGRESS-TEMPLATE.md` 建任务目录，状态设为 `planning`。范围不清时先完成只读调查，不按假设实现。
2. **开始。** 从最新 `main` 或明确的父 PR 分支切 `codex/<slug>-<YYYYMMDD>`。任务卡填 `branch` 和父分支；状态改为 `in_progress`，追加第一条检查点。
3. **推进。** 每完成一个可验证单元就提交代码和任务记录，并追加检查点。任务卡的 `## 当前状态` 和 `## 下一步` 随时保持可交接。
4. **审查。** 开 PR 后状态改为 `in_review`，在任务卡填 `pr`。PR 描述链接任务目录，按 [PR 模板](../../.github/pull_request_template.md) 写。
5. **合并。** PR 的最后一个提交把状态改为 `done`，填入 PR 链接。CI 和验证通过后合并。卡片随合并进入 `main`；如果 PR 没有合并，卡片只留在分支，不会在 `main` 留下已完成的假记录。
6. **放弃。** 状态改为 `abandoned`，写清原因。已有 PR 时把记录随 PR 合并；没有 PR 时把任务卡提交在分支上，并在下一个任务的 `## 链接` 里引用。不要为了归档单独开 PR。

## 状态

| 状态 | 含义 | 可以转到 |
|---|---|---|
| `planning` | 正在对齐目标、范围或方案 | `in_progress`、`blocked`、`abandoned` |
| `in_progress` | 正在实现或验证 | `blocked`、`in_review`、`abandoned` |
| `blocked` | 等待用户决定、权限或外部条件 | `planning`、`in_progress`、`in_review`、`abandoned` |
| `in_review` | PR 已开，等待检查和合并 | `in_progress`、`blocked`、`done`、`abandoned` |
| `done` | PR 已合并 | 无 |
| `abandoned` | 已停止 | 无 |

`blocked` 必须在 `## 下一步` 写清需要谁做什么决定。不要只写“等待确认”。

## 检查点

只在有意义的节点追加检查点。

- 任务开始。
- 一个可验证单元完成，例如提交、测试通过、PR 打开。
- 方案、范围或假设发生变化。
- 被阻塞或解除阻塞。
- 交接。

检查点格式见 `work/PROGRESS-TEMPLATE.md`。时间用 UTC，格式 `YYYY-MM-DDTHH:MM:SSZ`。证据写路径、提交 SHA、PR 号或命令结果，不写长段落。不要记录每次工具调用。

## 交接

会话结束前，如果任务还没完成，按顺序做四件事。

1. 更新任务卡 frontmatter 的 `status`、`updated`、`branch`、`pr`、`owner`。
2. 重写 `## 当前状态`，让没有聊天上下文的人能读懂。
3. 写一个具体的 `## 下一步`。如果被阻塞，写明需要的决定。
4. 追加一条检查点，列出完成、证据、下一步和阻塞，然后提交。

如果 PR 已经存在，推送分支并更新 PR。只是会话暂停且还没有 PR 时，按 pstack 的 Pause safely 处理，不为了暂停新开 PR 或推送。把任务卡写成 `wip:` 提交，留下恢复点。下一个 agent 在同一台机器上，或同一个 worktree 里，可以继续读。

## 并行可见性

任务卡随任务分支提交。未合并的任务只存在于该分支或 worktree，不在当前 checkout。

- 同一工作区先看 `git worktree list` 和 `git branch -a`，确认有哪些任务在并行。
- 读另一个分支的任务卡用 `git show <branch>:work/tasks/<date>-<slug>/TASK.md`。
- 跨机器或跨会话交接时，先开 PR 再推送，让任务卡随 PR 可见。没有 PR 时按 Pause safely 处理，不要假设对方能读到本地分支。

## 查找任务

列出所有任务。

```bash
rg -n '^(status|updated|branch|pr):' work/tasks/*/TASK.md 2>/dev/null || true
```

只列进行中的任务。

```bash
rg -n '^status: (planning|in_progress|blocked|in_review)$' work/tasks/*/TASK.md 2>/dev/null || true
```

任务卡的 `## 改动` 写用户可见的变化，`## 链接` 指向 PR。历史改动先看这里，再看 git log。这个索引从本框架启用后开始累积，既有功能仍以 README 和 git 历史为准。

## 与其他记录的关系

- pstack 的 playbook 决定如何调查、实现和验证。
- `work/` 保存跨会话的任务状态和交接，是 agent 的工作记忆。
- PR 保存交付内容、审查和 CI 结果。
- 稳定文档保存长期事实。README 写当前行为和运行方式，ADR 写技术决策，`docs/product/` 写产品定义。
- 同一个事实只放在权威文档里。任务记录链接过去，不复制。

## 不放进 work/ 的内容

- 密钥、个人资料、真实录音或转写。
- 原始命令输出、日志、截图和生成文件。放到 `runtime/` 或 `.claude/skills/verify-voiceos/evidence/` 等已忽略目录，任务记录只写路径。
- 已经合并的代码细节。看 PR 和 git 历史。
