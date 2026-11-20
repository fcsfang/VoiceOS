---
name: voiceos
description: 通过 voiceos-cli 只读浏览、筛选并挑选 VoiceOS 待办（actions），供本地 agent 找到下一件要做的事再自行执行。Use when an agent needs to read or pick VoiceOS todos.
---

# VoiceOS 待办（只读）

VoiceOS 把「读待办」暴露成只读 CLI：`voiceos-cli`。它直接用 SQLite 只读打开资料库，不启动 app、不抢 `store.lock`，app 运行时也能读。

## 何时使用

- agent 需要查看用户当前的待办，挑选一条去执行
- 需要确认某条待办的出处、期限、已有反馈数量
- 需要资料库概况（条数、schema 版本）

## 定位二进制

仓库内构建：

```bash
swift build --product voiceos-cli
.build/debug/voiceos-cli status
```

装进 PATH（可选）：

```bash
cp .build/debug/voiceos-cli ~/.local/bin/voiceos-cli
```

## 命令

资料库默认 `~/Library/Application Support/VoiceOS`；用 `--root <dir>` 或环境变量 `VOICEOS_ROOT` 覆盖。stdout 只输出 JSON，错误 JSON 写到 stderr。

挑选待办：

```bash
voiceos-cli actions list --state open --validity current --limit 20 --json
```

查看单条（出处、期限、修订账本、所属主题）：

```bash
voiceos-cli actions show <id> --include-feedback --topics
```

资料库概况：

```bash
voiceos-cli status
```

加 `--pretty` 输出缩进 JSON。

## JSON 字段

- 列表项：`id title kind state validity nature version parentID createdAt completedAt feedbackCount lastFeedbackAt sourceTitle reminderState due`
- `due`：`kind`（`none`/`dateOnly`/`instant`）、`localDate`、`utc`、`timeZone`、`source`（`localSchedule`/`reminderObservation`）、`isOverdue`
- `actions show` 另含 `schedule`、`reminder`、`revisions`、`source`；`--include-feedback` 加 `feedback`（id/kind/label/createdAt），`--include-feedback-text` 再加 `text`，`--include-note` 加 `note`，`--topics` 加 `topics`
- `status`：`userVersion walPresent sources actionsOpen actionsCompleted actionsDismissed actionsSomeday actionsCurrent actionsFrozen feedback topics`

## 限制

- 只读。写回通道（完成、改期、写反馈）在 122 波上线前不可用；不要用 sqlite 直接写资料库。
- 资料库 schema 必须是 76，否则退出码 3（资料库格式不兼容）。
- 退出码：0 成功；1 参数或内部错误；2 未找到；3 资料库不可用。

## 隐私

反馈原文与备注属于用户私密内容，默认不出现在输出里。不要把它们写进外部日志、提交信息、PR 或任何远端服务。