# 波 54 任务书（2026-11-17，用户提出）

## 需求（用户原话）

「现在这个启动页面有一点问题。比如说，我提出的问题是一个很简单的回复类问题，因为我调用的是 GPT 的 API，它完全可以充当回答我问题的角色。我问问题，它直接回答我就行，不需要动手或者交给 Agent 这种选项，它直接回答我就行。」

## 背景

启动页 `TaskInitiationView` 目前只有四条路由：交给 Agent（`agentHandoff`）、自己动手（`guidedStart`）、先问一个关键问题（`clarify`）、仅记录（`captureOnly`）。提问类输入被模型归类后仍落在任务路由里，用户要先看「交给 Agent / 自己动手」的选择，没有「就是回答我」的路径。分类端口 `ResponsesTaskInitiationPort`（TaskInitiation.swift:129 `initiate`）与校验 `validate`（:136）只接受现有四路由。

## 完成判据

1. 新增路由 `answer`（UI 文案「直接回答」）。分类请求允许模型把「提问/闲聊/知识型问题」判为 answer，并在同一响应里给出回答正文（`answer` 字段，纯文本、可多段），不再只是路由标签。
2. 启动页：
   - answer 提案的卡片直接展示回答正文（保留复制按钮），不显示「交给 Agent / 自己动手」为主操作；
   - 仍保留手动兜底：任何提案卡片上都能点「直接回答」，对原文再发一次回答请求（复用同一端口的新方法），回答就地展示；
   - answer 记录不创建任务、行动、材料或提醒，仅作为启动记录保存，可归档。
3. 校验：`validate` 对 answer 接受空 title/objective（或按现有字段语义映射），但回答正文非空且长度合理（≤ 8000 标量）；分类结果若既不是任务也没有回答正文，回退到现有 `clarify` 文案，不允许空卡片。
4. 回答请求与分类共用同一提示词版本升级（`task-initiation-v2`），已完成旧记录不受影响；恢复校验的 provider/prompt 排除清单同步。
5. 测试：分类返回 answer（含正文）通过校验并渲染；缺正文回退 clarify；手动「直接回答」请求构造与解析；answer 记录不产生行动/任务副作用；既有四路由行为不变。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0。

## 文件所有权

- 单单元 AN：`Sources/VoiceOSCore/TaskInitiation.swift`、`Sources/VoiceOSCore/ResponsesTaskInitiationPort.swift`、`Sources/VoiceOSApp/TaskInitiationView.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`（仅启动命令段）、对应测试。
- 不碰处理页（波 53 PG 待其后）、主题组织、全景、知识核查。

## 结果（2026-11-18）

- AN（a5a7f5c、1e1f0c2）：路由 enum 新增 `answer`「直接回答」；分类提示词升 task-initiation-v2，同响应返回回答正文；端口新增纯文本 `answer(_:)`；回答卡片以正文为主、「复制回答」「归档保存」，任务路线选择器隐藏；每张卡片保留手动「直接回答」；answer 记录不产生任务/行动/材料/提醒；schema 72（CHECK 放宽）。
- 集成修复：测试夹具域名改为授权主机（api.chiyi.cc）；回答请求的提示词在 content 而非 instructions，断言随之修正并删除空断言。
- 构建 build_exit=0；测试 test_exit=0，539 项 0 失败（39s）。
- 附带（用户当场提出）：首页「最近想法」显示修复——左栏固定 264pt 下正文最多 3 行、来源名最多 2 行并允许换行，不做折叠（折叠待用户看过新形态后再定）。
