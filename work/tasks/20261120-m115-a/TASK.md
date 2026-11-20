# 波 115-A 数字列等宽与摘要层级收口

基线 `work/m115-a`，工作树 `.worktrees/m115-a`。只改六个文件：`WorkspaceTextScale.swift`、`WorkspaceView.swift`、`RecentContentHome.swift`、`TranscriptSegmentationView.swift`、`FullRecordingView.swift`、`PausedActionBatchView.swift`。

## 目标

按排版审计收口两件事：数字列（存储字节数、各类计数、字符区间、时间码）统一用等宽数字，数字变化时列宽不跳动；两处「摘要继承 body」的层级问题改回 meta，让摘要与正文拉开层级。

## 前置：样式重载加参数

`Sources/VoiceOSApp/WorkspaceTextScale.swift:62-64`：`vosFont(_ style: WorkspaceTextStyle)` 增加 `monospacedDigit: Bool = false` 并转传给 size 重载，调用方写 `vosFont(WorkspaceText.meta, monospacedDigit: true)`，不再拆 `.size`。默认值 false，其余调用点行为不变。

## 改动清单（文件:行号为改后位置）

`Sources/VoiceOSApp/WorkspaceView.swift`

- `:1970` 存储字节数：`vosFont(WorkspaceText.meta)` → `vosFont(WorkspaceText.meta, monospacedDigit: true)`。
- `:1204` 本地完成待同步计数：`meta` → `meta` + mono。
- `:2337` 安排专注弹窗的已选条数：`vosFont(WorkspaceText.caption)` → `caption` + mono。
- `:2527` 批量操作已选条数：`vosFont(WorkspaceText.meta.size, weight: .medium)` → 同参数加 `monospacedDigit: true`。
- `:1073` 「尚未归入主题的材料（n）」：`vosFont(WorkspaceText.sectionTitle)` → `sectionTitle` + mono。计数内嵌在标题括号里，拆成拼接会改动标题结构，按任务约定整行加 mono。
- `:1214` 已有的 `.monospacedDigit().vosFont(WorkspaceText.meta)` 不动，沿用既有写法。

`Sources/VoiceOSApp/RecentContentHome.swift`

- `:487` 待办计数徽标：`vosFont(WorkspaceText.meta.size, weight: .semibold)` → 加 `monospacedDigit: true`。
- `:598` 「这条材料带出了 n 条待办」：`meta` → `meta` + mono。
- `:660` 「n 条 · 近 14 天」：`caption` → `caption` + mono。
- `:673` 日期分组「… · n 条」：`caption` → `caption` + mono。日期与计数同行，整行等宽，与文件内 `:539` 序号列的写法一致。

`Sources/VoiceOSApp/TranscriptSegmentationView.swift`

- `:11` 「… · n 段 · 每段最多 n 字符」：原本没有显式字体，只追加 `.monospacedDigit()`，不加 `vosFont`。用 `vosFont(WorkspaceText.body)` 会把默认正文字号改成 15pt，属于本项未要求的层级变化。
- `:17` 段序与字符区间：`vosFont(WorkspaceText.rowTitle)` → `rowTitle` + mono。
- `:23` 引用字符区间：`meta` → `meta` + mono。
- `:25` 「%.1f—%.1f 秒」时间码：`meta` → `meta` + mono。

`Sources/VoiceOSApp/FullRecordingView.swift`

- `:29` 完整时长/音轨行：原本无显式字体、继承 body，改为 `vosFont(WorkspaceText.meta, monospacedDigit: true)`。
- `:38` 主操作说明：`vosFont(WorkspaceText.caption)`（11pt）→ `vosFont(WorkspaceText.meta)`。审计给了 body 或 meta 两个选项，选 meta：这是主操作下方的解释段落，与同页 `:47`/`:52` 的状态与警告行同为 meta，升到 body 会与主操作按钮的文案等级打架。

`Sources/VoiceOSApp/PausedActionBatchView.swift`

- `:86-87` 批量摘要「已更新/跳过/失败」：继承 body → `vosFont(WorkspaceText.meta, monospacedDigit: true)`。
- `:89`、`:92`、`:95`、`:98`、`:101` 摘要里的剩余/核对/撤回计数行：继承 body + `.secondary` → `meta` + mono + `.secondary`。
- 明细行（`:105` 起 DisclosureGroup 内）保持 body，不动。

标识符与文案语义未改，没有用 `.font(...)` 绕过 vosFont（`TranscriptSegmentationView :11` 的 `.monospacedDigit()` 是 Text 自带修饰符，不改变字体与字号，且本文件其它位置已有同类用法，如 `WorkspaceView :1214`）。

## 验证

共享锁循环，工作目录 `.worktrees/m115-a`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码。

- 第一次运行：等待 `/tmp/voiceos-swift-build.lock` 40 次（每次 15 秒）未获得，脚本输出 `LOCK_TIMEOUT` 退出 3，未执行任何 build。按约定整段重跑一次。
- 重跑：`build_exit=0`（Build complete! 121.04s）
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 46.168 (46.232) seconds`
- 代码提交：`dfb9fe4 fix(ui): 数字列统一等宽，摘要行收口到 meta 层级`

## 未做与取舍

- 未做真实 UI 目测：本轮约束是不重启应用，验证止于全量构建与测试，没有在跑着的 app 里看数字列的等宽效果。
- `TranscriptSegmentationView :19` 的 DisclosureGroup「原片段引用（n）」是计数而非区间，按任务条件（若为区间也加）未加 mono；给它加字体需要把便捷构造改成 label 闭包，超出本轮最小改动。
- `WorkspaceView :1073` 标题整体加 mono，标题文字也变成等宽字形，这是「计数难拆」约定的取舍。
- `FullRecordingView :38` 在 body 与 meta 之间选了 meta，理由见上。
- `PausedActionBatchView` 进度态的 `progress.label`（`:75`）不在「摘要」范围，未动。
- 未 push、未合并，记录未删。