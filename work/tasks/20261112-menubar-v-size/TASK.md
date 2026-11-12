---
status: merged
started: 2026-11-12
updated: 2026-11-12
branch: work/menubar-v-size
pr: 132
merged: 19b151a
owner: coordinator
---
# 菜单栏 V 尺寸：16 点调到 12 点

## 目标

用户看过合并后的菜单栏 V 后要求调为 12 点。

## 决定

- 只改 `AppBrand.menuBarImage` 的目标高度，宽度按遮罩宽高比自动等比。
- 遮罩推导、模板着色与菜单逻辑不动。

## 范围

- `Sources/VoiceOSApp/AppBrand.swift`：`height` 从 16 改为 12。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 95 项 0 失败。
- dist 重建后重启应用，菜单栏截图为更小的黑色 V；状态项宽度从 40 缩到 34，位置右移。

## 进展

- 2026-11-12 完成，合并 `19b151a`（PR #132）；dist 从合并后 main 重建。
