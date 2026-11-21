# 140-B 只读弹层 Esc、表单 Esc 与危险确认顺序

## 背景

审计第二批判定：只读 sheet 缺 Esc；部分表单 sheet 的取消没有 Esc；危险 alert 的破坏性按钮排在最前。目标是键盘操作与 macOS 惯例一致，不改业务逻辑与文案。

## 逐条结果

### 1. 只读 sheet 补 Esc

- `BilingualView.swift:37`（任务写 `:41`；该行现为截断提示，关闭按钮实际在第 37 行）：关闭按钮补 `.keyboardShortcut(.cancelAction)`。
- `IncrementalReadingView.swift:52`、`TranscriptSegmentationView.swift:38`、`ClaimReviewHistoryView.swift:40`、`CorrectionImpactView.swift:76`：关闭或完成按钮是 sheet 唯一按钮且原绑 `defaultAction`，改为 `cancelAction`。选 Esc 的理由：这些是纯阅读 sheet，Esc 就是关闭语义，没有需要回车触发的提交动作。

### 2. ThoughtPanoramaView.swift:55 阅读器 sheet

- 阅读器内部已有可见 xmark（关闭主题、关闭检查器，共 3 处），无需新增按钮；三处均补 `.keyboardShortcut(.cancelAction)`。
- 副作用：侧栏阅读器（宽度 ≥ 740）共用同一批面板，Esc 在侧栏也会清空选择。

### 3. VoiceOSApp.swift:95 导入结果

- 重复的两个快捷键去重为单个 `.keyboardShortcut(.cancelAction)`。选 Esc 而不是 defaultAction：与本批其它只读 sheet 一致，该按钮只承担关闭。

### 4. 表单 sheet 补 Esc

- `ActionCreationView`：取消补 `cancelAction`；确认 / 取消布局本来就是取消在左，未动。
- `ActionFeedbackView`：取消补 `cancelAction`；布局已是取消在左，未动。
- `PackageRestoreView`：取消补 `cancelAction`，与 `BackupLibraryRestoreView` 范例对齐。
- `WorkspaceView` saveViewSheet：取消从 Spacer 右侧移到左侧并补 `cancelAction`；「保存」补 `defaultAction`。
- `WorkspaceView` mergeTopicSheet：取消移到 Spacer 左侧并补 `cancelAction`；「确认合并」是破坏性，不设 `defaultAction`。
- `WorkspaceView` 选择提醒清单：取消包进 HStack 放在 Spacer 左侧，补 `cancelAction`。
- 跳过：`NextActionFormSheet`（`WorkspaceActivityViews.swift:1479`）。该文件不在本单元文件清单内；本单元对它的唯一许可是危险 alert，不含表单 sheet。记录待后续。

### 5. 危险 alert 取消在前

- `WorkspaceActivityViews.swift:640`、`WorkspaceTopicReadingView.swift:147`、`AssistantExecutionView.swift:260`：取消按钮移到破坏性按钮之前；破坏性按钮保持最后，且不设默认。
- `RecordingInbox.swift:503/537`：grep 确认存在同类 alert，按第 5 条处理，取消在前。文件不在清单内，但该条明确要求处理并记录。

### 6. ReflectionQuestionsView

- createSheet 标题输入框补 `@FocusState`，`onAppear` 后 100ms 置焦。
- 管理主题资料 sheet 的「完成」由 `cancelAction` 改为 `defaultAction`，保持一个按钮一个快捷键。

### 7. 按钮布局抽查

- 修正 3 处取消在右：saveViewSheet、mergeTopicSheet、选择提醒清单。
- 其余弹层页脚已是取消左、主按钮右，或只有单个关闭按钮，未动。

## 未改动（记录）

- 140-A 文件集（ConfirmTaskView、FeynmanPractice、QuestionViews、RecentContentHome、RecordingTitleEditor、ReminderSettingsView、TextCaptureView、WorkspaceSourceView）与本单元无重叠。
- `WorkspaceActivityViews.swift:620` 重新打开 alert 非破坏性，未调整顺序。
- 文案与业务逻辑未改。

## 验证

- 按任务约束未运行 `swift build` / `swift test`。
- `xcrun swiftc -parse` 检查 13 个改动文件，退出码 0，输出为空。
- `git diff --check` 退出码 0。
- grep 核对：无重复 `keyboardShortcut`；只读关闭按钮无残留 `defaultAction`；危险 alert 均为取消在前。
- 未运行 deslop：cursor-team-kit 插件未安装。

## 风险

- 未做类型检查与真机验证。`.keyboardShortcut` 挂在自定义 `WorkspaceIconButton` 上，Esc 是否实际触发需实机确认；若无效，需改为在 sheet 容器加隐藏取消按钮，或给 `WorkspaceIconButton` 增加快捷键参数。
- 阅读器面板在侧栏与 sheet 共用，Esc 在侧栏也会清空选择，属可接受的行为扩展。
- 提醒清单与合并主题 sheet 的取消键位置变化是可见 UI 变化，可能与旧截图基线不符。

## 后续验证

打开任一只读 sheet（译文对照、按天读、分段、认知审阅历史、纠错影响、全景阅读器、导入结果）按 Esc 应关闭；打开记录行动意图、记录结果、迁移包恢复、保存视图、合并主题、选择提醒清单，按 Esc 应取消；新建主题或问题时标题输入框自动聚焦；危险确认弹窗取消在左。