# 优化审计 2026-11-16

目标：回答“现在的软件还能怎么优化（UI 与功能）”。只读审计，不改代码。

证据来源：
- 实机截图（本机实时库，只读导航）：`/tmp/p-home.png`、`/tmp/p-topics.png`、`/tmp/p-materials.png`、`/tmp/p-actions.png`、`/tmp/p-goals.png`、`/tmp/p-review.png`、`/tmp/p-launch.png`、`/tmp/p-settings.png`、`/tmp/p-processing.png`、`/tmp/p-panorama.png`
- 启动/刷新 trace：`/tmp/s1b-trace-1.txt`
- 实时库只读计数（`mode=ro`）：opportunity open current 197、opportunity open frozen 152、task open current 18、task completed 80、task open frozen 59、待核对合计 76

## A. 假控件与错位交互（先修）

1. 任务行左侧强调色圆圈不是完成按钮，点击打开详情；真正的完成按钮只在悬停胶囊里（`WorkspaceView.swift:1372`、`:1956-1971`）。HIG 实测（interface-reference.md:215,219）里勾选圈常驻且承担强调色。
2. 首页默认「最近」模式下工具栏「讨论」按钮必然报错：`.home` 分支要求全景 selection（`WorkspaceView.swift:1836-1841`）。
3. 底部处理条常驻所有页面；在处理页上点「查看处理」无动作（`go` 同目标不执行，`WorkspaceView.swift:425`、`:1702-1704`）。
4. 行悬停胶囊覆盖行尾状态文字（截图：材料页「在读」被胶囊压住；`WorkspaceView.swift:1951-1988` 的 overlay 与 `WorkspaceRow` trailing 同槽）。
5. 添加下一步失败后重试会重复建待办：`addNextAction` 每次新 UUID commandID，挂接失败表单保留（`VoiceOSApp.swift:2956-2975`、`WorkspaceActivityViews.swift:672-681`）。
6. 列表行菜单仍只有旧「转为待办」，把目标改成待办后不可逆；没有「添加下一步」（`WorkspaceView.swift:1358-1365`；对照 `action-model-research.md` 第 2 条）。

## B. 信息层级（规范落地后的残余）

1. 状态重复渲染：问题与目标 197 行每行尾「还没有下一步」（`WorkspaceView.swift:1293-1295`），待核对 76 行每行尾「待核对」（截图）。
2. 类型标签留在标题字符串里：`【问题】/【长期目标】/【想法】/【待核对】` 作为正文前缀进入数据（`RecentContent.swift:182`、`PanoramaThemeReply.swift:137`），各视图各自 `replacingOccurrences`（`RecordingFollowupView.swift:136`），展示不一致。
3. 首页时间线行只有标题+时间，缺材料页的四槽位状态（仅本地/整理中/待核对/在读），与 `hierarchy-spec.md:87` 验收不一致（`RecentContentHome.swift:60-74`）。
4. 「任务进展」按天聚合体被画成一条材料：标题固定、时间取当天最后一条（`RecentContent.swift:203-218`）。
5. 行槽位 2 塞两个事实（「到期… · 来自『…』 · 还没有下一步」），违反 `hierarchy-spec.md:49`。
6. 主题卡为两行摘要预留空间，无摘要的卡留 ~80pt 空洞（`WorkspaceTopicReadingView.swift:389-396`，截图 p-topics）。
7. 材料页「69 份」与「…」同排、随筛选变化无范围标签；阅读状态用 trailing 文字（`WorkspaceView.swift:756-764`、`:1256`）。
8. 启动页默认展开上一条草稿，历史列表被推到屏外；`text.cursor` 图标被读成 stray「字」（`TaskInitiationView.swift:26-29`、`:66`）。
9. 处理页每个失败项重复同一副标题 + 独立披露 + 独立重试，2 条失败占一张卡片（`WorkspaceProcessingView.swift:228-232`，截图 p-processing）。

## C. 功能缺口

1. 197 条问题与目标没有批量澄清队列；只有逐行详情 + 停滞横幅「打开第一条」（截图 p-goals；`WorkspaceView.swift:917`、`:1651-1681`）。
2. 「将来也许」状态缺失（`ActionStore.swift:6` 三态；rg someday 无结果），无回看节奏。
3. 主题对象不进搜索索引（`SearchIndex.swift:4-8`、`:76-99`），主题页无本地筛选。
4. 快捷键只以两列静态文字存在（`WorkspaceView.swift:1141-1159`），绝大多数命令不在菜单栏。
5. 首页读录音整理结果但不能回听、不能核对某条想法出自哪句原话；「打开材料」埋在页尾（`RecentContentHome.swift:148-157`）。
6. 多段录音在首页不合并，同一场对话出现多条（`RecentContent.swift:147-150` 对照材料页 `WorkspaceView.swift:707-719`）。

## D. 性能（store actor 上的重复开销，实测）

1. `savingAction` 锁跨整轮 `await refresh()`：实测一轮 reload 6.6s，期间任何任务操作被拒（`VoiceOSApp.swift:2898-2938`、trace 674→7289ms）。
2. 每轮刷新重算全库 briefing：1331–1577ms（trace；`WorkspaceSnapshot.swift:126`、`TopicOrganization.swift:99-160`）。
3. 每轮刷新逐条重新校验 8 条助理委托：2398ms（trace；`AssistantExecution.swift:131-175`，全库 context 屏障重复 8 次）。
4. 跟进回执 567ms + 有效性 905ms，重复全库读取与逐条转写重摘要（trace；`RecordingFollowup.swift:370-389`）。
5. 问题与目标行每行 O(n) 扫描统计下一步数（`WorkspaceView.swift:1294`），197 行 × 524 条。
6. 全景首帧先显示「部分全景 3/34」，数秒后跳到 30/34（两次截图对比），刷新粒度造成跳变。

## 审计覆盖

- 五路代码审查（首页/行动/界面/缺口/性能）完成；第六路（跨页 UI 系统）超时未返回，其范围由本人直接核对：字号令牌外的硬编码仅 6 处（19pt 品牌 4 处、62/18 各一）加 Onboarding 一处 28pt；侧栏按钮有 AXDescription；底部条为布局内常驻而非覆盖（`WorkspaceView.swift:418-425`）；窄窗 980pt 时全景工具栏搜索框被裁切。
- 性能数字来自单次 trace（`/tmp/s1b-trace-1.txt`），无多轮方差；按 Explain the Number，只能作为定位依据，改动后必须同库同 trace 复测再报数。
- 本人逐条核对过：讨论按钮错误分支、savingAction 锁、完成圈与悬停胶囊、addNextAction 幂等缺口、搜索索引缺主题、主题卡预留空行、处理页重复说明、快捷键静态清单、197/76 实时计数。

## 波次建议

- 波 A（交互正确性，全部 S）：A1 完成圈 / A2 讨论按钮 / A3 处理条 / A4 添加下一步幂等 / A5 行菜单语义。
- 波 B（层级收尾，S–M）：B1 状态去重 / B2 类型标签成字段 / B3 首页槽位 / B4 聚合体形状 / B5 小项合集。
- 波 C（功能，M–L）：C1 批量澄清队列 / C2 someday + 回看（schema 63）/ C3 主题进搜索。
- 波 D（性能，M）：D2 briefing / D3 助理快照 / D4 跟进复用 / D1 保存不等刷新。
