---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-4
owner: coordinator
---

# 并行大波第四批

## 目标

四条互不重叠的线：处理情况页的重新核对入口、任务页重新跟进、迁移包 v50 补任务启动记录、捕获主流程的无障碍标签。App Intents 由协调者单独推进，因为构建脚本与 Intent 元数据处理需要反复编译验证，不放进写入代理。

基线 `main` 为 `877a147`，schema 60，262 项测试。

## 单元

### I1 处理情况页重新核对

文件：`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/ReverifyControls.swift`（新）、`Sources/VoiceOSCore/Store.swift`。

- `reverifySource` 接受 `quarantined` 来源：核对通过则置回 `saved`、清空 error、按需补建转写任务；失败保留隔离并写错误。
- 处理情况页新增「需要重新核对的原件」区块：列出 error 含「核对失败」的 saved 来源与全部 quarantined 来源，显示标题与错误；每条一个「重新核对」，成功移出列表并提示，失败就地显示错误。
- 区块为空时不出现。

### I2 任务页重新跟进

文件：`Sources/VoiceOSApp/WorkspaceActivityViews.swift`。

- 已放下（dismissed）行动的任务页提供「重新跟进」，确认弹窗说明历史保留，确认后走既有 `changeAction` 回到 open，可再撤销。
- 只改任务页，不动行动列表与键盘路径。

### I3 迁移包 v50

文件：`Sources/VoiceOSCore/PortablePackage.swift`、`Tests/VoiceOSCoreTests/PackageRoundTripChecks.swift`。

- 包版本 50：在 49 基础上加入 `task_initiations`（用户数据）。`panorama_*`、`search_index*` 属于派生数据，仍不导出。
- 恢复校验保持 1 到 50；旧 48、49 包可导入且 `task_initiations` 为空。
- 测试追加：v50 往返含一条任务启动记录；现有 49 夹具仍可恢复。

### I4 捕获主流程无障碍

文件：`Sources/VoiceOSApp/TextCaptureView.swift`、`Sources/VoiceOSApp/QuickNote.swift`、`Sources/VoiceOSApp/SelectionActions.swift`、`Sources/VoiceOSApp/FeynmanPractice.swift`。

- 图标按钮补 `accessibilityLabel`，纯文字按钮补必要的上下文说明（如「保存为模板」而不是「保存」），关键弹窗补标题层级。
- 不改布局、不改变行为、不动其他文件。VoiceOver 实机验证取不到时写明。

## 集成顺序

四条并行，文件互不重叠，一次集成。App Intents 另开分支与任务卡。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机用隔离副本：处理情况页出现待核对列表并可重新核对；已放下任务可重新跟进；v50 导出再导入后有任务启动记录；标签静态检查通过。
- 取不到的项目写明原因。

## 已知边界

- 重新核对成功只恢复原件状态与转写任务，已被冻结的认知不自动解冻。
- 任务启动记录只做导出恢复，不做跨库合并。
- 无障碍本批只覆盖捕获与复述主流程，其余页面留到下一批。

## 链接

- `docs/product/reference-products.md` 第 9.2、9.5 节
