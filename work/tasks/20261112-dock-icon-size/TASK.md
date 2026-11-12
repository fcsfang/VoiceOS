---
status: started
started: 2026-11-12
updated: 2026-11-12
branch: work/dock-icon-size
owner: coordinator
---
# Dock 图标尺寸：图块缩进到系统图标网格

## 目标

用户觉得 Dock 里的 VoiceOS 图标比旁边的应用图标都大。

## 决定

- 两张标志是全出血图块，直接当应用图标会顶满槽位，视觉上大于系统图标。按 Apple 图标网格把图块画进 91% 画布，可见方块约占画布 80.5%。
- 运行时 Dock 图标用 `AppBrand.dockTile` 合成，比例常量 `AppBrand.iconContentFraction`。
- 构建产出的 `AppIcon.icns` 用新脚本 `scripts/app/pad_icon.swift` 套用同一比例，Finder 与 Dock 一致。
- 菜单栏 V 与侧栏标志不受影响。

## 范围

- `Sources/VoiceOSApp/AppBrand.swift`：`dockTile` 合成与比例常量。
- `scripts/app/pad_icon.swift`：构建期缩进脚本。
- `scripts/app/build.py`：图标集改为从缩进后的母版生成。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 95 项 0 失败。
- dist 重建并重启应用，Dock 截图前后对比：V 图块从顶满槽位变为与旁边图标齐平并留边距。
- `AppIcon.icns` 转 png 确认同样留有画布边距。

## 进展

- 2026-11-12 完成，PR 待开。
