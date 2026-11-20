# 130-B 材料详情、主题阅读、提醒设置一致性修正

只读复核清单逐条落实结果。只改四个文件，未运行 swift build / swift test，未写实时资料库。

## WorkspaceSourceView.swift

1. **:936 / :976 DisclosureGroup 内容 spacing 13 → rowGap 8**：采纳。两处都是同一组内的行式控件（按钮、状态行），`rowGap` 的文档语义就是组内行距；13 是孤值。未选 controlPadding 12，因为 12 在 token 里承担的是组内控件间距，这里需要的是行节奏。
2. **:124 / :217 SourceFold 与 SourceSection 头部统一**：采纳，以 SourceSection 为基准。SourceFold 标题改用 `WorkspaceSectionHeading`（sectionTitle、默认前景色、纯数字计数），标题下加 `WorkspaceListDivider`（上距 18），内容上距 16 → 8 对齐 SourceSection；徽标计数改为纯数字。SourceSection 的裸 `Rectangle` 同步换成 `WorkspaceListDivider`，并移除因此不再使用的 palette 环境。图标与展开箭头保留，箭头作为 heading 的 trailing。
3. **:796 长句压缩**：采纳给定文案「旧提取保留为历史；已连接的提醒事项不受影响。」
4. **:995 归档/回收站说明压成一行**：部分采纳，未照抄给定单行。给定句会丢掉「移入回收站会暂停相关理解」的政策语义和「已归档」状态回显。按规则「政策语义可压缩不可丢」，保留条件分支，压缩为「归档只收起材料；移入回收站会暂停相关理解，但可恢复。」；已归档分支原样保留。
5. **:1703 改名弹窗长句**：采纳「缩成字段副标」。改为 caption 级「N 段录音同属一段连续表达。」，紧跟标题输入框。理由：这是弹窗里唯一说明标题作用范围的上下文，删除会让用户不清楚改的是分组标题；缩为副标后不再抢主标题。

## WorkspaceTopicReadingView.swift

6. **:261 / :271 阅读卡片网格列距 16 → groupGap**：采纳，两处列距改为 `WorkspaceMetrics.groupGap`，行距保持 `rowGap`。
7. **:372 「值得继续的问题」改用 WorkspaceSection**：采纳。改为 `WorkspaceSection(title:icon:count:)`，与同页其它区块同构；问题卡片按钮保留原样式（同页 `outcomeCard` 也有 WorkspaceSection 内嵌卡片的先例）。
8. **:333 三个 DisclosureGroup 头部一致**：「查看原话依据」补 `WorkspaceBadge(evidence.count)`，标签改为 `Text(...).vosFont(WorkspaceText.meta)` 与另两个一致，移除外层 `.vosFont`。

## ReminderSettingsView.swift

9. **:63 / :85 / :90 分隔线统一**：采纳方案 A。组间统一 `WorkspaceListDivider`，组内 spacing 保持 `controlPadding` 12，删除三处裸 `Divider`。理由：ReminderScheduleViews 的对应条目要求组间加 `WorkspaceListDivider`；选 A 才能让两个提醒面板跨文件一致，全部去 Divider 会与 schedule 面板相反。
10. **:86 优先级 Picker 移回「日期、提醒与优先级」组末尾**：采纳。Picker 移入该组末尾，组内 spacing 用 `controlPadding`。连带调整：原顺序是标题块、稍后提醒、日期控件、优先级，标题与自己的内容被稍后提醒隔断；把日期控件一并移到标题块之后、稍后提醒之前，组层级才成立。
11. **:53 压缩**：采纳「保存前会重新核对提醒事项当前设置。」
12. **:98 压缩**：采纳「只按名称解析，不联网、不写坐标。」

## ReminderScheduleViews.swift

13. **:54 / :101 面板标题与分隔**：采纳。两个面板首段改用 `WorkspaceSectionHeading`（复用既有组件），组间加 `WorkspaceListDivider`（文件内原无分隔组件，用共享组件保持整文件一致）：标题块与控件块、控件块与说明块/确认块之间各一条。
14. **:69 压缩**：采纳「仅保存在本地；外部改期差异需另行确认。」
15. **:120 / :121 两段说明压缩**：采纳。第一段只留「只允许这一项变更，执行前重新核对。」；第二段压成一句「确认不代表任务已完成；撤回后续写入许可不会撤销已派发的变更。」，保留撤回许可与不可撤销两条语义。未移入 `.help()`，避免把政策藏进 tooltip。

## 风险点

- 未运行 build/test，仅对四个文件做了 `swiftc -parse` 语法检查与 diff 复核；类型检查未覆盖。
- SourceFold 箭头从 .top 对齐变为 heading 的基线对齐，视觉有轻微位移。
- 问题卡片在 WorkspaceSection 内形成嵌套卡片（同页有先例，但仍是双层 surface）。
- ReminderSettingsView 的稍后提醒组移动到日期组之后，行为不变，操作顺序变化。
- ReminderScheduleViews 在模态内新增三条发丝线，垂直占用略增。