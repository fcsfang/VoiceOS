---
status: done
started: 2026-10-28
updated: 2026-10-28
branch: codex/project-dashboard-20261028
pr: 30
owner: main session
---
# 项目管理看板与 CI 快速路径

## 目标

让项目级待办、状态和进展各有独立文件并统一放在 `work/`。让非 Swift 改动不再跑完整 Swift 测试。

## 范围

- 新增 `work/TODO.md`、`work/STATUS.md`、`work/PROGRESS.md`。
- 任务级进度文件改名为 `CHECKPOINTS.md`，避免和项目级 `PROGRESS.md` 混淆。
- 更新工作流、文档职责表、AGENTS.md 和 README。
- CI 检测改动路径，非 Swift 改动跳过 `swift test`。

## 改动

- `work/` 增加项目级 `TODO.md`、`STATUS.md`、`PROGRESS.md`；任务级日志改名 `CHECKPOINTS.md`，并加入第一个真实任务卡。
- 工作流、文档职责表、AGENTS.md 和 README 同步更新。
- CI 对非 Swift 改动跳过 `swift test`，workflow 改动仍跑完整测试。

## 非目标

- 不拆分 `CoreFlowTests.swift`。它是 Swift 变更的主要 CI 成本，留作单独任务。
- 不改产品代码和 SQLite schema。

## 决策

- 项目级三个文件只有主会话更新。任务 agent 写自己的任务目录，避免并行冲突。
- 任务级日志改名 `CHECKPOINTS.md`。项目级 `PROGRESS.md` 只记录已合并的改动。
- CI 无法判断改动范围时默认跑完整测试，不默认跳过。

## 当前状态

PR #30 已合并到 main（ab3710c）。

## 下一步

无；后续工作见 `work/TODO.md`。

## 验证

- PR #30 的 CI test 通过，14 分 40 秒。
- 14 个文件的相对链接检查，0 缺失。
- YAML 解析通过；快速路径匹配测试通过，文档改动为 false，`Sources/`、`Tests/`、`Package.swift` 和 workflow 为 true。

## 链接

- PR: #30（已合并，ab3710c）
- 工作流: `docs/agents/WORKFLOW.md`
- 文档职责: `docs/agents/DOCUMENT-MAP.md`
- 后续: 拆分 `CoreFlowTests.swift`，当前编译占 CI 11 分 17 秒。
