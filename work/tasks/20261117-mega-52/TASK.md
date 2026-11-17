# 波 52 任务书（2026-11-17，草案）

## 背景与证据

两段式上线后，实时库骨架请求（`topic-skeleton-v1`，22:41:45）仍以 600 秒超时告终。隔离实测（`/tmp/topic-probe-*.json`，同一端点、模型、json_schema strict、reasoning high）：

- 1.8KB 骨架形状，非流式：HTTP 200，10.6 秒完成。
- 1.8KB + stream:true（应用真实路径）：HTTP 200，10.1 秒完成，SSE 正常。
- 330KB（按实时库 732 条当前观点构造的真实体量）+ stream:true：服务器持续输出 SSE（`response.created` 后有 7500+ 增量事件），300 秒截断时仍在生成。

结论：端点与请求形状都没问题；瓶颈是真实库规模下的**生成时长与输出上限**。骨架要求为 732 个观点 ID 逐一分配，输出预估 2 万 token 以上，而骨架请求的 `max_output_tokens` 只有 16384（全景是 65536）；同时流式传输层把时限硬限制在 600 秒。

## 完成判据

1. 骨架请求 `max_output_tokens` 提到 65536；正文请求保持 16384（每批 3-5 主题，输出小）。
2. 主题组织两段的请求时限允许超过 600 秒：`DirectStreamingModelHTTPTransport` 的硬上限从常量改为实例参数（默认仍 600），主题端口用 1800 秒；其余端口行为不变。
3. 骨架失败原因区分「时限到点」与「输出被截断」：若响应 status 为 incomplete/输出长度到达上限，错误文案明确「观点过多，需要更小的骨架批次」并列出观点数。
4. 若实测证明 1800 秒仍不够（见「实测记录」），实现骨架分批：按来源把观点切成 ≤150 条/批，逐批产出主题候选，再用一次小请求合并去重（输入只含候选主题标题与观点数）；批次与合并均落阶段表、可续跑。
5. 测试：伪传输断言骨架与正文请求的 max_output_tokens、时限参数生效；骨架输出截断的错误分类；分批模式（若实现）合并去重与续跑。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0。

## 实测记录

- a4 探针（330KB、64k 输出上限、1800 秒上限）：HTTP 200，总耗时 **593.2 秒**，`response.completed` 到达；输出文本约 **49,647 字符（≈3 万 token）**。
- 对照：a3（同输入、16k 输出上限）300 秒截断时仍在生成；即便跑满也会在 16k token 处被截断——这正是此前「未返回结果」的另一半成因。
- 结论：单批 732 条观点的骨架在「输出量」与「时长」两方面都贴着/超过单请求上限；分批（≤150 条/批）后每批预估 2 分钟内完成、输出 <1 万 token，合流是小请求。

## 文件所有权

- 单单元 TS2：`Sources/VoiceOSCore/ResponsesTopicOrganizationPort.swift`、`Sources/VoiceOSCore/TopicOrganization.swift`、`Sources/VoiceOSCore/TopicOrganizationSlicing.swift`、`Sources/VoiceOSCore/ResponsesModelPort.swift`（仅传输时限参数化）、对应测试。
- 不碰 `WorkspaceProcessingView.swift`、`WorkspaceSourceView.swift`、`RecentContentHome.swift`。

## 结果（2026-11-17）

- TS2（7b8d2d6、adddd87、90c8c9d）：骨架按观点 id 切 ≤150 条/批，逐批请求并落阶段表（stage='skeleton'，scope=批 id 列表），`max_output_tokens` 65536；全部批后一次小请求合流去重（stage='skeleton-merge'，输入不含观点全文）；遗漏观点按批追加；截断（status=incomplete 或输出触顶）抛 `TopicSkeletonTruncated` 并带批内观点数；`DirectStreamingModelHTTPTransport(deadlineCap:)` 参数化（默认 600），主题端口 1800 秒；schema 71（阶段表 CHECK 接受 skeleton-merge，迁移保旧行）。
- 集成修复：`CognitiveStore.swift:360` 恢复摘要排除清单补 `topic-skeleton-merge-v1`；批失败保留 `ModelPortFailure.rejected` 原因与 `TopicSkeletonTruncated` 文案，不再退化为泛化 localizedDescription。
- 构建 build_exit=0（82s）；测试 test_exit=0，534 项 0 失败（32s）。
- 部署：与波 51 一起等闸门（用户在用机器，键鼠空闲未达 120 秒）。
