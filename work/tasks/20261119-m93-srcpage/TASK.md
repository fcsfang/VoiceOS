# 波 93 任务 B（2026-11-19）：来源详情页信息架构重排

## 用户诉求

「点进一个材料之后看内容，内容非常杂乱，出现非常多额外的信息。我点进一个材料只想看到这个材料能给我带来什么提醒、能给我带来什么帮助。」
目标：第一屏先给这份材料整理出的观点（帮助）与待办（提醒），过程性信息下沉或收起。

## 改动（Sources/VoiceOSApp/WorkspaceSourceView.swift，行号为改动后）

1. SourceFoldState `77-91`：`thoughts` 默认 true；`original` 默认 false；新增 `extras`、`records` 默认 false；删除 `collapsedTranscriptLimit` 与按长度展开逻辑；`initial(transcript:)` 保留签名并恒返回默认值，`WorkspaceView.swift:880` 调用点不变。
2. 计算属性 `337-342`：`historyActions`（原局部变量上提，供折叠计数与分组复用）、`extraSectionCount`（更多资料组内实际节数）。
3. 单条观点 `419-470`：保留陈述、归属与「记录行动意图」（426）；「更正理解或归属」「停止使用」收进行尾 Menu（428-433，ellipsis.circle，accessibilityLabel("更多操作")）；ClaimNoteRow 移入 DisclosureGroup「原话依据、旁注与调整」（435、455），其余原话引用、审阅历史、查看原讨论不动。
4. 空整理文案 `476-484`：改为「这份材料还没有整理出观点。」并给「重新整理」按钮（479-482），禁用与帮助条件对齐原菜单项「重新整理当前文字」。
5. 主阅读顺序 `608-844`：
   - `608-616` 转写未完成提示（原 643-651，任务书未指定位置；放在条件 banner 后、digest 前，保持阻塞信息最前）；
   - `617` digestSections（整体理解/内容摘要 → 核心要点，核心要点默认展开）；
   - `618-661` pausedThoughts 大面板与「观点已更正，关联待办需要重新确认」，连同 processing 行与 followup 摘要；
   - `662-674` 待办、问题与目标前置到 digest 之后；
   - `675-687` 理解有需要补充的地方；
   - `688-709` 原文与回听（内容不变，默认收起，保留 `.id("source-original-fold")`）；
   - `710-775` 新 SourceFold「更多资料」（archivebox）：节目与我的思考（含加载/失败行）、之前提取的任务与完成记录、逐字稿大纲、章节、人名与术语；组内渲染结构与内部 fold 保留；count 为实际节数，0 时隐藏；
   - `776-844` 新 SourceFold「处理记录」（tray）：现有「依据、修订与处理记录」WorkspaceSection 整体，组尾材料管理（837-842，归档/回收站与说明）与页面 error（843）。

## 判据落点

- 首屏：digest（核心要点默认展开）紧随头部与条件 banner；暂停说明、待办、问题与目标在 digest 之后、原文之前。
- 可达性：所有原功能保留，仅移动/收起；未删除既有 accessibilityIdentifier 与字符串锚点（`source-original-fold` 仍在 709，`source-para-`/`source-span-` 未动）。
- 标识与键盘：仅新增「更多操作」accessibilityLabel；未新增 keyboardShortcut。
- 无迁移：纯视图层重排。
- 测试：基线 637 项不动，未新增测试。

## 真实退出码

- `swift build -j 2` → `build_exit=0`（Build complete! 114.40s）
- `swift test -j 2` → `test_exit=0`，Executed 637 tests, with 0 failures (0 unexpected) in 42.410s
- 构建与测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁，结束 rmdir；任务结束后锁目录不存在）。

## 权衡与遗留风险

- 任务书未给「转写未完成」块（原 643-651）位置；放在条件 banner 后、digest 前，保证转写缺失时恢复动作仍最先可见。
- 「更多资料」count 为动态节数，无节时不显示数字。
- 「处理记录」内嵌 WorkspaceSection，展开后为卡中卡；折叠态页面更短，展开态层级比原先更深。
- 暂停面板按任务书 658-701 范围整体上移，含 processing 行与 followup 摘要，二者同属「整理中/更新」状态。
- 观点行的更正与停止使用现在多一次点击（菜单内），旁注收进「原话依据、旁注与调整」；均为任务书要求的收起。
- 未在运行中的应用里做视觉核验（约束：不重启应用）；本波只验证了真实构建与测试退出码。
