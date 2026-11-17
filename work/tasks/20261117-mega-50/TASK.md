# 波 50 任务书（2026-11-17）

## 背景与证据

主题组织（topic-reading-v2）在实时库上持续不可完成。波 46 加了 600 秒总闸门后，失败方式从「假死一小时」变成「超时 unknown」，但结果仍未落库：

- attempt `0B20D782-BC98-4C86-B255-A7EDAD72AD5D`（19:47:35 起，新构建首次运行）state=unknown，error「主题整理超时未返回；服务端结果未知，不自动重发」。
- 该 attempt 的输入快照 435,935 字符：59 份材料、照转录标量预算 178,354；输出要求一次给出全部主题卡片（当前库 28 个主题）。
- `reflection_questions.updated_at` 仍是 2026-10-20，说明历史上最后一次成功组织也是在全库远小于现在时。
- 现按 30 分钟冷却自动重试同一超大请求，每次到点丢弃并计费，属于持续浪费。

根因判断（证据如上，机制推断）：**单请求装下整库观点与转录、要求一次产出全部主题**，模型侧响应时间超过 10 分钟。全景核对的教训与解法同构：拆小请求、增量落库、可断点续跑。

## 完成判据

1. 主题组织改为两段式：
   - **骨架段**：输入只含观点（id、statement、sourceID、occurredAt 等，不含全文转录），产出主题列表（id/title/一句话摘要）与观点→主题归属；请求体实测 < 120KB。
   - **成段段**：按主题（可 3-5 个一批）请求卡片正文；每批输入只含该主题分配到的观点与其短引文，请求体 < 40KB。
2. 每段结果即时落库：骨架完成后主题即出现在主题页（可显示「正文整理中」），每批正文完成即更新该主题；中断或失败后重试只补齐未完成批次（按批次 digest 复用，不重复调用已完成批次）。
3. 单次模型请求失败（超时、校验失败）不使整次组织失败：该批标记失败、其余批次继续；全部批次结束若有失败，attempt 记 failed 并给出「N 个主题待补齐」，主题页提供「补齐」入口。
4. unknown/超时结果的自动重试冷却拉长到 6 小时（显式重试不受限）；用户可见错误文案说明「已完成的主题会保留」。
5. 测试：伪端口驱动两段式全流程（骨架→3 个主题批次），断言主题与卡片增量写入、续跑不重复调用已完成批次、单批失败不阻塞其它批次、冷却键行为。schema 若需新表从当前版本 +1 并幂等。
6. `swift build -j 2` 与 `swift test -j 2` 真实退出码 0。

## 单元与文件所有权

### Unit TS（分片组织核心 + 冷却与补齐入口）
- 文件：`Sources/VoiceOSCore/TopicOrganization.swift`、`Sources/VoiceOSCore/ResponsesTopicOrganizationPort.swift`、必要时新增 `Sources/VoiceOSCore/TopicOrganizationSlicing.swift`、`Sources/VoiceOSCore/CognitiveStore.swift`（仅 schema 迁移追加）、`Sources/VoiceOSApp/VoiceOSApp.swift`（仅组织队列与冷却、错误文案段）、主题页文件（`WorkspaceTopicReadingView.swift` 或实际文件，「补齐」入口与「正文整理中」状态）、新增测试 `Tests/VoiceOSCoreTests/TopicOrganizationSlicingChecks.swift`。
- 已有资产必须先读：attempt 行与 `topicOrganizationsAreCurrent`/`needsTopicOrganizationRefresh`、失败冷却（`UserDefaults voiceos.topics.lastFailure`）、`withModelDeadline`。保持 `topic-reading-v2` 旧 prompt 的恢复校验排除逻辑（`CognitiveStore.swift:367`）不被破坏。
- 提示词版本升为 `topic-reading-v3`，两段各自有 identity（骨架 `topic-skeleton-v1`、正文 `topic-body-v1`），attempt 行按段记录。
- 补充（来自静默失败审计第 6 条）：组织失败/冷却状态要接入处理页「需要查看」与首页注意力，不再只藏在主题页角落。

