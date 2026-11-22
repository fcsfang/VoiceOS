# 164-A 键盘步进实现统一（WorkspaceDesign + 四个文件）

## 背景
方向键步进有四份独立实现：WorkspaceView 的 `WorkspaceKeySelection`、WorkspaceTopicReadingView 的 `TopicReadingKeySelection`、WeeklyReviewView 的 `ReviewKeySelection`、WorkspaceSourceView 的 `stepSourcePlaybackSelection(_:up:over:)`。步进数学一致但各自维护，此前已出现注释「待提升为共享」的欠债。目标：收敛为一个设计系统类型，行为不变。

## 文件清单（只允许动这些）
- Sources/VoiceOSApp/WorkspaceDesign.swift（新增共享类型）
- Sources/VoiceOSApp/WorkspaceView.swift
- Sources/VoiceOSApp/WorkspaceTopicReadingView.swift
- Sources/VoiceOSApp/WeeklyReviewView.swift
- Sources/VoiceOSApp/WorkspaceSourceView.swift

## 改动
1. WorkspaceDesign.swift 新增 (internal)：
   ```swift
   struct WorkspaceKeyboardSelection: Equatable {
       var id: String?
       init(id: String? = nil) { self.id = id }
       /// Moves to the next/previous id; returns false when the list is empty.
       mutating func step(up: Bool, over ids: [String]) -> Bool { … 与现有实现逐字一致的数学 … }
   }
   ```
2. 三个私有类型改为 `private typealias WorkspaceKeySelection = WorkspaceKeyboardSelection`（保留原文件名内名称以最小化调用点改动；若更干净可直接替换类型名，按你的判断，但调用点行为不得变）。
3. `stepSourcePlaybackSelection` 改为基于共享类型的薄包装或直接以局部 `WorkspaceKeyboardSelection` 调用；签名与调用点尽量保持。
4. 删除重复的步进实现本体；所有调用点（step(up:over:)）不改语义。
5. 行为：空列表返回 false、未知当前 id 落到首/末元素、边界不循环——与现实现逐字一致。

## 约束
- 只改这五个文件；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、共享类型最终形状、四份旧实现的处理方式（类型别名/替换/包装）、parse 退出码、diff --stat。