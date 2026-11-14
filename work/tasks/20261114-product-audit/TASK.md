---
status: planning
started: 2026-11-14
updated: 2026-11-14
branch: -
pr: -
owner: coordinator
---

# 产品参照审计与逐单元改进

## 目标

用户要用 `docs/product/reference-products.md` 的三段参照检查现有功能，找出违背参照纪律的地方，按用户影响排序，再按单元改进。审计已完成，本文是缺口清单与修复顺序。修复未开始。

## 方法

四路只读审计，分抓取、归纳阅读、承诺行动、拼接共享层。每路读代码给 file:line 证据，按用户影响排序。主线程逐条核对关键结论，两处代理结论被修正，见决策。未运行应用，视觉和手感未实测。

## 范围

- 确认的缺口与排序。
- 修复单元 U1 到 U8 的边界和依赖。
- 不包含具体实现。

## 确认的缺口

### 结构缺口

1. 行动页没有「今天 / 即将 / 随时」时间面。只有分类清单和逐行到期信息（`WorkspaceView.swift:603`、`:671-679`、`:795-802`）。参照 Things 的 Today。
2. 没有澄清步骤。抽取的行动直接以 open/current 入库（`CognitiveStore.swift:189-193`），`ConfirmTaskView.swift:13-27` 只把问题与目标转成待办。参照 GTD 的 clarify。
3. 没有固定节奏的行动回顾。知识核查按材料整理事件触发，主题重现只在弹层内（`ReflectionQuestionsView.swift:108-117`）。参照 GTD 每周回顾和 Readwise 每日回顾。
4. 截止日与「何时做」没有分开。只有 `action_schedule_intents.due_json` 一个时间字段（`Database.swift:664-679`）。参照 Things。

### 接缝缺口

5. 任务页的「原话依据」只列来源标题和回听按钮，不显示引用 span（`WorkspaceActivityViews.swift:266-271`）。材料页显示 span 和回听（`WorkspaceSourceView.swift:266-274`）。同一份证据两处深浅不同。
6. 行动列表不显示来源（`WorkspaceView.swift:824`），要逐条点开才知道从哪句话来。
7. 标记已完成不产生回流。首页只收反馈记录（`RecentContent.swift:129-152`）。只点完成、不写结果时阅读面无变化。参照文档接缝三。

### 表面混用

8. 首页阅读栏末尾的「接下来」是死清单。有圆圈和任务行，没有 Button（`RecentContentHome.swift:211-236`），点不动。
9. 主题阅读页混入指标和开放行动清单。概览有「待办 / 完成记录」指标（`WorkspaceTopicReadingView.swift:89-94`）和「可以接着做」（`:220-233`）。
10. 行动段里放长篇 AI 报告（`WorkspaceView.swift:342, 390-393`；`WorkspaceActivityViews.swift:16-43`）。
11. 首页「最近 / 全景」并列，全景按 AI 分区组织（`WorkspaceView.swift:352-371`）。参照文档说不把图谱当导航首页。这一条存疑，全景是核心实验功能，本轮不动。

### 抓取摩擦

12. 文字抓取是表单。保存前必须填标题、选归属、决定云端、二选一保存（`TextCaptureView.swift:19-25, 89-95, 107`）。
13. 两条入口默认相反。手打文本默认个人加云端，导入文件强制外部加仅本地（`TextCaptureView.swift:151-153`）。自动入口只对首次默认授权改为可云端，显式撤销保留（`VoiceOSApp.swift:1101-1102`）。
14. 录音没有随手写几行的意图层，归纳只读转写（`Models.swift:36-47`；`RecordingExpression.swift:145-163`）。
15. 收件箱与已处理没有用户面视图，收件箱只列未完成和失败项（`RecordingInbox.swift:383-417`）。
16. 完整录音先问音轨和「是否我的声音」。单轨也要勾选，外部导入只在单轨且非本人时出现（`FullRecordingView.swift:30-69`）。

### 共享层

17. 没有间距 token。`WorkspaceMetrics` 只有宽度、圆角、弹窗尺寸。20 处字面圆角，7 处非 palette 颜色，固定高度不随字号缩放。见 PR #142 任务卡的已知边界。
18. 反馈标签映射有两份，`ActionFeedback.swift:22-30` 与 `RecentContent.swift:246-259`。

## 决策

