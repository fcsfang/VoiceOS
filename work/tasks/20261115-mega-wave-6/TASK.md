---
status: merge-ready
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-6
owner: coordinator
---

# 并行大波第六批

## 目标

三条线：重复任务与提醒事项的联动语义与撤销级联（含意图冷启动就绪）、产品文案与可发现性十条、迁移包 v51 全景表。基线 `main` 为 `495b756`，schema 60，264 项测试。

## 单元

### K1 重复×提醒×撤销

文件：`Sources/VoiceOSCore/RemindersStore.swift`、`Sources/VoiceOSCore/RemindersAccess.swift`、`Sources/VoiceOSApp/UndoSupport.swift`、`Sources/VoiceOSCore/ActionUndoStack.swift`、`Sources/VoiceOSCore/Recurrence.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/WorkspaceActivityViews.swift`、`Sources/VoiceOSApp/AppIntents.swift`、`Tests/VoiceOSCoreTests/RecurrenceChecks.swift` 与 `ActionUndoStackChecks.swift` 追加。

- 提醒事项完成：`applyReminder` 的完成分支提交后调用 `completeActionWithRecurrence`（alreadyCompleted 分支），外部勾完也生成下一次。
- 标题屏障：`activateExtractedTasks` 对 `command_id` 前缀 `recurrence:` 的行动豁免同标题过滤，后继可同步到提醒事项。
- 撤销级联：`ActionUndoEntry` 增可选 `successorID`；撤销完成或重新跟进时，若后继仍 open、version 1 且未被改动，事务内删除后继并把 `action_recurrence` 行移回原行动；否则保留后继并在提示里说明。任务页完成提示与撤销条显示「下一次 11-22」。
- 意图冷启动：端点等待 `ControlCenter.primary.initialized`，最多 8 秒（100ms 轮询），超时回「资料库正在打开，请稍后重试」。
- 测试：撤销级联删除后继并恢复序列；重新跟进同路径；标题屏障豁免。

### K2 产品文案与可发现性

文件：`Sources/VoiceOSApp/WorkspaceView.swift`、`Onboarding.swift`、`ReminderSettingsView.swift`、`Sources/VoiceOSCore/ReminderFields.swift`、`ReverifyControls.swift`、`WorkspaceProcessingView.swift`、`WeeklyReviewView.swift`。

- 行动列表底部常驻提示「↑↓ 选择 · ↵ 打开 · x 完成 · z 不再跟进 · ⌥⌘Z 撤销」。
- 引导第 3 步补 x/z/⌥⌘Z/⌘⇧R；设置页新增「键盘快捷键」小节列全量。
- 仅日期通知文案改「仅日期任务固定 09:00 提醒（当前不可关闭）」；任务页摘要标「默认 09:00 提醒」。
- 恢复核对成功文案带下一步，行内加「打开材料并重新识别」按钮；处理情况页改为一行交叉引用，不重复列出。
- 每周回顾行内提示可在任务页撤销。
- 不改行为与布局结构，只改文案与提示。

### K3 迁移包 v51 全景表

文件：`Sources/VoiceOSCore/PortablePackage.swift`、`Tests/VoiceOSCoreTests/PackageRoundTripChecks.swift`。

- 包版本 51：加入全景六表（以 `Database.swift` 实际表名为准：`panorama_attempts`、`panorama_steps`、`panorama_theme_replies`、`panorama_themes`、`panorama_theme_batches`、`panorama_theme_appearances`），按实际主键登记身份键；`search_index*` 仍不导出。
- 旧 48/49/50 包可导入，全景表为空。
- 测试：v51 往返含一条全景尝试与主题；49 夹具仍可恢复。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机：提醒事项里完成重复任务后出现下一次且可同步；撤销完成收回下一次；列表提示与设置快捷键小节可见；v51 包往返。
- 取不到的项目写明原因。

## 已知边界

- 撤销级联只在后继未被改动时收回；改过的后继保留并在提示说明。
- 提醒事项仍不显示为重复系列，重复只在 VoiceOS 内推进。
- 文案改动不做 VoiceOver 实机走查。

## 结果

2026-11-15 三条线集成到 `work/mega-6`：K1 `c2cb453`，K2 `d29b821`，K3 `1a07ce7`；主干并入 `1abb7d2`（含第五批急修 PR #164）。

集成期修复：级联恢复里 `??` 右侧的抛出表达式、编译错误收尾。

`swift build -j 2` 通过；`swift test -j 2` 270 项 0 失败（新增撤销级联收回、后继保留、标题屏障豁免、v51 往返等 6 项）。

实机：机器锁屏，提醒事项内完成重复任务的实机勾选、列表提示与设置快捷键小节目视不可得；联动逻辑由存储测试与代码审查覆盖。

## 链接

- `docs/product/reference-products.md` 第 9.2、9.4、9.5 节
