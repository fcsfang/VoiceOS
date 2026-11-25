# 2026-11-25 UI 第二波：次级页面与令牌一致性

分支 `ui-wave2-20261125`，基于 main（C 档合并后 5885065）。发现阶段用两个只读审查者：次级页面/弹层的容器语言、绕过设计令牌的硬编码。

## 本波实现（取影响大、成本小）

- `WorkspaceSection` 去掉卡片外壳与 19pt accent 图标，改为画布上的标题+计数/轻按钮+发丝线，与 `WorkspaceListSection` 同一平面。影响主题详情（相邻主题、值得继续的问题、待跟进、已完成、探索意图、AI 交付、认识与实践）、周回顾 9 段、启动详情、问题回答、复核、主题认领等 23 处调用；`icon:` 参数全部删除。
- 主题详情「值得继续的问题」：每题一张卡 → 行（10/12 内边距，hover/键盘高亮用 controlRadius 行底色，聚焦环只在聚焦时出现），行间发丝线；标题 medium。
- 主题详情「内容结构」根节点：selection 填充色带 → surface + 边框，未选子主题时用 focusRing 标示当前；子主题 hover 改 palette.hover。
- 一面一个主按钮：
  - 主题详情无小主题时，「补齐正文」只在准备卡里作为主按钮，顶部 banner 不再重复。
  - 材料详情转写失败时「重试本地转写」为主按钮，「重新识别/允许云端并重新识别」降为次按钮（新增 `retryOffersPrimary`）。
- 编辑弹层（编辑行动、编辑笔记）：标题 sectionTitle、错误 palette.danger、取消 secondary / 保存 primary、24 内边距、workspaceModalSurface。
- 原始系统色 → 调色板：PausedActionBatchControl 11 处、周回顾、观点笔记计数、计划候选勾选框共 14 处 `.secondary` → `palette.secondaryText`；侧边栏选中底 `Color.primary.opacity(0.12)`/6 → `palette.selection`/chipRadius。
- 弹层宽度令牌化：10 处 600/620/640/650/680/1020 → modalSmall/Medium/Large。

## 留待后续（已评估，未做）

- 材料详情 SourceFold/SourceSection 嵌套卡片（盒中盒）：结构改动大，需单独一波截图验证。
- 处理情况页：每个小组 warning 计数胶囊、行尾重复「查看材料」：涉及较多行原语替换。
- 监测页 QQ 环境检查列表折叠为单行、来源行降噪。
- padding 字面量 537 处：需先定规则（如 20=卡内水平边距），不逐个替换。
- 图标尺寸缺令牌（18/19/21/28）：可加 `WorkspaceText.icon`。

## 结果

- build_exit=0；test_exit=0（592 tests）；dist_build_exit=0。
- 隔离实例（/tmp/voiceos-wave2-data）截图：主题详情相邻主题与「值得继续的问题」在画布上成列表、内容结构根节点为描边。
- 深色模式：`-AppleInterfaceStyle Dark` 启动参数对此应用无效，本波未截深色；对比度已在 C 档按三主题深色值计算过。
