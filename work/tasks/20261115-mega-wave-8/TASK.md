---
status: merge-ready
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-8
owner: coordinator
---

# 并行大波第八批

## 目标

三条线：材料页双语对照（按需、标注 AI 译文、不覆盖原文）、地点提醒写入（EventKit 结构化地点）、意图开始口述。基线 `main` 为 `66d1b2d`，schema 60，包格式 51，278 项测试。

## 单元

### M1 双语对照

文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSApp/BilingualView.swift`（新）、`Sources/VoiceOSCore/Bilingual.swift`（新）、`Tests/VoiceOSCoreTests/BilingualChecks.swift`（新）。

- 纯函数：把原文按现有 span 或句子切成段落（上限 40 段、6000 字，超出截断并提示「已截断，分批查看」），组装翻译请求与拼接结果。
- 材料页加「译文对照」入口：手动触发，调用已配置文本模型（读现有 ModelPort/LocalTextModel 的文本入口，最小实现）；结果按段并排显示，明确标「AI 译文，仅供参考」；加载中、失败、未配置模型三种状态处理；生成结果只存视图会话，不落库，不覆盖原文。
- 测试：段落切分边界、截断提示、请求组装与结果拼接。

### M2 地点提醒写入

文件：`Sources/VoiceOSPlatform/NativeReminders.swift`、`Sources/VoiceOSApp/ReminderSettingsView.swift`、`Tests/VoiceOSCoreTests/ReminderLocationChecks.swift` 追加。

- 提醒设置加「地点提醒」：开关 + 地点名称输入（能拿到 MapKit 本地搜索就提供候选，取不到就纯文本名称），proximity 固定为到达（enter）。
- 写入：EKAlarm structuredLocation（title 用名称，geolocation 可空）追加到既有 alarms 之外，不影响日期/时刻与其他 alarms；关闭开关移除地点 alarm；保存失败就地显示错误。
- 纯函数 `locationSpec(title:proximity:)` 组装与校验（空名、超 120 字），配测试。
- 只读回读行保持现状。

### M3 意图开始口述

文件：`Sources/VoiceOSApp/AppIntents.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`。

- 新增 `ToggleDictationIntent`（「开始或停止口述」），openAppWhenRun true；端点协议加 `toggleDictation()`；delegate 就绪等待后调用 `ControlCenter.primary.canToggleCaptureDictation` 与 `toggleCaptureDictation()`，返回 Bool；dialog 显示「口述已开始」或「口述已停止」。
- 既有三个意图与文案不变；元数据步骤自动覆盖新意图。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机：材料页译文对照的未配置与成功两态、地点提醒写入与回读、意图元数据含四个意图。
- 取不到的项目写明原因。

## 已知边界

- 译文不落库、不缓存跨会话；不覆盖原文。
- 地点搜索依赖系统能力，取不到时纯文本名称。
- 口述意图只做开始/停止，不做参数化。

## 结果

2026-11-15 三条线集成到 `work/mega-8`：M1 `db48fcb`，M2 `88ee529`，M3 `3d146b3`；协调者修正译文模型名从配置读取。

`swift build -j 2` 通过（EventKit 的 `EKAlarm()` 与 `EKStructuredLocation()` 默认构造通过类型检查）；`swift test -j 2` 299 项 0 失败（新增双语切段 14 项、地点校验 7 项）。

实机：锁屏，材料页译文对照两态、地点提醒写入回读与意图口述不可得；元数据步骤在合并后发行构建中验证四个意图。

## 链接

- `docs/product/reference-products.md` 第 9.3、9.4、9.2 节
