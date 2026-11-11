---
status: started
started: 2026-11-11
updated: 2026-11-11
branch: work/menubar-logo
pr: 131
owner: coordinator
---
# 菜单栏标志：用应用标志替换波形符号

## 目标

应用标志已进入侧栏与 Dock，用户要求菜单栏也换成同一套 LOGO，而不是系统的波形符号。

## 决定

- `MenuBarExtra` 改为自定义 label，使用 `AppBrand` 的浅色/深色图块，18pt；取不到 bundle 资源时回退波形符号。
- 菜单栏 label 按菜单栏自身的颜色方案选择，不跟随应用强制的浅色/深色设置。
- 菜单栏名称与无障碍标签保持 VoiceOS。

## 范围

- `Sources/VoiceOSApp/VoiceOSApp.swift`：`MenuBarExtra` 的自定义 label 与 `MenuBarBrandLabel`。
- 不改菜单内容、快捷口述项或应用标志资源。

## 非目标

- 不做菜单栏专用的单色模板；两张标志是完整图块，本轮按要求直接使用。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 91 项 0 失败。
- dist 构建后启动隔离实例。辅助功能树里 `menu bar 2` 有名为 VoiceOS 的菜单栏项，说明自定义 label 已创建。测试机的菜单栏已满（11 个状态项加刘海），该项被系统收进溢出区，位置为 -1，未能在截图里直接看到；同一 `AppBrand` 资源已在侧栏与 Dock 的浅色/深色截图中确认。
- 限制：菜单栏空间不足时系统会隐藏该项，需要用户收起其他状态项或通过菜单栏管理器展开。

## 进展

- 2026-11-11 自定义菜单栏 label 完成，构建与测试通过。分支 `work/menubar-logo`，PR 待审。
