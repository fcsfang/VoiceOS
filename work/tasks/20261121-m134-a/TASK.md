# 134-A 行交互一致性

## 背景

用户要的是四个页面里同一类行的反馈一致。可打开的行应当整行可点，hover 覆盖命中区，尾部有打开提示。不可打开的行不摆出可点的样子。基准是 WorkspaceDesign.swift 的 `workspaceHoverHighlight`、`WorkspaceRowChevron` 与 `WorkspaceMetrics.rowActionMinHeight`。

## 改法（逐条）

### WorkspaceView.swift

1. 采纳。`WorkspaceRow` 带 completion 时改为 ZStack。整行 Button 承担打开与 hover，圆形完成控件置顶于前导位。按钮内边距与 14pt 间隙都进入整行 Button 的 label，hover 范围等于命中区。完成控件声明在前并 zIndex 1，Tab 顺序仍是完成、打开。
2. 采纳。本地完成待同步与今天/逾期两条摘要行补 `frame(minHeight: 24)`、`workspaceHoverHighlight` 与 `palette.focusRing` 焦点环。焦点环由 `@FocusState` 驱动并关闭系统焦点效果，避免双层描边。
3. 未采纳替换 `.link`。`executionRows` 的 `.link` 尾样式已自带 accent 文案与 `chevron.right`，同时承载未读与进度含义。换成 `WorkspaceRowChevron` 会丢状态文案。行动行的状态尾同样承载文案，`WorkspaceRow` 只有一个尾部槽位，补箭头需要改 WorkspaceDesign.swift，被本轮约束排除。两类行都在整行 hover 下可点，箭头语义由 `.link` 或卡片上下文提供。
4. 采纳。新增 `searchKeyboardRows`，空查询时返回材料列表，非空时把建议行放在结果行之前。材料行与建议行补与结果行相同的 selection 背景、`palette.focusRing` 描边与 `.id`。`handleSearchListKey`、`moveSearchSelection`、`openSearchSelection` 共用这份 id 集合。空查询且无选中时 Enter 不跳转，避免误开第一条材料。
5. 采纳。同一 id 集合覆盖建议行，选中样式与滚动定位沿用结果行。
6. 采纳。最近搜索删除按钮从 14pt 命中改为 24pt。`fieldHeight` 为 28，chip 高度不变。

### WeeklyReviewView.swift

7. 采纳。`unavailableProgressRow` 当前仍是信息行，133-C 未把它改成可点行。去掉 hover 与右侧 chevron，只保留显式「查看材料」按钮。
8. 采纳 dailyRow 与 somedayRow。两者整行打开任务详情，尾部补 `WorkspaceRowChevron`。nextWeekRow 未采纳。它是加入专注的多选开关，不是打开详情，补 chevron 会暗示导航。同页 reviewRow 的 chevron 也只出现在打开详情的行上。

### WorkspaceSourceView.swift

9. 采纳。时间片、大纲、章节三个回听 label 补 `palette.hover`，播放中的 `palette.selection` 优先。时间片 label 补 `minHeight 24`，原命中高约 19pt。
10. 采纳。人名与术语按钮行补同款 hover，并补 `minHeight 24`。
11. 采纳。`SourceFold` 折叠标题补 hover，label 拉满行宽，命中区覆盖整行标题带。

### RecentContentHome.swift

12. 采纳。时间线行用 `hoveredTimelineID` 记录 hover，`homeCard` 增加 `hovered` 参数。选中时仍用 `palette.selection` 与 `palette.focusRing` 描边，hover 不覆盖选中态，描边保持。

## 验证

- `xcrun swiftc -parse` 解析四个改动文件，退出码 0。
- `git diff --check` 退出码 0。
- `git diff --stat` 显示四个文件，88 增 29 删。
- 按约定未运行 `swift build` 与 `swift test`，未写实时资料库。
- 键盘与焦点行为需在主会话集成构建后目视确认。

## 风险

- 摘要行的焦点环依赖 Button 参与键盘焦点链。系统未开启全键盘控制时 `@FocusState` 不会置真，环不出现，hover 仍有效。
- 完成控件禁用时，SwiftUI 的禁用命中行为可能让点击穿透到整行打开按钮。行为未在真机确认。
- 搜索方向键集合变为建议行在前、结果行在后，空查询走材料列表。滚动定位依赖新增的 `.id`，与既有结果行一致，未目视。
- 回听 label 的 hover 状态不进 `Equatable` 比较，父视图刷新仍被抑制，本地 hover 状态照常触发重绘。
- 删除 chip 按钮命中区变宽 10pt，chip 在 28pt 固定高度内，宽度随内容增加。未目视。
- 未运行应用，行高、箭头位置与高亮形状需集成构建后目视。