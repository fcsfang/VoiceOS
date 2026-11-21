# 139-A 设计系统收敛（技术债审计 P1–P4）

## 背景
技术债审计把四处重复决策列为 P1–P4：每个页面各写一遍的慢加载 150ms 门控、五处手写的焦点环、首页两处手写发丝线，以及应用与只读库各写一遍的 manual→automatic 标题漏斗。目标是每个决策只有一个入口，行为与外观不变。

## P1 慢加载门控
新增 `View.workspaceSlowLoading(_:into:)`（`Sources/VoiceOSApp/WorkspaceDesign.swift`）。`task(id:)` 只在 `isLoading` 为真时睡 150ms；取消或状态已变则不置位；`isLoading` 为假立即复位。

替换点（`@State` 变量保留，行号为改动前）：
- `WeeklyReviewView.swift:148-152` `loadState == .loading` → `$showSlowLoad`
- `WorkspaceMonitorView.swift:105-109` `monitorLoadState == .loading` → `$showSlowLoad`
- `WorkspaceActivityViews.swift:828-832` `feedbackLoading` → `$feedbackPlaceholderVisible`
- `WorkspaceView.swift:662-666` `workspaceStarting` → `$showStartupProgress`
- `ReflectionGraphView.swift:172-176` `loading` → `$showSlowLoad`

等价性：150ms 睡眠、`Task.sleep` 取消即返回、置位前复查状态，与共享实现逐字一致；消费点未变。唯一行为差异是 `WeeklyReviewView` 原先在 `loadState` 离开 `.loading` 时不复位 `showSlowLoad`（陈旧 flag），新 modifier 在 `isLoading == false` 时复位。其余四处原实现已有复位。

## P2 焦点环
新增 `View.workspaceFocusRing(_:radius:)` 与私有 `WorkspaceFocusRing: ViewModifier`，从 `@Environment(\.workspacePalette)` 读取 `focusRing`，`strokeBorder` 线宽 1。

替换点（`WorkspaceView.swift`，行号为改动前；均为 `overlay { if … focusRing }` → `workspaceFocusRing(…)`）：
- 1346 `summaryPendingFocus`，`controlRadius`
- 1361 `summaryTodayFocus`，`controlRadius`
- 1662 `searchKeyboardFocus.id == rowID`，`panelRadius`
- 1691 `searchKeyboardFocus.id == row.id`，`panelRadius`
- 1834 `searchKeyboardFocus.id == suggestion.id`，`panelRadius`

未动：MaterialCard highlighted、HomeCard isSelected、TopicReading selected/focus 三元等混合语义样式；`WorkspaceView.swift:3348` 的 `highlighted ? focusRing : border` 也保留。

等价性：圆角、颜色、线宽与 overlay 层级相同；palette 由调用方传入改为从环境读取，渲染结果一致。

## P3 首页发丝线
- `RecentContentHome.swift:109` header 底边 `Rectangle().fill(palette.border).frame(height: 1)` → `WorkspaceListDivider()`，保留 `.overlay(alignment: .bottom)` 位置。
- `RecentContentHome.swift:711` → `WorkspaceListDivider().padding(.top, 8)`。
- `RecentContentHome.swift:65` 竖向分栏线保留，补注释说明它是竖向接缝，`WorkspaceListDivider` 只表达横向分隔。

等价性：`WorkspaceListDivider` 本身即 `Rectangle().fill(palette.border).frame(height: 1)`，颜色来自同一 palette；它额外设置 `accessibilityHidden(true)`，属装饰元素，外观零变化。

## P4 标题漏斗去重
`MaterialDisplayTitle` 新增 `explicitTitle(presentation:transcriptVersionID:) -> String?`：manual（trim 后非空）优先；automatic 需版本匹配且过 `MaterialTitleText.normalizedGenerated`；都不满足返回 nil。

调用方：
- `MaterialDisplayTitle.title` 的 manual→automatic 两段改为调用它（第三处，行为不变）
- `SourceRecord.contentTitle` 改为直接调用
- `ReadOnlyLibrary.displayTitle` 的 manual→automatic 两段改为调用；版本不匹配后的回退保持原状（`MaterialNaming.displayName` / `recordingFallbackTitle`）

测试：`MaterialTitleTextChecks` 新增 `testExplicitTitleSharesManualAndVersionCheckedAutomaticContract`（空白 manual 让位 automatic、跨版本拒绝、manual 跨版本仍优先、nil 输入）；`ReadOnlyLibraryChecks` 新增 `testDisplayTitleFunnelSharesExplicitTitleContract`（manual、匹配 automatic、过期 automatic 回退原名）。既有 ReadOnlyLibraryChecks 与 contentTitle 测试未改动。

等价性：两个漏斗原本逐字相同；`title` 的第三处调用是等价分支替换。版本匹配语义保留原先 `nil == nil` 的行为。

## 验证
未运行 `swift build` / `swift test`（任务约束）。对改动文件运行 `xcrun swiftc -parse` 语法检查，并用 `rg` 确认五处手写 150ms 门控、五处纯 focus ring overlay、首页两处手写横向发丝线均已消失。