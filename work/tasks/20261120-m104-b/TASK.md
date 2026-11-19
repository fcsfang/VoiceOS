# 波 104-B：工作台残余视觉收尾

## 背景

波 102 建立组件、波 103 覆盖主页面与弹窗后，波 104 清点残余系统按钮。本单元负责工作台残留的 7 处 `.borderedProminent`、主题确认识别行、录音标题编辑器与收件箱视图。约束是行为、identifier、键盘、文案不变，只把系统默认按钮与裸状态文本换成 `WorkspaceDesign` 词汇。

## 改动

### WorkspaceView.swift（7 处系统蓝主按钮 + 同区域次要按钮）

| 区域 | 主操作 | 次要操作 |
| --- | --- | --- |
| 保存当前视图弹窗 | 保存 → `workspacePrimary` | 取消 → `workspaceSecondary` |
| 资料库未打开空态 | 重试打开资料库 → `workspacePrimary` | 打开其他资料库 → `workspaceSecondary` |
| 口述采集页 | 开始口述并自动整理 / 停止并整理 → `workspacePrimary` | 导入音频 / 视频 → `workspaceSecondary` |
| 新建或修改主题 | 保存主题 → `workspacePrimary` | 取消 → `workspaceSecondary` |
| 周期回顾 | 让 AI 一起回顾这个周期 → `workspacePrimary` | 无同区域系统按钮 |
| 安排今天弹窗 | 加入专注 → `workspacePrimary` | 取消 → `workspaceSecondary` |
| 行动多选浮条 | 标为完成 → `workspacePrimary` | 不再跟进 → `workspaceSecondary`；取消 → `workspaceQuiet`（浮条已有主次两档，退出动作保持低权重） |

每个弹窗或区域只保留一个 primary。没有任何一处主按钮属于破坏性语义，因此本文件未使用 `workspaceDestructive`。

### TopicClaimConfirmViews.swift

- 确认关联 → `workspaceSecondaryCompact`，取消关联 → `workspaceQuietCompact`。取消关联是可逆的解除，不算删除或清空，用 quiet 而非 destructive。
- `row` 增加带默认值的 `style` 参数，忙时禁用逻辑与按钮文案不变。

### RecordingTitleEditor.swift

- 保存 → `workspacePrimary`，取消 → `workspaceSecondary`，恢复自动标题 → `workspaceQuiet`。`.defaultAction` 与 `.cancelAction` 快捷键不变。

### RecordingInbox.swift

- 按钮分档：启用 VoiceOS收件箱 → `workspacePrimary`；其他文件夹、连接语音备忘录、检查新素材、重试未完成素材、打开系统隐私设置、完成 → `workspaceSecondary`；行内打开文件夹、重试这份素材、配置本地 Qwen 转写、配置文本模型 → `workspaceSecondaryCompact`；移除入口、不再处理这份素材 → `workspaceDestructive`。
- 系统 alert 内的按钮（移除入口确认、不再处理确认）保持系统角色样式。
- 未完成素材的三条状态行由彩色 `Text` 改为 `WorkspaceBadge`，正在整理用 accent，自动重试用 neutral，等待手动重试用 warning。徽标文案逐字保留原句。

### 圆角

四个文件中的自写圆角已全部使用 `WorkspaceMetrics` 常量（`panelRadius`、`controlRadius` 等），没有数字字面量残留，本项为 no-op。

## 验证

- `swift build -j 2`（唯一构建锁内）：build_exit=0。
- `swift test -j 2`：test_exit=0，Executed 662 tests, with 0 failures (0 unexpected) in 45.937 seconds。
- 范围：仅四个文件，`git diff --check` 干净。

## 未做

- 口述页两处内联 `.controlSize(.small)` 配置按钮与所有 `ProgressView` 未动。
- 系统 alert 按钮未加自定义样式。
- 未改 data 层，未写实时库，未重启，未 push。