# 171-C 首页（收件箱式时间线）的信息展示与美化

## 背景
产品文档《VoiceOS 产品方向与开发交接：把口述整理成笔记》「其他页面也有信息展示问题」对首页与材料详情的观察：首页右侧已有长阅读区，材料行却连续使用近似外框的行、长标题被截断；后续优化方向是「首页承担辨认和重访，用同一笔记标题与一段能唤起记忆的预览，时间线保留日期和选择状态」。本单元只改首页时间线的信息层级与视觉，不改数据查询、选择与交互语义。

## 必读（均已读）
- `docs/product/VoiceOS 产品方向与开发交接：把口述整理成笔记.md`：「打开后的第一眼」「其他页面也有信息展示问题」。
- `docs/product/audits/2026-11-22/09-首页读一条表达.png`、`02-首页.png`。
- `Sources/VoiceOSApp/RecentContentHome.swift` 全文；`Sources/VoiceOSApp/WorkspaceView.swift` 的 `RecentContentHome` 调用处（只读，未改）。
- `Sources/VoiceOSApp/WorkspaceDesign.swift`、`WorkspaceTextScale.swift`、`WorkspaceTheme.swift`：既有字阶、间距、色板与行原语。

## 文件清单（只允许动这些）
- `Sources/VoiceOSApp/RecentContentHome.swift`（唯一改动文件）
- `WorkspaceDesign.swift` 未改：所需原语（WorkspaceListDivider、palette、WorkspaceMotion）都已在用。

## 行结构变化
- 去掉每行左侧 28pt 图标瓦片和整行外框描边：时间线由「叠放卡片」改为平面列表，结构交给日期标题与细分隔线承担，消除审计指出的「轮廓相似」。
- 每行骨架＝状态点（6pt，挂在预留的左侧 gutter）＋可换行题目＋一行 meta；meta 仍是「来源 · 时间 · 状态 · N 条待办」，三态语义不变（未读＝accent 点、在读＝次要点、已读＝无点且题名转次色）。
- 反馈行（任务进展）无阅读状态，gutter 留空，题名与材料行同列对齐。

## 长标题与预览
- 题名取消 `lineLimit`，`fixedSize(horizontal: false, vertical: true)` 自然换行，不再出现省略号；窄栏下让位的是预览与 meta。
- 材料行新增摘要预览：取 `item.summary`（与右侧阅读器开篇同一段导语），无摘要时退到第一条想法；空白折叠为一行流，`lineLimit(2)`、meta 字阶、次色，只做记忆钩子不做正文。
- 选中且已读的行题名恢复全强度，与右侧阅读器题名一致；未选中的已读行保持弱化。

## 日期分组与间距（邻近原则）
- 日期标题改为「日期文本 ＋ 右侧细分隔线」，去掉 accent 竖条（accent 在本列留给选中行与通向阅读器的动作）。
- LazyVStack 间距归零，逐组控制：标题距本组首行 6pt＋行内边距，组内行距 2pt，上一组末行到下一日期标题 20pt；日期从属于其下的行，组与组之间才是大间隔。
- 「待处理/全部」分段、三态状态点、`最近想法` 披露区语义均不变；披露区条目同步改为平面行，条目之间加细分隔线。

## 选中高亮
- 选中行＝selection 底色＋左缘 3pt accent 圆条，与右侧阅读器的 accent 动作同一语义；未选中:hover 用 palette.hover，默认无底色。
- 右侧阅读器本身未改动；行内题名与预览即阅读器开篇的同一题目与同一段导语，强化「左选右读」的对应。

## 不改的部分
- `selected`/`selectedID`、`syncSelection`、`handleTimelineKey`、`restoreTimeline`、`TimelineAnchorKey` 全部原样；键盘可达与滚动恢复行为不变。
- 不新增查询 API；预览仅读快照已有的 `item.summary`/`item.thoughts`。
- 未触碰 WorkspaceView.swift、WorkspaceSourceView.swift、WorkspaceActivityViews.swift、WeeklyReviewView.swift。

## 约束与验证
- 不跑 swift build/test；`xcrun --sdk macosx swiftc -parse Sources/VoiceOSApp/RecentContentHome.swift` 真实退出码 0。
- 视觉验收（真实窗口、长标题、窄窗口、大字号）留给主会话集成构建后与文档「视觉验收」一起做。

## 回报
行结构变化、长标题与预览处理、选中高亮处理、parse 退出码、diff --stat。