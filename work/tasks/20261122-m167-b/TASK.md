# 167-B 消息监测测试套件缩减（9 个文件）

## 背景
同 167-A：用户要求缩减测试规模。只允许表驱动折叠（全部案例作为数据行保留）或有对应测试引证的重复删除；生产代码零改动。禁止碰 MessageMonitorStorageChecks（存储安全）。

## 文件清单（只允许动这些）
- Tests/VoiceOSCoreTests/MessageMonitorRunnerChecks.swift
- Tests/VoiceOSCoreTests/MonitorEvidenceChecks.swift
- Tests/VoiceOSCoreTests/MonitorItemsPresentationChecks.swift
- Tests/VoiceOSCoreTests/MonitorOpenItemsSummaryChecks.swift
- Tests/VoiceOSCoreTests/MonitorPushChecks.swift
- Tests/VoiceOSCoreTests/QQMonitorChecks.swift
- Tests/VoiceOSCoreTests/QQConversationsChecks.swift
- Tests/VoiceOSCoreTests/QQPythonProbeChecks.swift
- Tests/VoiceOSCoreTests/WebsiteMonitorChecks.swift

## 目标
- 测试函数总数减少 ≥25%，覆盖不降（见 167-A 的两种允许方式）。
- 优先点：Runner/Evidence/ItemsPresentation 中同一 monitor 结果对象的多断言拆分；QQ 三套件中重复的会话解析与路径探测案例；Push 的格式化矩阵改成表驱动。

## 验证
- 每个改动文件 `xcrun --sdk macosx swiftc -parse` 退出码 0；不跑 swift test。
- 回报：前后函数计数、折叠形态、删除项对应测试名、parse 退出码、diff --stat。