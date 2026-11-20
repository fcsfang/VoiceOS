# 131-A 设置页分组间距，组内 12、组间 28

## 背景

`WorkspaceView.settings` 是单个 `VStack(alignment:.leading,spacing: WorkspaceMetrics.sectionGap)`，8 个区块的标题与内容平铺在同一层，所有元素间距都是 28。区块标题与它自己的内容没有比区块之间更近，扫读时找不到组的边界。

## 改法

只动 `Sources/VoiceOSApp/WorkspaceView.swift` 的 `settings` 属性，只做包裹与缩进。控件、修饰符、顺序与文案不变。

外层 `VStack` 保留 `sectionGap` 28，`WorkspacePageHeading(title:"设置")` 保持在外层最前。其下 8 个 `VStack(alignment:.leading,spacing: WorkspaceMetrics.controlPadding)`（12）依次为：

1. 模型与服务，标题加 2 个 `WorkspaceRow` 及其 `help`、`contextMenu` 修饰符。
2. 隐私与云端，标题、隐私两行与「详细说明」`DisclosureGroup`，含 `.frame(maxWidth: 620)`。
3. 连接与自动入口，标题至 `launchAtLoginStatus`，含提醒事项失败提示、权限按钮、暂停连接、待核对按钮、麦克风块与授权按钮、系统通知行与按钮、登录时启动开关与状态。
4. 外观，标题、主题 `HStack` 与文字大小 `Picker`。
5. 键盘快捷键，标题、快捷键说明 `VStack`、冲突警告与「再看一次引导」按钮。
6. 资料与历史，标题至「从迁移包恢复」行，含导出、备份、保留份数与清理、检查与恢复、健康状态、打开资料库。
7. 存储与清理，标题、存储明细 `VStack`、统计提示、访达与删除按钮行、删除状态。
8. 回顾与查找，标题、3 个 `WorkspaceRow` 与「其他工作与维护」`DisclosureGroup`。该组以函数结尾为界，其后没有剩余元素。

## 验证

- 用脚本剥掉 8 对包裹行并把内容反缩进 4 格，与 HEAD 的 `settings` 正文 163 行逐行相等。内容零改动。
- 脚本确认 8 个包裹 `VStack` 开头、8 个对应结尾，`sectionTitle` 顺序与 8 组一致。
- `xcrun swiftc -parse Sources/VoiceOSApp/WorkspaceView.swift` 退出码 0，无输出。
- `git diff --check` 无空白错误；工作区只有该文件一个修改。
- 按约定未运行 swift build 或 swift test，未写实时资料库。

## 风险

- 第 3 组与第 8 组内容较长，归属靠区块标题与业务含义划分。第 3 组把「登录时启动」状态行算作该组末尾，第 8 组以函数结尾为界，均已逐行核对。
- 组内统一 12 后，部分原本 28 的间隔会收紧。条件出现的按钮与提示之间也是 12。视觉密度需要主会话集成后确认。
- 外层 `VStack` 与 `WorkspacePageHeading` 未改，标题到第一组仍为 28。