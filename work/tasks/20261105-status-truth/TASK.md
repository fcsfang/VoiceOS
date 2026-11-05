---
status: merged
started: 2026-11-05
updated: 2026-11-05
branch: worktree-agent-ab4d0bbfc52073980
pr: 108
owner: poteto-agent
---
# 状态栏只显示正在发生的工作

## 目标

真实使用中发现状态栏在几条文案间轮换，但库内没有对应模型尝试。状态栏不得声称没有发生的工作。

## 范围

- 追踪 `WorkspaceProcessingView` 的 busy 标志与 `organizingTopics` 的真实来源。
- 去掉轮换、定时器或过期标志；仅在有真实操作进行时显示对应文案，其他时候显示稳定默认。
- 提取纯函数并测试：进行中显示对应文案；空闲显示默认；过期标志不产生忙碌文案。

## 当前状态

实现代理在独立 worktree 工作，未合并。

## 下一步

复核 diff、构建测试、实时应用核对状态栏。

## 验证

`swift build -j 4`、`swift test -j 4`；空闲与进行中两张截图。

## 链接

真实使用盘点中的状态栏条目。
