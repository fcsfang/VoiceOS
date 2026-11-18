# 波 74 任务书（2026-11-18）：首页列表边界与信息分层

## 背景（用户反馈 2026-11-18）

「主页最近想法全是文字，每一个栏目全是文字，没有明显的边界，不能很好地区分不同的想法，信息呈现效果比较差。」

现状（`RecentContentHome.swift`）：时间线行是无背景透明行（仅选中时 `palette.selection`），行间距 4；最近想法行 padding 纵向仅 4、组内 spacing 3，两行文字直接相接；日期分组头与内容同色级。全部区域堆成文字墙。

## 设计（按现有设计语言，不引入新视觉体系）

1. 统一行卡片修饰符 `homeCard(isSelected:)`（本文件私有）：
   - 背景 `palette.surface`，描边 `palette.border` 1 点，圆角沿用 `WorkspaceMetrics.controlRadius` 或 9；
   - 水平内边距 12、垂直 10；
   - 选中态保持现行为：`palette.selection` 背景 + `palette.focusRing` 描边，并保持不因加卡片而变重的观感；
   - 深色主题下同样成立（canvas 与 surface 已有对比）。
2. 时间线行（`row(item)`）：套 `homeCard`；行间距 4 → 8；日期分组头上下加间距（组间保持 18，组头与首行间 6），组头左侧加 2 点竖向 accent 条作分组标记。图标、标题两行限、meta、状态位保留不变。
3. 最近想法行（`recentThoughtsSection`）：每条 entry 套 `homeCard`（不选中）；entry 间距 3 → 8；entry 内两行间距 2 → 4；想法文本与来源标题维持现字体与行数限制；分组标题与首个卡片间 6。
4. 不新增/不改文案；不改任何 identifier（`recent.item`、`recent.thought` 等）、键盘导航、滚动锚点与选中逻辑；不改 reader 区；不加迁移、不碰其他文件。
5. 首页其余栏目如仍有「行与行无边界」的同类堆叠（如组织提示卡以外的列表行），按同一 `homeCard` 处理，但**不做**大幅重排；只处理 RecentContentHome.swift 内的列表行。

## 完成判据

1. 时间线与最近想法的每一条记录都有可见卡片边界，相邻条目肉眼可区分；浅色与深色主题下均成立。
2. 选中态、键盘（上下键）导航、滚动恢复、`recent.item`/`recent.thought` 标识与点击行为不回归。
3. `swift build -j 2` / `swift test -j 2` 真实退出码 0（先 merge main，基线 615 项）。
4. 纯布局改动，不加单测；由协调方安装后截图比对浅色/深色两种主题。
5. 结果里给出改动清单（file:line）与设计取舍一句话说明。

## 文件所有权

- `Sources/VoiceOSApp/RecentContentHome.swift`
- 不碰其他文件（如确需主题 token，先报告再动 `WorkspaceTheme.swift`）。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；不重启应用；不 push、不合并；完成直接提交到 `work/m74-homecards`。
- 分支 `work/m74-homecards`，提交回报。

## 结果

- 分支：work/m74-homecards（基于 main fda2cc3，merge main 退出码 0，已是最新）。
- 代码提交：3fa7e87「feat(首页): 时间线与最近想法条目加卡片边界与分组标记」。
- 改动：`Sources/VoiceOSApp/RecentContentHome.swift` 单文件。
  - 新增文件私有 `homeCard(isSelected:)` 修饰符（`HomeCard` 在 738 行，`View` 扩展在 753 行）：背景 `palette.surface`、描边 `palette.border` 1 点、圆角 `WorkspaceMetrics.controlRadius`（8）、内边距水平 12 垂直 10；选中时背景换 `palette.selection`、描边换 `palette.focusRing`，不再叠加普通描边。
  - 时间线（104-124 行）：日期组改为组头与行列表两层，组头到首行 6、行间 8（组间仍 18）；组头抽为 `dayHeader`（146 行），左侧加 2×12 accent 竖条，保留 isHeader 语义。
  - 最近想法（514 行起）：每条 entry 套 `homeCard(isSelected: false)`，entry 间距 8、entry 内两行间距 4、分组标题与首个卡片 6；整组结束线上边距 4 → 8。
  - 未改 identifier（`recent.item`、`recent.thought`）、键盘导航、滚动锚点、选中逻辑、reader 区与文案。
- 验证：build_exit=0（`swift build -j 2`，108.25 秒）；test_exit=0（`swift test -j 2`），615 项测试 0 失败，与基线一致。构建与测试共用 `/tmp/voiceos-swift-build.lock`，结束后已释放。未加新测试（纯布局改动，无纯逻辑可测）。
- 判据落点：
  - 判据 1：时间线与最近想法每条记录均有 surface 背景加 border 描边卡片，条目间距 8；浅色与深色均取 `WorkspaceTheme.swift` 既有 token，canvas 与 surface 已有对比。实机截图比对留协调方。
  - 判据 2：`.id(item.id)` 锚点、Button 选中、方向键与 Return 处理、两个 identifier 均未改动；选中态观感与原行为一致（selection 背景 + focusRing 描边）。
  - 判据 3：见「验证」。
  - 判据 4：纯布局改动；未重启应用，浅色/深色实机比对由协调方安装后执行。
  - 判据 5：改动清单与取舍见本结果。
- 设计取舍：未选中行用 `palette.surface` 而不是 selection 系做底，边界完全交给 1 点 border，选中态复用既有 selection + focusRing，避免卡片与选中各加一层描边让选中变重。
- 遗留风险：
  - 深色主题下 surface（0x272727）与 canvas（0x1E1E1E）明度差小，卡片边界主要由 border（0x4A4A4A）承担，实机观感待协调方截图确认。
  - 时间线宽 264，每行水平内边距从 10 增到 12，标题可用宽度少 4 点，折行可能略增（两行上限不变）。
  - 选中行与未选中行只差背景与描边颜色，快速扫视时选中对比弱于旧版「透明行仅选中着色」；若实机觉得弱，可后续单独调 selection 透明度，不改本轮结构。

