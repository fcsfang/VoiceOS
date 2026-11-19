# 波 102-A：首页视觉统一

## 背景

用户反馈 UI「还是很杂乱，不像是精心设计过的」。首页是打开应用第一屏：左列 264pt 卡片密集、标题两行截断；右栏把裸 URL 当 30pt 标题、下方空白。本单元只改视觉，不改数据与交互。

## 改动

- `Sources/VoiceOSApp/RecentContentHome.swift:59` 时间线加宽到 288pt，卡片获得呼吸空间。
- `:218-244` 列表行：标题经 `WorkspaceTitleFit.present` 拆出可读名称；副标题依次为来源（github.com/owner）、时间、状态；「N 条待办」改为 `WorkspaceBadge(.accent)`，反馈类结果仍用 warning 文字。
- `:250-268` 标题与副标题装配内联 fit，feedback 保留「· N 条」。
- `:433-439` 阅读栏：标题用 fit.title，其下新增 source 行（caption/tertiary、可选中），标题限 4 行。
- `:109-120` 空状态与整理提示按钮改为 `.workspacePrimary` / `.workspaceSecondary`。
- `:514`、`:724` 目标与整理提示底块圆角统一 `WorkspaceMetrics.panelRadius`，不再用孤立字面值 9。

## 验证

- `swift build -j 2` → build_exit=0。
- `swift test -j 2` → test_exit=0，`Executed 661 tests, with 0 failures`（基线 657，新增 WorkspaceTitleFitChecks 4 项）。
- 构建/测试在 `/tmp/voiceos-swift-build.lock` 互斥下完成。

## 取舍与风险

- URL 标题只做展示层拆分，不写回数据；原文仍可通过 source 行看到 host 与路径，完整 URL 仍在材料页。
- 反馈类长徽标（84 项结果待填）保持文字形态，避免胶囊在窄列溢出。
- 未改选择、键盘、日分组与滚动锚点逻辑。