# 波 89 任务书（2026-11-19）：监测与历史报告的加载态与保存反馈

## 背景（发现者 B 报告，波 85/86 未覆盖部分）

- B5：监测页首帧先渲染误导性空态（「还没有报告」「未添加 QQ 群来源」），`onAppear` 后才异步加载；「保存 QQ 设置」只写 `monitorStatus`，而该变量只在「报告」页 runBar 渲染，设置页看不到保存结果。证据：`WorkspaceMonitorView.swift:61-65,112-122,403-410,103-106,33-48`；`MonitorCenter.swift:392-395,204-213,293-334`。
- B6：历史报告展开瞬间先显示「没有需要关注的事项」（缓存缺失当空数组），随后条目出现。证据：`WorkspaceMonitorView.swift:212-216,148`；`MonitorCenter.swift:171-183`。

## 完成判据

1. 加载态分离：`monitorLoaded` 标记（或等效）区分「未加载」与「确实为空」；首帧显示 ProgressView 而非空态；加载完成前不渲染「未添加 QQ 群来源」类提示。
2. 设置页可见保存结果：`monitorStatus`（或其细分状态）在「设置」页对应操作旁渲染（QQ 保存、来源开关、起始时间、事项状态变更），失败可见且有下一步提示；不改变报告页现有展示。
3. 历史报告：事项缓存缺失时显示 ProgressView，加载完成后才允许空态；补齐失败时显示错误而非空。
4. 行为、文案（除新增提示）、标识、键盘零变化；不加迁移。
5. 测试 ≤3（纯逻辑，中文断言，例如加载态状态机）；build/test 真实退出码 0（基线 632）。
6. 结果给 file:line 清单与判据落点。

## 文件所有权

`Sources/VoiceOSApp/WorkspaceMonitorView.swift`、`Sources/VoiceOSApp/MonitorCenter.swift`、对应测试。不碰其他文件。

## 约束

16GB：锁 `/tmp/voiceos-swift-build.lock`；先 merge main；不写实时库；不重启应用；不 push、不合并。分支 `work/m89-monux`。

## 结果

- 分支：work/m89-monux（基于 main 14635ba；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：06170fb「fix(消息监测): 加载态与保存反馈分离，未加载不再显示为空」（4 文件，115 增 20 删）。
- 归因（任务书背景 B5/B6，行号为改动后）：
  - B5 首帧空态：`Sources/VoiceOSApp/WorkspaceMonitorView.swift:28` 新增 `monitorLoaded`，`68` 在首轮 `onAppear` 重载完成后置真。`117-124` 今日报告、`139-156` 历史报告（未加载时计数徽标不渲染，`141`）、`435-462` 来源状态在加载前只显示 ProgressView 行（`289-294`），不再渲染「还没有报告」「还没有更早的历史报告」「未添加 QQ 群来源」「内置栏目未添加」（内置提示在 `453` 增加加载门）。
  - B5 设置页保存结果：`WorkspaceMonitorView.swift:693-697` 在 QQ 操作按钮组下方就地显示保存结果，失败转警告色；`876-884` 保存后快照结果与文案。`Sources/VoiceOSApp/MonitorCenter.swift:50-55` 让设置存储返回成功标记，`419-427` 让保存返回结果，失败文案为「QQ 读取设置保存失败，请重试；若仍失败请重启应用后再试」。报告页 runBar 的既有状态展示未改（`WorkspaceMonitorView.swift:108-111`）。
  - B6 历史报告展开闪空态：`WorkspaceMonitorView.swift:296-307` 展开时按缓存发起加载，完成后仍无缓存则记录失败；`218-231` 事项区按 `MonitorItemsPresentation` 分四态渲染，缓存缺失显示「正在读取事项…」，失败显示「事项读取失败，请收起后重新展开重试。」并转警告色，读取成功后才允许空态文案；`273-279` 头部计数同规则，未加载时不再显示「未处理 0 · 已处理 0」。状态机在 `Sources/VoiceOSCore/MessageMonitor.swift:181-190`。
- 测试：`Tests/VoiceOSCoreTests/MonitorItemsPresentationChecks.swift:14-31` 三项纯逻辑测试（缓存缺失未失败为加载态、读取成功后的空数组才是空态、失败为错误且旧缓存优先），断言为中文。
- 验证：merge_exit=0；build_exit=0（`swift build -j 2`，99.01 秒）；test_exit=0（`swift test -j 2`），635 项 0 失败（基线 632 加新增 3），41.75 秒。构建与测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；本波 rmdir 执行于 06:15:54（与 `/tmp/m89-test.log` mtime 相同），检查时目录创建时间同为 06:15:54 且无 swift 构建进程，推断为其他任务随后重建，未代为删除。`git diff --check` 退出码 0；未写实时库、未重启应用、未 push、未合并。
- 判据落点：
  - 判据 1：`monitorLoaded` 区分未加载与确实为空；三处首帧显示 ProgressView，加载完成前不渲染「未添加 QQ 群来源」类提示。
  - 判据 2：设置页 QQ 保存、依赖检查、列出群都经 `saveQQSettings()`，结果显示在按钮组下方；失败为警告色并给出重试提示。来源开关、起始时间、事项状态变更发生在报告页，既有 runBar 状态展示保持不变，未按设置页新增渲染。
  - 判据 3：历史报告事项缓存缺失显示 ProgressView，读取失败显示错误与重试提示，空态只在读取成功后出现。
  - 判据 4：除新增提示文案外，行为、标识、键盘未变；不加迁移。
  - 判据 5：测试 3 项，纯逻辑，中文断言；真实退出码见验证。
  - 判据 6：归因 file:line 见上。
- 所有权说明：新增的纯状态机放在 `Sources/VoiceOSCore/MessageMonitor.swift`，超出任务书文件清单。原因：XCTest 目标只依赖 VoiceOSCore 与 VoiceOSPlatform，`VoiceOSApp` 是可执行目标，纯逻辑放在本波拥有的两个 App 文件里无法被测试；替代做法是改 `Package.swift` 给测试目标加 App 依赖（改动面更大），或本波不加测试（与判据 5 冲突）。波 85/86 在需要测试时同样在任务书里列入 Core 文件，此处按同一先例处理。
- 遗留风险：
  - 今日报告的事项由 `performMonitorReload` 自动补载（`MonitorCenter.swift:189-191`），该路径失败时视图收不到失败信号，事项区会停留在加载行，错误文本在上方 runBar 可见。要彻底区分需要在 `VoiceOSApp.swift` 增加发布状态，本波未动。
  - 检查运行会清空全部事项缓存并只重载最新报告（`MonitorCenter.swift:185-188`），此刻展开中的历史报告会回落到加载行，收起再展开即恢复；改动前这里是误导性空态。
  - QQ 保存的失败分支在现有存储实现下几乎不可达（四个字符串的 JSON 编码与 UserDefaults 写入）；失败文案为诚实保留，仅由返回值驱动。
  - 侧栏未处理计数 `monitorOpenItemCount`（`MonitorCenter.swift:621-624`）仍把缺失缓存当作 0，不在本波点名的首帧区域，未改。