- 2026-11-14 字号结论修正：代理称 `dynamicTypeSize` 定义了未应用，不成立。`WorkspaceView.swift:204` 已应用，全仓只剩 `PanoramaConstellation.swift:1219` 一处有意缩放。不修。
- 2026-11-14 自动入口授权修正：不是任意改回云端，只对 `policy.version == 1` 的首次默认生效，显式撤销保留。缺口收窄为两条入口默认不一致。
- 2026-11-14 阅读宽度 720 与 860 不是缺陷。阅读 measure 应窄于混合详情页。要做的是定义 reader token，不统一成 860。
- 2026-11-14 全景不动。它违背「图谱不当导航首页」，但它是核心实验功能，且不是默认视图。保留观察。
- 2026-11-14 修复必须等 PR #142 合并。它改了多数行动与阅读视图文件，先落地避免冲突。
- 2026-11-14 单元排序按用户可见影响和依赖，不按代码整洁度。
- 2026-11-14 执行授权。用户全权授权本任务并允许并行。采用堆叠分支，根是文档提交，基分支为 PR #142 的 `work/ui-copy-cleanup`。不合并任何 PR，全部停在 merge-ready。
- 2026-11-14 U1 取舍。首页「接下来」不保留清单，改成一行「这条材料带出了 N 条待办」加一个入口。阅读面不出现复选框式列表。
- 2026-11-14 U2 取舍。完成时用一次轻提示「记录结果」接上既有反馈流程，不自动生成完成记录。用户可以跳过，不污染反馈流。
- 2026-11-14 U3 取舍。「改天」复用现有的日期与提醒设置弹窗，不新增计划日字段。「不再跟进」走既有 dismissed，历史记录要能找回已放下的行动。
- 2026-11-14 U6 取舍。采用附加式澄清，不改变行动创建。仅在任务页给出一次三选一提示，判断落新表 `action_clarifications`，schema 升到 54。只提示最近 14 天抽取且未澄清的任务，避免历史任务涌入。
- 2026-11-14 U7 取舍。每周回顾做成行动页打开的回顾面板，复用 U3、U4、U6 的出口，不新增顶级导航。
- 2026-11-14 U8 取舍。只收外层可见不一致和标签映射合并，不逐条替换 144 处 padding。
- 2026-11-14 编译策略。三个并行 owner 各自全量编译，16GB 机器内存被耗尽。用户指定只在最后编译一次。U1 到 U8 全部集成完成后跑一次 `swift build -j 2`，修复编译错误后再跑一次 `swift test -j 2`。中间单元不编译。

## 修复单元

- U1 阅读面去清单化与死控件（S）。待办行可点或收敛为单行入口，主题页开放行动移出阅读面。文件：RecentContentHome、WorkspaceTopicReadingView、WorkspaceView。
- U2 任务面出处与完成回流（S/M）。任务页直接渲染引用 span，行动行显示来源标题，完成时就地记录结果或插入轻量完成记录。文件：WorkspaceActivityViews、WorkspaceSourceView、RecentContent、VoiceOSApp。
- U3 行动出口（S）。加「不再跟进」走既有 dismissed，加「改天」写计划日期。文件：WorkspaceActivityViews、ActionStore。
- U4 今天面（M）。行动页加今天、即将、随时。日期先取本地 schedule intent，再退回提醒事项回读，并标「未同步」。文件：WorkspaceView、ActionScheduleStore。
- U5 抓取减负（M）。文字允许空标题按首行命名，归属和云端推迟到第一次归纳，两条入口默认一致。文件：TextCaptureView、TextCaptureDraft、TextCapture、RecordingInbox。
- U6 澄清入口（M）。任务页对最近抽取且未澄清的行动给一次三选一提示，承诺、问题与目标、不是。判断落 `action_clarifications`，schema 54。不改变行动创建。文件：CognitiveStore、WorkspaceView、ActionStore、Database。
- U7 每周回顾（M/L）。行动页打开的回顾面板，覆盖逾期、长期未动、待确认、本周完成与结果、暂停。在 U3、U4、U6 之后。
- U8 共享层收尾（M）。spacing token、minHeight、颜色逃逸、标签映射合并。

建议顺序：U1、U2、U3 先做，小改动、用户可见。再做 U4、U5。U6 需要产品确认。U7、U8 最后。

## 非目标

- 不做 PDF、网页剪藏。
- 不加录音随手记字段。新功能，L 级，本轮不做。
- 不重做全景导航。
- 不引入看板、优先级矩阵、多人指派。

## 当前状态

2026-11-14 执行中。审计完成，用户全权授权。堆叠根 `work/product-audit` 已并入第一批，阅读面 `179d332`、抓取 `944f3fe`、任务页出处与完成提示 `74d0072`、行动出口 `aa287e3`。U4 加 U6 进行中，U7 加 U8 最后。全部单元结束后只编译一次。

## 下一步

集成第一批，复核差异，再派 U4 和 U6。全部停在各分支 merge-ready，合并顺序从 `work/product-audit` 起逐层向上。

## 验证

- 全部单元集成后只编译一次 `swift build -j 2`，修复错误后跑一次 `swift test -j 2`。中间不编译。
- 每个 UI 单元取实机前后对比截图。无法取得时在任务记录里标注。
- U4 的日期口径在本地排期与提醒事项回读冲突时以本地为准，并可见标注。

## 链接

- `docs/product/reference-products.md`
- `work/TODO.md`
- PR #142
