# 并行波 27：口述可见性、回答证据、页内回听

来源：四路产品发现与两路专项发现的剩余高价值项，本波取三组不与前十波重复、文件互不冲突的改动。数据事实：AI 交付与回答的 input_json 里每条带 2 到 5 个 references 但记录与界面都丢掉；全局口述热键注册失败静默、菜单栏图标不反映录音状态；材料详情「回听」跳出应用、页内播放器一换页就停、核对项无法当场回听。

## 完成判据

1. 全局口述有状态反馈：菜单栏图标在口述进行时切换形态；热键注册失败（被其它应用占用）在设置页与菜单里可见并有更换指引，菜单不再宣称可用的快捷键。
2. 回答有证据条：问题详情的回答区块下方显示「依据原话」（来自该执行 input 的 references，2 到 5 条），每条可打开材料并回听；无引用的旧执行不显示空块。
3. 材料详情页内回听：详情页的「回听」不再跳外部播放器，走页内播放条；播放条常驻于详情页底部，切换页面时停止的行为收窄到离开材料页；核对项（未解决转写问题）每条带「回听」与「跳到原文」。
4. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（420 项基础上新增）。

## 共享契约

- 口述状态：ControlCenter 增加 `@Published var dictationActive: Bool`（或等价只读派生），菜单栏图标与其同步；`GlobalHotKey.register` 的注册结果聚合暴露，设置页「快捷键」行在冲突时显示「快捷键 ⌥⌘D 被其它应用占用」。
- 回答证据：`AssistantExecutionRecord` 增加 `inputReferences: [ClaimReference]`（从 input_json 解码，公开只读）；问题详情渲染引用时复用现有引用组件（如 ActionOriginalQuotes / QuoteHoverPreview 与打开材料、播放的既有通道），不自造新视图体系。
- 页内回听：详情页播放走既有 `playSpan` 通道与 NativePlayerView；常驻条只在材料详情页挂载，离开详情才停止；正文高亮跟随播放位置若现有数据（playbackMS + spans）可支持则做，否则在报告说明。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| N 口述可见性 | `work/m27-n` / `.worktrees/m27-n` | `VoiceOSApp.swift`、`GlobalHotKey.swift` | 判据 1 |
| O 回答证据 | `work/m27-o` / `.worktrees/m27-o` | `AssistantExecution.swift`、`QuestionAnswerSection.swift`、`WorkspaceActivityViews.swift` | 判据 2 |
| P 页内回听 | `work/m27-p` / `.worktrees/m27-p` | `WorkspaceSourceView.swift` | 判据 3 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- N：菜单栏图标用现有 AppBrand/menubar 资产派生两种形态（录音中用强调色或波形态）；录音状态来源是现有 dictation 状态机（自寻）；注册失败只记一次日志并在设置页行内显示；不改快捷键绑定本身。VoiceOSApp.swift 已连续多波修改，贴现有模式，保留 fresh 入队、菜单（查找/记录想法/每周回顾）与处理页接线。
- O：inputReferences 解码失败按空数组处理（旧数据不崩溃）；证据条放在回答结果之下、动作行之上；引用行显示材料名 + 原话摘要（截断 120 字）+ 打开材料/回听；播放与打开走既有 ControlCenter 通道（openSource/playSpan 等，自寻现有方法名）。
- P：现有 detail 播放器挂在「原文与回听」折叠区且换页 stopPlayback（Wave 22 前既有行为）；本波把「回听」入口从 model.play（外部播放器）改为页内播放条并常驻；核对项 unresolved_issues 每条按 span_id 加两个动作；正文高亮与自动滚动若 span 时间数据完备则实现，否则报告说明缺口。

## 验证基线

- 实时库：79 材料、5 条 completed analysis（references 全为 0 但 input 里 2 到 5 条）、50/79 材料带 transcriptionReview、最长材料 4947 秒。
- 锁屏仍在，交互截图待解锁后统一补拍；本波以构建、测试与代码路径为证据。
