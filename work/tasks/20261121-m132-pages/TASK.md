# 132-C 全景、材料页、启动页与引导的层级/空态/小字收口

基准：main 154f507（含分隔线全仓替换）。
范围：只改 ThoughtPanoramaView.swift、WorkspaceView.swift（材料页与全景 tab 的 picker 行）、TaskInitiationView.swift、Onboarding.swift。

## ThoughtPanoramaView.swift

- [采纳] :41 页头手工 padding 26/12/2：删除全景独立 WorkspacePageHeading 后整块 padding 一并移除；WorkspaceView.swift:798 的「最近/全景」picker 行水平 padding 改为 WorkspaceMetrics.pagePadding（32）。两个 tab 的标题与内容左缘都以 32 为基准，切换不再跳动。
- [采纳] :40 全景 tab 再叠「思考全景」页标题：选「去掉全景独立页头」。理由：picker 已经表达 tab 名；「最近」tab 无页标题，删页头是二选一里改动更小、两 tab 更一致的一侧。全景工具栏仍在 picker 下方，层级不变。
- [采纳] :647 空态：改为 WorkspaceEmptyState。保留上方椭圆插画底，移除插画内的重复图标，由 WorkspaceEmptyState 的 Label 承载「point.3.connected.trianglepath.dotted」。emptyDetail 删除，改为 PanoramaEmptyMode.detail 逐模式文案；.unverified 只有存在具体错误时才复用错误句，其余不再回落 toolbarMessage 原句，避免与工具栏状态逐字重复。toolbarMessageHelp 仍挂在整个空态上。
- [采纳] :468/:501 裸 Text 区块头：改为 WorkspaceSectionHeading（「问题与联系列表」「候选联系」）。
- [采纳] :472/:554 区块 VStack spacing 6 → WorkspaceMetrics.rowGap。
- [采纳] :584 搜索结果行 vertical padding 2 → 3，落回标题/详情 2–3pt。
- [未改] :512/:573 标题与详情 spacing 2 已在 2–3pt 区间，保持原值。
- [采纳] :890/:1093/:1182 免责小字：保留 :1093 的 WorkspaceBadge「AI 候选解释 · 尚待核对」；删除 :890「AI 的推断，不是你的结论」caption（上一行已有「AI 的回应」标签）；:1182 保留来源归属，删除「· 不代表本人认可」尾句，避免同一阅读流第三次免责。
- [未改] :699 覆盖弹层 warning 文案不在同一阅读流，保留。

## WorkspaceView.swift（材料页）

- [采纳] :1029 分组头与行组 spacing：外层 6 → 0。WorkspaceListGroupHeader 自带 vertical padding 8 与底部 WorkspaceListDivider，再留 6 会把行推离分隔线；取 0 让分隔线直接接行。行组内部 spacing 8 → WorkspaceMetrics.rowGap（值同为 8，改用 token）。
- [采纳] :1014 未读/在读空态 description：两处说明只解释机制、不引导行动，删除；标题与「查看日常材料」按钮保留。
- [采纳] :996 今日阅读 vs 日常材料壳体：统一到日常材料的列表行壳。今日阅读的 WorkspaceRow 加 .materialCard(highlighted:false)，去掉行间 WorkspaceListDivider，改用 WorkspaceMetrics.rowGap 间距。理由：materialCard 承载日常材料的键盘高亮与悬停，保留它比拆掉日常材料卡片更安全；交互不变。
- [采纳] :1006 长尾说明：已归档/回收站条件显示保留；「Apple 提醒事项未被删除或取消」从正文移入回收站筛选 tab 的 .help。为此给私有 WorkspaceFilterTabItem 增加默认空串的 help 字段，并在 tab 上透传；行动页初始化不带该参数，行为不变。

## TaskInitiationView.swift

- [采纳] :511 空态：改为 WorkspaceEmptyState；showArchived 两态分别给 title 与 description（「还没有归档的记录」/「还没有启动记录」+ 原说明拆成第二句）。
- [采纳] :529 历史行：VStack spacing 6 → 3，vertical padding 18 → 10，horizontal 保持 10，对齐 WorkspaceRow 的 10 / 3 规范。未直接换 WorkspaceRow：WorkspaceRow 必须带图标，而历史行原本无图标；直接换会改变行结构与选中态语义，超出壳与间距的范围。
- [采纳] :505 启动记录区块：WorkspaceSection → WorkspaceListSection（列表类区块基准）。去掉 clock 图标与卡片壳，标题下改走分隔线。subtitle 精简为「生成过的材料都在这里。」，不再与 :176「已复制 · 复制不代表已执行」重复。
- [采纳] :142 三连句：压成「只发送这段原话给模型；不读取其他材料，也不创建任务或提醒。」

## Onboarding.swift

- [采纳] :73 引导卡 padding 28 → 24，对齐全应用弹层。
- [采纳] :36 步骤图标与文字 HStack spacing 14 → WorkspaceMetrics.controlPadding（12）。
- [采纳] :98「开始前检查」：Text(rowTitle) → WorkspaceSectionHeading + 说明 → WorkspaceListDivider 的小节头结构；说明与标题间距 3pt，分隔线下留 10pt。

## 风险与未验证项

- 按任务约束未运行 swift build 与 swift test，编译与真实渲染未验证。
- ThoughtPanoramaView 空态从手写 VStack 改为 ContentUnavailableView，纵向留白由 WorkspaceEmptyState 决定；插画仅保留椭圆底。
- 今日阅读改为 materialCard 后视觉比原 WorkspaceRow 多一层 surface + hairline，这是与日常材料统一的结果。
- WorkspaceFilterTabItem 与 WorkspaceFilterTabs 位于 WorkspaceView.swift，行动页共用；help 字段默认空串，不影响行动页文案与布局。
- 历史行未改用 WorkspaceRow，hover 与分隔线保持原实现，仅收敛间距。