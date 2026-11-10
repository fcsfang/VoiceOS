# 任务启动 P0 设计契约

规格基线：`docs/feature-plans/VoiceOS_Task_Initiation_Feature_Spec.md`。本文件是实现契约，冲突时以规格的用户可观察行为为准。

## 形状

一条竖直切片：`task_initiations`（每次显式请求一行） + 单次结构化模型调用 `TaskInitiationModelPort` + 纯函数拼装器 + 一个工作台页面。零写入 `actions`、`claims`、`assistant_executions`、提醒表，不创建 `ai_text` 来源（`validateStoredAssistantExecutions` 要求每个 ai_text 来源恰属一次助理交付）。

模型只给语义字段；可复制的交接提示词与教程由代码确定性拼装，保证结构完整、事实与假设分离。

## 领域类型（`Sources/VoiceOSCore/TaskInitiation.swift`）

```swift
public enum TaskInitiationRoute: String, Codable, CaseIterable, Sendable {
    case agentHandoff = "agent_handoff", guidedStart = "guided_start", clarify, captureOnly = "capture_only"
}
public enum TaskInitiationMode: String, Codable, Sendable { case direct, interactive }
public enum TaskInitiationPreference: String, Codable, Sendable {
    case quickDelivery = "quick_delivery", learnWhileDoing = "learn_while_doing"
}
public struct TaskInitiationProposal: Codable, Sendable {
    public let isTaskInitiation: Bool
    public let route: TaskInitiationRoute
    public let title: String
    public let objective: String
    public let knownFacts: [String]
    public let assumptions: [String]
    public let missingInformation: [String]
    public let constraints: [String]
    public let acceptanceCriteria: [String]
    public let preference: TaskInitiationPreference
    public let targetExecutor: String
    public let deliverables: [String]
    public let guidePrerequisites: [String]
    public let guideSteps: [String]
    public let firstAction: String
    public let verification: String
    public let clarifyQuestion: String
    public let reason: String
}
public struct TaskInitiationInput: Codable, Sendable {
    public let sourceID: String
    public let transcriptVersionID: String
    public let text: String
    public let answer: String
    public let mode: TaskInitiationMode
    public let preferredRoute: TaskInitiationRoute?
    public let recordedAt: String
    public let timeZone: String
}
public struct TaskInitiationRecord: Identifiable, Sendable {
    public let id, sourceID, transcriptVersionID, state, createdAt, updatedAt: String
    public let route: TaskInitiationRoute
    public let proposal: TaskInitiationProposal
    public let input: TaskInitiationInput
    public let editedArtifact, copiedAt: String?
    public let basisChanged: Bool
    public var artifact: String { editedArtifact ?? TaskInitiationComposer.render(proposal) }
    public var isConfirmed: Bool { state == "confirmed" }
    public var isClarifying: Bool { state == "clarify" }
}
public protocol TaskInitiationModelPort: Sendable {
    var configuration: ModelConfiguration { get }
    func initiate(_ input: TaskInitiationInput) async throws -> TaskInitiationProposal
}
```

`TaskInitiationProposal` 用自定义 `init(from:)`：数组缺省为 `[]`，字符串缺省为空串，`preference` 缺省 `.quickDelivery`；`route` 与 `isTaskInitiation` 缺失即解码失败（T12 降级）。

`TaskInitiationComposer` 全部是纯函数：

- `validate(_ proposal:mode:preferredRoute:) throws -> TaskInitiationProposal`：`isTaskInitiation == false` 时把路线规范为 `captureOnly`；`mode == .direct` 且路线为 `clarify` 时抛错；指定了 `preferredRoute` 且路线不同（非 captureOnly 规范）时抛错；`clarify` 必须有且只有一个问题（非空）；`agentHandoff` 要求 `objective` 与至少一条 `acceptanceCriteria`；`guidedStart` 要求 `guideSteps` 非空、`firstAction`、`verification` 非空；标题空时用 `objective` 首行或原文首行兜底。
- `render(_ proposal:) -> String`：`clarify` 与 `captureOnly` 返回空串。交接包按规格 5.3 的八段结构，教程按规格路线 B 的五段。事实只来自 `knownFacts`；`assumptions` 标「假设（请先核实）」；`missingInformation` 标「待确认」。`# 请先做的事` 固定包含「先检查真实环境（仓库、文件、工具与已有资料），不要假设已经读过它们」。`learnWhileDoing` 必须出现「边做边学：交付时解释关键实现、入口与验证方法」。
- `secretWarning(in:) -> String?`：正则识别 `sk-` 长串、`AKIA[0-9A-Z]{16}`、`-----BEGIN ... PRIVATE KEY-----`、`password=`/`passwd=`/`api_key=`/`token=`，返回中文提醒；普通文本返回 nil。

## 存储（迁移 52）

`Database.swift`：守卫改 `(0...52)`；在 51 之后加：

```sql
CREATE TABLE task_initiations (
  id TEXT PRIMARY KEY,
  command_id TEXT NOT NULL UNIQUE,
  source_id TEXT NOT NULL REFERENCES sources(id),
  transcript_version_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('clarify','draft','confirmed')),
  route TEXT NOT NULL CHECK(route IN ('agent_handoff','guided_start','clarify','capture_only')),
  input_json TEXT NOT NULL,
  proposal_json TEXT NOT NULL,
  edited_artifact TEXT,
  copied_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK((state='clarify') = (route='clarify'))
);
CREATE INDEX task_initiation_created ON task_initiations(created_at, id);
PRAGMA user_version=52
```

