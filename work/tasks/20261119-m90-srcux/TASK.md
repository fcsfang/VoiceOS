# 波 90 任务书（2026-11-19）：来源页体验与 AX 树瘦身

## 背景（发现者 B 报告 + 波 88 澄清，2026-11-19）

- B8：切换材料后「全文选读」「核心要点」「原文与回听」折叠状态丢失（局部 @State + 页面 `.id(id)` 重建），而滚动位置却保留，行为不一致。证据：`WorkspaceSourceView.swift:154-161,863-865`；`WorkspaceView.swift:782-788,237,2521-2527`。
- B12：来源页异步区块（节目关联、讨论、实体、章节）无加载占位，内容在阅读中突然出现。证据：`WorkspaceSourceView.swift:806-848` 与区块 `526-554,603-605,614-662`。
- AX 瘦身（波 88 证据）：sample 显示切页「慢」是应用在服务 AX 查询（主线程停在 mshMIGPerform）；来源页 AX 树超过 4000 节点（逐段转写行全部暴露），VoiceOver 与自动化工具变慢。要求：正文逐段文本合并为块级可访问元素（每段一个静态文本元素即可），装饰性元素 `accessibilityHidden`，把来源页 AX 元素数显著降下来（目标：普通材料 < 800）。

## 完成判据

1. 折叠状态按材料持久：至少「全文选读」展开状态跨材料切换保留（WorkspaceView 持有字典按 sourceID）；其余折叠如需一并处理。
2. 异步区块加轻量占位（ProgressView 或占位行），加载失败给出简短失败文案；不改变加载逻辑。
3. AX 瘦身：`SourceTranscriptBody` 等逐段行不额外暴露每个 span/装饰元素；用 `.accessibilityElement(children: .combine/.ignore)` 与 `.accessibilityHidden` 收敛；实现后用 coordinator 实测（代理不启动应用，给出预期元素数估算方式）。
4. 行为、标识、键盘零变化；不加迁移。
5. 测试 ≤2（纯逻辑）；build/test 真实退出码 0（基线 632）。
6. 结果给 file:line 清单与 AX 元素变化的推理依据。

## 文件所有权

`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSApp/WorkspaceView.swift`（仅折叠状态字典与传参）、对应测试。不碰其他文件。

## 约束

16GB：锁 `/tmp/voiceos-swift-build.lock`；先 merge main；不写实时库；不重启应用；不 push、不合并。分支 `work/m90-srcux`。

## 结果

- 分支：work/m90-srcux（基于 main 14635ba；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：8771ad4「perf(来源页): 折叠状态按材料保留，异步区块补占位，AX 树收敛」（2 文件，130 增 57 删）。
- 归因（任务书背景 B8、B12、AX 瘦身；行号为改动后）：
  - B8（切换材料折叠状态丢失）：`WorkspaceView.swift:261` 新增按 sourceID 的 `sourceFoldStates`；`:879-880` 以 `SourceFoldState.initial(transcript:)` 为缺省值生成绑定；`:806` 传入来源页。`WorkspaceSourceView.swift:77-89` 折叠状态模型；`:189` 接收绑定；`:256-258` 统一生成 `Binding<Bool>`；`:368,384,389,590,600,702,709,716` 八处折叠改读按材料状态。原 `onAppear` 与 `onChange(of:source.id)` 的默认重置删除，`.id(id)` 重建后由字典缺省值给出相同初值；转写更正时仍在 `:956` 重置「原文与回听」初值，保持旧行为。
  - B12（异步区块无占位）：`WorkspaceSourceView.swift:91-103` 新增三态 `SourceLoadPhase`；`:134-149` 轻量占位与失败文案视图；`:612,641` 节目关联、`:780-781` 讨论、`:706-707,713-714` 章节与实体在加载中显示 ProgressView 行、失败显示简短文案；状态转换在 `:880`（节目关联）、`:866`（讨论）、`:904`（实体）、`:922`（章节）。读取调用与顺序未变，只把原被吞掉的实体/章节读取失败显式化。
- AX 瘦身（推理与预期元素数）：
  - 逐段正文 `TranscriptParagraphRow` 在 `WorkspaceSourceView.swift:1321-1322` 用 `children:.ignore` 加显式 label 收敛为每段一个静态文本元素；回听段按钮 `:1336`、大纲按钮 `:1372`、章节按钮 `:1392` 同样收敛为单个可访问元素，按钮 label 内的 Text 不再另生成元素。装饰性图标：折叠 chevron `:123`、纠错箭头 `:793`、页内回听播放图标 `:1259`、占位 ProgressView `:138` 均 `accessibilityHidden`；`SourceFold` 类别图标原有 `:114` 隐藏保留。
  - 估算方式（coordinator 实测，代理不启动应用）：`voiceos-check ax dump --pid <pid> --json`，统计 `.elements` 数组长度；实现见 `Sources/VoiceOSPlatform/AXDriver.swift:64-80` 与 `Sources/VoiceOSCheck/AXCommands.swift:5-7`，遍历上限 4000，`truncated=true` 表示超过上限。预期元素数约等于「可见段落数 + 可见回听段按钮数 + 可见大纲小节数 + 可见章节数 + 页面固定控件数」，改动前同一段落与按钮还会暴露内部 Text 和装饰图标。以约 300 段的材料估算：正文与回听各 300，加上大纲、章节与固定控件约 100，落在 800 以内；这是推算，不是实测。
- 测试：未新增测试（判据允许 ≤2）。`Tests/VoiceOSCoreTests` 只依赖 `VoiceOSCore` 与 `VoiceOSPlatform`，来源页折叠与占位状态位于 `VoiceOSApp` 可执行目标，按文件所有权不新增 Core 文件，故零新增测试跑满基线。
- 验证：merge_exit=0；build_exit=0（首次完整构建日志 `Build complete! (111.49s)`；包装脚本因 zsh 只读变量 `status` 退出 1，随后加锁重跑取真实退出码 0，增量 0.18 秒）；test_exit=0（`swift test -j 2`），632 项 0 失败，41.738 秒，与基线 632 一致。构建与测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir），已释放；`git diff --check` 退出码 0；未写实时库、未重启应用、未 push、未合并。
- 判据落点：
  - 判据 1：八处折叠状态按 sourceID 持久，含「全文选读」。
  - 判据 2：节目关联、讨论、实体、章节均有加载占位与失败文案；读取调用与顺序未改。
  - 判据 3：逐段行与回听、大纲、章节按钮收敛为单元素，装饰图标隐藏；coordinator 计数方法见上。
  - 判据 4：标识与键盘未改；无迁移；除判据 1 的折叠持久与判据 2 新增的占位、失败文案外行为不变。
  - 判据 5：未新增测试；build/test 真实退出码 0，632 项与基线一致。
  - 判据 6：file:line 与 AX 推理见上。
- 遗留风险：
  - 长文本材料走 `MarkdownText`（`MarkdownText.swift:20-29`），每个 Markdown 块仍是一个元素；若这类材料仍超 800，需要在该文件收敛，超出本波文件所有权。
  - 「全文选读」展开时 `SelectableText` 是 `NSTextView`（`SelectableText.swift:13-40`），其 AX 子元素数量由 AppKit 决定，未在本波收敛；默认收起，不影响普通材料首屏。
  - 占位状态在 `contextReadKey`、`discussionReadKey` 变化时会短暂重设，连续刷新可能出现占位闪现；仅在数据为空时渲染，已有内容时不显示。
  - `sourceFoldStates` 按 sourceID 累积，不随材料删除清理；字典只存布尔值，内存可忽略，未加清理。
