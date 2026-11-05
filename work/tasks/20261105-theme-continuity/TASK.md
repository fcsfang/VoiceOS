---
status: merged
started: 2026-11-05
updated: 2026-11-05
branch: worktree-agent-a8af4fe9dc5d98497
pr: 109
owner: poteto-agent
---
# 主题回应与历史跨快照连续

## 目标

主题身份已稳定（PR #106）。让 AI 回应缓存不再被每次综合变化的问题 ID 打断，并在主题页显示真实的首次出现与出现次数。

## 范围

- `PanoramaThemeReply.Digest` 用 `openQuestionTitle` 与证据数替代 `openQuestionID`；不改变发给模型的内容。
- `PanoramaState` 增加主题历史（次数、首次、最近），从出现账本查询。
- 主题页元信息显示 `第 N 次出现` 与 `首次 M月D日`；没有账本记录的主题不显示。
- 测试：不同问题 ID 相同内容只调用一次端口；改原话会重新调用；两次快照计数为 2；回填快照首次时间正确。

## 非目标

- 不做多对多主题谱系。
- 不改生成提示词。

## 当前状态

实现代理在独立 worktree 工作，未合并。

## 下一步

复核 diff、跑构建与测试、实机核对主题页后合入。

## 验证

`swift build -j 4`、`swift test -j 4`；实时应用主题页截图。

## 链接

PR #106。
