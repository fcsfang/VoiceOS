# 152-A 处理情况页卡片化（WorkspaceProcessingView.swift）

## 背景
设置页已用「每类信息一张卡 + 统一行原语」重构并被用户确认效果显著。处理情况页（~965 行、20+ 个 `WorkspaceSectionHeading` 平铺）是同一反模式的最大页面：转写、理解、行动、提醒、监测、系统状态混在同一节奏里。本单元只重排外壳与分组，不改任何动作、绑定、文案与逻辑。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/WorkspaceProcessingView.swift

## 可用原语（已在 WorkspaceDesign.swift，直接引用）
- `WorkspaceSettingsCard(title:subtitle:content:)` 每类信息一张卡。
- `WorkspaceSettingsRow(title:subtitle:showsDivider:trailing:)` 标签列 + 右对齐控件。
- `WorkspaceSettingsNavRow(title:subtitle:showsDivider:action:)` 整行可点 + chevron + hover。
- `WorkspaceSettingsValueRow(label:detail:value:emphasized:showsDivider:)` 值行。
- 既有 `WorkspaceSectionHeading` 继续用于卡内子分组；`WorkspaceListDivider` 用于卡内分隔。

## 分组方案（保持页面上下顺序与所有条件渲染）
1. **转写与理解**：文字理解与关联、录音与转写需要查看、转写为空、录音处理请求、长录音分段理解未完成、完整转写核对未完成、转写疑点待核对、批量重新识别。
2. **行动与知识**：这些待办需要核对、思想与目标跟进未完成、知识核查未完成、AI 代办未完成、AI 委托识别未完成。
3. **提醒与监测**：提醒事项需要核对、本地变更待同步提醒事项、消息监测。
4. **系统与后台**：资料库尚未打开（条件）、全景生成未完成、主题整理未完成、录音自动入口、模型与提醒事项。
5. **最近完成**。
每个卡片标题下给一行说明（如「失败、待核对与可重试的处理项」）；卡片计数徽标保留在卡头 trailing 或首个子分组头（若原页面已有徽标，保持原徽标与计数不变，位置随分组调整）。
- 卡内各子分组之间用 `WorkspaceListDivider` 分隔；子分组沿用 `WorkspaceSectionHeading`（含计数），其行内容保持在卡内并左右对齐（行左右 padding 20，与设置页节奏一致；列表行自身 padding 可保留但需与卡边距相加后小于 28）。
- 页面列限宽 760；卡间距 `WorkspaceMetrics.sectionGap`；页头（WorkspacePageHeading）保持原样。
- 空态/错误/加载状态与各动作按钮、sheet、alert、导航调用逐字保留。

## 约束
- 不改任何逻辑、文案、动作、sheet/alert 与可访问性标识；只重排容器与分组。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 先用 grep 列出全部 WorkspaceSectionHeading 与条件分支并逐一映射到分组，回报里给映射表；确有不应移动的段落（例如顶部状态栏）说明理由。

## 回报
提交哈希、每个原区块 → 新分组的映射、保留原样的段落、parse 退出码、diff --stat。