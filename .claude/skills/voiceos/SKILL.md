---
name: voiceos
description: 通过 voiceos-cli 浏览、筛选 VoiceOS 待办（actions），并在执行后把结果或完成状态写回 VoiceOS。Use when an agent needs to read or pick VoiceOS todos, or report back on one.
---

# VoiceOS 待办

VoiceOS 把「读待办」与「写回结果」暴露成 CLI：`voiceos-cli`。读命令直接用 SQLite 只读打开资料库，不启动 app、不抢 `store.lock`；写命令不碰资料库文件，而是把 `voiceos://` 链接交给运行中的 VoiceOS app，由 app 进程完成写入，再轮询只读库确认效果。

## 何时使用

- agent 需要查看用户当前的待办，挑选一条去执行
- 执行后需要把经过或结果写成行动反馈
- 执行后需要把行动标记完成
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

## 读命令

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

## 写回命令

写回要求 VoiceOS 正在运行，且 `--root` 指向 app 打开的资料库（app 用 `VOICEOS_DATA_DIR` 启动时也要用同一个目录）。CLI 交付链接后每 0.3 秒轮询资料库，最多 10 秒；app 未运行退出码 5，超时退出码 4。

写反馈（`--kind` 默认 `outcome`，可改 `reflection`）：

```bash
voiceos-cli action feedback <id> --text "已完成并整理成笔记"
```

重试时带上同一个 `--command <uuid>`，app 侧按命令幂等接收：

```bash
voiceos-cli action feedback <id> --text "已完成并整理成笔记" --command 2C9D8F4A-1B67-4E20-8A3D-5F0C9E7B6A12
```

标记完成，与界面「标记已完成」走同一条路径：

```bash
voiceos-cli action complete <id>
```

写回成功时 stdout 输出结果 JSON，带 `observed: true`；`action feedback` 另含 `command`、`kind`、`feedbackCount`，`action complete` 另含 `state`。正文最多 4000 字符，正文与参数不会写进任何日志。

`action feedback` 以该行动的 `feedbackCount` 增加作为观察依据。同一个 `--command` 之前已写入时计数不会再增加，CLI 会按超时退出。

## JSON 字段

- 列表项：`id title kind state validity nature version parentID createdAt completedAt feedbackCount lastFeedbackAt sourceTitle reminderState due`
- `due`：`kind`（`none`/`dateOnly`/`instant`）、`localDate`、`utc`、`timeZone`、`source`（`localSchedule`/`reminderObservation`）、`isOverdue`
- `actions show` 另含 `schedule`、`reminder`、`revisions`、`source`；`--include-feedback` 加 `feedback`（id/kind/label/createdAt），`--include-feedback-text` 再加 `text`，`--include-note` 加 `note`，`--topics` 加 `topics`
- `status`：`userVersion walPresent sources actionsOpen actionsCompleted actionsDismissed actionsSomeday actionsCurrent actionsFrozen feedback topics`

## 限制

- 写回只经运行中的 VoiceOS app。不要用 sqlite 直接写资料库。
- 资料库 schema 必须是 76，否则退出码 3（资料库格式不兼容）。
- 退出码：0 成功；1 参数或内部错误；2 未找到；3 资料库不可用；4 等待 app 写回超时；5 app 未运行。

## 隐私

反馈原文与备注属于用户私密内容，默认不出现在输出里；写回时只把正文放进本机 `voiceos://` 链接交给运行中的 app。不要把它们写进外部日志、提交信息、PR 或任何远端服务。