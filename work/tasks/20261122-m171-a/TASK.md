# 171-A 材料列表与主题列表的信息展示与美化

## 背景
产品文档《VoiceOS 产品方向与开发交接：把口述整理成笔记》「其他页面也有信息展示问题」表，材料列表与主题列表一行（证据：`docs/product/audits/2026-11-22/01-打开工作区.png`、`07-主题.png`）：

- 材料连续使用近似外框的行，长标题被截断。方向：依靠日期、清楚的题目和必要的来源提示来辨认，长题目给足换行空间。
- 主题网格里多张等重卡片都有摘要和数量，扫过去轮廓相似。方向：用真正区分它的具体问题或一句真实摘录做预览，把计数降为辅助信息，长内容自然换行。

本单元只改信息层级与视觉，不改数据查询与交互语义。

## 文件清单
- `Sources/VoiceOSApp/WorkspaceView.swift`（材料列表、主题列表、`WorkspaceRow` 增补题目行数参数、主题卡）
- 未改 `WorkspaceDesign.swift`：现有字阶、间距、卡片与选中原语已经够用
- 新建本 `TASK.md`

没有改动 `WorkspaceSourceView.swift`、`RecentContentHome.swift`、`WorkspaceActivityViews.swift`、`WeeklyReviewView.swift`。

## 材料列表
- **一天一张卡。** 日期组头保留；同一天的材料行连续排在一张卡里，用细分割线分隔，不再每行各套一个近似外框。卡与卡之间仍是 `WorkspaceMetrics.groupGap`。
- **题目不再截断。** 资料库的转写回退题目与自动题目带 20/24 字上限并以「…」收尾（`MaterialTitleText`，Core 不在本单元范围）。列表改为：
  - 用户自己保存的题目原样显示（即使以省略号结尾）；
  - 带「…」的题目改用该材料原文首句（到第一个句末标点为止；首句无句末标点时保留整行），走 `fittedDisplayTitle` 处理链接与 markdown；
  - 行内 `titleLineLimit: Int.max`，长题目按自身长度换行，不再收成省略号。
- **副行只留辨认所需。** 保留日期时间；默认来源「我的表达」不再逐行重复，AI 交付、外部资料、仅本地、疑点照旧提示。行尾在读/已读、待办徽标、右键菜单、管理菜单均不变。
- **选中与悬停** 沿用现有原语：行内 hover 高亮，键盘选中用 `workspaceSelectionHighlight`（selection 底 + focusRing）。

## 主题列表
- 新增私有 `TopicPreviewCard`（`WorkspaceView.swift` 内）：标题（sectionTitle，自然换行）→ 预览 → 底部脚注。去掉每张卡相同的六边形装饰图标，轮廓由预览结构本身拉开差异。
- 预览优先序，全部取自现有已加载字段，不新增查询：
  1. `topic.organization.questions` 的第一个非空具体问题（questionmark.bubble 图标 + 正文色）；
  2. `topic.organization.sections[].evidence.quote` 的第一段可用原文的首句（引号包裹 + 次要色 + 「原话 · 来源日期」脚注）；
  3. `topic.organization.summary`（旧行为兜底）。
- 计数（份材料、小主题、最近日期）收为 meta 字号、tertiary 色的单行脚注，不再与标题争夺注意力。
- 「材料已更新，待重新整理」与「正文整理中」提示保留在标题下方。

## 键盘与选择
主题网格的 `.focusable/.focused($themeListFocused)/.onKeyPress(handleThemeListKey)`、`themeKeyboardFocus` 步进、`.id(listing.id)` 与 `onChange` 滚动、`restoreKeyboardScroll`、`selectTopic` 全部未改。材料行的 `MaterialMenuRow` 键盘 reveal 与 `.id(source.id)` 也未改。

## 验证
- 改动文件逐个 `xcrun --sdk macosx swiftc -parse <绝对路径>` 取真实退出码，不加管道。
- 按波次约定不跑 `swift build/test`，由主会话统一集成构建验证。
- 未新增查询 API，未改数据模型。