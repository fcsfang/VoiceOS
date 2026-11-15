---
status: merge-ready
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-13
owner: coordinator
---

# 并行大波第十三批（按参照文档收口）

## 目标

按 `docs/product/interface-reference.md` 的高优先级差距与实机走查发现收口。基线 `main` 为 `86cb29c`，321 项测试。

## 单元

### W1 标题栏、搜索与列表行
文件：`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/WorkspaceDesign.swift`。
- 标题栏区整合：保留左侧返回与面包屑（详情页），去掉与页内 H1 重复的小号页名；右侧搜索改为胶囊按钮（高 28，含放大镜与「搜索」文字），点击进入搜索页并聚焦；讨论入口保持图标 28 命中区。
- 列表行：只保留悬停浮现的单个「⋯」菜单（去掉行尾常驻的第二个图标与 chevron），整行可点；行按钮补可读标签（标题 + 元信息），供 VoiceOver 与自动化；行垂直内距收紧到参照密度（标题 16、元信息 13、上下 10）。
- 显示标题清洗：以 `#` 加空格开头或 `#` 直接开头的内容标题在显示时去掉前缀（只清洗展示，不改存储）。
- 设置页侧栏底部入口保留，同时加 App 菜单入口的视图端消费（见 W2 契约）。

### W2 App 菜单设置入口
文件：`Sources/VoiceOSApp/VoiceOSApp.swift`。
- App 菜单新增「设置…」，快捷键 ⌘,，打开主窗口设置页；`ControlCenter.pendingWorkspaceRoute` 增加 `.settings` 分支，WorkspaceView 消费后跳到设置页（W1 已含消费逻辑）。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机：⌘, 打开设置；材料行只剩一个悬停菜单；标题无井号；搜索胶囊进入搜索页。截图留档。

## 已知边界

- 搜索仍是独立页面，胶囊是入口不是内联结果。
- 外观三选一与 HIG 的冲突按文档列表留后观察。

## 结果

2026-11-15 两条线集成到 `work/mega-13`：W1 `9fd13d8`，W2 `6856bc6`；协调者恢复行动行悬停完成圆钮并保留「⋯」菜单。

`swift build -j 2` 通过；`swift test -j 2` 321 项 0 失败。

实机截图核对：材料页页名重复消失、搜索为胶囊、标题井号清洗生效、行尾常驻图标消失且密度接近参照；⌘, 打开设置页（含主题卡片与快捷键小节）；阅读页原文主体与任务交付页排版正常。悬停完成圆钮的静态截图未卡到时机，行为由编译与代码路径覆盖。

## 链接

- `docs/product/interface-reference.md`
