# 波 115-C 标题层级统一与监测计数等宽

基线 `work/m115-c`，工作树 `.worktrees/m115-c`。只改 `Sources/VoiceOSApp/WorkspaceProcessingView.swift`、`ThoughtPanoramaView.swift`、`WorkspaceMonitorView.swift`。

## 目标

三处字号层级混档：处理条把标题与来源副标题一起压成 12pt meta；全景面板里「问题与联系列表」「候选联系」用行标题 15pt 而同级面板标题「完整材料与覆盖情况」是 17pt；监测页计数列数字宽度不一，方头数字没对齐。统一到 `WorkspaceText` 既有语义档，不新增 token。

## 逐条修法

### 1. 处理条标题（`WorkspaceProcessingView.swift:238-239`）

- 标题：`Text(title).lineLimit(1)`（继承外层 `:259` 的 `.vosFont(WorkspaceText.meta)`，即 12 regular）→ `.vosFont(WorkspaceText.rowTitle)`（15 semibold）。
- 来源副标题：`Text(source.displayTitle)` → 加显式 `.vosFont(WorkspaceText.meta)`，与 `WorkspaceView.swift:212-213`、`WorkspaceDesign.swift:294-298` 的标准行一致。
- 外层 `.vosFont(WorkspaceText.meta)` 保留：按钮、口述计时与无标题状态文案仍是 12。
- 高度影响：标题行 12→15，整条约增高 3pt；`lineLimit(1)` 未动，长标题截断不换行，横向空间语义不变。

### 2. 全景面板标题（`ThoughtPanoramaView.swift:462`、`:496`）

- `:462` 「问题与联系列表」：rowTitle（15 semibold）→ sectionTitle（17 semibold）。
- `:496` 「候选联系」：rowTitle（15 semibold）→ sectionTitle（17 semibold）。
- 保持不动：`:492` `region.title`（列表行，rowTitle）；`:833` 区域详情标题（已是 sectionTitle）；`:704`「尚未合格的材料」是覆盖面板内部的子列表标题，不在本波清单内，保留 rowTitle。
- 340pt 侧栏换行核对：popover 宽 340、`padding(16)`，内容宽 308pt。7 个汉字在 17pt 标准档约 119pt，特大殿（scale 1.45）约 173pt，均远小于 308pt，不换行，无需回退 rowTitle。

### 3. 监测计数等宽（`WorkspaceMonitorView.swift`）

- `:360` 报告头「未处理 n · 已处理 n」（`itemCountText`）：`.vosFont(WorkspaceText.meta)` → `.vosFont(WorkspaceText.meta.size, monospacedDigit: true)`。
- `:408` 分组标题「适用 n / 待核对 n」：`.vosFont(WorkspaceText.meta.size, weight: .semibold)` → 追加 `monospacedDigit: true`，字号与字重不动（12 semibold 属有意降级）。
- `:419` 「已处理 n 项，切换「全部」查看」：同样改 `vosFont(WorkspaceText.meta.size, monospacedDigit: true)`。
- `:430` 「已处理（n）」：weight 保持 semibold，追加 `monospacedDigit: true`。
- 用 `vosFont` 的 `monospacedDigit:` 参数而非 `Text.monospacedDigit()`：`VOSFontModifier` 内部 `content.font(...)` 会覆盖先置的 Text 字体变体，先 `monospacedDigit()` 后 `vosFont()` 的写法等宽会失效（`WorkspaceDesign.swift:613` 即此写法，属三文件范围外，未动）。

### 4. 约束遵守

未改任何标识符与文案语义；未用 `.font(...)` 绕过 `vosFont`；未新增 token 或抽象。

## 验证

共享锁循环，工作目录 `.worktrees/m115-c`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 43.162 (43.221) seconds`（与 114-C 同为 669，无测试增减）
- 代码提交：`124e10b fix(ui): 处理条标题与全景面板标题层级统一，监测计数等宽`

## 未做与取舍

- 未做真实 UI 驱动：本轮约束是不重启应用，验证止于全量构建与测试，没有在跑着的 app 里看字号与换行。
- `WorkspaceDesign.swift:613` 的 `Text(count).monospacedDigit().vosFont(WorkspaceText.meta)` 等宽疑似被 `vosFont` 覆盖而失效，属三文件范围外，未修，建议后续单独波次核对。
- `ThoughtPanoramaView.swift:704`「尚未合格的材料」未升级 sectionTitle：父任务只列了 462/496，且它是覆盖面板内部的子列表标题，保持现状更符合层级。
- 未 push、未合并、记录未删。