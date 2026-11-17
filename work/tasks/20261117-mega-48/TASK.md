# 波 48：认知地图可达、回顾汇总；Spotlight 深链与搜索建议

来源：发现者 L（每周回顾与回顾图）与 M（搜索建议与系统集成）。

## 完成判据

1. 周期认知地图可达（L1）：每周回顾顶部给「认知地图」入口，以独立模式呈现 ReflectionTimelineView（embeddedTopicID nil），周期切换、认知对照、「一起回顾」与 Esc 关闭全部可用；现有主题嵌入入口不变。
2. 每周回顾首屏汇总（L2）：标题下一行可点汇总「本周完成 N · 待补结果 M · 停滞目标 K · 待确认 L」（数字取自现有数据）；点击跳到对应区块；「关闭」支持 Esc；加载失败时显示 model.status（不再静默）。
3. 入口与快捷键（L3 + M4）：首页页头加「每周回顾」按钮（走 openWeeklyReview）；CommandMenu 加 ⌘⇧E；首页待填结果徽标可点（进每周回顾或行动页结果区，报告说明）；菜单栏「今日一览」追加「另有 N 条未排期任务」与「查看全部行动…」。
4. Spotlight 深链（M1）：观点条目用首个 reference 生成 voiceos://source/<id>；主题 28 条以 voiceos://topic/<id> 入索引并在 routeExternalURL 处理 topic 分支（选中主题进主题页）；无引用观点保持现行为。
5. 搜索建议（M2）：输入 ≥2 字符时，下拉前 5 条前缀建议（材料名、主题名、开放任务标题、观点陈述，类型图标），回车直达（结果行打开或查询该词，报告说明）；最近搜索 chip 可单条删除。
6. swift build 与 swift test 真实退出码 0（508 基础上新增，如核心有变化）。

## 共享契约

- WA：认知地图入口放周回顾页头（不新增 WorkspaceView 路由）；Esc/快捷键沿用现有 keyboardShortcut 模式；汇总数字全用既有已发布数据，不新增查询。
- WB：Spotlight topic 分支在 routeExternalURL 内加 host 处理（读码定位既有 source/action 分支）；建议用已发布的四个内存数组（sources/reflectionQuestions/actions/claims）做前缀过滤，不新增 DB 查询；最近搜索存储沿用 UserDefaults。
- 文件不重叠（见下表）。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| WA 回顾与地图 | `work/m48-wa` / `.worktrees/m48-wa` | `Sources/VoiceOSApp/ReflectionGraphView.swift`、`Sources/VoiceOSApp/WeeklyReviewView.swift`、`Sources/VoiceOSApp/RecentContentHome.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift` | 判据 1-3 |
| WB Spotlight与建议 | `work/m48-wb` / `.worktrees/m48-wb` | `Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSPlatform/SpotlightIndexer.swift`（路径以实际为准） | 判据 4-5 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- L 证据：唯一调用点 WorkspaceView.swift:1051 传 embeddedTopicID；ReflectionGraphView.swift:96 嵌入不渲染 header、158-186 周期控件仅 header；周回顾 95-115 无汇总、120-124 失败静默；首页徽标 205-206/263-267/472-475 是 Text；CommandMenu 4343、菜单栏 4004 无快捷键。
- M 证据：SpotlightIndexer.swift:89-107（claim url nil、无 topic）；OpenSearch 无参数（本期不做）；route host 仅 action/source（WorkspaceView.swift:2444-2457）；建议数据已发布（VoiceOSApp.swift:147/753/762/895）；最近搜索 WorkspaceView.swift:1501-1517。
- 协调者纪律：构建与测试后台直跑并记录真实退出码；重启先过 scripts/app/restart_preflight.sh（当前全景在跑）。

## 验证基线

- 全景一次运行中（用户发起），不得重启；波 46/47 dist 排队。
- 实时库：完成近 7 天 21/待补 20、停滞 62、待确认 13；主题 28、观点 current 732。

## 结果（完成后填）

## 结果（2026-11-17）

- WA（d7c78b4、0531a50）：周回顾页头认知地图 sheet（embeddedTopicID nil、周期切换、一起回顾、Esc 关闭）、首屏四段汇总（本周完成/待补结果/停滞目标/待确认，可点击滚动定位）、加载失败可见化、首页「每周回顾」按钮与待填徽标可点、CommandMenu ⌘⇧E、菜单栏「另有 N 条未排期任务」+「查看全部行动…」。
- WB（fd67a1d、f2a7c4d）：Spotlight 观点条目深链到首个引用、主题以 voiceos://topic/<id> 入索引并路由选中、搜索前缀建议（≥2 字，取已发布内存数组前 5，类型图标与中文标签，回车直开首条建议）、最近搜索单条删除。
- 集成：work/mega-48 合并两单元无冲突（VoiceOSApp.swift 仅 WB 两行 topics 参数）。
- 构建：`swift build -j 2` build_exit=0（156s）。
- 测试：`swift test -j 2` test_exit=0，Executed 508 tests, 0 failures（58s）。
- 部署：等闸门（全景用户运行已结束：35/36，失败单元另立案波 49）。
