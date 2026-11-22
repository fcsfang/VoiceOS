# 170-B 笔记生成门控下沉 Core 与表驱动测试

## 背景

169-C2 在 `Sources/VoiceOSApp/MaterialNoteCenter.swift` 实现了笔记生成的许可/就绪门控与版本失效判定，但编排在 App 目标里，`VoiceOSCoreTests` 无法导入，门控矩阵没有测试。本单元把纯判定逻辑下沉到 `VoiceOSCore`，行为与文案逐字不变，为后续质量迭代兜底。

## 文件清单（只允许动这些）

- 新建 `Sources/VoiceOSCore/MaterialNoteGating.swift`
- `Sources/VoiceOSApp/MaterialNoteCenter.swift`
- 新建 `Tests/VoiceOSCoreTests/MaterialNoteGatingChecks.swift`
- 新建 `work/tasks/20261122-m170-b/TASK.md`

## 改动

1. **Core 新 API**（`MaterialNoteGating` 命名空间，与 `MaterialNoteAnchoring` 同风格）：
   - `unavailableReason(memberIDs:catalog:) -> String?`：按成员顺序返回首个原因；材料缺失 →「材料已变化或已移出资料库」、state 非 saved/reference_only →「材料尚未保存完成」、localOnly →「仅本机保存」、无转写/空转写/无 transcriptVersionID →「尚无转写」。「资料库尚未打开」「文本模型未配置」仍归编排层。
   - `transcriptVersions(memberIDs:catalog:) -> [String: String]`：memberID → transcriptVersionID，跳过缺失成员与无版本成员。
   - `MaterialNoteMemberSnapshot`（public，原私有 struct 原名上移）：保存 state、transcriptVersionID、policyVersion、localOnly 与 sourceID；`matches(_:)` 语义不变，含「记录 state 仍需在 saved/reference_only 内」这一条。
2. **App 改调用**：`MaterialNoteCenter` 删除两份私有助手与私有快照 struct，改调 Core；`members.map(MaterialNoteMemberSnapshot.init)` 因同名 public 类型不变。对外行为、状态文案、调用顺序不动。
3. **测试**：`MaterialNoteGatingChecks` 四个表驱动用例，覆盖就绪（含 reference_only 与空成员）/ 成员缺失 / state 不允许 / localOnly / 无转写 / 空转写 / 纯空白 / 无版本号 / 首个原因按成员顺序 / 版本映射与跳过规则 / 快照字段保存 / 快照一致与每种字段变化（含 state 在允许值间变化、移出资料库、字段全等但状态不可参与）。

## 约束

- 不碰生成端口、锚定、存储、UI；不加迁移。
- 16GB 内存：不跑 swift build/test，主会话统一集成构建。
- 改动文件逐个 `xcrun --sdk macosx swiftc -parse <绝对路径>` 真实退出码，不加管道。
- 完成后提交到本工作树分支（不推送），任务书一并提交，尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 结果

- 新 API：`MaterialNoteGating.unavailableReason(memberIDs:catalog:)`、`MaterialNoteGating.transcriptVersions(memberIDs:catalog:)`、public `MaterialNoteMemberSnapshot`（`init(_ record: SourceRecord)`、`matches(_ record: SourceRecord?) -> Bool`）。
- App 改动点：4 处调用替换 + 删除 2 个私有函数与 1 个私有 struct；`materialNoteSpans`、`materialNoteFailureMessage` 原样保留。
- 测试矩阵：4 个用例，共 30 行矩阵（门控 15、版本映射 5、快照比对 10）加 5 条快照字段断言。
- parse 退出码（逐文件，无管道）：`MaterialNoteGating.swift` 0、`MaterialNoteCenter.swift` 0、`MaterialNoteGatingChecks.swift` 0。
- diff --stat：3 个 Swift 文件 196 insertions(+), 46 deletions(-)（未含本任务书）。