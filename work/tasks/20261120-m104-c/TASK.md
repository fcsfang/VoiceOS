# 波 104-C：反思与讨论视图视觉收尾

## 背景

波 102 建立 `WorkspaceDesign` 组件、103 覆盖主页面与弹窗后，反思与讨论相关页面仍混用系统蓝 `.borderedProminent`、默认 `.bordered` 按钮、手写卡片容器与裸边框编辑器。本单元只做组件替换，不改行为、identifier、键盘与文案。

## 文件所有权

- `Sources/VoiceOSApp/ReflectionQuestionsView.swift`
- `Sources/VoiceOSApp/ReflectionGraphView.swift`
- `Sources/VoiceOSApp/ReflectionChangeView.swift`
- `Sources/VoiceOSApp/WorkspaceDiscussionView.swift`
- `Sources/VoiceOSApp/BilingualView.swift`

## 完成判据

1. 系统蓝/旧 tint 主按钮改 `.workspacePrimary`，每个上下文唯一；次要 `.workspaceSecondary`（密集行 compact），纯文字 `.workspaceQuiet`，破坏性 `.workspaceDestructive`。
2. 反思问题/改变视图的手写卡片改 `WorkspaceCard`；状态改 `WorkspaceBadge`。
3. 图谱只改外围工具栏与按钮，图形绘制、布局算法、命中测试不动。
4. 对照视图主次按钮分档；双语行容器圆角统一常量。
5. 讨论条与输入区按钮分档；裸边框编辑器改 `.workspaceEditorSurface()`。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0。

## 约束

- 唯一构建锁（`/tmp/voiceos-swift-build.lock`）；16GB 机器构建/测试互斥。
- 不写实时库、不重启、不 push、不合并。

## 结果（2026-11-20）

- 分支 `work/m104-c`，基线 `d563cad`。
- 按钮分档：五文件内 `.borderedProminent` 与 `.tint(palette.accent)` 清零。主操作 `一起探索/一起回顾`、`保存我的记录`、`建立主题或问题`、`带着原话继续讨论`、`发送`、`生成译文`、`允许云端处理`、`继续下一批` 改 `.workspacePrimary`；工具条与行内动作改 secondary/compact；纯文字与记录内动作改 quiet/quietCompact；`提示设置` 等 Menu 保留菜单样式。
- 卡片与徽章：`entryCard`、资料行、知识关联卡、任务关联卡、`evidenceCard` 改 `WorkspaceCard`（padding 12/13/14/16）；`AI 关系候选 · 待你核对` 与任务状态（已完成登记/已放下/待跟进）改 `WorkspaceBadge`。
- 编辑器：问题记录编辑器与讨论输入框改 `.workspaceEditorSurface()`。
- 图谱：只动页头、刷新、空状态、`回到全部` 与右侧检查器按钮；节点按钮、连线标签、命中测试、布局与绘制未改。
- 双语：三处主按钮改 primary，其余归 secondary/quiet；双语行本身没有手写圆角容器，无圆角可统一，未新增容器。
- 构建/测试：首次尝试等待共享锁 10 分钟后退出 3（LOCK_TIMEOUT），未执行构建；第二次运行 `swift build -j 2` 退出码 0，`swift test -j 2` 退出码 0，`Executed 662 tests, with 0 failures (0 unexpected) in 44.352 (44.407) seconds`。
- 未做：可选择的题目行与关联列表行保留自绘选中背景（`WorkspaceCard` 表达不了 selection 状态）；无独立破坏性按钮，现有 `role: .destructive` 仍留在 Menu 与确认弹窗；未写实时库、未重启应用、未 push、未合并。