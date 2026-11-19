# 波 96 任务 A：空闲负载收敛

## 背景

用户反馈「软件很卡、按钮点击有性能问题」。波 87/88 已交付刷新代际门与定时器门控，静置 140 秒以上为 0% CPU。本波把剩余的周期性空闲负载逐个测量、收敛，不改功能语义：收件箱仍要及时发现新文件，全景仍要在内容变化时更新。

## 测量（修改前，运行中的 dist 应用）

环境：pid 97949（Version 0.1.0 (1)，启动约 21 分钟），10 核，load average 3.90（其他进程占用；按进程归因，不按整机）。未在测量期间运行构建。

### 短窗 14:59:41 起，13 次 ×5s

- %CPU 序列：0.0 / 0.0 / 0.4 / 0.0 / 0.4 / 0.0 / 59.0 / 16.5 / 0.4 / 0.0 / 0.4 / 1.3 / 0.4。
- CPU TIME：45.35s → 45.42s（前 30 秒共 0.07s），随后一次 +3.02s 突发（45.42 → 48.44），之后回到每秒级噪声。
- `sample 97949 10`（15:00:42 起）：栈顶全部空闲（mach_msg2_trap 15286、__workq_kernreturn 15274）；另有 getattrlistbulk 5 次，对应当前 10 秒收件箱扫描的一次目录枚举。

### 长窗 15:11:54–15:17:02，61 次 ×5s

- CPU TIME：63.76s → 77.16s，300 秒共 13.40s（4.5% 单核）。
- 前约 80 秒集中突发：增量 2.02 / 3.74 / 2.36 / 0.60 / 0.36 / 1.94 / 1.86s（累计 13.03s）。
- 之后 220 秒只花 0.37s（76.79 → 77.16），平均 0.17% 单核，单次采样 0.0–0.3%。
- 没有 60 秒周期性；两个窗口的突发都集中在开头。成因未能归因：StartupTrace 需要 VOICEOS_STARTUP_TRACE 环境变量且未开启，统一日志中无 VoiceOS 条目，用户交互未排除。内存 717M → 855M 跨一小时增长，符合一次性后台整理/索引，未发现与本波候选定时器的对应关系。

### 扫描单次成本（参考量级）

对实际连接的两个入口做等价枚举（Python os.walk + stat，仅作量级参考）：默认收件箱 4 个文件 0.01s，语音备忘录 Recordings 102 个文件 0.01s。合计约 0.02s/次，6 次/分 ≈ 0.12s/分（约 0.2% 单核），另加 6 次/分主线程 timer 唤醒。两个入口在 defaults 中均已启用（baseline 4 与 85）。

## 候选去留

1. **RecordingInbox 10 秒 Timer（原 `RecordingInbox.swift:103`）——收敛。** 改为 DispatchSource 目录事件（沿用 `FolderWatch.swift:64` 的仓库内既有做法）；只有目录 open 失败（路径缺失、不可读、不投递事件）才退回 10 秒轮询。语义保持：新文件仍要连续两次检查不变才处理（`observed` 双查逻辑原样保留）；整理忙时被阻塞的文件仍按 10 秒重试；失败重试按 `nextAttempt` 精确唤醒；唤醒与窗口激活照常扫描；新增 0.3 秒去抖合并连续目录事件。UI 文案同步为「有变化时立即检查」。
2. **ClipboardMonitor 1 秒 Timer（`ClipboardHistory.swift:43`）——保守保留轮询，加 tolerance。** 查证 macOS SDK 的 NSPasteboard.h 没有任何变更通知 API，changeCount 轮询是唯一手段；改 `timer.tolerance = 1`，让系统合并唤醒，语义不变（仍 1 秒轮询，仍记录最新一次变更，最迟约 2 秒内可见）。
3. **PanoramaScreenModel 1 秒循环（`:60-66`）——保留。** 仅在 `generate()` 工作期间轮询进度，工作完成即 `progressWorker?.cancel()`；空闲不运行。
4. **RecentContentHome 100ms（`:196-201`）——保留。** `.onAppear` 的一次性聚焦延迟，非周期。
5. **VoiceOSApp 300 秒提醒刷新（`:3532`）——确认无回归。** `requestReminderRefresh` 受 `reminderAccess.enabled` 门控，经 `ReminderRefreshCoordinator` 500ms 去抖；`automaticReminderRefresh` 另有 `remindersBusy` / `reminderFieldEditing` / `isAuthorized` 门控。
6. **VoiceOSApp 60 秒 followup（`:3533`）——确认无回归。** `resume*` 系列按 `store.dataGeneration` 变化门控；`refresh(.full)` 在 `reloadFullWorkspace`（`:1556-1560`）遇到相同 generation 时整轮跳过。
7. **其他发现（不在本波文件所有权，未改，仅记录）：** `MonitorCenter.swift:598` 600 秒 timer（`MonitorSchedule.decide` 日级门控，命中前只读一行报告）；`WorkspaceSourceView.swift:988-993` 300ms 播放位置轮询（仅来源页可见时）；`WorkspaceProcessingView` 的 `TimelineView` 1 秒（视图可见时，且属禁改文件）；`VoiceOSApp.swift:4225-4231` 口述计时器（仅口述中）。grep CADisplayLink / CVDisplayLink / makeTimerSource / DispatchSourceTimer / NSBackgroundActivityScheduler / NSTimer / repeatForever 均无结果；Task.sleep 的其余 25 处逐一查看为一次性延迟、去抖或活动流程内轮询。

