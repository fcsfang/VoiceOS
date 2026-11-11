---
status: started
started: 2026-11-11
updated: 2026-11-12
branch: work/menubar-logo
pr: 131
owner: coordinator
---
# 菜单栏标志：无底色的 V

## 目标

应用标志已进入侧栏与 Dock，用户要求菜单栏也换成同一套 LOGO，并明确只要没有底色的核心 V，而不是整块图标。

## 决定

- `MenuBarExtra` 在这台系统上只接受系统符号 label，自定义 label 创建不出状态项，改用 `NSStatusItem` 加 `NSMenu`。
- 菜单图标从浅色标志的墨色推导成模板遮罩（`MenuBarMark.derive`，亮度到透明度并按笔画裁剪），模板渲染由系统按菜单栏颜色着色，不再按浅色/深色切换素材。
- 菜单承接原三项：口述开关（打开菜单时按当前模型状态刷新标题与可用性）、打开 VoiceOS、退出 VoiceOS。
- 窗口关闭后 SwiftUI 场景实例不存在；`NSWorkspace.openApplication` 与自发 Apple Event 都不重建，改为 `/usr/bin/open -a <bundle>` 发出 LaunchServices 打开请求。

## 范围

- `Sources/VoiceOSCore/MenuBarMark.swift`：遮罩推导纯函数。
- `Sources/VoiceOSApp/AppBrand.swift`：`menuBarImage()` 生成模板 V。
- `Sources/VoiceOSApp/VoiceOSApp.swift`：移除 `MenuBarExtra` 与三个菜单栏视图，`ApplicationDelegate` 建立状态项与菜单。
- `Tests/VoiceOSCoreTests/MenuBarMarkChecks.swift`：4 项推导测试。

## 非目标

- 不做可配置图标或在设置里开关菜单栏项。
- 不改口述、开窗、退出三个动作本身的行为。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 95 项 0 失败。
- 探针实验：`NSStatusItem` 装图块正常显示；`MenuBarExtra` 的自定义 label 系列（图块、模板图、原色符号、纯文本）全部无状态项，系统符号正常。
- dist 隔离实例：菜单栏出现黑色 V、无底色（截图）；菜单四项标题与可用状态正确；关窗后「打开 VoiceOS」把窗口调回；「退出 VoiceOS」退出进程。
- 深色菜单栏未能在本机截到，菜单栏跟随壁纸颜色，系统切深色时栏仍为浅色；白 V 由系统模板着色机制推断。
- 两实例并存时辅助功能读取状态项坐标为 -1，单实例为真实坐标。

## 进展

- 2026-11-11 `MenuBarExtra` 自定义 label 版本完成并开 PR #131，实机无图标。
- 2026-11-12 用户明确只要无底色的 V；探针定位 `MenuBarExtra` 限制后改用 `NSStatusItem`/`NSMenu` 与模板遮罩，补齐窗口重建与验证。
