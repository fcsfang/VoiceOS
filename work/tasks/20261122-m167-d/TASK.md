# 167-D 纯函数助手测试表驱动化（7 个文件）

## 背景
同 167-A。这一组是纯函数/映射的案例矩阵，最适合表驱动折叠：所有案例原样进入数据行，断言等价，函数数大幅减少。生产代码零改动。

## 文件清单（只允许动这些）
- Tests/VoiceOSCoreTests/MaterialTitleTextChecks.swift
- Tests/VoiceOSCoreTests/MaterialNamingChecks.swift
- Tests/VoiceOSCoreTests/WorkspaceTitleFitChecks.swift
- Tests/VoiceOSCoreTests/SnoozePresetChecks.swift
- Tests/VoiceOSCoreTests/ReminderDefaultAlertChecks.swift
- Tests/VoiceOSCoreTests/MarkdownTextChecks.swift
- Tests/VoiceOSCoreTests/BilingualChecks.swift

## 目标
- 七个文件合计测试函数减少 ≥40%；每个原案例必须以 (输入, 期望) 数据行保留，断言语义等价（包括 nil/空串/边界）。
- BilingualChecks 若含跨文件集成断言而非纯函数矩阵，只折叠纯函数部分，集成场景保留并可合并为少量流程测试。

## 验证
- 每个改动文件 `xcrun --sdk macosx swiftc -parse` 退出码 0；不跑 swift test。
- 回报：七文件前后计数、数据行数量、parse 退出码、diff --stat。