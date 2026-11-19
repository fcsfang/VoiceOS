# 波 102 任务 D：消息监测页视觉统一

分支 `work/m102-monitor`（基于 main 529b9d4）。

## 背景
消息监测页（报告与设置两个分页）此前混用旧版 `WorkspaceSection`、默认灰胶囊按钮和零散小字说明，与第 101 波落地的共享组件体系不一致。用户目标：页面读起来像精心设计过。本次只替换视觉承载层，检查流程、推送状态计算、采集逻辑与全部 `monitor.*` 无障碍标识保持不变。

## 改动 file:line
路径均为 `Sources/VoiceOSApp/WorkspaceMonitorView.swift`。

- `:36` 页头改 `WorkspacePageHeading`，报告/设置分段控件放进 trailing 槽，与标题同一行右侧，`monitor.page` 保留。
- `:102-131` 运行条：「立即检查」改 `.workspaceSecondary`，忙碌时保留 `ProgressView`；下次检查时间 meta secondary；两段解释文案合并为一行 caption tertiary。
- `:133-147` 未配置推送横幅改 `WorkspaceNoticeText(severity: .warning)`，`去设置` 用 `.workspaceQuietCompact` 叠加在横幅行尾；横幅与按钮标识保留。
- `:149-178` 今日报告：`WorkspaceCard(padding: 20)` 加 `WorkspaceSectionHeading("今日报告")`；空态说明 meta secondary，解释文案 caption tertiary。
- `:180-210` 历史报告：`WorkspaceCard` 加 `WorkspaceSectionHeading("历史报告", count:)`；行尾「查看/收起」改 `.link` 样式。
- `:212-274` 报告卡：标题行、日期与状态 meta secondary，生成时间 meta tertiary，分隔线统一 `WorkspaceListDivider`（1pt `palette.border`）；操作按钮换 compact 档。
- `:276-294` 历史展开正文补生成时间 meta tertiary。
- `:308-310` 事项读取失败「重新读取」改 `.workspaceSecondaryCompact`。
- `:343` 已处理提示改 meta tertiary。
- `:418-437` 更早未处理提示：`WorkspaceBadge(.warning, "N 项")` 加 meta 文案加 `.workspaceQuietCompact`「展开最早的报告」，同一行。
- `:472-491` 事项操作：标记完成 `.workspaceSecondaryCompact`，不适用与重新打开 `.workspaceQuietCompact`。
- `:523-524` 原文链接改 `.workspaceQuietCompact`。
- `:579-614` 来源状态改 `WorkspaceCard` 加 `WorkspaceSectionHeading`；「去设置」quiet compact，「添加内置来源」secondary compact。
- `:633-634` 删除来源改 `.workspaceDestructive`。
- `:700-726` 设置分页改为三张 `WorkspaceCard`（检查计划、微信推送、QQ 群读取），分组标题 `WorkspaceSectionHeading`，组内主操作 secondary、次操作 quiet。
- `:761-821` 推送设置：保存地址 secondary，发送测试与立即推送 quiet；地址保存状态、最近投递改用 `WorkspaceBadge`；移除由卡片标题承担的两处 rowTitle。
- `:823-837` 新增 `deliveryBadgeText` 与 `deliveryBadgeTone` 视图内状态映射。
- `:839` 起 QQ 设置：保存 QQ 设置 secondary；检查依赖、列出群、选择…、打开系统设置 quiet；添加所选群 secondary；移除「QQ 群读取」rowTitle。
- `Sources/VoiceOSApp/MonitorCenter.swift` 未改。该文件不含 SwiftUI 视图片段，没有可统一的字体或颜色令牌。

## 验证（真实退出码与测试数）
- `swift build -j 2`（在 `/tmp/voiceos-swift-build.lock` 下执行）→ `build_exit=0`，`Build complete! (123.85s)`，工作区文件无告警。
- `swift test -j 2`（同一把锁，先等待其他代理释放约 3 分钟）→ `test_exit=0`，`Executed 661 tests, with 0 failures (0 unexpected) in 51.276 (51.344) seconds`。
- 标识符对照：`git show HEAD:...` 与工作区分别提取 `monitor.*` accessibilityIdentifier 集合后 `comm -3`，无输出，集合一致。
- 静态扫描：文件内无 `WorkspaceSection(`、无 `Button(...).vosFont` 残留、无裸 `Divider()`。

## 取舍与风险
- 未重启应用，未做真机 UI 截图；验证限于编译、单测与标识符集合一致性。
- 横幅按钮以 overlay 叠在 `WorkspaceNoticeText` 行尾。窄窗口且横幅文案换行时按钮可能压住末行文字；文案很短，常规窗口宽度不触发。
- 更早未处理提示同时出现徽章计数与句子内计数，属于可读性取舍；若嫌重复，可把徽章文案改为单个数字。
- 设置页原「检查设置」副标题与图标随旧 `WorkspaceSection` 一并移除，信息由三张卡片标题承担。
- 设置页没有独立的「学院官网」分组，官网栏目仍在报告页「来源状态」管理，未新增分区。
- 未改动 `WorkspaceDesign.swift`、`WorkspaceTheme.swift`、`WorkspaceTextScale.swift`，未新增颜色或字号令牌；未 push、未合并。