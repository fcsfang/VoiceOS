# 波 103-C：执行 / 讨论 / 知识核查三页视觉收口

## 背景

波 102 统一了首页、材料、行动、设置等六屏。只读审计（2026-11-20）确认 `AssistantExecutionView`、`DiscussionView`、`KnowledgeReviewView` 仍混用系统默认灰胶囊、未加 tint 的主按钮、裸边框编辑器与第二套卡片容器。本单元只统一视觉词汇，不改行为与 identifier。

## 改动

### `Sources/VoiceOSApp/AssistantExecutionView.swift`

- 主次层级：`委托并开始`、`关联成果` 改 `workspacePrimary`；`完成`、`取消`、`取消代办`、`保存完整报告…`、`记录使用结果`、`带着成果继续讨论` 改 `workspaceSecondary`；`重新执行` 改 `workspaceQuiet`。两处旧 `.borderedProminent.tint(palette.accent)` 全部清除。
- 代办列表选中卡改 `WorkspaceCard(padding: 14, radius: WorkspaceMetrics.panelRadius)`，选中态以 `palette.selection` 内底加 accent 描边保留。
- 报告代码块圆角由 `controlRadius` 统一为 `panelRadius`（12），保留 border。
- 委托子弹窗宽度 680 改 `WorkspaceMetrics.modalSmall`（620），页脚按钮统一风格。

### `Sources/VoiceOSApp/DiscussionView.swift`

- `发送本轮文字` 为 `workspacePrimary`；`保存文字发言`、`关联核对后的口述`、`整理整段讨论成果`、口述与停止口述按钮为 secondary（与发送同排的用 compact）；`结束讨论` 为 `workspaceDestructive`；`关闭` 为 `workspaceQuiet`。
- 行内导航类按钮（查看原文、候选、引用、追问建议）落 `workspaceQuietCompact`；状态动作（整理这轮表达、保留为 AI 候选）落 `workspaceSecondaryCompact`。
- `TextEditor` 裸 `.border` 改 `.workspaceEditorSurface()`。
- 宽度 760 改 `WorkspaceMetrics.modalMedium`（720），高度 780 不变。

### `Sources/VoiceOSApp/KnowledgeReviewView.swift`

- 段头 `Label 知识理解核查 + spinner` 改 `WorkspaceSectionHeading(title: "知识核查")` 加 trailing 进度。这是审计指定的标题文案，且与处理页已有文案（`知识核查未完成`、`知识核查已排队`）一致；唯一一处可见文案变化。
- 自绘 accent 4.5% 容器改 `WorkspaceCard(padding: 14)`；问题卡在 panelRadius 背景上补同圆角 border。
- 计数行拆为 `WorkspaceBadge`：待核查 warning、已读 neutral、已认可 success、已驳回 neutral（success 沿用全景页对已核对状态的既有语义）；原 accessibilityLabel 保留。
- `核查知识理解` primary；`重试知识核查`、`核查当前原文` secondary；每条问题三按钮：已读与认可 `workspaceSecondaryCompact`，驳回 `workspaceQuietCompact`。

## 验证

- `swift build -j 2` → `build_exit=0`（日志 `/tmp/m103-exec-build.log`）
- `swift test -j 2` → `test_exit=0`，`Executed 661 tests, with 0 failures (0 unexpected) in 44.483 seconds`（日志 `/tmp/m103-exec-test.log`）
- 构建与测试在 `/tmp/voiceos-swift-build.lock` 互斥锁下执行。第一次运行遇到一枚 02:56:44 遗留的孤儿锁（机器上无任何 swift/swiftc/llbuild 进程，/tmp 在锁创建后无任何新写入），确认无活体构建后清除并重跑，全部通过。

## 硬约束核对

- 仅修改三个目标文件，行为、identifier 不变（一处段头文案按审计指定调整，见上）。
- 未写实时库、未重启、未 push、未合并。
- 代码与记录两次提交，分支 `work/m103-exec`。