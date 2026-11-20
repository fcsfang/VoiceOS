# 127-B 设置/搜索/任务/问答区小字压缩与间距节奏

## 背景

用户反馈：解释性小字没有实际作用却影响观感；同类信息间距要小，不同区块间距要大。本单元只改九个文件的文案与间距，不改组件、布局结构与配色。行号为改动前基线（4e4bc7e）。

## 小字裁决（64 条）

### 删除（6 条）

- WorkspaceView.swift:1122 原文「线索会随材料积累成为主题。」与 :1105 重复。
- WorkspaceView.swift:1214 原文「放在完整主题的脉络里，看这段时间的变化。」复述回顾页功能。
- WorkspaceView.swift:1910 原文「配色即时生效，并在下次打开时沿用。」常识。
- WorkspaceView.swift:2827 原文「选择要把「…」并入的主题。」下方列表即 Picker 本身。
- QuestionAnswerSection.swift:63 原文「回答已保存，可以在下面继续追问或阅读完整结果。」完成态副标题置空，`WorkspaceSection` 对空 subtitle 不渲染。
- QuestionAnswerSection.swift:101 原文「回答已就绪。」删除无报告时的 else 分支；按钮已在下方。

### 压缩为一句（24 条）

- WorkspaceView.swift:1006 回收站说明现为「原件与历史保留；恢复后仅本机保存。Apple 提醒事项未被删除或取消。」
- WorkspaceView.swift:1914-1922 删除重复句「撤销只对当前会话有效」，所在组已有「⌥⌘Z 撤销 · 仅本次运行」。
- WorkspaceView.swift:2671 现为「这些变更只保存在 VoiceOS；恢复提醒事项连接并授权后自动写入并回读。」
- VoiceOSApp.swift:4718 现为「可选记录，原话与原行动保持关联。开启下方选项后会自动核对思想变化与目标下一步；反馈不会当成已验证事实。」
- VoiceOSApp.swift:4900 现为「可以直接关闭。这里显示已接纳的关联提案和相关原文。」
- QuestionViews.swift:26 现为「答案依据已变化；可重开，旧答案仍保留在历史中。」
- QuestionViews.swift:49 现为「历史版本。原话更正后仍保留原依据；当前状态可能已冻结。」
- QuestionViews.swift:87 现为「选择一份明确回答这个问题的个人表达，引用连续原话；记录解决不改变未验证状态。」
- QuestionViews.swift:121 现为「出处中的问题记录；AI 关联提案不确认两次表达是同一问题，也不改变解决状态。」
- QuestionAnswerSection.swift:61 现为「让 VoiceOS 回答；答案会保存，可继续追问。」
- QuestionAnswerSection.swift:62 现为「回答正在生成，可以先做别的事。」
- QuestionAnswerSection.swift:230 现为「依据已变化，旧回答不能重试；可在操作区重新回答。」
- RecordingTitleEditor.swift:19 现为「标题用于资料库；手动标题不会被自动整理覆盖。」
- AssistantExecutionView.swift:44 现为「写下你想要的结果。应用会调研、比较或起草；可以关闭窗口，稍后回来查看。」
- AssistantExecutionView.swift:224 现为「可以关闭窗口；VoiceOS 需要保持运行。」
- TaskInitiationView.swift:119 现为「还没有可带入的个人原话；先录制或保存一段你说出的材料。」
- TaskInitiationView.swift:213 现为「回答会更准确；也可以跳过，按假设给出草稿。」
- TaskInitiationView.swift:287 现为「直接要一份回答，不创建任务或提醒。」
- TaskInitiationView.swift:331 现为「已手动编辑，偏好不再自动调整。」
- PausedActionBatchView.swift:125 现为「涉及 … 份材料、… 条暂停待办。每份材料重新识别一次，会调用已配置的文本模型；长文字或完整录音沿用现有分段流程，部分材料会先校正转写，可能多一次调用。相同依据会复用，不会重复发送。」
- PausedActionBatchView.swift:131 现为「没有可批量重新识别的暂停待办；上面的事项需要逐条核对。」
- CorrectionImpactView.swift:12 现为「更正后的内容用于后续理解。下面保留依赖更正前内容的任务；完成记录和反馈不会丢失，提醒事项也不会因一次更正被删除。」
- CorrectionImpactView.swift:33 现为「保存的观测；回读只核对现状，不取消、不改写、不补偿。」
- CorrectionImpactView.swift:73 现为「此前 AI 改过期限的，可查看恢复方案；恢复会保留任务的真实完成状态。」

另有 2 条压缩并入 .help（见下节），与上表合计 26 条压缩类裁决。

### 移入悬停提示（2 条）

- WorkspaceView.swift:1436 键盘提示「↑↓ 选择 · ↵ 打开 · x 完成 · z 不再跟进 · ⌥⌘Z 撤销上一次变更」移至任务列表容器的 `.help`。
- WorkspaceView.swift:1951 「保留份数在下次备份或立即清理时生效。」移至保留份数 HStack 的 `.help`。

### 保留（32 条，按要求）

- 政策与隐私：本机保存、会发送给模型、关联提案、查找与判断说明。
- 不可逆操作：合并主题的删除警告、导入替换、清理旧备份按钮。
- 失败、暂停、失配：快捷键冲突、依据变化、未配置模型、停止与重试。
- 输入缺失：保存视图上限与重名、没有可带入原话、没有可合并主题。

## 间距节奏（22 处）

统一使用 `WorkspaceMetrics.rowGap`（8）/ `groupGap`（18）/ `sectionGap`（28）：

- WorkspaceView: 侧栏底部 12→rowGap；材料按日分组 16→groupGap；回顾页 20→groupGap；其他工作与维护 16→rowGap。
- VoiceOSApp: 静默回顾列表 16→rowGap。
- QuestionAnswerSection: 空态/完成态/失败态 14→groupGap；依据原话与追问编辑 10→rowGap。
- AssistantExecutionView: 7/9/14→rowGap；报告分组 12→groupGap。
- TaskInitiationView: 页面 24→sectionGap；启动包 16→groupGap；启动包内 6→rowGap。
- CorrectionImpactView: 影响列表 20→groupGap；政策冻结项 4→rowGap；补偿历史行 6→rowGap。

## 未采纳

无。逐条复核后未发现与上下文矛盾的裁决，保留项均按清单执行。

## 验证

- 删除文案已检索 Sources 与 Tests，无测试或无障碍标识依赖。
- 按任务约定未运行 swift build / swift test，仅做 diff 级核对；`.help` 修饰符与 `WorkspaceMetrics` token 均为既有用法。
- 风险：两处常驻快捷键提示改为悬停提示后，发现成本升高；文案已保留在 `.help` 中。