---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-12
owner: coordinator
---

# 并行大波第十二批（界面与交互大整）

## 目标

按 D1 设计系统审计与 D2 交互审计实施界面优化。机器已解锁，合并后做截图对比。基线 `main` 为 `d976106`，321 项测试。

## 共享契约（V1 定义，其余单元依赖）

`WorkspaceMetrics` 新增（旧名保留兼容）：`sectionGap=24`、`pagePadding=32`、`panelRadius=12`、`chipRadius=6`、`sectionRadius=16`、`iconButtonSize=28`、`rowActionMinHeight=24`、`fieldHeight=28`。
`WorkspacePalette` 新增：`hover`、`pressed`、`disabledText`、`focusRing`、`success`（固定绿，不跟随 accent）；`secondaryText` 提到 text@0.72；两主题画布加深、边框提高到可辨、graphite accent 换成可识别色。
`WorkspaceNoticeText` 升级为块级（图标 + 浅底 + 描边 + 13pt），severity 增加 `.info`、`.success`，旧调用不变。
新增 `WorkspaceToast` 与 `.workspaceToast($text)` 修饰器（底部浮层，2.5 秒自动消失）。
`WorkspaceIconButton` 命中区 28pt。
`workspaceEditorSurface()` 内部补 `scrollContentBackground(.hidden)` 与内距 10，调用点无需改。
新增 `WorkspaceListRow(density:.comfortable/.compact,title:subtitle:icon:trailing:highlighted:action:)` 共享行组件。

## 单元

### V1 令牌与共享组件
文件：`Sources/VoiceOSApp/WorkspaceDesign.swift`、`WorkspaceTheme.swift`、`WorkspaceTextScale.swift`。
- 落地上表全部令牌与组件；字号阶梯定义（pageTitle 28/600、sectionTitle 20/600、rowTitle 16/600、body 16、meta 13、caption 11），`vosFont` 保持 API。
- 不改任何页面文件。

### V2 外壳与行动列表
文件：`Sources/VoiceOSApp/WorkspaceView.swift`。
- 行动行：悬停浮现圆形完成钮与「⋯」菜单（改天、不再跟进、加入专注），右键菜单补齐同样三项；行内完成/放下后显示 8 秒撤销条并可点撤销。
- Esc 分层：先退出选择模式，再清空搜索词，最后返回。
- 材料列表与搜索结果接入方向键与 ↵（抽出本文件内共享焦点模型）；搜索结果 `ForEach` 改用命中稳定标识。
- 页面骨架改用 `WorkspaceMetrics.pageWidth/pagePadding`，区块间距统一 `sectionGap`；字面量圆角 9 换 `panelRadius`。
- 行高与字号向 `WorkspaceListRow` 看齐（能替换的行替换，其余对齐数值）。

### V3 阅读页重构
文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`。
- 原文成为主体：标题下第一区块是「原文与回听」，默认展开；理解类区块（整体理解、逐层读、大纲、人名与术语、章节）保留但顺序调整到原文之后、默认折叠。
- 四个原文入口合并为一个：删除重复的「更正原文」，把「全文选读」「查看完整文字」收进「原文与回听」的轻量切换；工具行改为吸顶紧凑条，主操作 + 「⋯」（修改标题、重新整理、策略、更正文本各一处）。
- 禁用按钮补 `.help` 说明；更正/更新理解的 sheet 用本地状态展示结果，成功关闭并 toast，失败就地红字可重试。
- 字面量圆角与内距对齐令牌。

### V4 任务页与启动页
文件：`Sources/VoiceOSApp/WorkspaceActivityViews.swift`、`TaskInitiationView.swift`。
- 三个日期/提醒入口合并为一个「日期与提醒」，打开既有 ReminderSettings；排期内部术语（外部期限基线、弹性安排）收进「处理记录」折叠区并改写为动作语言。
- 提醒事项同步期间按钮禁用时，旁边显示「正在同步提醒事项，稍后可操作」并可点击重试；不改变本地/外部写入顺序。
- 启动页标题改用 `WorkspaceHeading`；子任务删除等小按钮命中区 ≥24pt。

### V5 周回顾与引导
文件：`Sources/VoiceOSApp/WeeklyReviewView.swift`、`Onboarding.swift`。
- 截断区块显示「查看全部 N →」跳行动页对应筛选；徽标与列表数量一致；行补悬停与 8 秒撤销条；删除与「今天收尾」重复的区块。
- 引导拆四步（记录、整理、快捷键三条以内、完成），用分页点；快捷键表只留设置页一处并链接指过去；标题统一。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 合并后构建 dist，复制为独立 bundle id 的测试包，用隔离资料库启动，截图对比主要页面（材料列表、行动页、任务页、阅读页、周回顾、设置）。

## 已知边界

- 语义字体（.caption 等）与 vosFont 并存问题本批只统一新代码与改动处，全量迁移留后。
- 动效只加列表身份动画与 toast 过渡，不做全面转场。
- 截图走查以本机辨识度为准，不做像素级 parity。

## 链接

- D1 设计系统审计、D2 交互审计（本批报告）
- `docs/product/reference-products.md` 第 9 节
