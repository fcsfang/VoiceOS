# 146-A 区块标题语义扫（第一组：WorkspaceView / VoiceOSApp / 首页 / 全景 / 反思 / 材料 / 助理 / 阅读组件）

## 背景
无障碍发现：全仓 60 处裸 `Text(...).vosFont(WorkspaceText.sectionTitle)` 没有 `.accessibilityAddTraits(.isHeader)`，VoiceOver 标题导航会跳过这些区块；`WorkspaceSectionHeading` 组件本身已带该 trait，缺口只在裸 Text。本单元负责第一组文件的机械补齐。

## 文件清单（只允许动这些，括号为待检查站点数）
- Sources/VoiceOSApp/VoiceOSApp.swift（7）
- Sources/VoiceOSApp/WorkspaceView.swift（5）
- Sources/VoiceOSApp/RecentContentHome.swift（5）
- Sources/VoiceOSApp/ThoughtPanoramaView.swift（4）
- Sources/VoiceOSApp/ReflectionQuestionsView.swift（4）
- Sources/VoiceOSApp/WorkspaceSourceView.swift（3）
- Sources/VoiceOSApp/AssistantExecutionView.swift（3）
- Sources/VoiceOSApp/WorkspaceReadingViews.swift（2）

## 规则
- 对每个 `.vosFont(WorkspaceText.sectionTitle)` 的 `Text` 链，若链上还没有 `.accessibilityAddTraits(.isHeader)`，在 `vosFont(...)` 调用之后追加 `.accessibilityAddTraits(.isHeader)`（位置在后续 `.foregroundStyle` 等之前合法）。已带 trait 的跳过。
- 判定为「区块标题」的才加：独立成行的标题、弹层内小节标题、分组标题。若 `Text` 其实是行内计数、按钮标签的一部分或纯说明文字，跳过并记录行号与理由。
- 若某处 Text 已在 `WorkspaceSectionHeading` 或其它已带 header 的组件内重复出现，不要重复添加。
- 只加 trait，不改文案、样式、布局与业务。

## 验证
- `grep -c "WorkspaceText.sectionTitle" 每文件` 与改动数对账；改动后 `grep -n "sectionTitle" 文件` 人工核对每条链都有 trait 或记录跳过理由。
- `xcrun --sdk macosx swiftc -parse <files>` 真实退出码 0。
- 不跑 swift build/test（波次批处理）。

## 回报
提交哈希、每个文件改动站点数、跳过项（文件:行 + 理由）、parse 退出码、diff --stat。