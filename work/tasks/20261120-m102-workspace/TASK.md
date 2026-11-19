# 波 102-C：材料、行动、设置三页视觉统一

## 背景

材料、行动、设置三页各自沿用旧的页头、页签与系统默认按钮，放在一起读不出同一套设计。本波只改 `Sources/VoiceOSApp/WorkspaceView.swift` 的呈现层，把三页收进已有的 WorkspacePageHeading、WorkspaceSectionHeading、WorkspaceBadge、WorkspaceButtonStyle 与 WorkspaceCard 体系。数据计算、过滤集合、键盘事件、排序逻辑、accessibilityIdentifier 均未改动。

## 改动逐条

- 页头统一为 WorkspacePageHeading。材料 `WorkspaceView.swift:948`，行动 `:1142`，设置 `:1723`。行动页「AI 交付 N 份待读」改为中性徽标按钮 `:1146`，仍是同一个筛选跳转；「安排今天」改为唯一主按钮 `:1152`。
- 新增 WorkspaceFilterTabItem 与 WorkspaceFilterTabs（`:3034`、`:3044`）。材料 5 个、行动 8 个页签改为选中 ink semibold、未选中 secondary regular、2pt accent 下划线，整行无胶囊底色；计数单独用 monospacedDigit tertiary。identifier 仍拼成 `workspace.tab.` + 旧组合标签，既有 UI 检查不受影响。调用点 `:961`、`:1171`。
- WorkspaceRow 新增 `.badge` 尾标 `:142` 与 `subtitleTone` `:153`；标题改为两行截断 `:203`，hover 统一用 palette.hover `:177`、`:188`。材料行的「N 条待办」改为 accent 徽标 `:1950`、`:1952`，疑点信息保留在朗读状态里。
- 行动页待办行：标题保持 rowTitle semibold，第二行保持 meta regular；提醒异常在 `:2089` 判定后以 warning 色传入 `:2098`。工作台行容器与材料行统一到 panelRadius `:2937`，行间距沿用 ActionCardList 的 8。复选框改为顶部对齐首行（WorkspaceRow `:169`）。
- 行动页摘要行「今天 N · 逾期 N」改为整体 monospacedDigit `:1194`。「N 个目标还没有下一步」横幅改用 WorkspaceNoticeText 告警底，右侧 quiet 按钮「打开第一条」`:2054`。
- 设置页所有默认按钮换成新按钮体系：暂停提醒事项连接与各「打开系统设置」为 workspaceSecondary `:1740` 起；授权麦克风为 workspacePrimary `:1755`；提醒待核对为 warning 徽标加 quiet「去核对」`:1743`、`:1744`；导出、备份、资料库维护按主次使用 secondary、secondaryCompact、quietCompact、destructive `:1795` 至 `:1838`。分组标题改用 WorkspaceSectionHeading `:1900`。
- 侧栏 WorkspaceAttentionDot 改为一行 caption 加 warning 徽标「转写疑点 N」与 neutral 徽标「其他 N」`:250`，原 Button 行为、help、accessibilityLabel 与跳转保持不变。

## 验证

- 构建：`swift build -j 2`，经 `/tmp/voiceos-swift-build.lock` 串行。首次构建暴露一处 memberwise 参数顺序错误，修复后完整构建 `Build complete! (88.10s)`，最终增量构建 `Build complete! (27.26s)`，真实 `build_exit=0`。本文件对构建日志贡献 0 条 warning。
- 测试：`swift test -j 2`，同一把锁。真实 `test_exit=0`，`Executed 661 tests, with 0 failures`，耗时 45.82 秒。修复后的构建与测试各重跑一次，全部通过。

## 取舍与风险

- WorkspaceRow 是共享组件，标题两行截断与 hover 改色会同时作用于主题、搜索等列表，这是有意收口；若某处需要三行标题，需要显式参数化。
- 筛选页签在 WorkspaceView.swift 内新建了一份局部视图，因为本波只允许改一个文件，WorkspaceReadingViews.swift 的旧 WorkspaceTabs 未动。后续应把 chips 与 filters 两种样式合并回一处。
- 提醒异常颜色由 ActionRowLayout 的 meta 文案前缀判定（提醒待核对、提醒缺失、已逾期）。这是呈现层耦合，若文案变化会失去 warning 色；没有改数据层。
- 材料行的「疑点 N」从视觉尾标移入朗读状态，屏幕上只留「N 条待办」徽标。这是按本波规范做的取舍，仍有完整的 VoiceOver 信息。
- 未做应用内视觉走查：约束禁止重启应用。验证范围是编译、661 项测试与 diff 语义，不是屏幕像素。