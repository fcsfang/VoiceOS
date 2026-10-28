# 项目状态

更新：2026-10-28T15:53:53Z

## 当前基线

- `main` 65d83cc，与 origin/main 一致。
- SQLite schema 43。
- `swift build` 通过，`swift test` 7 项通过。
- 无自动 CI；验证在本地运行。

## 进行中

- 移除自动 CI 和自托管 runner。仓库已恢复公开。

## 阻塞

无。

## 下一步

完成 CI 移除后开始技术访谈闭环的缺口盘点。

## 风险

- 没有自动 CI；合并前在本地运行 `swift build`、`swift test` 和真实应用。
- 自托管 runner 尝试已放弃，仓库公开，runner 服务已移除。
- 既有功能没有统一的历史索引，暂时以 README、git log 和 PR 为准。
