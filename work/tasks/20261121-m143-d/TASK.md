# 143-D VoiceOSApp 弹层按钮与日期、DiscussionView 中英间距、RecentContentHome 收尾

## 背景
承接 143 设计系统收敛：主应用文件里约十个弹层按钮仍是原生样式；静修/回顾行显示原始 ISO 时间戳；讨论页拉丁词与中文粘连；首页一处「取消」按钮与残留用词。只改样式、日期显示与空白，不改业务。

## 文件清单（只允许动这些）
- Sources/VoiceOSApp/VoiceOSApp.swift
- Sources/VoiceOSApp/DiscussionView.swift
- Sources/VoiceOSApp/RecentContentHome.swift

## 逐条
1. **弹层按钮词表**（VoiceOSApp.swift）：约 95（导入结果「完成」）、4665（ActionCreation 取消）、4723（ActionFeedback 取消）、4791（PackageRestore 取消/完成）、4863（BackupLibraryRestore 关闭）、4943（只读 sheet 完成）等 `.keyboardShortcut(.cancelAction)` 裸 Button 补 `.buttonStyle(.workspaceSecondary)`；同弹层主按钮（defaultAction/确认）若裸 Button 补 `.buttonStyle(.workspacePrimary)`（ActionCreation「确认」、ActionFeedback「提交」、PackageRestore「恢复」等，按实际语义）。用 grep 核对全部 `keyboardShortcut` 站点，成套补。
2. **编辑器表面**：4718 附近用 `.border(.secondary.opacity(0.2))` 的 TextEditor 改 `.workspaceEditorSurface()`（保留 frame/placeholder 等）。
3. **静修/回顾时间戳本地化**：约 4934 的 quiet-review 行显示原始 ISO 8601 字符串，改为本地化日期时间（解析 `ConversationReflectionFocus.date(...)` 或等价；失败保留原文兜底）。同文件其它相同模式一并处理（以 grep ISO/createdAt 文本渲染为准，仅限用户可见文本）。
4. **DiscussionView 中英间距**：约 62 附近把拉丁产品名/数字与相邻中文之间补一个空格（如「用Claude分析」→「用 Claude 分析」），只改字符串空白，不改措辞。
5. **RecentContentHome 收尾**：约 987 的「取消」（线索改名 sheet）补 `.buttonStyle(.workspaceSecondary)`（保存已有 workspacePrimary 则不动）；grep 「开放任务」「开放行动」「知识库」等一处性用词，统一为「待办」「未完成」「资料库」（仅当语义对应）。

## 约束
- 不改业务逻辑、数据结构；不改清单外文件；页眉与字段表面归 143-B/143-C。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：提交哈希、逐条完成情况、跳过的 grep 站点及证据、parse 退出码、diff --stat。