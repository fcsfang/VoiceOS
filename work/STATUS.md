# 项目状态

更新：2026-10-29T03:39:21Z

## 当前基线

- `main` 70cfb34，合线提交，树取自运行时线；本地与远端一致。
- SQLite schema 49，迁移包版本 1 到 47。
- `swift build -j 4` 通过，`swift test -j 4` 10 项通过。
- 仓库不使用自动 CI。日常迭代用 `swift build`，需要完整测试时本地跑 `swift test`，UI 改动构建后实际操作一次。
- 本地和远端只剩 `main`。旧 main 保存在 `archive/main-migration-20261028`，运行时线另有 `archive/pre-migration-runtime-20261028`。

## 进行中

无。

## 阻塞

无。

## 下一步

回到技术访谈闭环：录音 → 转写 → 理解 → 观点和任务 → 提醒事项 → 结果回流。

## 风险

- 旧 main 的 schema 43 资料库不能用运行时构建打开，只能用导出包迁移。
- 运行时线里约 981 行不可达视图待清理，不阻塞功能推进。
