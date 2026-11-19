# 波 94 任务 A：行动链路的提醒状态与日期一眼可见

## 背景

用户点进材料要看到它带来的提醒；打开行动页要一眼看清每条提醒是什么、哪天该做、做没做、是否已写入提醒事项。发现者用真实数据证实：行动行只显示 linked 链路的到期，conflict/missing 的到期被吞；日期是 ISO 原文不可扫读；「全部」列表按创建时间升序把最旧的排最前。

## 改动

### Core（纯逻辑，可测）

- `Sources/VoiceOSCore/ActionRowStatus.swift:54` `ActionRowFacts.reminderLinkState`：最新观察的提醒链路状态（linked/conflict/missing），仅展示。
- `Sources/VoiceOSCore/ActionRowStatus.swift:56` `ActionRowFacts.reminderDue`：最新观察到的提醒到期。
- `Sources/VoiceOSCore/ActionRowStatus.swift:62` `ActionRowReads` 从 WorkspaceView 迁入 Core，放宽到全部链路状态，按 action 索引链路与最新到期；`linkedReminderByActionID` 仍是 linked-only，供「改天」可用性判断。
- `Sources/VoiceOSCore/ActionRowStatus.swift:111` `ActionRowLayout.status(_:now:calendar:)`：meta 优先级 完成时间 → 提醒链路 → 本地排期 → 来源。
- `Sources/VoiceOSCore/ActionRowStatus.swift:149` `reminderSummary`：组合「已写入提醒事项 · 明天」「提醒待核对 · 已逾期 11月18日」「提醒缺失」。
- `Sources/VoiceOSCore/ActionRowStatus.swift:166` `relativeDayLabel`：今天/明天/昨天/周X；超一周回退「M月d日」。
- `Sources/VoiceOSCore/ActionRowStatus.swift:180` `dueSummary`：本地排期行「到期 明天」/「已逾期 11月18日」。

### 行动页

- `Sources/VoiceOSApp/WorkspaceView.swift:1439` `todoOrder`：「全部」按 逾期 → 今天 → 即将 → 随时 → 无日期 排序；无日期按创建时间倒序。复用 `ActionTimeSurface`。
- `Sources/VoiceOSApp/WorkspaceView.swift:1189` 「全部」主列表使用该排序。
- `Sources/VoiceOSApp/WorkspaceView.swift:1251`、`:1265` 问题/目标预览可折叠且默认收起；`:1290` 完成后的结果去掉 `initiallyExpanded`；`:1299` AI 助理工作默认收起（原有 `collapsible`）。
- `Sources/VoiceOSApp/WorkspaceView.swift:1912` `actionRowStatus` 填入提醒链路字段；删除 `reminderDueIsPast`（逾期判定移到 Core）。

### 材料页

- `Sources/VoiceOSApp/WorkspaceSourceView.swift:547` 页面级 `reminderReads`。
- `Sources/VoiceOSApp/WorkspaceSourceView.swift:291` `relatedActionRow`、`:633`/`:665` 暂停行、`:751` 历史行补同样的提醒状态与相对日期；`:299`/`:302` 复用 Core 文案，不重复实现。

### 测试

- `Tests/VoiceOSCoreTests/ActionRowStatusChecks.swift:208` 今天、`:213` 明天、`:218` 逾期、`:223` 超一周。

## 验证（真实退出码）

- `swift build -j 2; echo build_exit=$?` → `build_exit=0`。首次构建在 `todoOrder` 链式表达式上类型检查超时，拆成显式子表达式后通过。
- `swift test -j 2; echo test_exit=$?` → `test_exit=0`，Executed 643 tests, with 0 failures（基线 639，本波新增 4）。

## 遗留风险

- 「已逾期」永远用绝对「M月d日」，即使只逾期一天。这是按用户示例「提醒待核对 · 已逾期 11月18日」定的；若希望「已逾期 昨天」，只改 `reminderSummary` 一处。
- 行动页的提醒链路只在 open+current 行展示；材料页暂停/历史行也会展示（按任务要求做只读展示）。
- 未做迁移、未改 schema、未碰同步写路径与状态机。
- 未重启应用、未做真实 GUI 验证；本波验证是构建加单测。
