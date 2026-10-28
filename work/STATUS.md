# 项目状态

更新：2026-10-28T15:37:15Z

## 当前基线

- `main` 70a9608，与 origin/main 一致。
- SQLite schema 43。
- `swift build` 通过，`swift test` 7 项通过。
- CI `test` 对 Swift 改动 11 分 34 秒（拆分后，托管 runner）。文档改动走快速路径，约 20 秒。

## 进行中

- 自托管 runner 安装。仓库已改为私有，runner 压缩包下载中。任务卡待建。

## 阻塞

无。

## 下一步

下载并注册 runner，把 workflow 改到 self-hosted，用一个 PR 验证。

## 风险

- Swift 改动在托管 runner 上仍需 11 分 34 秒；自托管 runner 装好后应显著下降。
- 文档改动已走快速路径。
- 既有功能没有统一的历史索引，暂时以 README、git log 和 PR 为准。
