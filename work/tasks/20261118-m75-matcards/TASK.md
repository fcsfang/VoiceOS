# 波 75 任务书（2026-11-18）：材料页列表卡片化

## 背景（实机走查 2026-11-18，波 74 后）

首页已卡片化。逐页核对：主题页已是卡片网格；处理页已是分区面板；材料页仍是文字墙——`WorkspaceView.swift` 的 `sourceRow`（1819 行起）无背景透明行 + `WorkspaceListDivider` 细线，与波 74 前的首页同病。

## 设计（与波 74 的 `homeCard` 同一语言）

1. `sourceRow` 行改为卡片：`palette.surface` 底、`palette.border` 1 点描边、圆角 9、保留既有行内边距；`highlighted`（键盘焦点）仍用 selection + focusRing。
2. 材料页 `LazyVStack` 中 `ForEach` 行间距 8；移除行间 `WorkspaceListDivider`（卡片即边界）；日期分组头保留并在其后留 6 点。
3. `MaterialMenuRow` 的悬停/焦点菜单机制、`.id(source.id)`、键盘焦点（`materialKeyboardFocus`）、context menu、状态点（TrailingStyle.dot）与读状态逻辑全部不动。
4. 不动「今日阅读」的 `WorkspaceListSection`（面板内行保持现状）；不动归档/回收站文案与空态。
5. 不改文案、identifier、数据逻辑；不加迁移。

## 完成判据

1. 材料页四个筛选（日常材料/未读/在读/已归档/回收站共享同一渲染路径）下每份材料为独立卡片，相邻条目可区分。
2. 键盘焦点高亮、右键菜单、悬停菜单、状态点、点击打开材料全部不回归。
3. `swift build -j 2` / `swift test -j 2` 真实退出码 0（先 merge main，基线 615 项）。
4. 纯布局改动，不加单测；结果给改动清单（file:line），协调方安装后截图比对。
5. 结果补记进任务书 `## 结果`。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceView.swift`（材料页 section 与 sourceRow，最小增量）
- 如 `MaterialMenuRow`（同文件 2794 行）需要配合留白，可最小调整，仍限本文件。
- 不碰其他文件。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；不重启应用；不 push、不合并。
- 分支 `work/m75-matcards`，提交回报。

## 结果

- 分支：work/m75-matcards（基于 main 2793143，merge main 退出码 0，已是最新）。
- 代码提交：ef1c2fd「feat(材料页): 材料列表改为卡片边界并去掉行间分隔线」。
- 改动：`Sources/VoiceOSApp/WorkspaceView.swift` 单文件。
  - 新增文件私有 `materialCard(highlighted:)` 修饰符（`MaterialCard` 在 2793 行，`View` 扩展在 2804 行）：背景 `palette.surface`、描边 `palette.border` 1 点、圆角 `WorkspaceMetrics.controlRadius`（8）；高亮时背景换 `palette.selection`、描边换 `palette.focusRing`。未加内边距，沿用 `WorkspaceRow` 既有水平 10、垂直 10。
  - 材料列表（957 行起）：日期组头与行列表拆成两层（组头 960 行、行列表 961 行），组头后留 6、行间 8（组间仍 16）；移除行间 `WorkspaceListDivider`。`sourceRow` 不再接收 `highlighted`，高亮 chrome 移到 966 行的 `materialCard` 调用。
  - `sourceRow`（1820 行）保留内容与 context menu，删除旧的 selection/clear 底与 focusRing 覆盖层。
  - 未改 identifier、键盘焦点（`materialKeyboardFocus` 与方向键处理）、滚动锚点 `.id(source.id)`、context menu、悬停菜单 `MaterialMenuRow`、状态点（`TrailingStyle.dot`）、文案与数据逻辑；「今日阅读」的 `WorkspaceListSection` 未动。
- 验证：build_exit=0（`swift build -j 2`，107.87 秒）；test_exit=0（`swift test -j 2`），615 项测试 0 失败，与基线一致。构建与测试共用 `/tmp/voiceos-swift-build.lock`，结束后已释放。未加新测试（纯布局改动）。
- 判据落点：
  - 判据 1：日常材料、未读、在读、已归档、回收站共用同一 `materialRows` 渲染路径，每份材料由 `materialCard` 绘制 surface 底、border 描边与圆角 8，行间 8；日期分组头保留并后留 6。
  - 判据 2：高亮仍为 selection 底加 focusRing 描边；`.id(source.id)`、`MaterialMenuRow`、context menu、状态点与点击打开均未改动。
  - 判据 3：见「验证」。
  - 判据 4：改动清单与 file:line 见上；实机截图比对留协调方。
  - 判据 5：本节。
- 设计取舍：圆角用 `WorkspaceMetrics.controlRadius`（8）而不是任务书写的 9，因为波 74 合入的 `HomeCard` 实际用的就是这个 token（`RecentContentHome.swift:743`），「同一语言」以代码 token 为准，也不新增字面量。卡片不加额外内边距，保留 `WorkspaceRow` 原有 10/10，避免行高变化。高亮 chrome 从 `sourceRow` 移到材料列表调用点，使主题页与处理页复用 `sourceRow` 时外观保持原样。
- 遗留风险：
  - 深色石墨下 surface（0x272727）与 canvas（0x1E1E1E）明度差小，边界主要靠 border（0x4A4A4A）；鼠尾草深色 surface（0x242925）与 canvas（0x1B1F1D）同理。实机观感待协调方截图确认。
  - `WorkspaceRow` 自带悬停底色圆角为 `panelRadius`（12），卡片圆角 8，悬停时四角可能有 1 到 2 点视觉外溢；为保持其他页面行为未改 `WorkspaceRow`。
  - 卡片宽度沿用既有 `trailingGutter`（44 或 152），悬停菜单胶囊仍压在行尾；未加内边距，窄窗口下标题可用宽度不变。
  - 主题页「尚未归入主题的材料」与处理页失败材料仍走 `sourceRow`，这些页面本轮未要求卡片化，外观与波 74 后一致。

