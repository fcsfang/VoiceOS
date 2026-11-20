# 波 110-B：动画减少动态效果门控

## 背景

按 ui-ux-pro-max SwiftUI 规则审计，波 110 拆出 18 处未门控动画。本单元覆盖 WeeklyReviewView、WorkspaceDiscussionView、TaskInitiationView、WorkspaceReadingViews 四个文件，共 10 处动画；行为、文案与 identifier 不变。行号为修复前位置。

## 逐条修法

### 1 WeeklyReviewView
- 位置：`Sources/VoiceOSApp/WeeklyReviewView.swift:137`（撤销条出现）、`:142`（8 秒自动消失）、`:181`（汇总链接滚动定位）、`:328`（完成或不再跟进后撤销条出现）、`:340`（撤销清除）、`:621`（结果行展开收起）、`:652`（保存结果后收起）。
- 修法：结构体加 `@Environment(\.accessibilityReduceMotion) private var reduceMotion`。`.animation` 改为 `reduceMotion ? nil : .easeOut(duration: 0.2)`。已有显式曲线的滚动定位沿用 `.easeInOut(duration: 0.2)` 并加门控。裸 `withAnimation` 统一补 `.easeOut(duration: 0.2)`。

### 2 WorkspaceDiscussionView
- 位置：`:122-123` 回复数与轮次数变化后自动滚到底部。
- 修法：结构体加环境值。两处改为 `withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2))`，减少动态效果时无动画滚动。

### 3 TaskInitiationView
- 位置：`:73` 选择记录后滚动到启动材料。
- 修法：结构体加环境值，改为 `withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2))`。

### 4 WorkspaceReadingViews
- 位置：`:129` `WorkspaceListSection` 折叠区展开与收起。
- 修法：`WorkspaceListSection` 加环境值，沿用 `.easeOut(duration: 0.16)` 并加门控。

### 复核
对四个文件执行 `grep 'withAnimation\|\.animation('`，全部命中行均含 `reduceMotion`。无遗漏，无重复门控。

## 构建与测试

按任务给定的共享锁门执行，真实退出码如下。

- `swift build -j 2`，`build_exit=0`
- `swift test -j 2`，`test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 50.331 (50.399) seconds`

首次执行等待共享构建锁 10 分钟超时（`exit 3`，未启动构建）；锁释放后重跑得到以上结果。

## 风险

- 裸 `withAnimation` 原本使用系统默认动画，门控后开启动效时统一为 `.easeOut(duration: 0.2)`，与同文件已有撤销条动画节奏一致，属于轻微观感变化。
- 只过编译与单元测试。减少动态效果的实机表现未验证（任务禁止重启应用）。

## 约束

只改四个源码文件；不写实时库、不重启、不 push、不合并。