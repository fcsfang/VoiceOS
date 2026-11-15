---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-10
owner: coordinator
---

# 并行大波第十批（R4 余项）

## 目标

R4 代码复核剩余六条。基线 `main` 为 `ff47468`，307 项测试。

## 单元

### O1 地点提醒的 proximity 保留
文件：`Sources/VoiceOSApp/ReminderSettingsView.swift`、`Sources/VoiceOSPlatform/NativeReminders.swift`。
- 界面载入并回写 proximity（到达/离开分段选择），不再一律改写为到达；切换后保存与回读一致。
- 写入保持标题型 structuredLocation；界面注明「地点由系统按名称解析」，坐标解析不在本批。

### O2 构建与基线脚本护栏
文件：`scripts/app/build.py`、`scripts/perf/baseline.py`。
- build.py：进入元数据步骤前先删目标 Metadata.appintents；整段用宽异常捕获（Exception），失败只警告不阻断签名。
- baseline.py：open 测量加只读打开；search 重建只在脚本自建临时副本上执行，除非显式 `--allow-write`；拒绝直接对默认资料库写。

### O3 口述意图四态与等待语义
文件：`Sources/VoiceOSApp/AppIntents.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`。
- 端点返回 started/stopped/failed(reason)/notReady；前置条件不满足立即返回 failed 并给出具体 dialog；停止不强等封存但标注「正在停止」。

### O4 译文编号严格校验
文件：`Sources/VoiceOSCore/Bilingual.swift`、`Tests/VoiceOSCoreTests/BilingualChecks.swift`。
- 出现编号时必须恰为 1...count；0 基或混排判格式错误并提示重试；补 0 基与混排测试。

### O5 全景表恢复语义校验
文件：`Sources/VoiceOSCore/PortablePackage.swift`、`Tests/VoiceOSCoreTests/PackageRoundTripChecks.swift`。
- 恢复后在既有校验追加全景账本检查：theme_count 与出现记录数一致、JSON 数组可解码、引用的 claim/source 不存在时裁剪；坏包失败并回滚。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。

## 链接

- R4 复核报告；第九批任务卡
