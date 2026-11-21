# 154-B 思想与下一步顶部控件改行（RecordingFollowupView.swift）

## 背景
工具页顶部控件簇（分段 Picker + 来源 Picker + 主按钮 + 进度 + 提示 + 状态 + Toggle）混排，与设置语言不一致。把控件簇改为行原语，列表区不动。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/RecordingFollowupView.swift

## 可用原语
`WorkspaceSettingsCard` / `WorkspaceSettingsRow` / `WorkspaceListDivider`；`WorkspaceNoticeText` 既有。

## 改动
1. 顶部控件簇改为一张 `WorkspaceSettingsCard(title:"生成与筛选", subtitle:"选择来源、生成跟进、切换查看范围")`：
   - 行「查看」：分段 Picker 右对齐（labelsHidden）。
   - 行「来源」：来源 Picker 右对齐；副标题承载「先选择来源录音，再生成跟进。」（仅当 sourceID=="all" 且 eligible 非空时显示，条件保留）。
   - 行「操作」：生成或重试跟进按钮右对齐（workspacePrimary），进度指示保留在按钮行。
   - 行「显示历史版本」：Toggle 右对齐。
   - `model.followupStatus` 作为卡内说明行（保留原文与 meta 样式）。
2. 列表区（ScrollView/LazyVStack、空态、tab 内容、goalList、english 部分与每张卡片）**逐字不动**。
3. 页头 WorkspaceHeading 与非嵌入时的「完成」按钮原样。
4. 页列限宽 760（列表原本就占满页宽；只约束顶部卡与整体列）。

## 约束
- 不改逻辑、文案、动作、disabled、可访问性与列表内容；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、行映射、parse 退出码、diff --stat。