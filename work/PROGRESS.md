# 项目进展

## 2026-10-28

- PR #26 ASR runner 打包。验证：CI test 通过。
- PR #27 反馈声明只校验被引用的内容。验证：CI test 通过。
- 分支整理。删除 29 个本地分支、19 个远端分支和 10 个 worktree，保留 5 个 archive 标签。验证：本地和远端只剩 main，archive 标签已推送。
- PR #28 验证技能和文档状态。两个验证技能进入仓库，2026-10-10 设计文档标注为历史。验证：TLA+ 模型检查、CLI 导入和恢复 proof、CI test。
- PR #29 Agent 工作框架。任务记录、工作流和文档职责表进入 main。验证：链接检查、模板检查、CI test。
- PR #30 项目管理看板和 CI 快速路径。TODO、STATUS、PROGRESS 和任务 CHECKPOINTS 进入 main；非 Swift 改动跳过 Swift 测试。验证：链接检查、YAML 检查、完整 CI test 14 分 40 秒。
- PR #32 拆分 CoreFlowTests。测试文件从 1 个拆成 5 个，7 项测试不变。托管 runner 的 CI test 从 14 分 40 秒降到 11 分 34 秒。验证：本地 7 项 0 失败，独立核对无问题，CI test 11 分 34 秒。
- 移除自动 CI。删除 GitHub Actions workflow；自托管 runner 尝试后放弃，仓库恢复公开。验证改为本地 `swift build`、`swift test` 和真实应用。

## 2026-10-29

- PR #36 星图首页。首页改为单画布全景，区域同屏、点击进检查器、零联系状态专门设计；先在 main 验证，合线后随运行时线进入基线。验证：真实资料库截图、构建、测试。
- PR #37 基线重组。运行时线成为 `main` 的树，旧 main 保存为 `archive/main-migration-20261028`；反迁英文练习与六处入口，流程资产与 ADR042 进入新基线。验证：`swift build`、10 项测试、真实资料库副本。
- 分支清理。删除 3 个本地分支、3 个远端分支和一个 worktree；本地与远端只剩 `main`。

