# 171-B 行动页与每周回顾的信息展示与美化

## 背景
产品方向文档「其他页面也有信息展示问题」表（行动页与每周回顾一行）与「把注意力留给有后果的事」：审计当天真正的当日待办为零，最抢眼的却是 61 个没有下一步的目标和 84 项待补结果。要求首屏先呈现今天确实要处理什么；聚合数字写明单位、期限与去向；警示色只留给有实际后果的期限、阻塞与错误。

## 本次交付

### 每周回顾（已完成）
- 首屏结构：页面标题下先给一行范围副标题（「最近 7 天完成的行动，和仍等你处理的积压。」），接着是两组辅助数字，然后才是「今天收尾」「下周先做」等实体区块。两组数字：
  - `回顾 · 最近 7 天`：`8 项已完成`（跳「本周完成」）。
  - `待处理 · 点数字跳到对应区块`：`84 项待补结果（累计）`、`61 个停滞目标`、`10 项待确认（最近 14 天抽取）`，分别跳到对应区块。
- 数字文案规则（新增原语 `WorkspaceStatLine`，见 `WorkspaceDesign.swift`）：
  - 每行有一句说明范围的 caption（期限/窗口），线下每个数字按「数值+单位+名称」成句（`84 项待补结果`），窗口用括号补注（`累计`、`最近 14 天抽取`）。
  - 去向：能跳转的数字是既有 quiet 链接（help 与 accessibilityHint 写明「跳到…所在区块」）；区不存在的零值降为次要色纯文本，不可点，与 `WeeklyReviewSummaryLinks` 的既有口径一致。
  - 字号压到 meta/caption，数值 semibold + 等宽数字，整组读作辅助信息，不与页面主体抢层级。
  - 窄窗或放大字号时由新增的 `WorkspaceFlowLayout` 自动换行，不截断；caption 与数字能同排时同排，放不下时 caption 独占一行。
  - 统计口径与数据来源未变：`weekCompleted`、`visibleOutcomeFollowups`、`stalledOutcomes`、`unclarifiedTasks` 仍是原来的属性与切片。
- 警示色清单（改动后 `WeeklyReviewView.swift` 中 warning/accent 的全部去向）：
  - `逾期` 区块标题、逾期行图标与「逾期」徽标：warning —— 已过期限，有后果。
  - 非逾期的今日到期行图标、完成勾选、专注选中态、撤销条勾选：accent —— 期限与已发生的结果、选择状态。
  - 专注名额已满与 `focusError`：warning —— 阻塞当前操作。
  - 状态写回失败 `actionError`：warning —— 错误。
  - 降为次要色（secondaryText）：停滞目标行图标、长期未动/待确认/暂停与冻结行图标（共用 `reviewRow`）、留到以后行图标、任务已结束的结果行图标；「待补结果」徽标由 warning 改为 neutral —— 这些是普通疑点/积压，没有实际后果。
  - 「没有下一步的目标」区块新增一句副标题说明补一条下一步即可回到待办。
- 键盘可达与既有交互不变：统计数字仍复用 `.workspaceQuietCompact` 按钮与 `scroll(to:)` 滚动动画；行选择、撤销、专注勾选逻辑零改动。

### 行动页首屏（已完成；经主会话授权，改动 `WorkspaceView.swift` 行动区三处）
1. **今日摘要行（原 :1567-1583）→ 首屏「今天」区块。** 原「今天 X · 逾期 Y」裸数字行改为直接列出今天确实要处理的两组行动：逾期在前、今天到期在后，复用现有 `actionRow`（行内勾选、菜单、右键、跳转全部不变）；区块副标题写明「逾期 N 项 · 今天到期 M 项」。专注中的行动仍只出现在「专注」区块，不与今天区块重复。今天和逾期都为空时，只剩一行安静收束：「今天没有要处理的待办」+ 安静的「查看我的待办」链接（保留原摘要行切换到我的待办的交互与 `summaryTodayFocus` 键盘焦点）。
2. **我的待办积压列表（原 :1635）。** 今天区块已展示的条目从该列表移除（不再重复）；副标题补「7 天内与没有日期的待办」，让积压的范围写明，且整体位于今天区块之后，不再占据首屏第一眼。
3. **无下一步目标横幅（原 :2652）。** 由 warning 通知条降为次要色单行辅助信息：「N 个目标还没有下一步 · 补一条下一步就回到待办」+ 安静的「打开第一条」；在「全部」页移到我的待办之后，「目标」页仍保留在顶部。单位（个）与去向（补下一步回到待办）写明，且不再使用警示色。

**今日为空时的首屏表现：** 标签页下方第一行即「今天没有要处理的待办」——没有要求注意力的按钮或警示色，右侧只有安静的「查看我的待办」一步跳转；其下才是「我的待办」积压区块。用户一眼可以确认今天无事、离开页面。
**未改：** 数据查询与统计口径、过滤切换、行交互、`actionKeyboardOrder` 键盘顺序（今天/积压的行仍在其集合内）、专注逻辑。本轮未改 `WorkspaceDesign.swift`（按主会话护栏，行动区需要的新视图就地写成 `WorkspaceView.swift` 私有成员：`actionTodayFirstScreen`/`todaySummaryJump`/`todayScopeText`）。

## 验证
- `xcrun --sdk macosx swiftc -parse Sources/VoiceOSApp/WorkspaceDesign.swift` → exit 0
- `xcrun --sdk macosx swiftc -parse Sources/VoiceOSApp/WeeklyReviewView.swift` → exit 0
- `xcrun --sdk macosx swiftc -parse Sources/VoiceOSApp/WorkspaceView.swift` → exit 0
- 未跑 swift build/test（约束）；类型集成由主会话统一构建验证。

## 文件清单
- Sources/VoiceOSApp/WeeklyReviewView.swift
- Sources/VoiceOSApp/WorkspaceDesign.swift（新增 `WorkspaceStatLine` 与 `WorkspaceFlowLayout` 两个小原语）
- Sources/VoiceOSApp/WorkspaceView.swift（仅行动页三处区块：今天首屏块、我的待办积压区、无下一步目标横幅，及其私有辅助）
- 本任务书