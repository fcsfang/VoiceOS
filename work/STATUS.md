# 项目状态

更新：2026-10-28T14:41:21Z

## 当前基线

- `main` 382887f，与 origin/main 一致。
- SQLite schema 43。
- `swift build` 通过，`swift test` 7 项通过。
- CI `test` 对 Swift 改动约 14 分钟。14 分 39 秒的构建里，`CoreFlowTests.swift` 编译占 11 分 17 秒，测试本身 25 秒。

## 进行中

- 项目管理看板和 CI 快速路径。分支 `codex/project-dashboard-20261028`，任务卡 `tasks/20261028-project-dashboard/TASK.md`，PR #30，状态 `in_review`，CI 运行中。

## 阻塞

无。

## 下一步

CI 通过后合并 PR #30。合并后开一个只改 `work/` 的关闭 PR，把任务状态改为 `done`，在 `work/PROGRESS.md` 写入 #30 的记录，并刷新本文件的基线。

## 风险

- Swift 改动仍跑完整测试，`CoreFlowTests.swift` 编译占 11 分 17 秒；拆分是下一个优化。
- 文档改动已加入快速路径，PR #30 合并后生效；关闭 PR 会实测耗时。
- 既有功能没有统一的历史索引，暂时以 README、git log 和 PR 为准。
