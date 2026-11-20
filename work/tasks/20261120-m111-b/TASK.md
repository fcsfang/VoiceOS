# 波 111-B：周回顾页假空态与加载、失败门控

## 背景

周回顾页的 `isEmpty` 依赖尚未加载的 `somedayRows`。首次进入会先显示「这一周没有需要回顾的行动。」，等 `load()` 返回后再跳变。本单元加加载状态机，给空态补入口，并统一回顾行节奏。只改 `Sources/VoiceOSApp/WeeklyReviewView.swift`。行号为基线 fa18612 的位置。

## 逐条修法

### 1 加载状态机与假空态
- 位置：`:91-95` `isEmpty`；`:122-124` 空态文案；`:138` `.task { await load() }`；`:194-201` `load()`。
- 修法：加 `private enum LoadState`（idle/loading/loaded/failed）与 `@State loadState`、`showSlowLoad`。`load()` 开始置 `.loading` 并复位 `showSlowLoad`；结束时按 `model.status` 是否变化置 `.failed` 或 `.loaded`。页级空态改为 `loadState == .loaded && isEmpty`。加载超过 150ms 才显示 `ProgressView("正在读取本周行动…")`，本地查询快时不闪烁。失败时只保留既有 `WorkspaceNoticeText` 与「重试」按钮，不同时显示空态；重试重跑 `load()` 并复位状态。

### 2 空态补入口
- 位置：`:122-124`。
- 修法：空态改为 `emptyReviewState`，保留原文案，加「打开行动页」「查看待确认」按钮，走已有 `jump(.todo)` / `jump(.review)`，即 `openFilter` 或 `openActions` 闭包。未新增依赖，未改导航结构。

### 3 回顾行节奏
- 位置：`unavailableProgressRow :571` 与 `reviewRow :808` 为 vertical 14 / horizontal 10。同文件其余回顾行 `:316`、`:490`、`:638`、`:720`、`:768` 都是 vertical 10 / horizontal 10，全局 `WorkspaceRow`（`WorkspaceView.swift`）也是 10 / 10。
- 修法：两处统一为 10 / 10。逐行核对后没有发现 14 是有意区分的独立卡行，按历史差异处理。

### 4 未变项
- accessibility identifier 未动。文案改动只在空态、加载与错误提示。

## 构建与测试

按任务给定的共享锁循环执行，工作目录为该工作树。真实退出码：

- `swift build -j 2`：`build_exit=0`
- `swift test -j 2`：`test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 48.791 (48.860) seconds`

## 未做与风险

- 未实机重启应用验证（任务禁止重启）。150ms 延迟与不闪烁只在代码层面确认。
- 失败判定沿用既有语义，`load()` 前后 `model.status` 变化即失败。若查询失败但 status 未变，页面按 loaded 处理。这是原逻辑的边界，本单元没有扩大。
- 加载中 `dailyCloseSection` 等由 model 同步数据驱动的区块照常显示，只有页级空态被门控。这是最小改动取舍。