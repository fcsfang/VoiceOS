# 波 105-A：组件与首页特大字号适配

## 背景

波 105 的只读审计在「特大」（xlarge，scale 1.45，`EnvironmentValues.vosTextScale`）下发现组件与首页截断：首页时间线固定 288pt 里行标题只剩约 10 字；徽标无 lineLimit 可换行成两行胶囊；按钮长文案直接省略；页头 trailing 与标题在窄宽互相挤压。本单元只改 `WorkspaceDesign.swift` 与 `RecentContentHome.swift`；行为、identifier、文案、键盘不变；不写实时库、不重启、不 push、不合并。

## 改动（行号为改后行号）

- `WorkspaceDesign.swift`
  - L262 `WorkspaceListRow` 读取 `@Environment(\.vosTextScale)`；L326 `textLineLimit` 在 scale >= 1.3 时 2 行、否则 1 行；标题 L296、副标题 L300 改用 `textLineLimit`。
  - L464 `WorkspaceButtonBody` 的 `.lineLimit(1)` 后加 `.minimumScaleFactor(0.85)`，长文案按钮略微缩小而不是省略。
  - L529–530 `WorkspaceBadge` 的 Text 加 `.lineLimit(1).minimumScaleFactor(0.8)`，禁止变两行胶囊。
  - L567 `WorkspacePageHeading` 改用 `ViewThatFits(in: .horizontal)`：首选原 HStack；放不下时回退 `VStack(alignment: .leading, spacing: 12)`，标题块在上、`trailing()` 在下。标题块抽为 L580 `titleBlock`，眉题、标题、说明的字体与文案逐字不变。
- `RecentContentHome.swift`
  - L17 读取 `@Environment(\.vosTextScale)`；L43 `isLargeText`（scale >= 1.3）；L44 `timelineWidth = 288 * min(max(scale, 1), 1.3)`。
  - L63 时间线宽由固定 288 改为 `timelineWidth`，随字号缩放到 1.3 封顶。
  - L239 列表行标题 lineLimit 2 → 特大 4；L241 meta lineLimit 1 → 特大 2。
  - L643「最近想法」入口预览 statement lineLimit 3 → 特大 4；L647 sourceTitle lineLimit 2 → 特大 3。

## 验证

- 首次共享锁等待 40×15s 被 105-B 占满（锁目录 05:31 创建、其 swift-test 进程在跑），脚本按约定退出 3（LOCK_TIMEOUT）；确认持有者后立即重试。
- 重试一次拿到锁。`swift build -j 2`：build_exit=0，`Build complete! (118.80s)`。
- `swift test -j 2`：test_exit=0，`Executed 662 tests, with 0 failures (0 unexpected) in 43.731 (43.787) seconds`。
- 日志：`/tmp/m105-a-build.log`、`/tmp/m105-a-test.log`；跑完共享锁已释放，`git status` 仅上述两文件与本记录。

## 取舍与风险

- 阈值 1.3：四档 scale 为 1.0 / 1.12 / 1.28 / 1.45，只有「特大」越过 1.3；「大」（1.28）保持原单行/两行节奏，不让中间档位出现布局跳动。
- 时间线宽在 1.0–1.3 间线性缩放（288 → 374.4pt），1.45 下不再继续加宽，避免窗口被挤爆；多出的空间由加行消化。
- `ViewThatFits` 按候选的理想宽度判断：标题能整行放下才用 HStack，需要换行时整块回退为上下布局；两套候选复用同一 `titleBlock`，字体与 accessibility 语义一致。
- 徽标与按钮是「缩小而非换行/省略」；`minimumScaleFactor` 只在实测宽度不足时生效，正常宽度下字号不变。
- `WorkspaceListRow` 定义在 `WorkspaceDesign.swift`，已在 105-A 范围内处理，无需顺延给 105-B。
- 无 UI 快照测试；1.45x 下的最终观感需随 105-B/C 合入后的下一安装批次人工确认。