## 改动

- `Sources/VoiceOSApp/RecordingInbox.swift:58-65` 新状态：窗口激活观察、`started`、目录观察表、重扫任务/去抖/退避。
- `Sources/VoiceOSApp/RecordingInbox.swift:110` 状态文案；`:458` 说明文案：有变化时立即检查。
- `Sources/VoiceOSApp/RecordingInbox.swift:114-116` 窗口激活扫描（覆盖权限恢复与模型就绪后的补扫）；`:122-129` stop 完整拆除。
- `Sources/VoiceOSApp/RecordingInbox.swift:133` `refreshWatchers`；`:152` `installPollingFallback`（仅降级模式，10 秒 + tolerance 2）；`:167` `requestScan`；`:180` `scheduleFollowUp`。
- `Sources/VoiceOSApp/RecordingInbox.swift:343-349` scan 头：重入标记、取消已排队的重扫；`:364-365` 不稳定/阻塞分类；`:406-407` 与 `:416` 收尾调度；`:421` `RecordingInboxDirectoryWatch`。
- `Sources/VoiceOSCore/RecordingInboxScanPacing.swift:7` 与 `:19` 纯调度决策：不稳定 1→30s 退避、阻塞 10s、`nextAttempt` 到点唤醒、其余 nil。
- `Sources/VoiceOSPlatform/ClipboardHistory.swift:46` `timer.tolerance = 1`。
- `Tests/VoiceOSCoreTests/RecordingInboxScanPacingChecks.swift:5` / `:13` / `:18` 三项测试。

## 验证

- 事件机制 harness（`/tmp/m96-harness/watcher_probe.swift`，镜像目录观察类）：`idle_10s_events=0 idle_10s_cpu=0.02s`；`event_latency=0.002s events_for_one_file=2`（连续事件由 0.3 秒去抖合并为一次扫描），退出码 0。
- 首轮完整验证：`swift build -j 2; echo build_exit=$?` → `build_exit=0`；`swift test -j 2; echo test_exit=$?` → `test_exit=0`，`Executed 648 tests, with 0 failures`（基线 645，本波新增 3）。
- 最终树（删除一条评注后）：`build_exit=0`、`test_exit=0`，`Executed 648 tests, with 0 failures`。
- 应用级修改后空闲测量受「不重启应用」约束无法进行。机制证据代替：事件驱动下空闲收件箱不再持有任何 timer；下次重启后可用 `top -pid <newpid> -l 61 -s 5` 复核整分钟序列。

## 取舍与风险

- 目录观察只看被监视目录本身的变更事件（DispatchSource 不递归）。连接入口内新增文件/子目录会立即触发；已存在子目录里的后续新增要等扫描时递归枚举，触发时机为窗口激活、唤醒或手动检查。当前两个连接入口都是平铺布局（收件箱 4 个文件、语音备忘录 Recordings 102 个文件，均无子目录），不影响现有数据。
- 整理忙时阻塞的文件保持 10 秒重试；不稳定文件确认退避 1→30 秒；定时重试按 `nextAttempt` 到点唤醒，不再依赖 10 秒心跳。
- 窗口激活增加一次枚举（约 0.02s），换来权限恢复/模型配置完成后无需空等 10 秒。
- 轮询回退只在 open 失败时启用，行为与旧版一致；watcher 打开成功但平台不投递事件的极端情况没有额外保底定时器，恢复依赖激活/唤醒/手动检查。
- 剪贴板 tolerance 最多把记录延迟到约 2 秒；记录规则（只记最新一次、跳过重复）不变。
- 未重启应用、未 push、未合并 main；未做迁移、未改 schema；行为、标识、键盘不变。

## 文件所有权说明

- `Sources/VoiceOSPlatform/ClipboardHistory.swift` 未在清单逐字列举；清单把「剪贴板历史相关…（grep ClipboardHistory/剪贴板）」列为候选并由 grep 定位，轮询本体只存在于该文件，改动仅一行 tolerance。
- 未修改清单外的任何其他文件；未触碰 WorkspaceActivityViews.swift 与 WorkspaceProcessingView.swift。
