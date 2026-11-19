# 波 104-A：处理页与活动视图视觉统一

## 背景

波 102 建立了 WorkspaceDesign 的共享词汇（`WorkspacePageHeading` / `WorkspaceSectionHeading` / `WorkspaceCard` / `WorkspaceBadge` / 四档按钮），波 103 覆盖主页面与弹窗后，处理页仍停在旧的 serif Hero 时代：页头用 `WorkspaceHeading`，24 个分节用旧的 `WorkspaceSection` 卡片；`WorkspaceActivityViews` 里另有 2 个旧页头、10 个旧分节，以及 11 处系统蓝 `.borderedProminent` 与若干无样式 / `.borderless` 文本按钮。本波只改 `WorkspaceProcessingView.swift` 与 `WorkspaceActivityViews.swift`；行为、identifier、键盘与文案不变；不写实时库、不重启、不 push、不合并。

## 改动（行号为改后行号）

- `WorkspaceProcessingView.swift`
  - L279 旧 `WorkspaceHeading` → `WorkspacePageHeading`，眉题、标题、说明逐字保留。
  - L242「等待自动重试」Label → `WorkspaceBadge(.warning)`；L338 空闲状态 → `.neutral`；L739「已全部处理」→ `.success`。
  - 24 个 `WorkspaceSection` 全部改为 `WorkspaceCard` + `WorkspaceSectionHeading` + 说明行 + `WorkspaceListDivider`；16 圆角、hairline、20 内边距均由 `WorkspaceCard` 提供（L282、311、324、341、357、396、420、439、464、489、513、524、544、558、578、602、616、630、644、680、702、713、726、893）。
  - 分节计数改 `WorkspaceBadge`：需查看的失败/核对分节 warning（L284、359、398、422、441、466、491、526、546、560、580、604、646）；本地待同步与待登记 accent（L682、895）；最近完成 neutral（L728）。L651–653 提醒回读异常拆为「找不到 / 身份不一致 / 未确认」三个 warning 徽标，文字逐字保留。
  - 按钮：处理条「停止并整理」→ `workspacePrimary`，「取消并丢弃…」→ `workspaceDestructive`，「查看处理 / 停止后续处理」→ `workspaceSecondary`；重试、继续、核对类按上下文 `workspaceSecondary`（分节级）或 `workspaceSecondaryCompact`（行内），「忽略这次」类 → `workspaceQuietCompact`；「移入回收站」→ `workspaceDestructive`。处理页共 39 处 workspace 按钮样式。
  - 未发现需要改圆角/边线的自绘时间线容器；文件内唯一 `TimelineView` 是口述计时，不是容器。自绘选择底与胶囊（撤销条、复核面板）本就用 `panelRadius` / `Capsule` + `palette.border`。
- `WorkspaceActivityViews.swift`
  - L27、L446 两个旧页头 → `WorkspacePageHeading`。
  - 10 个 `WorkspaceSection` → `WorkspaceCard` + `WorkspaceSectionHeading`（L40 交付正文、L59 参考与来源、L88 继续使用这份成果、L644 重复、L662 子任务、L705 任务说明、L732 AI 的工作与交付、L756 实际进展与收获、L771 记录与依据、L915 下一步 / 我自己做）。
  - 状态与计数徽标：未读交付 accent（L30）、已逾期 warning（L457）、目标进展 neutral（L505）、参考计数 neutral（L61）、子任务 / 交付 / 进展 / 下一步计数 neutral（L665、734、758、918）；长句状态说明（如「依据已变化…」、提醒同步说明）保留为文本 / Label，仅短状态与计数改徽标。
  - 11 处系统蓝 `.borderedProminent` 清零：交付页「带着成果继续讨论」、任务底部「标记已完成 / 添加下一步 / 重新打开 / 想清楚了」、下一步表单「添加 / 重试挂接」→ `workspacePrimary`；澄清面板、提醒写入、保存替代待办、代办表单等面板内动作按“每页唯一 primary”降为 `workspaceSecondary`。
  - 其余按钮：行内重试 / 打开材料 / 回听 / 摘除 / 清除 → `workspaceQuietCompact`；预计时长选择 → `workspaceSecondaryCompact`；「不再跟进 / 放下 / 移入回收站」→ `workspaceDestructive`；日期与提醒、写入提醒事项、核对提醒同步、排期核对 / 撤回等 → `workspaceSecondary`。全文件 workspace 样式共 8 primary、47 secondary、26 secondaryCompact、18 quietCompact、5 destructive。
  - 行级图标按钮（子任务勾选、下一步勾选）保留 `.plain`；删除子任务的纯图标按钮保留 `.borderless`（非灰胶囊）。

## 验证

- 首次共享锁等待 40×15s 仍被其他波占满，脚本按约退出 3（LOCK_TIMEOUT）；确认锁目录已释放、无 swift 进程后立即重试并一次拿到。
- `swift build -j 2`：build_exit=0，`Build complete! (113.38s)`。
- `swift test -j 2`：test_exit=0，`Executed 662 tests, with 0 failures (0 unexpected) in 44.790 (44.846) seconds`。
- 日志：`/tmp/m104-a-build.log`、`/tmp/m104-a-test.log`；跑完共享锁已释放。
- `git status`：仅 `WorkspaceProcessingView.swift`、`WorkspaceActivityViews.swift` 与本记录。

## 取舍与风险

- 共享页头 / 分节头不含旧分节的 accent 图标，页头标题也不再带旧 `WorkspaceHeading` 的 `.textSelection(.enabled)`；字体未变（两代组件都用 `WorkspaceText` 同一组字号 / 字重），编辑性阅读气质由眉题、说明行与行距保持，没有引入或移除 serif。
- 分节说明从标题旁移到标题下的 meta 行，文案逐字保留。
- primary 采用“每页唯一”：处理条只给「停止并整理」，任务页只给底部主操作，独立表单 / 工作表才有自己的 primary；面板类动作统一 secondary，避免同屏多个实心按钮。
- `.alert` 内按钮由系统渲染，不参与分档；行级图标按钮保留 `.plain` / `.borderless`。
- 未新增颜色与字号；没有 UI 快照测试，最终视觉效果仍需随 104-B/C/D 合入后的下一安装批次人工确认。