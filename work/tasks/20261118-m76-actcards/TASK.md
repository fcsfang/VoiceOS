# 波 76 任务书（2026-11-18）：行动页列表卡片化

## 背景（实机走查 2026-11-18，波 75 后）

行动页（`WorkspaceView.swift` 的 actions section）仍是文字墙：圆形完成控件 + 标题 + 来源副标题逐行直排，行间靠 `WorkspaceListDivider` 细线。首页（波 74）与材料页（波 75）已卡片化，行动页是同一渲染文件的最后一处大面积列表。

## 设计（与波 74/75 同一语言）

1. `actionRow(...)` 行改为卡片：`palette.surface` 底、`palette.border` 1 点描边、圆角 `WorkspaceMetrics.controlRadius`；键盘高亮/焦点仍是 selection + focusRing。
2. 行动页各处 `ForEach` 列表（全部/我的待办/逾期/今天/之后/随时/待核对/已完成/历史记录等 actionRow 所在分组）行间距 8、移除行间 `WorkspaceListDivider`；`WorkspaceListSection` 面板结构保留。
3. 已使用 `WorkspaceRow` 的分组（若行动页内存在）不强制改样式；本轮只卡片化 `actionRow` 渲染路径与其直接所在的 ForEach。
4. 不改文案、identifier、键盘导航、批量选择（selectingActions）、context menu、完成控件与数据逻辑；不改材料页（波 75 刚交付）。
5. 圆角与描边 token 与波 75 完全一致；不新增字面量。

## 完成判据

1. 行动页各筛选下每条行动为独立卡片，相邻条目肉眼可区分；完成控件、标题、来源副标题、状态徽标层次不变。
2. 键盘上下选择、批量选择、右键菜单、点击打开全部不回归。
3. `swift build -j 2` / `swift test -j 2` 真实退出码 0（先 merge main，基线 615 项）。
4. 纯布局改动，不加单测；结果给改动清单（file:line），协调方安装后截图比对。
5. 结果补记进任务书 `## 结果`。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceView.swift`（actionRow 与行动页各 ForEach 的最小增量）
- 不碰其他文件。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；不重启应用；不 push、不合并。
- 分支 `work/m76-actcards`，提交回报。

## 结果

- 分支：work/m76-actcards（基于 main bdd5e01；merge main 退出码 0，已是最新）。
- 代码提交：e81e1d3「feat(行动页): 行动列表改为卡片边界并去掉行间分隔线」。
- 改动：`Sources/VoiceOSApp/WorkspaceView.swift` 单文件，40 增 15 删。
  - `actionRow`（1996 行）尾部删除旧的 selection/clear 底与 focusRing 覆盖层，改为 `materialCard(highlighted: keyboardHighlighted)`（2029 行），复用波 75 的 `MaterialCard`（2808 行），surface 底、border 1 点描边、`WorkspaceMetrics.controlRadius` 圆角；高亮时背景换 selection、描边换 focusRing。
  - 新增文件私有 `ActionCardList`（2849 行）：`VStack(alignment:.leading,spacing:8)` 加 `.padding(.top,8)`，是行动页卡片行距的唯一来源。
  - 行动页九处 `actionRow` 分组改用 `ActionCardList` 并移除行间 `WorkspaceListDivider`：专注（1173 行）、逾期（1184 行）、今天（1191 行）、即将（1198 行）、随时（1205 行）、我的待办与各筛选的 listed（1216 行）、需要核对（1223 行）、问题（1232 行）、目标（1246 行）。
  - 保留的分隔线：今日阅读（930 行）、系统整理的建议 `suggestionRow`（1263 行）、AI 助理工作 `executionRows`（1392 行）。`WorkspaceListSection` 与 header 结构未动。
  - 未改文案、identifier、键盘导航、批量选择（selectingActions）、context menu、完成控件与数据逻辑；材料页 `materialCard` 调用点（966 行）未动。
- 验证：build_exit=0（`swift build -j 2`，108.91 秒）；test_exit=0（`swift test -j 2`），615 项测试 0 失败，与基线一致。两者共用 `/tmp/voiceos-swift-build.lock`，结束后已释放；`git diff --check` 退出码 0。未加新测试（纯布局改动）。
- 判据落点：
  - 判据 1：全部与我的待办（专注、逾期、今天、即将、随时）及问题、目标、已完成、历史等筛选中，每条行动经 `materialCard` 绘制独立卡片，行距 8；首卡与分区细线留 8，避免卡片描边与 header 细线贴成双线。
  - 判据 2：键盘高亮仍为 selection 底加 focusRing 描边；`WorkspaceActionRowChrome` 悬停菜单、`WorkspaceRow` 完成控件、`actionMenuItems`、`selectedActionIDs` 与 context menu 均未改。
  - 判据 3：见「验证」。
  - 判据 4：改动清单与 file:line 见上；实机截图比对留协调方。
  - 判据 5：本节。
- 设计取舍：复用波 75 `materialCard` 与既有 token，不新增圆角或描边字面量；行距 8 与材料页一致，首卡上留白取 8（材料页组头后为 6），因为 `WorkspaceListSection` 的 header 细线与内容之间没有额外间距。圆角从原高亮层的 `panelRadius`（12）改为 `controlRadius`（8），与首页、材料页卡片一致。
- 遗留风险：
  - `WorkspaceRow` 悬停底色圆角仍为 `panelRadius`（12），卡片圆角 8，悬停时四角可能外溢 1 到 2 点；与材料页同一现象，未改共享组件。
  - 批量选择态下卡片底色不变，仅靠行尾「已选」文字与图标区分，与波 74、75 行为一致；如观感偏弱可在后续波单独加强。
  - 深色主题下 surface 与 canvas 明度差小，边界主要靠 border；实机观感待协调方截图确认。
  - 「系统整理的建议」与「AI 助理的工作」仍为分隔线列表，按任务书本轮只卡片化 actionRow。
  - 分组面板（专注、逾期等）内卡片紧贴 header 细线下方 8 点，实机若觉得分组拥挤，可再调 `ActionCardList` 的顶部留白。
