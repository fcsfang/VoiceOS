# 波 105：特大字号下不截断

## 背景

视觉统一（波 102-104）大量使用固定宽度与单行限制。只读审计在 1.45x「特大」下发现 12 处可证实的截断/挤压风险：首页时间线 288pt 里标题只剩约 10 字；全景阅读器三按钮必然省略；材料侧栏 248pt 单行标题约 7 字；主导航 172pt 放不下「消息监测 + 徽标」；徽标无 lineLimit 会换行成两行胶囊；监测设置 90pt 标签放不下「Python 解释器」等。

## 修法原则

- 宽度与行数随 `vosTextScale`（@Environment(\.vosTextScale)）在 1.0-1.45 间缩放；缩放上限 1.25-1.3，避免窗口被挤爆。
- 徽标与按钮单行 + minimumScaleFactor(0.8)，绝不换行成两行胶囊。
- 页头 trailing 在窄宽时落到标题下方（ViewThatFits）。
- 装饰图标框随字号放大；固定宽弹窗允许加宽并滚动。

## 单元与文件所有权

| 单元 | 文件 | 范围 |
| --- | --- | --- |
| 105-A 组件与首页 | `WorkspaceDesign.swift`、`RecentContentHome.swift` | Badge/按钮/页头自适应；时间线宽与行数；最近想法预览 |
| 105-B 工作台与引导 | `WorkspaceView.swift`、`WorkspaceSourceView.swift`、`Onboarding.swift` | 主导航/材料侧栏宽、WorkspaceListRow 行数、筛选网格、页头 trailing、图标框、引导滚动与可加宽 |
| 105-C 监测/主题/全景 | `WorkspaceMonitorView.swift`、`WorkspaceTopicReadingView.swift`、`ThoughtPanoramaView.swift` | pathRow 标签 minWidth、Picker 宽度、主题网格最小宽与预览行数、全景阅读器宽与动作行换行 |

## 约束

- 只改尺寸/行数/换行策略，不改行为、identifier、文案、键盘。
- 唯一构建锁；真实退出码；TASK.md + 两次提交；不写实时库、不重启、不 push。
- 完成后合并、整体测试、随下一次安装批次交付。