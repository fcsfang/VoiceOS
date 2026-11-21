# 152-B 行动详情页卡片化（WorkspaceActivityViews.swift）

## 背景
行动详情页（WorkspaceTaskView 族，~1500 行、10 个 `WorkspaceSectionHeading` 平铺）与设置页属同一反模式。本单元把它的区块按「任务、AI 交付、记录依据、进展」重组为卡片；只换外壳，不改内容。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/WorkspaceActivityViews.swift

## 可用原语（WorkspaceDesign.swift 已有）
`WorkspaceSettingsCard` / `WorkspaceSettingsRow` / `WorkspaceSettingsNavRow` / `WorkspaceSettingsValueRow`；`WorkspaceSectionHeading` 用于卡内子分组；`WorkspaceListDivider` 卡内分隔。

## 分组方案（保留页面顺序、所有条件渲染与动作）
1. **任务**：「任务说明」+「子任务」+「下一步」（948 行附近的下一步区块）+「重复」（若存在，作为卡内提示行/子分组）。
2. **AI 的工作与交付**：773 行的「AI 的工作与交付」（含交付正文/参考与来源/继续使用这份成果——注意 42/61/89 行属于执行页执行详情，若在同一视图族内按同样方式包卡）。
3. **记录与依据**：790 行「记录与依据」及其行。
4. **实际进展与收获**：1014 行区块。
每张卡头给一行说明；页面列限宽 760；卡间距 sectionGap；卡内行左右 padding 20、子分组间发丝线。

## 约束
- 不改任何逻辑、文案、动作、sheet/alert、键盘焦点与可访问性标识；只重排容器与分组。
- 不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 先 grep 全部 WorkspaceSectionHeading 与条件分支做映射表；执行页（AssistantExecutionView 内 42/61/89）若不在本文件则不动并在回报说明。

## 回报
提交哈希、区块映射表、保留原样段落、parse 退出码、diff --stat。