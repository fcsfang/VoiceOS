# 143-C 字段/编辑器表面应用、英文页眉中文化（WorkspaceActivityViews、WorkspaceMonitorView 等）

## 背景
承接 143-B 提升的 `workspaceFieldSurface()`（internal，签名 `func workspaceFieldSurface() -> some View`，语义同 TextCaptureView 原私有实现）与既有 `workspaceEditorSurface(radius:)`。本单元在其余文件落地，并把四处全大写英文 hero 页眉改成与全站一致的中文 `分类 · 页面` 样式。

## 文件清单（只允许动这些）
- Sources/VoiceOSApp/ReminderSettingsView.swift（91 附近 TextField）
- Sources/VoiceOSApp/WorkspaceMonitorView.swift（922/1004/1136 附近字段；另加报告日期本地化，见第 3 条）
- Sources/VoiceOSApp/WorkspaceActivityViews.swift（722、1500 字段；1520 的取消按钮补 `.buttonStyle(.workspaceSecondary)`）
- Sources/VoiceOSApp/ReflectionQuestionsView.swift（279 字段；82 页眉）
- Sources/VoiceOSApp/ActionClarifyQueueView.swift（133 字段）
- Sources/VoiceOSApp/QuestionAnswerSection.swift（127 字段）
- Sources/VoiceOSApp/QuickNote.swift（75 TextField 改 workspaceFieldSurface；76 TextEditor 改 `.workspaceEditorSurface()`）
- Sources/VoiceOSApp/AssistantExecutionView.swift（47-49 TextEditor 改 `.workspaceEditorSurface()`；119 页眉）
- Sources/VoiceOSApp/ReflectionChangeView.swift（33 页眉）
- Sources/VoiceOSApp/ReflectionGraphView.swift（177 页眉）

## 逐条
1. **字段表面**：把清单中所有 `.textFieldStyle(.roundedBorder)`（SecureField 同理）替换为 `.workspaceFieldSurface()`；保留原有 `.focused`、`.onSubmit`、`.disabled`、`.accessibilityLabel` 等修饰与顺序。若某字段外层已有 frame/padding 造成明显冲突，保留外层、只换表面。
2. **编辑器表面**：AssistantExecutionView 47-49 的 TextEditor 手写 chrome（padding 8 + surface + accent 描边）换成 `.workspaceEditorSurface()`，`.frame(height:190)` 保留；QuickNote 76 的裸 TextEditor 加 `.workspaceEditorSurface()`。
3. **报告日期本地化**（WorkspaceMonitorView）：报告头部渲染 `yyyy-MM-dd` 原始字符串的地方改为本地化日期（参照文件内其它日期显示；用 `Date` 解析后 `.formatted(date: .abbreviated, time: .omitted)` 或既有 dateLabel 辅助；解析失败保留原文兜底）。
4. **页眉中文化**：`WorkspaceHero(eyebrow:)` 的四处英文改为：
   - AssistantExecutionView: "YOUR ASSISTANT" → "助理 · 协作"
   - ReflectionQuestionsView: "TOPICS IN PROGRESS" → "主题 · 问题"
   - ReflectionChangeView: "THOUGHTS IN CONTEXT" → "主题 · 认识对照"
   - ReflectionGraphView: "REFLECTION ATLAS" → "主题 · 认知地图"
   - 其它 WorkspaceHero 调用若 eyebrow 为空或已是中文则不动。
5. **按钮**：WorkspaceActivityViews:1520 的「取消」（NextActionFormSheet 内）补 `.buttonStyle(.workspaceSecondary)`（同弹层主按钮已有 workspacePrimary）。

## 约束
- 不改业务逻辑、文案（除页眉四处与日期显示）、disabled/help；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：提交哈希、逐条完成情况、日期本地化实现方式、parse 退出码、diff --stat。