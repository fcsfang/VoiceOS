# 波 95 任务 B（2026-11-19）：交付页非主按钮失败反馈补全

## 用户诉求

波 91 已把任务详情主操作失败改为按钮组附近就地显示并可重试（InlineFailurePresentation），但交付页（WorkspaceDeliveryView）与记录保存等非主按钮操作失败时仍只写页面底部 error，长页里用户可能看不到。目标：失败时在对应按钮组附近就地显示 warning 短文案与「重试」，成功路径与页底 error 保持不变，行为、标识、键盘零变化。

## 改动（Sources/VoiceOSApp/WorkspaceActivityViews.swift，行号为改动后）

1. 状态 `23`：`@State private var exportFailure: InlineActionFailure?`，沿用既有 `InlineActionFailure`（actionID + message + retry）结构，不引入新通道。
2. 保存报告（交付正文区）`43-49`：WorkspaceSection「保存报告…」正下方就地渲染 warning 横幅与「重试」按钮（accessibilityLabel「重试保存报告」）。
3. 取消代办 `81`：按钮改走 `cancelExecution()`；`126-136` 实现——先清空 failure，调用 `model.cancelAssistant`，以刷新后记录的 state 是否仍为 queued/running 判定失败，失败写入既有横幅槽位（复用 `84-91` 的 warning + 「重试」行），文案经 `InlineFailurePresentation.message(operation: "取消代办", reason: model.assistantStatus)`。
4. 导出实现 `148-163`：进入时清空 exportFailure（`149`）；写入失败 catch 内保留原 `self.error = error.localizedDescription`，并新增 `self.exportFailure = InlineActionFailure(operation: "保存报告", retry: { self.export(report) })`（`159-163`），重试重新打开保存面板、写同一报告内容。
5. 记录保存 `1163-1172`：`saveFeedback` 开始时清空 `mainActionFailure`（`1165`）；失败分支保留 `error = model.status`，并新增 `noteMainActionFailure("保存记录") { saveFeedback() }`（`1170`），复用波 91 主操作失败横幅（`605-611`，位于动作行与记录编辑器之间）。重试沿用草稿与同一 commandID。

未改动：任务详情既有主操作失败反馈、提醒区块（波 91/94 成果）、成功路径、页底 error 展示、标识与键盘。未新增迁移与测试。

## 真实退出码

- `swift build -j 2` → `build_exit=0`（Build complete! (117.45s)）
- `swift test -j 2` → `test_exit=0`，`Executed 643 tests, with 0 failures (0 unexpected) in 43.553 (43.608) seconds`（基线 643 项不动；日志尾部另有 swift-testing 运行器「0 tests in 0 suites」行，为本包无 swift-testing 套件的正常输出，XCTest 汇总为 643 项）
- 构建与测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、mtime 超 2400 秒陈旧可清、结束 rmdir）。本任务完成后检查时锁目录已被另一并行任务重新持有（mtime 距检查 92 秒，早于本任务 117s+44s 的运行时长），未干预。

## 遗留风险

- 未在运行中的应用里做视觉核验（约束：不重启应用）；本波只验证真实构建与测试退出码。
- `cancelAssistant` 返回 Void：失败判定以刷新后的记录 state 为依据。若点击瞬间记录已在别处完成，底层 UPDATE 空更新不报错、视图也不会误报失败；只有记录仍停留在 queued/running 时才显示失败与重试。
- 保存报告的重试会重新弹出 NSSavePanel，需要重新选择目标路径；失败时文件未写入（atomically 写入）。
- 范围取舍：只覆盖简报点名的取消代办、保存报告、反馈（记录）保存。任务详情页其余次级写入（子任务增删勾选、预计时长、重复设置、分析/代办触发等）仍只写页底 error，本次不动，避免扩散到波 91/94 已定稿的交互面与键盘路径。
- 纯视图层改动，未新增测试；基线 643 项保持。
