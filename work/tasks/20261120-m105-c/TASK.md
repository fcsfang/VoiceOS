# 波 105-C：监测、主题与全景在特大字号下不再截断

## 背景

波 105 针对「特大」（vosTextScale 1.45）下会裁字、折行或必然省略的固定尺寸做适配。本单元覆盖消息监测设置、主题阅读卡片与思考全景阅读器：固定宽标签放不下「Python 解释器」，固定宽 DatePicker 与筛选 Picker 裁字，主题网格最小宽 290 不随字号增长，观点预览与主题摘要只留 2 行，全景阅读器固定 310pt 且三枚动作按钮必然省略。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceMonitorView.swift`
- `Sources/VoiceOSApp/WorkspaceTopicReadingView.swift`
- `Sources/VoiceOSApp/ThoughtPanoramaView.swift`

## 完成判据

1. pathRow 标签与「账号」行标签改 `minWidth: 90` + `fixedSize(horizontal: true, vertical: false)`，1.45x 下不折行、不压缩、不错位。
2. 固定宽 DatePicker / Picker（190/130/110/190/140）改 `minWidth`，系统字号增大后取固有宽度而不裁字。
3. 主题网格最小宽按 `290 * min(max(scale,1),1.25)` 随设置缩放，缩放上限 1.25；观点预览与主题摘要的 `lineLimit` 在 `scale >= 1.3` 时从 2 行放到 3 行。
4. 全景阅读器宽按 `310 * min(max(scale,1),1.3)` 缩放；阅读器动作行改 `ViewThatFits`，窄宽时三枚按钮各占一行，不出现省略号；面板 padding 20 不变。
5. 行为、identifier、文案、键盘不变。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0。

## 约束

- 唯一构建锁（`/tmp/voiceos-swift-build.lock`）；构建/测试互斥。
- 不写实时库、不重启、不 push、不合并。

## 结果（2026-11-20）

- 分支 `work/m105-c`，基线 `43be016`。
- 监测：`pathRow` 标签与「账号」行标签从 `frame(width: 90)` 改为 `minWidth: 90` + `fixedSize(horizontal: true, vertical: false)`；`monitor.filter` 分段筛选 140、来源起始 DatePicker 190/130、每日检查时间 110、QQ 起点 190 全部由固定宽改 `minWidth`。可选 `maxWidth 240` 上限未加，保持最小改动。
- 主题阅读：两处主题网格（`readingCards`、`overviewReadingCards`）最小宽改为 `290 * min(max(scale,1),1.25)`；观点预览（`readingCard`）与主题摘要（`WorkspaceTopicTile`）的 `lineLimit` 在 `scale >= 1.3` 时改 3 行。两处结构新增 `@Environment(\.vosTextScale)`，取值由 `WorkspaceView` 注入的 `model.textSize.scale` 提供。
- 全景：侧栏阅读器宽改为 `310 * min(max(scale,1),1.3)`；`ReaderQuoteCard` 动作行改 `ViewThatFits`，宽时 HStack、窄时 VStack(spacing: 6)，三枚按钮抽为 `actionButtons`，文案、动作与顺序不变；面板 padding 20 未动。
- 构建/测试：`swift build -j 2` 退出码 0；`swift test -j 2` 退出码 0，`Executed 662 tests, with 0 failures (0 unexpected) in 45.676 (45.733) seconds`。`git diff --stat` 仅三个文件。
- 未做：未在运行中的应用里目测 1.45x 实际布局（约束禁止重启）；`Tests` 中没有这三个视图的布局测试，构建与测试只证明可编译、既有行为未回归；未加可选宽度上限；不写实时库、不重启、不 push、不合并。