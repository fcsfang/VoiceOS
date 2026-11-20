# 波 118：待办进展时间线

用户反馈：补充待办实际进展的交互不优雅；补充后应形成可追踪的时间线；看一条待办的进展要一直往下翻，信息层级没有优先级。

## 改动范围

只改 `Sources/VoiceOSApp/WorkspaceActivityViews.swift`。反馈数据层（记录类型、保存流程、历史记录后缀语义）未动。

## 卡片位置

- 之前：页面底部，「AI 的工作与交付」与「记录与依据」之间，且只在有记录时出现。
- 之后：内联记录编辑器之后、「下一步」/「重复」卡之前。任务类与非任务类共用同一位置，打开详情首屏即可看到最近进展。卡片始终存在。

## 时间线结构

- 条目按时间倒序（store 返回旧到新，用 `reversed()`），最新在上。
- 左侧固定 12pt 圆点列：2pt 竖线（`palette.border`）贯穿条目，圆点 9pt，最新一条用 `palette.accent`，其余 `secondaryText`。首条上半截与末条下半截随条目自然截断。
- 右侧内容：首行「今天/昨天/M月d日/yyyy年M月d日 + HH:mm · 类型 label」，下行正文（`WorkspaceExpandableText`），再下「查看结果原话」按钮。
- 日期与时间文案复用 `RecentContentHome.swift` 中 `dayLabel`/`timeLabel` 的写法，在本文件内实现为私有 `feedbackDayLabel`/`feedbackTimeLabel`，不跨文件改动。
- `actionVersion == action.version && sourceState != "frozen"` 的「历史记录」后缀逻辑原样保留。
- 空态：无记录且非加载中时显示「还没有记录进展。记录后会按日期在这里形成时间线。」（meta 字号）。加载态沿用原 `feedbackPlaceholderVisible` 的 150ms 延迟，避免闪烁；读取失败的错误行移到卡片下方。

## 滚动与高亮

- `body` 用 `ScrollViewReader` 包裹原 `Group`，时间线卡加 `.id("progress-timeline")`。滚动触发器放在 `body` 闭包内（`onChange(of: progressScrollToken)`），不改 `pageContent` 里 ScrollView 的 task 链，属最小侵入方案。
- `saveFeedback` 成功后：`draft.expanded = false`，重载反馈，最新条目 id 写入 `feedbackHighlightID`，`progressScrollToken` 换新触发 `scrollTo(anchor: .top)`；`reduceMotion` 时直接跳转，否则 0.25s 缓动。
- 高亮用 `palette.selection` 背景，约 2 秒后由 `.task(id: feedbackHighlightToken)` 清除（沿用本文件 `undoToken` 的任务模式，重开计时自动取消旧任务）。`reduceMotion` 时不做动画，直接出现、直接清除。
- 保存成功后用 `AccessibilityNotification.Announcement("已记录进展")` 播报一次。

## 无障碍

- 每条时间线条目 `.accessibilityElement(children: .combine)`，label 为「日期 时间，类型，内容」。
- 圆点与竖线列 `accessibilityHidden(true)`。
- 未改任何既有 identifier，未改其他页面。

## 验证

- `swift build -j 2`：`build_exit=0`
- `swift test -j 2`：`test_exit=0`，`Executed 669 tests, with 0 failures (0 unexpected) in 43.532 (43.589) seconds`

## 未做与取舍

- 未在真机运行界面做视觉核对，验证止于全量构建与测试。
- 未把 `dayLabel`/`timeLabel` 提取成共享工具（约束为单文件改动，复制两份私有实现）。
- 打开详情时不做自动滚动，滚动只发生在保存之后。
- 未 push、未合并。