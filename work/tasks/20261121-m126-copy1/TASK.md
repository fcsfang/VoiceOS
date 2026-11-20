# 126-B 路线一小字清扫与间距节奏

## 背景

用户反馈：界面里解释性小字过多，同类信息与不同区块之间的间距没有层次。本单元只改五个文件的文案与间距，不改布局与配色。

行号为改动前基线（811d526）。

## 小字裁决

### 删除（9 条）

- WorkspaceActivityViews.swift:85 原文「可以继续阅读其他材料，VoiceOS 保持运行就会继续处理。」
- WorkspaceActivityViews.swift:892 原文「历史记录已冻结，不再写入。」冻结分支并入 `operation.validity != "frozen"`，行为不变。
- WeeklyReviewView.swift:102-104 原文 `undoHint` 整块「完成或不再跟进后可立即撤销，任务页也保留撤销。」
- WeeklyReviewView.swift:109 原文副标题「今天收尾可直接完成或不再跟进；点开任意一条查看任务、原话与结果。」
- WeeklyReviewView.swift:282 原文区块副标题「逐条完成或不再跟进；改天仍到任务页处理。」
- WeeklyReviewView.swift:566 原文行副标题「打开任务页完成一次三选一澄清。」
- WeeklyReviewView.swift:623 原文「全部完成事项按完成时间列在「已完成」。」
- WorkspaceMonitorView.swift:156-157 原文「每天最多自动检查一次；应用退出后不自动运行，下次启动补跑；每 10 分钟只比对时间，不读 QQ、不调模型。」
- WorkspaceMonitorView.swift:1095-1096 原文「已添加的群来源在「报告」页的「来源状态」中管理启停、起始时间与删除。」

### 压缩（21 条）

- RecentContentHome.swift:717 原文「原话或处理许可变化后，旧观点不再作为当前观点显示。重新整理会生成新的观点，旧观点保留为历史。」现为「重新整理会生成新观点，旧观点保留为历史。」
- RecentContentHome.swift:923 原文「只改变这条线索的显示名，原始想法不变；留空或恢复默认后回到「…」。」现为「只改变这条线索的显示名，原始想法不变。」
- WorkspaceActivityViews.swift:202 原文「本窗口内切页保留草稿；正式保存后才接回任务，关闭窗口前请保存。」现为「未保存的草稿只在本窗口保留，关闭窗口前请保存。」
- WorkspaceActivityViews.swift:571 三项非当前状态说明压缩为「这项任务已有完成记录，无需再次完成。」「这项待办尚未登记完成；暂停不代表识别有误，打开下方材料查看原因。」「这次提取作为历史保留；本条记录仍单独保留完成状态。」
- WorkspaceActivityViews.swift:898 原文「上次改期没有派发；重新设置期限会建立新的写前核对，旧记录保留。」现为「上次改期未派发；重新设置期限会重新核对，旧记录保留。」
- WorkspaceActivityViews.swift:1012 原文「还没有记录进展。记录后会按日期在这里形成时间线。」现为「还没有记录进展。」
- TextCaptureView.swift:57 原文「草稿自动保存在本机，切页或重开应用可继续；保存成功后清空。」现为「草稿自动保存在本机，保存成功后清空。」
- TextCaptureView.swift:230 原文「把当前完整原文保存为模板，之后可一键填入草稿。」现为「之后可从「模板」菜单一键填入草稿。」
- TextCaptureView.swift:258 原文「还没有模板。写好正文后，从「模板」菜单保存。」现为「还没有模板；写好正文后从「模板」菜单保存。」
- TextCaptureView.swift:285 原文「只支持 http 或 https 链接。抓取成功后填入当前草稿；当前草稿不为空时会先确认替换。」现为「支持 http 或 https 链接；草稿不为空时会先确认替换。」
- WeeklyReviewView.swift:456 原文「从即将与随时里挑最多 3 条，确认后加入专注。」现为「最多选 3 条加入专注。」
- WeeklyReviewView.swift:617 原文「最近 7 天登记完成的行动，按完成时间倒序；没有记录结果的仍留在列表里。」现为「最近 7 天登记完成的行动，按完成时间倒序。」
- WeeklyReviewView.swift:716 原文「目标还没有可以推进的下一步；逐个澄清，或直接加一个下一步。」现为「目标还没有可以推进的下一步。」
- WeeklyReviewView.swift:763 原文「超过 60 天没有回看；回看后恢复为目标或放手。」现为「超过 60 天没有回看。」
- WorkspaceMonitorView.swift:120-122 原文副标题含「微信收到每日汇总。」与「微信推送尚未配置。」两句，现为单句「每天检查一次 QQ 班级群与学院官网；需要行动的事项在这里跟进。」
- WorkspaceMonitorView.swift:273 原文「最近 N 次检查中早于今天的报告；点开查看同结构内容。」现为「最近 N 次检查中早于今天的报告。」
- WorkspaceMonitorView.swift:473 原文「报告未完成，暂无事项。先处理上方原因，再重新检查。」现为「报告未完成，暂无事项。」
- WorkspaceMonitorView.swift:888 原文「应用退出后不会自动运行；下次启动会补跑漏掉的一天。检查开始前只比对时间，不读 QQ、不调模型。」现为「应用退出时不自动运行，下次启动会补跑。」
- WorkspaceMonitorView.swift:900 原文「默认关闭；关闭时检查会停在分析前，不偷偷发送。」现为「默认关闭；关闭时检查在分析前停止。」
- WorkspaceMonitorView.swift:1003 原文占位「可选；留空自动选择（多数情况留空即可）」现为「可选，留空自动选择」
- WorkspaceMonitorView.swift:1151 原文「选择要监测的群（同名时按最新消息时间和群号区分，不默认选择）」现为「选择要监测的群」

