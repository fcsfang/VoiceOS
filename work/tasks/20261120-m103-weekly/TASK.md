# 波 103-B：每周回顾页按钮与状态视觉统一

## 背景

每周回顾页此前仍用系统 `.bordered` / `.borderedProminent` 按钮、自拼 `WorkspaceHeading` 页头、手写 accent 文本按钮与 meta 状态文字，和波 102 已统一的工作台三页读起来不是一套语言。本波只改 `Sources/VoiceOSApp/WeeklyReviewView.swift`，行为、identifier、键盘与文案不变。

## 改动（行号为改前行号）

- 页头 L103-108：`WorkspaceHeading` + 裸按钮 → `WorkspacePageHeading(trailing:)`；认知地图 `workspaceSecondary`，关闭 `workspaceQuiet`，保留 `.cancelAction` 与 help 文案。
- L302-307：完成 / 不再跟进 `.bordered` small → `workspaceSecondaryCompact`。
- L429：加入专注 `.borderedProminent`（系统蓝）→ `workspacePrimary`。
- L749-757：恢复为目标、仍留到以后 → `workspaceSecondaryCompact`；放弃 → `workspaceDestructive`。
- L558 查看材料 → `workspaceSecondaryCompact`。
- L612-616 记录结果 / 收起 → 收起态（记录结果）`workspaceSecondaryCompact`，展开态（收起）`workspaceQuietCompact`。
- L707 加下一步 → `workspaceSecondaryCompact`。
- 手搓 accent 文本按钮（L175-181 summaryStat、L267-268 到行动页查看、L345-349 allButton、L415-416 与 L436-437 到行动页移出、L651-654 linkButton）→ `workspaceQuiet`；行内与摘要按密度用 `workspaceQuietCompact`。
- 行尾状态 → `WorkspaceBadge`：逾期 warning（L300）、已专注 accent（L474）、待补结果 warning（L603）、停滞 neutral（L699）、搁置/待确认/待核对/日期 neutral（reviewRow trailing，L795）。同状态的手写文字被 badge 替换，不再并存。
- 摘要统计条 L161-167：标题与数字拆成两段 Text，数字 `monospacedDigit`；不可点项 `WorkspaceText.meta` + secondary，可点项 `workspaceQuietCompact`。
- 撤销条 L352-371：保留自写容器，补 `shadow(.black 0.12, radius 12, y 4)`，圆角沿用 panelRadius（12），与 `WorkspaceToast` 规格一致。
- 九个 `WorkspaceSection` 调用不动（共享层已升级）。

## 验证

- `swift build -j 2`（共享锁）：build_exit=0。
- `swift test -j 2`（共享锁）：test_exit=0，Executed 661 tests, with 0 failures (0 unexpected)。
- 首次尝试因共享构建锁 10 分钟超时（LOCK_TIMEOUT，exit 3，未进入编译）；延长等待后锁空出，第二次完整通过。日志在 /tmp/m103-weekly-build.log 与 /tmp/m103-weekly-test.log。
- `git status` 确认只改 `Sources/VoiceOSApp/WeeklyReviewView.swift`。

## 取舍与风险

- 文案、accessibilityLabel、快捷键逐字保留；compact 按钮（9pt 横距 / 25pt 高）比系统 small 略收紧，行内宽度会小幅变化，属预期视觉差异。
- 该页没有 UI 快照或等价性测试，行为 pin 依赖构建、661 项既有测试与文案逐字比对；真机视觉效果仍需人工确认。
- 摘要里可点项与不可点项分别走按钮与 Text，颜色由共享样式提供；数字统一 monospacedDigit，避免计数变化时横向抖动。
- L117 错误态「重试」不在审计清单内，仍是系统 small 按钮，未改。
- 「逾期」分组小标题与行尾 badge 并存：小标题是分组标签，badge 是行状态，职责不同；同页没有新增其他 warning 文本写法。