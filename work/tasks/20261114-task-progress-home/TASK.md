---
status: open
started: 2026-11-13
updated: 2026-11-14
branch: work/task-progress-home
pr: pending
owner: coordinator
---

# 首页「行动反馈」改造为「任务进展」

## 背景与证据

- 用户反馈：从没主动填过行动反馈，首页却出现多条；围绕行动闭环跟踪的功能是需要的，但现在的呈现不知道是干什么的、不知道去哪跟踪、没有主线。
- 实时库查证：20 条反馈全部来自「整理」录音时的自动接续（`OrganizedPodcast` 调用 [TaskContinuation.swift](Sources/VoiceOSCore/TaskContinuation.swift) 的 `recordTaskContinuation`），把原话逐字摘录与任务关联，关系分再次提及、实际进展、收获与结果；没有一条是手打。
- 问题定位：数据层的关联记录被当成一种内容类型塞进阅读首页，没有任务名、没有跳转；任务页本来已有「实际进展与收获」时间线。

## 决定（用户选定）

首页保留按天分组，但改造成「任务进展」：每条显示任务名与关系，点击进入该任务页；关系映射为再次提及、实际进展、收获与结果，无关系时按类型回退为实际结果、我的反思、进展。时间线行副标题显示关系构成（如「实际进展 1 · 我的反思 1」），不再重复计数。

## 范围

- `Sources/VoiceOSCore/Models.swift`、`Store.swift`：`SourceRecord` 补 `feedbackRelation`。
- `Sources/VoiceOSCore/RecentContent.swift`：分组标题改为「N 条任务进展」；新增 `RecentContentProgressRow` 与快照的 `progressRows`（任务名解析失败显示「任务已不可用」）。
- `Sources/VoiceOSApp/RecentContentHome.swift`、`WorkspaceView.swift`：阅读区逐条渲染任务名、关系与原话，整行可点进任务页；新增 `openTask` 参数。
- 测试：快照行解析、关系标签、跨天分组、不可用任务禁用。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 125 项 0 失败（新增 2 项）。
- 隔离实例（分支构建 + 实时库副本）实机：首页时间线出现「2 条任务进展」，关系构成显示正确（截图核对）。
- 阅读区逐条样式与点击跳转未取得截图：取证时用户在前台看全屏视频，按窗口截图 API 在 CLI 环境不可用、屏幕坐标点击会打到其他应用，故以单元测试与代码走查覆盖，部署后由用户确认。

## 进展

- 2026-11-14 实现与验证完成；分支从 main 独立开出。
