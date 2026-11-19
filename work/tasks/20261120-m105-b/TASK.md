# 波 105-B：工作台与引导页特大字号适配

## 背景

波 105 审计在 1.45x「特大」下发现固定宽度与单行限制造成截断。本单元覆盖工作台主导航、保存视图、材料侧栏、WorkspaceRow、筛选页签回退网格、待同步弹窗、来源折叠图标与引导页。只改尺寸、行数与换行策略，行为、identifier、文案与键盘不变；不写实时库、不重启、不 push、不合并。

## 改动（行号为改后行号）

- `WorkspaceView.swift`
  - L142 新增 `vosLayoutScale`，全模块共用同一个上限 `min(max(scale, 1), 1.3)`。
  - L678 主导航宽 `172` 改为 `172 × vosLayoutScale`；L685 导航标签在 scale ≥ 1.3 时允许 2 行，否则保持 1 行。
  - L640 保存视图名同样在 scale ≥ 1.3 时 2 行，否则 1 行。
  - L2571 材料侧栏宽 `248` 改为 `248 × vosLayoutScale`；L618 品牌图标 26pt 同步缩放。
  - L211、L212 WorkspaceRow 标题与副标题在 scale ≥ 1.3 时放宽到 3 行，否则保持 2 行。
  - L222-236 trailing 状态文本（secondary / status / link / dot）加 `lineLimit(1)`，secondary 与 status 补 `.help`。
  - L177、L191 两个 30×30 图标框按 scale 缩放。
  - L3068 筛选回退网格最小宽 `56` 改为 `56 × vosLayoutScale`；L3082 计数加 `lineLimit(1)`，标题保留单行。
  - L2517 待同步弹窗 `frame(width: 520)` 改为 `frame(minWidth: 520)`。
- `WorkspaceSourceView.swift`
  - L117 `SourceFold` 的 19pt 图标框由固定 `26×28` 改为按 scale 缩放的 `minWidth` / `minHeight`，避免特大字号下裁切。
- `Onboarding.swift`
  - L40 28pt 步骤图标所在的 40pt 框按 scale 缩放。
  - L33-54 内容包进 `ScrollView`，`fixedSize` 与 `maxHeight: 520` 让内容超高时才滚动；步骤圆点（L55）与底部按钮留在滚动区外，始终可见。
  - L72 sheet `frame(width: modalSmall)` 改为 `frame(minWidth: modalSmall)`。
  - 检查行动作按钮原已使用 `workspaceQuietCompact`，未新增样式。

## 验证

- 共享锁脚本一次执行，真实退出码：`build_exit=0`，`Build complete! (117.00s)`；`test_exit=0`，`Executed 662 tests, with 0 failures (0 unexpected) in 44.316 (44.371) seconds`。
- 日志：`/tmp/m105-b-build.log`、`/tmp/m105-b-test.log`。脚本退出后锁由并行波 105-A 的构建接续持有，未干预。
- `git status`：仅三个源文件与本记录。

## 取舍与风险

- 宽度缩放上限取 1.3，与波 105 计划一致。特大 1.45 下导航与侧栏各多出约 17%，其余由行数与换行补偿。
- 行数放宽只看 `textScale >= 1.3`，即只有「特大」变化，「大」（1.28）保持原样。
- 引导页滚动区上限 520pt 为手选值，按 modalSmall 620 宽与各步骤内容高度估算；没有 UI 快照测试，1.45x 下的实际视觉仍需随下一安装批次人工确认。