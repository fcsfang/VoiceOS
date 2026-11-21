# 156-A 英文表达反馈页控件行化（EnglishPracticeView.swift）

## 背景
设置语言推广的最后一批工具页之一。英文表达反馈页顶部是「原话选择 Picker + 旧练习 Toggle 列表 + 状态 + 按钮排 + 提示」的平铺堆叠，与全站行语言不一致。把控件簇改为卡片行，反馈历史区成卡；列表内容与逻辑不动。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/EnglishPracticeView.swift

## 可用原语
`WorkspaceSettingsCard` / `WorkspaceSettingsRow` / `WorkspaceListDivider` / `WorkspaceNoticeText` / `WorkspaceEmptyState`（既有）。

## 改动规则
1. 页头（WorkspacePageHeading 带 eyebrow/subtitle）原样保留。
2. 主控件簇改为一张 `WorkspaceSettingsCard(title:"本次练习", subtitle:"选择原话与旧练习，准备核对后发送")`：
   - 行「原话」：选择 Picker 右对齐（labelsHidden，宽 ≥320），disabled 保留。
   - 旧练习块：保留原 Toggle 列表结构（每项标题+两行摘要、最多 2 份规则、disabled 条件），作为卡内子分组：小标题「可选旧练习（最多 2 份）」+ 列表 + 上下 20/12 内边距；列表高度逻辑保留。
   - 行「准备与发送」：准备并核对文字（secondary）、发送文本反馈（primary）、未配置时「配置文本模型…」、待发送时「查看待发送文字…」，全部右对齐一行，disabled 原样；非嵌入时「完成」仍在页脚右侧（保留 cancel 快捷键）。
   - 状态行：`model.englishStatus` 沿用错误/普通两种呈现（NoticeText danger / meta），作为卡内说明行；`sendHint` 保留为卡内说明。
3. 反馈历史：`WorkspaceListDivider + 标题 + 历史 ScrollView` 改为一张 `WorkspaceSettingsCard(title:"反馈历史", subtitle:"共 N 次，最新在上")`，内部条目逐字保留（建议/比较/警示/免责声明）。
4. 空态 `WorkspaceEmptyState` 原样保留（无来源时整页空态）。
5. 列宽 760；窗口宽度（非嵌入 760×?) 保持原值不动。
6. 所有动作、异步调用、disabled、onChange、文案与可访问性标识逐字保留（新增卡标题/说明除外）。

## 约束
- 只改这一个文件；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、行映射、保留原样项、parse 退出码、diff --stat。