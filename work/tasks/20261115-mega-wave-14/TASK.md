---
status: done
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-14
owner: coordinator
---

# 并行大波第十四批（清差距 4 到 12）

## 目标

按 `docs/product/interface-reference.md` 差距 4 到 12 收口。差距 11（系统焦点效果）按文档决定保留现状并记录理由。基线 `main` 为 `fc7e5a5`，321 项测试。

## 单元

### U1 外壳与设置页
文件：`Sources/VoiceOSApp/WorkspaceView.swift`。
- 差距 5：侧栏底部移除全宽「记录想法」主按钮；主操作移到页头右侧为强调胶囊（图标 + 记录想法，28 到 32 高）；侧栏底部只留设置。
- 差距 8：设置页「键盘快捷键」之后新增「再看一次引导」按钮，调用模型的 `onboardingRequested` 开关（U3 提供）。
- 差距 9：消费 `WorkspaceRoute.discussion`（U3 新增），调用既有 toggleDiscussion。
- 差距 10：本文件内固定宽 sheet（安排今天 560、选择清单 440）改 `minWidth/idealWidth` 与可拉伸高度。
- 差距 12：面包屑只在多级路径（材料、任务、交付详情）显示；设置、主页、搜索等单级页不显示。

### U2 主题、对比度与提示
文件：`Sources/VoiceOSApp/WorkspaceTheme.swift`、`Sources/VoiceOSApp/WorkspaceDesign.swift`。
- 差距 4：移除显示模式三选一的实现依赖；调色板只按系统外观（NSApp.effectiveAppearance）；保留石墨与鼠尾草两套主题色。设置页里的 Picker 由 U1 删除。
- 差距 7：读 `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`，为 true 时 secondaryText 提到 0.85、border 加深、禁用文字提高对比；两主题都覆盖。
- 差距 6：`workspaceToast` 去掉 2.5 秒自动消失，改为常驻浮层带关闭按钮，直到关闭或被下一条替换；过渡保留。

### U3 菜单命令与引导开关
文件：`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/Onboarding.swift`。
- 差距 9：`WorkspaceRoute` 增加 `.discussion`；View 菜单（或现有 CommandGroup）新增「讨论」命令，动作设置该路由并激活主窗口。
- 差距 8：`ControlCenter` 新增 `@Published onboardingRequested: Bool`；Onboarding presenter 在其为 true 时显示引导并复位；`完成`/`跳过` 写回既有 UserDefaults 键。

### U4 交付结果 sheet
文件：`Sources/VoiceOSApp/OutcomeFollowupView.swift`。
- 差距 10：固定宽 820 改 `minWidth 680 / idealWidth 820`，允许窗口拉伸。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机：设置页无显示模式三选一、有「再看一次引导」；页头有记录想法主按钮；面包屑单级不显示；sheet 可拉伸；主菜单有讨论命令。截图留档。

## 已知边界

- 提高对比度按启动时读取，系统设置运行中切换需重启生效。
- 差距 11 保留自定义焦点环，理由与 HIG 允许的例外一致（列表键盘光标需要自定义高亮）。
- 外观仅跟随系统，用户偏好固定明暗需等真实反馈再议。

## 结果

2026-11-15 四条线集成到 `work/mega-14`：U1 `6ab5fd0`，U2 `fb92823`，U3 `4d2a41b`，U4 `66b1c0f`；协调者补 `20c42aa` 清理 `WorkspaceAppearance` 残留（`AppBrand.applyApplicationIcon()` 改跟随系统外观）。

U4 的初版只换 min/ideal 尺寸，实机验证不通过：sheet 窗口 `AXSize` 不可设（err=-25200），拖拽边缘与角落均无尺寸变化，SwiftUI `.sheet` 在 macOS 上不响应拉伸。按 HIG「支持调整大小」补 `workspaceResizableSheet()`（sheet 窗口补 `.resizable` 掩码 + 最小尺寸），`5dad876`。复测 `AXSize` 可设，重设到 1200×723 布局正常。参考文档差距 10 已记录做法与 400 宽表单保持固定尺寸的取舍。

`swift build -j 2` 通过；`swift test -j 2` 321 项 0 失败。

实机（`dist/VoiceOS.app`，独立启动）：设置页外观只有石墨/鼠尾草两张主题卡、无显示模式三选一；「再看一次引导」可重新打开引导；页头为强调胶囊「记录想法」，侧栏底部只剩设置；材料详情页显示「材料 / 标题」面包屑、设置与列表页不显示；View 菜单首项为「讨论」；交付结果 sheet 78 项，重设尺寸后列表与页脚布局正常；提示条「已保存视图」6 秒后仍在、✕ 可关闭。测试用的视图已删除。

## 链接

- `docs/product/interface-reference.md` 第 4、5 节
