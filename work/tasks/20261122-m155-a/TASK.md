# 155-A 查找历史文字与静默回顾顶部控件改行（VoiceOSApp.swift）

## 背景
设置语言推广的收尾：主应用内两个工具页（HistorySearchView、CognitiveFeedbackView，均在 VoiceOSApp.swift）顶部是「标题+说明+裸 TextField/Picker/Toggle+按钮行+状态」平铺，字段仍是系统边框。把控件簇改为卡片行与字段表面，结果列表区保留。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/VoiceOSApp.swift

## 允许改动的结构体（其余一律不动）
- `HistorySearchView`（约 4998 行）
- `CognitiveFeedbackView`（约 4943 行）

## 改动规则
1. 顶部控件簇改为 `WorkspaceSettingsCard` + `WorkspaceSettingsRow`（右对齐控件）：
   - HistorySearchView：卡「查找」（关键词 TextField 整行 + `.workspaceFieldSurface()`；「按意思找原文」Toggle 行，disabled 保留；「查找 / 停止查找」按钮行与字数计数；`model.retrievalStatus` 作为卡内说明）。说明文字（本机查找/语义资源）作为卡头 subtitle 或行 subtitle，逐字保留。
   - CognitiveFeedbackView：卡「显示方式」：分段 Picker 行（changeQuietMode 调用保留）；`model.quietStatus` 作为卡内说明；顶部说明作为卡头 subtitle。
2. 结果列表（ScrollView 内全部内容、卡片、按钮、空态）逐字不动；页列限宽 760（嵌入模式保持原宽度逻辑）。
3. 页头 `Text(...).vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)` 原样；非嵌入时「完成」按钮与快捷键原样。
4. 所有动作、异步调用、disabled、文案、可访问性标识逐字保留（新增卡标题/说明除外）。

## 约束
- 只动上述两个结构体；不改其它代码。不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、两结构体行映射、parse 退出码、diff --stat。