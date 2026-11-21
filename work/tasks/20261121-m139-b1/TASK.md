# 139-B1 周回顾 sheet 键盘导航

## 目标
周回顾 sheet 原先只能靠鼠标。把 sheet 内全部可打开行拼成一条扁平导航序：↑↓ 移动选择，Enter 执行该行的默认动作（与点击一致），选中行复用现有键盘选中背景与焦点环，并在选择变化时滚动到可见区域。

## 导航序
按 sheet 自上而下的渲染顺序收集，只收行渲染函数当前实际展示的条目：

1. 今天收尾：今日行 `dailyRow`（前 5 条），随后逾期行（前 5 条）
2. 下周先做：`nextWeekRow`（`nextWeekCandidates` 前 5 条），Enter 切换专注勾选
3. 长期未动：`reviewRow`（`staleTasks` 前 5 条）
4. 待确认：`reviewRow`（`unclarifiedTasks` 前 5 条）
5. 停滞目标：`stalledGoalRow`（前 5 条）
6. 留到以后：`somedayRow`（前 5 条）
7. 本周完成：`weekCompletedRow`（全部）
8. 本周结果：可打开任务行 `reviewRow`（前 5 条）；任务不可用时仅在有材料时入选，Enter 查看材料
9. 暂停与冻结：`reviewRow`（`pausedTasks` 前 5 条）

纯信息行、区块标题、「查看全部」「加入专注」等按钮不进入导航序，仍保持原有 Tab 可达性。前 5 条之后的条目与「还有 N 条」文案一致，不入选。

## 交互
- `ScrollViewReader` 内的 ScrollView 增加 `.focusable()`、`.focused($reviewListFocused)`、`.focusEffectDisabled()`、`.onKeyPress`，滚动结构与既有 modifier 不变。
- ↑↓ 由文件内私有 `ReviewKeySelection.step(up:over:)` 步进；无当前选择时 ↓ 从首行开始、↑ 从末行开始。按住重复仅对方向键生效。
- Enter 执行该行默认动作：打开详情、切换 «加入本周专注» 勾选、查看材料，与点击行体一致。
- 选中行背景 `palette.selection.opacity(0.5)`，焦点环调用 `workspaceFocusRing(_:radius:)`（139-A 共享实现），悬停仍走 `workspaceHoverHighlight`。
- `keyboardSelection.id` 变化时 `proxy.scrollTo(id, anchor: .center)`。
- 打开后 100ms 请求容器焦点，与 `requestActionListFocus` / `requestMaterialListFocus` 一致；未安装 NSEvent monitor。

## 行标识
`reviewRowID(section:id:)` 是唯一入口：普通行为 `review.nav.<section>.<id>`；已完成行沿用 `review.pending.<id>`，与摘要「待补结果」的滚动锚点共用同一 id，不新增锚点。各行渲染函数新增 `highlighted: Bool`，只负责视觉。

## 保持不变
- 行内按钮的点击行为与全部无障碍标签。
- 「加入本周专注」的开关与上限逻辑：行点击体抽成 `toggleNextWeekSelection`，按钮与 Enter 共用。
- 未安装 NSEvent monitor；搜索页的 monitor 仍明确跳过 sheet。

## 风险
- 容器本身新增一个 Tab 停靠点；行内按钮仍是各自的 Tab 停靠点，Tab 顺序与行为不变。
- 行按钮持有键盘焦点时，Enter 由按钮原生处理；方向键需容器持有焦点，与现有行动页、材料页一致。
- 切换下周专注后已专注行会排到前面，选择跟随行 id 而非序号；重排不会重复触发 scrollTo。
- 行条目可能在操作后消失（完成、放弃）；旧选择 id 不在导航序时方向键重新落到首/末行，Enter 忽略。

## 验证
未运行 `swift build` / `swift test`（任务约束）。对改动文件运行 `xcrun swiftc -parse`，通过（exit 0）。