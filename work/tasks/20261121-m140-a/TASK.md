# 140-A 高频表单弹层的键盘语义（审计修复第一批）

## 背景
键盘审计指出高频弹层的 Enter/Esc 语义不一致：部分主按钮没有 defaultAction，部分取消按钮排在 Spacer 右侧，输入型弹层打开后焦点不落在输入框，破坏性 alert 声明在取消之前。目标是统一约定，只改键盘快捷方式、初始焦点与按钮声明顺序，不动业务逻辑、校验与文案。

## 统一约定
- 主按钮 `.keyboardShortcut(.defaultAction)`，取消 `.keyboardShortcut(.cancelAction)`，一个按钮只挂一个快捷键。
- 输入型弹层用 `@FocusState` 加 `.task` 睡 100ms 后聚焦第一个输入框，沿用仓库既有模板。
- 破坏性 alert 取消声明在前，破坏按钮在后，破坏按钮不设 defaultAction。
- 按钮布局为 `取消 — Spacer — 主按钮`，辅助按钮放在取消左侧。

## 逐条（行号为改动前）
1. TextCaptureView 主 composer（63/66/87）：稍后继续挂 cancelAction，保存挂 defaultAction；初始焦点由 `.text` 改为 `.title`。保存原有禁用条件 `draft.saving || !valid` 未动，禁用时 Enter 不触发。
2. TextCaptureView 保存为模板（235-251）：新增 `sheetFocus`（`SheetField.templateName`），100ms 后聚焦模板名输入框；保存挂 defaultAction；布局改为取消在 Spacer 左侧。
3. TextCaptureView 管理模板（256）：完成按钮挂 cancelAction，等价于 Esc 关闭。
4. TextCaptureView 从链接导入（288-295）：链接输入框 100ms 后聚焦（`SheetField.link`）；抓取正文挂 defaultAction。
5. TextCaptureView 三个 alert（90/99/103）：90 与 103 原本取消在前，未动；99 应用模板 alert 调整为取消在前、替换在后，破坏性的替换不再是默认按钮。
6. RecordingTitleEditor（19/31/38）：标题框 100ms 后聚焦；取消移到 Spacer 左侧；恢复自动标题保持在取消左侧；保存原有 defaultAction 保留。
7. RecentContentHome 线索改名 sheet（931/944/955）：标题框 100ms 后聚焦；取消移到 Spacer 左侧；恢复默认保持在取消左侧；保存原有 defaultAction 保留。
8. WorkspaceSourceView 更正原文（1706/1711/1715）：TextEditor 100ms 后聚焦；保存更正挂 defaultAction。
9. WorkspaceSourceView 更正理解（1748/1757/1761）：TextEditor 100ms 后聚焦；更新理解挂 defaultAction。
10. WorkspaceSourceView 分组改名（1791/1794/1801）：标题框 100ms 后聚焦；取消移到 Spacer 左侧；恢复自动标题保持在取消左侧；保存原有 defaultAction 保留。
11. ConfirmTaskView（16/22/35）：标题框 100ms 后聚焦；确认为待办挂 defaultAction。
12. ReminderSettingsView（102/119）：保存到提醒事项挂 defaultAction；关闭发送通知 alert 调整为保留通知在前、关闭并清空通知在后。
13. QuestionViews 登记问题状态（85/101/110）：原因输入框 100ms 后聚焦；保存状态挂 defaultAction。
14. FeynmanPractice（31/32）：取消移到 Spacer 左侧（cancelAction 原有）；对照原话挂 defaultAction，原禁用条件 `!claimReady || trimmed.isEmpty` 保留。

## 交互说明与风险
- 禁用中的 defaultAction 按钮按 Enter 无效果，这是禁用语义的自然结果。主 composer 保存、分组改名保存等禁用条件均未改动。
- Enter 在 TextEditor 内仍由编辑器消费为换行，defaultAction 只在焦点不在文本编辑器时触发；这与仓库既有 TextEditor 弹层一致，不影响按钮点击。
- alert 只调整声明顺序，SwiftUI 的默认按钮落在最后一个非取消按钮上，破坏性操作不再是 Enter 目标。
- 改动前八个文件均无 `onSubmit` 或回车快捷键，新增 defaultAction 不与既有写法冲突（rg 确认）。

## 验证
未运行 `swift build` / `swift test`（任务约束）。对八个改动文件运行 `xcrun swiftc -parse`，退出码 0。`git diff --stat` 显示只触及指定八个文件，47 行增、27 行删。