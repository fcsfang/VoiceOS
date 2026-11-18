# 波 92 任务书（2026-11-19）：视觉一致性清扫

## 背景（发现者 B 报告 B10）

- 来源页 38 处 `.foregroundStyle(.secondary)` 与一处 `.font(.caption)` 绕过 `palette` 与增大对比度设置（`WorkspaceSourceView.swift:191-198,439,680-693` 等）。
- 材料管理/回收站页、自动入口说明、来源页抓取信息未用 `vosFont`，文字大小设置对其无效（`MaterialManagementView.swift:72-78`、`RecordingFollowupView.swift:89-90`、`RecordingInbox.swift:347-350`）。
- 处理页用 30/860、回收站用 30/820，token 是 32/860；标题有 `WorkspaceHero` 与 `WorkspaceHeading` 两套（`WorkspaceProcessingView.swift:583`、`WorkspaceView.swift:82-93`）。

## 完成判据

1. 在任务书拥有的文件里，把 `.foregroundStyle(.secondary)` 改为 `palette.secondaryText`（同层级 `.tertiaryText` 有对应 token 的也改），`.font(.caption)` 改为 `vosFont(WorkspaceText.caption)`。
2. 未用 `vosFont` 的正文/说明文字改用对应 `vosFont` 层级。
3. 页宽/字号字面量（30/820、30/860 等）改回既有 token（如 `WorkspaceMetrics.pageContentWidth`、`WorkspaceText` 层级）。
4. 纯样式替换，不改布局结构与文案；不改标识与键盘；不加迁移。
5. build/test 真实退出码 0（基线 635）；不加测试（纯样式）。
6. 结果给替换清单（文件与数量）与判据落点。全部替换必须逐一核对目标存在对应 token，找不到等价 token 的保留并列入结果。

## 文件所有权

`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSApp/MaterialManagementView.swift`、`Sources/VoiceOSApp/WorkspaceProcessingView.swift`、`Sources/VoiceOSApp/RecordingFollowupView.swift`、`Sources/VoiceOSApp/RecordingInbox.swift`。不碰其他文件。

## 约束

16GB：锁 `/tmp/voiceos-swift-build.lock`；先 merge main；不写实时库；不重启应用；不 push、不合并。分支 `work/m92-visual`。

## 结果

- 分支：work/m92-visual（基于 main 666b14c；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：face1ba「style(视觉): 次要前景、字号与页宽改回 palette/vosFont/WorkspaceMetrics token」（5 文件，99 增 95 删）。
- 替换清单：
  - `WorkspaceSourceView.swift`：37 处 `.foregroundStyle(.secondary)` 改为 `palette.secondaryText`；10 处文字补 `vosFont`（`historyVersions` 空态 281、转写未完成 643、无可用转写 988 用 meta；版本原文 283、逐层读圆点 400、引文 435/438、无观点说明 464、节目双方原话 626/629 用 body）。`532` 的 `.font(.caption)` 改为 `.vosFont(WorkspaceText.caption)`；`ClaimCorrectionView` 底部 `frame(width:620)` 改为 `WorkspaceMetrics.modalSmall`。`SourceLoadingRow` 135 与 `RecordingExpressionTitleEditor` 1501 补 `@Environment(\\.workspacePalette)`。
  - `MaterialManagementView.swift`：2 处换色（75/77）；回收站说明 74 补 `vosFont(WorkspaceText.body)`；页框 `padding(30)`/`maxWidth:820` 改为 `WorkspaceMetrics.pagePadding`/`pageWidth`（79）；`TrashedMaterialView` 68 补 `palette` 声明。
  - `WorkspaceProcessingView.swift`：15 处换色（235/238/239/243/308/310/315/318/354/439/542/559/571/606/607）；状态 Label 315/606 补 `vosFont(WorkspaceText.meta)`；页框 `maxWidth:860`/`padding(30)` 改为 `pageWidth`/`pagePadding`（611）；主视图 262 补 `palette` 声明。
  - `RecordingFollowupView.swift`：19 处换色；空态与引文 9 处补 `vosFont(WorkspaceText.body)`（89/90/115/119/132/180/181/189/190）。
  - `RecordingInbox.swift`：8 处换色（349/350/357/372/390/392/396/404）；首段说明 347 补 `vosFont(WorkspaceText.body)`。
  - 合计：换色 81、补 `vosFont` 27（4 处环境声明，23 处文字层级）、字面量换 token 4（两处页框、一处 caption、一处弹窗宽度）。
- 判据落点：
  - 判据 1：81 处 `.secondary` 全部改为 `palette.secondaryText`；五个文件原本没有裸 `.foregroundStyle(.tertiary)`，无 tertiary 替换。
  - 判据 2：任务点名的回收站说明、跟进空态（89/90/132）、收件箱首段（347）以及来源页引文与说明均补 `vosFont`，正文用 body，短状态用 meta。
  - 判据 3：材料管理 30/820 与处理页 30/860 统一为 `pagePadding`/`pageWidth`（32/860）；弹窗 620 用 `modalSmall`。
  - 判据 4：纯样式替换，未改布局结构、文案、标识与键盘，不加迁移。
  - 判据 5：build_exit=0（`swift build -j 2`，76 秒）；test_exit=0（`swift test -j 2`），635 项 0 失败（基线 635），43.839 秒。首次构建 70 秒 exit 1，原因是 `RecordingExpressionTitleEditor` 未声明 `palette`（1515/1516 两行）；补声明后重建 exit 0。未新增测试。
  - 判据 6：替换逐一核对了目标 token；保留项与原因见下。
- 保留项与原因：
  - `WorkspaceProcessingView.swift:438` 的 `Text(task.title)`、`534` 的 `Text(issue.title)`，以及 `RecordingFollowupView.swift:155` 的 `Text(step.title)`：行内标题层级，套用 `rowTitle` 会拉平阶段/步骤或与行标题同级，保留系统字号。
  - 系统弹窗与菜单文案（`MaterialManagementView.swift:22`、`RecordingInbox.swift:380/414`、`RecordingFollowupView.swift:70`、`WorkspaceProcessingView.swift:257/685/710/788`、`WorkspaceSourceView.swift:859`）：由系统控件排版，未改。
  - `RecordingFollowupView.swift:94` 的窗口 820×700：独立工具窗尺寸，非页宽，无等价 token。
  - `WorkspaceSourceView.swift:1441/1523` 的 650/600 编辑窗宽、`1266` 的 280 回听进度、`114` 的 26/28 图标，以及 `WorkspaceProcessingView.swift:764` 的 30×30 图标按钮：控件尺寸，非页宽/字号，保留。
  - `WorkspaceView.swift:102-110` 的 `WorkspaceHeading` 与其余文件仍有裸 `.secondary`，不在本波所有权内；五个文件内未使用 `WorkspaceHero`。
- 验证补充：`git diff --check` 退出码 0。构建与测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；本波释放后，07:51:04 该目录由 `work/m91-feedback` 的 `swift-build -j 2` 重建（编译进程指向 m91 工作树），未代为删除。未写实时库、未重启应用、未 push、未合并。
- 遗留风险：
  - 引文由系统 13 号改为 `WorkspaceText.body`（15，乘文字缩放），阅读尺寸变大属预期，部分面板的换行分布会变化。
  - 计数与第三级事实统一用 `secondaryText`，未改用 `tertiaryText`；如要更细分可按点位再收。
  - 其他文件与 `WorkspaceView` 的裸 `.secondary`、`WorkspaceHero`/`WorkspaceHeading` 两套标题仍存在，留给后续波次。