不加入 `PortablePackage` 的表清单（P0 导出不含启动草稿；原口述作为普通来源照常导出）。`WorkspaceSnapshot` 增加 `taskInitiations: [TaskInitiationRecord]`，`workspaceSnapshot()` 填充。

## Store 方法（同文件，extension VoiceOSStore）

- `taskInitiationInput(sourceID:mode:preferredRoute:answer:) throws -> TaskInitiationInput`：来源存在、`origin=user`、`speaker=user`、`state` 为 `saved/reference_only`、当前转写文本非空且不超过 4000 个 Unicode 标量、未 `needsTranscriptionReview`、`localOnly == false`（否则抛「这份材料仍是仅本地…」）。
- `recordTaskInitiation(_ input:proposal:commandID:)`：先 `validate`；来源与转写版本仍与输入一致，文本未变；`command_id` 幂等返回已有行；插入 `state = route == .clarify ? 'clarify' : 'draft'`。
- `recordTaskInitiationClarification(id:answer:proposal:)`：行必须 `state='clarify'`；来源仍一致；以 `mode=.direct` 校验（不允许第二个问题）；把 answer 写入 `input_json`，更新路线/提案，`state='draft'`，清空编辑与复制时间。
- `replaceTaskInitiation(id:preferredRoute:proposal:)`：行必须 `state='draft'`（已确认不可改）；校验路线等于 `preferredRoute`、非 clarify；更新提案与 `input_json.preferredRoute`，清空 `edited_artifact` 与 `copied_at`。
- `setTaskInitiationPreference(id:preference:)`：行必须 draft，且 `edited_artifact == nil`（手改过不再自动调整）；重建提案写回。
- `confirmTaskInitiation(id:artifact:)`：行必须 draft、路线为 handoff/guided、artifact 去空白后非空；与渲染结果不同就存 `edited_artifact`；`state='confirmed'`。
- `markTaskInitiationCopied(id:artifact:)`：有可复制材料（artifact 非空）才能标记；存编辑文本；写 `copied_at`，**不改 state**，不写任何任务或完成状态（T10）。
- `discardTaskInitiation(id:)`：只删非 confirmed 行；已确认抛错。
- `taskInitiations(limit:)`：按 `created_at DESC, id DESC`；解码 `input_json`/`proposal_json`；`basisChanged` = 来源缺失、状态不在 saved/reference_only、或当前 `transcript_version_id`/文本与输入不一致。

所有新方法 `guard ready`。SQL 只碰 `task_initiations`。

## 模型端口（`Sources/VoiceOSCore/ResponsesTaskInitiationPort.swift`）

镜像 `ResponsesAssistantPort`：`baseURL/apiKey/model/transport`，配置 `promptVersion: "task-initiation-v1"`、`schemaVersion: "task-initiation-v1"`、`.cloud`。一次请求，`store:false`、`reasoning.effort:"high"`、`max_output_tokens:8192`、`truncation:"disabled"`、无 tools，`text.format` 严格 JSON Schema（上面所有字段，全部 required，数组项为 string，`route`/`execution_preference` 为 enum）。`ResponsesEnvelope.parse` 后状态必须 `.completed` 且有文本，再解码。提示词（中文）覆盖：四种路线的判断、`is_task_initiation`、事实/假设/待确认分离、不假装读过外部环境、尊重明确否定、`.direct` 不得返回 `clarify`、指定路线优先（但明确拒绝任务化时仍 captureOnly）、教程 3 到 7 步。输入是 `TaskInitiationInput` 的排序 JSON 字符串，附当前时间。

`LocalTextModel.Suite` 增加 `initiation: ResponsesTaskInitiationPort`，`loadSuite` 用同一地址与密钥构造。

## 测试（`Tests/VoiceOSCoreTests/TaskInitiationChecks.swift`）

假端口 actor，记录收到的输入并按场景返回提案或抛错。用 `VoiceOSStore(root:)` + `recover()`，只写临时目录。断言用户可观察行为：

- T01/T07/T08：handoff 提案 → draft；artifact 含八段标题、假设与待确认分开、固定检查环境段；learn 偏好含边做边学句；无 actions/claims 增加。
- T02：guided 提案 → 步骤、第一步、验证非空。
- T03：`isTaskInitiation=false` → 规范为 captureOnly、无 artifact、无 action/claim。
- T05/T06：interactive clarify → `state=clarify` 且只有一个问题；第二次 clarify 抛错；回答后变 handoff draft；跳过（direct）时可带假设成稿。
- T09：handoff 换 guided → 同一行更新、`copied_at` 清空；已确认不可换。
- T10：复制 → `copied_at` 有值、state 仍 draft；确认后 state=confirmed 且没有任何完成/执行字段。
- T11：discard 删除草稿；confirmed 拒绝删除。
- T12：端口抛错由调用方处理（本层测非法提案被 `validate` 拒绝且不落行）；缺字段 JSON 解码失败。
- T13：`secretWarning` 命中 API key，普通文本 nil；localOnly 来源在 `taskInitiationInput` 抛错。
- 迁移：写入一行后重开 store（`recover`）仍可读，证明 schema 52 与校验通过。

## 不做

- 不自动创建 action、提醒、claim、ai_text。
- 不把启动包写入长期知识。
- 不做任务恢复（`resume_task`，P1）、导出包、多来源合并、修订历史表。
