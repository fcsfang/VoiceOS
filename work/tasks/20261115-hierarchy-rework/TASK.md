---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-15
owner: coordinator
---

# 信息层级重做批

## 目标

按 `docs/product/hierarchy-spec.md` 重做界面层级。用户判定当前信息展示层级「非常糟糕」，根因是 23 个散写字号、三套页标题声音、区块头与页标题同色同重、元数据/状态/操作共用一档灰字、容器混用。本批先落六档令牌与共享组件（W1），再按页重排（W2 到 W4）。基线 `main` 为 `ef0cef2`，321 项测试。

## 单元

### W1 字级令牌与共享组件
文件：`Sources/VoiceOSApp/WorkspaceTextScale.swift`、`WorkspaceDesign.swift`、`WorkspaceTheme.swift`。
- 六档令牌：pageTitle 26 semibold、sectionTitle 17 semibold、rowTitle 15 semibold、body 15 regular、meta 12 regular、caption 11 regular。提供 `.vosFont(WorkspaceTextStyle)` 重载。
- 调色板新增 `tertiaryText`（约 #8E8E8E）。
- `WorkspaceRow` 与 `WorkspaceListRow` 的标题到副标题间距统一 3，行内边距竖 8 到 10；`WorkspaceSection` 区块头改 `sectionTitle` 加 `secondaryText`。
- 不重排任何页面结构，只动令牌与共享组件。`swift build -j 2` 单独通过后再交 W2 到 W4。

### W2 行动与材料页重排
文件：`Sources/VoiceOSApp/WorkspaceView.swift`（行动与材料区段）、`WorkspaceReadingViews.swift`、`SavedViews.swift`。
- 行动：待办置顶为唯一主区块、去卡片壳、行四槽位；结果与 AI 工作降为折叠次级区块；页头操作收进「…」；筛选改文字标签。
- 材料：日期组头、行尾状态色点、计数右对齐 caption、行线 1px。

### W3 阅读页
文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`、新增 `Sources/VoiceOSApp/MarkdownText.swift`。
- 标题走 `displayTitle()`；正文按 Markdown 渲染（标题、加粗、列表、引用分层）；工具行并入窗口头；状态行降到 meta；正文从窗口头下 16 开始。

### W4 首页、主题与设置
文件：`Sources/VoiceOSApp/RecentContentHome.swift`、`WorkspaceTopicReadingView.swift`、`WorkspaceTheme.swift`（设置页主题卡）。
- 首页时间线统一「标题在上、时间在下」，一栏一个字体家族，线程头 17 semibold。
- 主题卡摘要固定两行，页脚 caption。
- 设置页区块头 17 次级灰；主题卡改 vosFont。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机：行动、材料、阅读、首页、主题、设置六页截图前后对比；`rg -o "vosFont\([0-9.]+"` 去重不超过 8 个值；阅读页无字面 Markdown 符号；每个区块头是次级灰。

## 已知边界

- 不改任何交互与数据语义，只改视觉层级与信息排布。
- 悬停操作、深色主题与三档非标准文字大小作为验收项在合并前抽查。

## 结果

（待填）

## 链接

- `docs/product/hierarchy-spec.md`
