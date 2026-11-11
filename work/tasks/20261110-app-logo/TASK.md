---
status: merged
started: 2026-11-10
updated: 2026-11-11
branch: work/app-logo
pr: 130
owner: coordinator
---
# 应用标志：浅色与深色两张 LOGO 接入

## 目标

用户提供两张 1254×1254 的应用标志，浅色是白底黑 V，深色是黑底白 V。当前应用没有应用图标，侧栏顶部也是波形占位。把两张标志接进 Dock 与应用内品牌位。

## 决定

- 标志是完整的圆角应用图块，不是字标；侧栏用 26pt 图块加「VoiceOS」，不再叠加波形符号。
- 运行时按外观选择：跟随系统时用窗口的实际外观，用户在设置里强制浅色或深色时用对应标志。应用图标也按同一规则切换，Dock 在浅色和深色下显示对应版本。
- 打包时从浅色标志生成多尺寸 `.icns` 作为 Finder 的默认图标，并把两张 PNG 复制进 `Contents/Resources`；Info.plist 写 `CFBundleIconFile=AppIcon`。
- 菜单栏快速入口继续使用波形符号，因为两张标志是完整图块，缩到菜单栏会变成小方块；本轮不改菜单栏。

## 数据形状

- `AppBrand`：按 `ColorScheme` 或 `NSAppearance` 读取 `VoiceOSLogoLight`/`VoiceOSLogoDark`；`applyApplicationIcon(preferred:)` 设置 `NSApplication.applicationIconImage`。
- `ApplicationDelegate` 在启动时设置一次，并观察 `NSApp.effectiveAppearance` 变化。
- 侧栏在出现与外观设置变化时同步应用图标。

## 范围

- `Sources/VoiceOSApp/AppBrand.swift`（新）、`VoiceOSApp.swift`（委托）、`WorkspaceView.swift`（侧栏与外观同步）。
- `scripts/app/build.py`：复制两张 PNG、生成 `.icns`、写图标键。
- `logo/voiceos-light.png`、`logo/voiceos-dark.png`（由用户提供的 1.png、2.png 重命名）。

## 非目标

- 不做菜单栏单色标志、About 面板定制或 Finder 的深色图标变体（标准 `.icns` 不随系统外观切换）。
- 不改窗口标题栏与文档图标。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 91 项 0 失败。
- dist 构建后 `AppIcon.icns` 含 16、32、128、256、512 与各自 @2x 共 10 个尺寸；`VoiceOSLogoLight.png`、`VoiceOSLogoDark.png` 在 `Contents/Resources`；Info.plist `CFBundleIconFile=AppIcon`。
- 隔离实例实机：浅色侧栏显示黑 V 与 VoiceOS，`/tmp/logo-light.png`；临时把外观设为深色后侧栏显示白 V，`/tmp/logo-dark-2.png`，随后恢复为 system。Dock 图标在浅色下是白底黑 V、深色下是黑底白 V，`/tmp/logo-full.png` 与 `/tmp/logo-dark-full.png`。
- 限制：菜单栏快速入口仍是波形符号（两张标志是完整图块，缩到菜单栏会变成小方块）；Finder 使用浅色 `.icns`，标准 `.icns` 不随系统外观切换。

## 进展

- 2026-11-11 标志接入侧栏与 Dock，浅色与深色实机核对完成。合并 `6fca1a5`（PR #130）；dist 从合并后 main 重建。
