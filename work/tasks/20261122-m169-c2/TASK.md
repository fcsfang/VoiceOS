# 169-C2 App 笔记生成编排与许可门控

## 背景（产品方向文档第一阶段）
域模型（169-A）与 Core 端口（169-C1，契约见下）之后，本单元在主应用接通真实生成流程：打开材料时按许可懒生成、保存版本、暴露状态与失效判定；UI 由 169-D 消费。

## Core 契约（来自 169-C1，直接引用不要重定义）
`MaterialNotePort.writeNote(_ request: MaterialNoteRequest) async throws -> MaterialNote`、`MaterialNoteAttemptIdentity`、`MaterialNoteMember/MaterialNoteSpan/MaterialNoteRequest`、`MaterialNoteAnchoring.anchored(_:members:)`。

## 文件清单（只允许动这些）
- Sources/VoiceOSApp/VoiceOSApp.swift
- Sources/VoiceOSPlatform/LocalTextModel.swift（如 Suite 需要挂 note 端口）
- 新建 Sources/VoiceOSApp/MaterialNoteCenter.swift（编排扩展，避免继续膨胀主文件）
- 新建 Tests/VoiceOSCoreTests/MaterialNoteOrchestrationChecks.swift（可选，仅当可在无 App UI 下测试的部分存在；否则不建）

## 改动
1. **端口接线**：在构建 `topicModel` 的同一配置来源处（VoiceOSApp 内 `suite.topics` 附近）构建 `materialNoteModel`（`ResponsesMaterialNotePort`，同 baseURL/apiKey/model/transport）；配置为空时置 nil。
2. **编排**（新文件 extension ControlCenter）：
   - 状态枚举 `MaterialNoteState { idle, unavailable(reason), generating, failed(message) }`，`@Published var materialNoteStates: [String: MaterialNoteState]`（按材料 sourceID 记录，内存即可）。
   - `func requestMaterialNote(sourceID: String, force: Bool = false) async`：
     a) 解析表达成员：`sourcePageIndex.expression(for: sourceID)?.sourceIDs ?? [sourceID]`；
     b) 许可与就绪门控：所有成员 `state ∈ {saved, reference_only}`、有 transcript、**非 localOnly**、模型已配置；任一不满足 → `.unavailable(具体原因)`（文本模型未配置 / 仅本机保存 / 尚无转写）。
     c) 已有笔记且 `materialNoteIsCurrent`（用当前 transcriptVersionID 映射）且非 force → 直接 `.idle` 返回，不调用模型。
     d) 捕获成员 policyVersion/transcriptVersionID 快照；生成期间若任一成员版本或许可变化，丢弃结果并置失败（与标题生成相同的失效守卫）。
     e) 构建 `MaterialNoteMember`（transcript 取成员当前版本文本；spans 从该成员转写时间片获取，复用现有读取 API，找不到则空数组）；调用端口；`MaterialNoteAnchoring.anchored`；`store.saveMaterialNote(...)`；成功 `.idle`，失败 `.failed(model.status)`。
     f) 并发守卫：同一 sourceID 生成中再次请求直接返回。
   - `func materialNoteForDisplay(sourceID: String) async -> (note: StoredMaterialNote, isCurrent: Bool)?`：按表达成员取 latest，用当前版本判定 current。
3. **懒触发**：材料详情打开路径调用一次 `requestMaterialNote(sourceID:)`（放 WorkspaceSourceView 的 `.task` 由 169-D 接；本单元只保证 API 幂等、可被重复调用）。
4. 不写 UI、不改 WorkspaceSourceView。

## 约束
- 不改既有生成流程（标题/主题/理解）；本地模型端口不动；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse` 真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：端口接线位置、许可/失效守卫清单、并发守卫、parse 退出码、diff --stat。