### 移入悬停提示（2 条）

- WorkspaceActivityViews.swift:653-655 原文「键盘：x 或空格完成 · s 改期 · f 记结果；在输入框里打字时不生效。」移至任务页 ScrollView 的 `.help`。
- TextCaptureView.swift:122 原文「⌘⇧R 开始或停止口述」移至原文编辑器的 `.help`。

### 保留（按要求）

- 政策与授权：仅本机保存、允许云端、会发送给模型、密钥与数据库不发送、钥匙串存储。
- 不可逆操作：导入替换草稿、模板覆盖草稿、删除模板、删除监测来源。
- 断连、失败、暂停：提醒事项未连接或待核对、整理受阻、监测读取失败。
- 草稿会丢失：记录进展编辑器与记录想法页的草稿提示，均已压缩但保留。

## 间距节奏

- RecentContentHome：时间线列表 18 → groupGap；结果阅读区 16 → groupGap；反馈条目 12 → rowGap；阅读区标题 16 → groupGap，摘要 24 → sectionGap，待办徽标 20 → groupGap；线索区块 44 → sectionGap，线索分隔线 18 → groupGap；想法条目 12 → rowGap；想慢慢做到与想法组顶距 18/20 → groupGap；待办列表顶距 54 → sectionGap。
- WorkspaceActivityViews：交付页与任务页主栈 30 → sectionGap；进展时间线条目 16 → rowGap，并去掉 6 的顶部内边距。
- TextCaptureView：正文区外层 16 → groupGap；标题、原文、保存选项收进 rowGap 表单组；三个弹层 16 → groupGap。
- WeeklyReviewView：页面主栈 24 → sectionGap；逾期分组顶距 12 → groupGap。
- WorkspaceMonitorView：运行栏 10 → rowGap；事项分类组顶距 8 → groupGap。

保留的间距：

- 行内 `padding(.vertical, 10)` 是命中区，不是行间距，未动。
- 监测事项卡之间保留 6 加 10 的间距，卡片内含按钮，需要分离防误触。
- 周回顾区块副标题保留 14 天、7 天、60 天与暂停口径的说明。
- 记录想法页底部状态栈保持 12，错误、进度、说明与按钮同属一个操作区。

## 风险与待复核

- 删除「历史记录已冻结，不再写入。」后，冻结操作仍显示「上次改期：」与状态摘要，但 `ReminderScheduleOperationState.summary` 未写明已冻结。若复核认为必要，可改在 state summary 里补「已冻结」。
- 快捷键只剩悬停提示，可发现性下降，符合本次「不再常驻可见」的要求。
- 首页材料阅读区线索区块 44 → 28、待办列表 54 → 28，阅读页整体更紧，仍在 sectionGap 之上。
- 周回顾页标题副标题已删除，首屏少一句导语；各区块保留标准与范围副标题。

## 验证

- 五个文件逐个执行 `xcrun swiftc -parse`，均通过。
- 按约束未运行 swift build 或 swift test。
- `git status` 只含本单元的五个源文件与本文档。
