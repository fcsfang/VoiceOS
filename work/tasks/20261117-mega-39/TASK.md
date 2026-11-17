# 波 39：全景失败引导与阶段进度、搜索过滤与直达

来源：只读发现者 F（全景浏览）与 E（搜索体验）。六件事全部 S/S·M，两单元文件不相交。

## 完成判据

1. 全景 failed/unknown 状态行：显示「已有 N/M 个单元通过核对」；快照存在且已核对单元 > 0 时给「生成带候选联系的综合草稿」主按钮，点击复用既有草稿生成通道、不重跑核对。
2. 运行中状态句渲染当前阶段「正在核对〈材料标题〉· 分片 i/n」（activeScope 来自 panorama_steps 的 running 行，已有数据）；无 running 行时退回「已核对 x/y」。
3. 失败原因去 UUID：错误文本把单元 id 映射为材料标题（input.sources 有 title），按错误类别各给一句可操作建议；工具栏 tooltip 不再裸露 UUID。
4. 搜索行动段只列 open 且 current；观点段只列 current；段头计数与可见集合一致（SQL 先过滤再截断与计数）。
5. 观点结果点击直达原话段落：用引用 spanID 设材料页滚动锚点后打开（span 缺失退回顶部）。
6. 每类结果段头给「显示全部」入口（空结果不显示）；最小可行 = 临时抬高该类上限重查并在报告说明。
7. swift build 与 swift test 真实退出码 0（465 项基础上新增）。

## 共享契约

- P1：草稿按钮复用既有「生成草稿」动作（ThoughtPanoramaView 溢出菜单 395-411）；文案「已有 N/M 个单元通过核对，可先生成带候选联系的综合草稿」。activeScope 已在 PanoramaProgress 计算未渲染（ThoughtPanorama.swift:217-222），只做渲染与材料标题映射。
- Q1：过滤在 searchAll 的 SQL（claims.validity='current'；actions.state='open' AND validity='current'），计数取同一过滤集；span 锚点复用 WorkspaceSourceView 的 source-span 锚点命名（892/937 行），经 sourceScrollPositions 写入后打开。
- 两单元都不动对方文件；本轮无 schema。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| P1 全景感知 | `work/m39-p1` / `.worktrees/m39-p1` | `Sources/VoiceOSApp/ThoughtPanoramaView.swift`、`Sources/VoiceOSApp/PanoramaScreenModel.swift`、`Sources/VoiceOSCore/ThoughtPanorama.swift`、`Sources/VoiceOSCore/ThoughtPanoramaStore.swift`（仅错误映射）、`Tests/VoiceOSCoreTests/`（全景相关，如有核心行为变化） | 判据 1、2、3 |
| Q1 搜索收敛 | `work/m39-q1` / `.worktrees/m39-q1` | `Sources/VoiceOSCore/SearchIndex.swift`、`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/WorkspaceReadingViews.swift`、`Tests/VoiceOSCoreTests/SearchIndexChecks.swift`、`Tests/VoiceOSCoreTests/TopicSearchIndexChecks.swift` | 判据 4、5、6 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- P1：今天 02:44Z 的尝试快照 34/35 单元、85 区域、可恢复展示（发现者 F 实证）——状态行应把这一点说人话。错误分类五类：响应未完成或格式无效 7、单元语义核对失败 3、依据变化 3、网络或 403 2、进程退出 5。
- Q1：段头按钮位已在 WorkspaceReadingViews.swift:169-171 预留；「显示全部」用 per-kind 上限抬高（如 200）重查一次，不做分页；观点行打开前写锚点，失败静默退回。
- 协调者纪律：构建与测试一律后台直跑并记录真实退出码（`> log 2>&1; echo "$?"`），任何管道退出码不作证据。

## 验证基线

- panorama_attempts 22 行分类与今天 02:44Z 尝试快照（发现者 F 的 SQL 证据）。
- 搜索：实时库「任务」前 20 行动仅 5 条 open 且 current；「问题」前 20 观点 4 条 frozen；观点 current 730 / frozen 323。
- 锁屏时界面实拍留待解锁。

## 结果（完成后填）

## 结果（2026-11-17 晚）

- P1：失败/中断状态行改为「已有 N/M 个单元通过核对，可先生成带候选联系的综合草稿」并把草稿升为主按钮（复用既有草稿通道，不重跑核对）；运行中显示「正在核对〈材料标题〉· 分片 i/n」（来自 panorama_steps 的 running 行与 input_json 分片序号）；错误文本与 tooltip 去 UUID，unit 映射为材料标题并按五类错误各给一句建议；旧尝试的错误也按文本归类。新增测试 2 条。
- Q1：searchAll 两条路径（trigram 与子串）都在 JOIN 后、截断前过滤（行动 open 且 current，观点 current 且非 rejected），段头计数与可见集合一致；观点结果直达原话段落（span 锚点，缺失退回顶部）；每类段头「显示全部」（perKindLimit 200 重查、换词重置）。新增测试 3 条。
- 验证（真实退出码）：swift build 0（Build complete! 66.68s）；swift test 0，471 项 0 失败（465 基础上新增 6）。
- 说明：通用 store.search 同样只返回 current/open 集合（Q1 报告注明）；显示全部上限 200。
