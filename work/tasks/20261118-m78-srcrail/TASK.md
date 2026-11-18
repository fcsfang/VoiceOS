# 波 78 任务书（2026-11-18）：来源页材料侧栏常驻与可收起

## 背景（用户反馈 2026-11-18）

「在主页点进去一个材料后，只能返回才能切换另一个材料，这个选择材料的侧边栏用户应该可以主动选择是否隐藏，而不是被迫消失。」

现状：从首页想法或材料列表进入 `.source(id)` 后，来源页占满内容区，材料列表整体消失，切换材料必须先返回。用户要的是：详情页旁边保留可切换材料的选择列表，并让用户自己决定收起或展开，选择可记住。

## 设计（Experience First，最小改动）

1. `.source(id)` 页面渲染改为左右两栏：左侧材料选择栏（宽约 240-260，沿用 `palette.sidebar` 底），右侧现有来源页内容；顶部或栏头提供收起/展开按钮（chevron 图标，切到约 0 宽时隐藏栏）。
   - 收起状态用 `@AppStorage("voiceos.sourceRail.visible")` 持久化，默认展开。
2. 选择栏内容：与材料页同源的材料集合（`model.records` 中非归档、非回收站的日常材料，按与材料页一致的顺序：按日期分组或直接按时间倒序；取实现简单的形态）。每行：类型图标 + 标题（单行截断）+ 时间；当前来源高亮（selection 底）；点击切换 `go(.source(newID))` 不压栈（用 replace 当前项，避免返回栈无限增长）。
3. 交互细节：
   - 键盘：选择栏不抢现有来源页焦点逻辑；点击仅鼠标。
   - 深链/主题内打开来源时同样显示该栏（简单一致），若返回语义受影响，以「返回仍回到打开处」优先，不改变现有 path 逻辑，只有材料间切换用替换。
   - 收起后保留一个窄条（例如 24 宽）带展开按钮，避免无法恢复。
4. 标识：`sourceRail.toggle`、`sourceRail.item.<sourceID>`；当前项 `.isSelected` 语义。
5. 不改来源页内部（波 77 刚改过 `WorkspaceSourceView.swift`，本波不碰该文件）；不改材料页列表与首页；不加迁移。

## 完成判据

1. 从首页想法或材料列表进入来源页后，材料选择栏默认可见，点选任一行立即切换详情，无需返回。
2. 收起按钮隐藏选择栏并保留展开入口；状态跨重启记住。
3. 返回行为不回归：顶部返回仍回到打开来源前的位置；材料间切换不增长返回栈。
4. `swift build -j 2` / `swift test -j 2` 真实退出码 0（基线 617 项）。
5. 纯布局交互改动，不加单测；结果给改动清单（file:line），协调方安装后截图验证。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceView.swift`（路由与栏渲染，最小增量）
- 不碰 `WorkspaceSourceView.swift`、Core/Platform、材料页/首页既有样式。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；不重启应用；不 push、不合并。
- 分支 `work/m78-srcrail`，提交回报。

## 结果

- 分支：work/m78-srcrail（基于 main 8ae2932；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：3e565cd「feat(来源页): 详情页保留可收起的材料侧栏，切换不压返回栈」。
- 改动（1 个文件，67 增 10 删，`Sources/VoiceOSApp/WorkspaceView.swift`）：
  - `WorkspaceView.swift:229`：`@AppStorage("voiceos.sourceRail.visible")`，默认展开，状态跨重启保留。
  - `WorkspaceView.swift:769-790`：`.source(id)` 改为左右两栏；左栏为 248 宽材料栏（`palette.sidebar` 底）或 28 宽收起条，右栏沿用原来源页内容与 `.id(id)`，未改 `WorkspaceSourceView`。
  - `WorkspaceView.swift:2463-2470`：`sourceRailRows` 取非归档、非回收站材料，经 `model.sourcePageIndex.expression(for:)` 合并多段连续表达（沿用波 77 索引，不重跑 `recordingExpression` 全量扫描），按 `createdAt` 倒序。
  - `WorkspaceView.swift:2472-2491`：`sourceRail(selectedID:)` 栏头为「材料 + 数量 + 收起按钮」，行复用 `WorkspaceListRow(density:.compact)`（类型图标、单行标题、时间），当前项 `highlighted` 带 selection 底与 `.isSelected`；标识 `sourceRail.toggle`、`sourceRail.item.<sourceID>`。
  - `WorkspaceView.swift:2493-2500`：`collapsedSourceRail` 为 28 宽常驻条，带 `chevron.right` 展开按钮，避免无法恢复。
  - `WorkspaceView.swift:2502-2508`：`selectSource` 只把 `page` 换成新的 `.source`，不 append `path`，并调用现有 `markSourceOpened`；`go`、`back`、`sourceOpenedFromTheme` 未改。
- 判据落点：
  - 判据 1：进入 `.source` 后选栏默认可见，点任一行立即切换详情；当前材料高亮。
  - 判据 2：收起按钮隐藏选栏并保留 28 宽展开条；`voiceos.sourceRail.visible` 由 `@AppStorage` 持久化，跨重启保留。
  - 判据 3：材料间切换只改 `page`，`path` 与其记录的主题上下文不变，返回仍回到打开来源前的位置；切换不增长返回栈。
  - 判据 4：build_exit=0（`swift build -j 2`，110.84 秒）；test_exit=0（`swift test -j 2`）617 项 0 失败（基线 617），36.16 秒。构建与测试共用 `/tmp/voiceos-swift-build.lock`，结束后已释放；`git diff --check` 退出码 0。
  - 判据 5：纯布局交互改动，未加单测；改动清单见上，实机截图由协调方验证。
- 遗留风险：
  - 窄窗口叠加讨论面板：主列 `minWidth:440`，侧栏 248 加最宽 380 的讨论面板会把正文压到约 190 宽，阅读体验差；未做自动收起，用户可手动收起侧栏。
  - 主题内打开来源：按设计同样显示选栏；若当前材料不在日常材料集（如已归档），栏内无高亮项，切换后返回仍回主题（`path` 未变）。
  - 键盘焦点：只新增按钮，未加 `focusable` 或 `onKeyPress`，未改变来源页既有焦点逻辑；栏内按钮按系统默认参与键盘导航。
  - 连续表达组只列组首成员；组内其他分段仍从来源页既有入口切换，本波不新增入口。
  - 选栏每次求值重建行数组（过滤、排序、索引查询），规模为材料数；未复用 `materialRows`，避免把波 77 去掉的 digest 扫描带回主线程。
