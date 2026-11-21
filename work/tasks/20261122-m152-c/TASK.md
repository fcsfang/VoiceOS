# 152-C 消息监测页卡片化（WorkspaceMonitorView.swift）

## 背景
监测页设置标签已用 WorkspaceCard 分组（143 波），但报告与来源标签仍是标题+散内容的平铺结构（今日报告 ×3 分支、历史报告、来源状态）。按设置页同一语言重组。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/WorkspaceMonitorView.swift

## 可用原语
`WorkspaceSettingsCard` / `WorkspaceSettingsRow` / `WorkspaceSettingsNavRow` / `WorkspaceSettingsValueRow` / `WorkspaceSectionHeading` / `WorkspaceListDivider`（均已在 WorkspaceDesign.swift）。

## 分组方案
1. **报告标签**：将「今日报告」的三种分支（238/249/258 行附近）统一包进一张 `WorkspaceSettingsCard(title:"今日报告", subtitle:…)`；「历史报告」包进一张卡（计数保留在卡头 trailing 或子分组头）；「事项筛选」单选与列表作为今日报告卡内的子分组或独立小卡（按读代码结果选择更能读清的一种，并在回报说明理由）。
2. **来源状态标签**：「来源状态」区块与其内每行（启用开关、起始时间、删除、状态文本）改成 `WorkspaceSettingsRow`（标签+说明在左，开关/日期/删除等控件右对齐）；已停用提示作为行说明或卡内提示行；「内置栏目未添加」条目同样分行。
3. **设置标签**：已卡片化，不重排；若与其新原语有样式冲突（卡片成分不同）则仅换用 `WorkspaceSettingsCard` 外壳，内容零改动。
- 页面列限宽 680（设置标签已是 680 以内节奏）；卡间距 sectionGap；保留全部动作、异步调用、sheet、alert 与可访问性标识。

## 约束
- 不改逻辑、文案、动作；只重排容器与分组。
- 不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、每个区块 → 分组的映射、选型理由、parse 退出码、diff --stat。