### Unit UC（页面断头路，来自只读审计）
- 文件：`Sources/VoiceOSApp/WeeklyReviewView.swift`、`Sources/VoiceOSApp/ReflectionGraphView.swift`、`Sources/VoiceOSApp/WorkspaceDiscussionView.swift`、`Sources/VoiceOSApp/RecentContentHome.swift`。
- 修复项（按审计排序取前五，第六条视成本顺手）：
  1. 周回顾顶部统计：计数为 0 或目标区块未渲染时改为纯文本，不再渲染可点按钮（审计 1，WeeklyReviewView.swift:159-178 与 :118-121）。
  2. 周回顾加载失败加「重试」，重跑同一段加载（审计 2，:129-136/:110）。
  3. 讨论页未配置模型时在 composer 处说明「发送需要先配置文本模型」并给出配置入口；若开口需改 WorkspaceView.swift，最小版本只显示原因文字（审计 3）。
  4. 认知地图刷新：`topics` 为空或 `error` 非空时同时重跑 `loadTopics()`（审计 4，ReflectionGraphView.swift:193/:146/:209-220）。
  5. 「最近想法」「看原话」查不到声明时用既有 `showClueFailure` 提示（审计 5，RecentContentHome.swift:458-462）。
  6. 「还有 N 条」等剩余计数改为跳转按钮（审计 6，WeeklyReviewView.swift:651 等），若需要新路由且成本高，记录并跳过。
- 不改 VoiceOSApp.swift（TS 独占）、WorkspaceProcessingView.swift（波 51 独占）与主题组织核心（TS 独占）。

## 集成

- 分支 `work/m50-ts`、`work/m50-uc` 从波 49 合并后的 main 切出；协调者合并到 `work/mega-50`，单次构建 + 全量测试，结果写本文件。
- 波 51 预定：长录音分段理解的失败出口（静默失败审计第 1 条，`SegmentExtraction.swift:118/:131-132`、`SegmentAggregation.swift:121/:133-134`、未被调用的 `revalidateRejectedSegmentAggregation`），以及审计第 2-5 条按成本取舍。
- 不写实时库；不重启应用；等闸门。

### Unit UC（页面断头路，来自只读审计）
- 文件：`Sources/VoiceOSApp/WeeklyReviewView.swift`、`Sources/VoiceOSApp/ReflectionGraphView.swift`、`Sources/VoiceOSApp/WorkspaceDiscussionView.swift`、`Sources/VoiceOSApp/RecentContentHome.swift`。
- 修复项（按审计排序取前五，第六条视成本顺手）：
  1. 周回顾顶部统计：计数为 0 或目标区块未渲染时改为纯文本，不再渲染可点按钮（审计 1，WeeklyReviewView.swift:159-178 与 :118-121）。
  2. 周回顾加载失败加「重试」，重跑同一段加载（审计 2，:129-136/:110）。
  3. 讨论页未配置模型时在 composer 处说明「发送需要先配置文本模型」并给出配置入口（复用 RecentContentHome.swift:552-555 的既有模式；审计 3）。
  4. 认知地图刷新：`topics` 为空或 `error` 非空时同时重跑 `loadTopics()`（审计 4，ReflectionGraphView.swift:193/:146/:209-220）。
  5. 「最近想法」「看原话」查不到声明时用既有 `showClueFailure` 提示（审计 5，RecentContentHome.swift:458-462）。
  6. 「还有 N 条」等剩余计数改为跳转按钮（审计 6，WeeklyReviewView.swift:651 等），若需要新路由且成本高，记录并跳过。
- 与其它单元无文件重叠；不改 VoiceOSApp.swift（CL 独占）与主题组织核心（TS 独占）。
