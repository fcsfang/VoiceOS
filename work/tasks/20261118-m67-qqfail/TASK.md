# 波 67 任务书（2026-11-18）：QQ 采集的静默失败与误诊修复

## 背景（只读发现 2026-11-18）

真实链路核对结论：密钥缺失、包缺失、超时、分析失败已有明确文案与不推进游标；缺口集中在「语义上失败但没抛错」与「诊断链路与实际读取不一致」两类：

1. **空结果当成功**：退群/解散、账号被自动切走时查询返回 0 行 → ok:true、游标推进、报告 complete，用户永久收不到消息且无提示（qq_read_range.py:150-184；MessageMonitorRunner.swift:153-158）。
2. **FDA 撤销误报为目录缺失**：discover_active_nt_db 的 glob 把 EPERM 吞成空列表 → FileNotFoundError → 文案让用户去登录 QQ；诊断同样误诊，m62 的 FDA 指引不可达（live.py:29-54；qq_read_range.py:72-74；QQMonitorHelper.swift:285-302）。
3. **密钥轮换误诊**：QQ 升级后密钥失效，select_mirror_key 吞错 →「expected exactly one valid key candidate; found 0」→ 归为 read_failed「可稍后重试」，永远不成功；「检查 QQ 依赖」全绿（live.py:162-184；QQMonitorHelper.swift:255-258）。
4. **大窗口补读无恢复路径**：起始时间控件只在改早时回拨游标，改晚只改显示；超时/超 32MB 后每天重试同一区间失败，用户无法从 UI 恢复（MonitorCenter.swift:322-326；MessageMonitorRunner.swift:113-116；WorkspaceMonitorView.swift:404-407）。
5. 次要（本波只做类型映射）：合并转发（ChatLab 26）与语音（2）未映射 →「[消息类型 16]」；引用上下文 meta 不参与分析（qq_read_range.py:9-16；MessageMonitorRunner.swift:254-257）——本波只补 26→forward、2→other 与可读占位，引用上下文入分析留待后续。

## 完成判据

1. 脚本在读取成功但群不在当前群列表时返回新错误码 `group_missing`（中文「群不存在或已退出，请重新选择目标群」）；仅有 group_info.db 可读时做该校验，无群库时跳过不误报。runner 走失败路径：来源红字、报告 incomplete、游标不推进。
2. 脚本对目录枚举失败做二次复核：捕获 PermissionError → `permission_denied`（沿用 m62 文案）；诊断的目录探测同样复核，`needsFullDiskAccess` 能触发。
3. 脚本把「valid key candidate」类失败归为 `key_invalid`，中文写明「QQ 可能已升级导致密钥失效，请重新导出密钥」；「检查 QQ 依赖」增加一次真实打开镜像库的探测（select_mirror_key），能发现密钥轮换与缺 SQLCipher。
4. 起始时间控件改晚时同步推进游标（advanceMonitorCursor 到所选时间，去重吸收重叠）；超时/预算错误的文案指向「把起始时间调近后重试」。界面显示与实际读取一致。
5. 脚本 CHATLAB_KINDS 补 26→forward、2→other，占位文案可读（如 [合并转发]、[语音]）；既有 kind 判定与测试 fixture 相应更新。
6. 测试（≤4 个，隔离/纯解析）：group_missing 分类与不推进游标（runner 假采集器抛错）；PermissionError 复核归为权限；valid-key 文案归为密钥失效；起始时间改晚推进游标。中文断言。
7. `swift build -j 2` / `swift test -j 2` 真实退出码 0；当前 main 597 项测试（波 66 合并后以新基线为准，先 merge main）。

## 文件所有权

- `scripts/qqmonitor/qq_read_range.py`
- `Sources/VoiceOSPlatform/QQMonitorHelper.swift`
- `Sources/VoiceOSApp/MonitorCenter.swift`
- `Sources/VoiceOSCore/MessageMonitorRunner.swift`（仅必要的错误路径/不推进游标语义，若已满足则不改）
- 对应测试
- 不碰 WorkspaceMonitorView（波 66 在改）、主题组织、全景、知识核查、分段理解、提醒同步；不加迁移。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`；先 merge main。
- 不写实时库；不启动真实进程读真实 QQ（用 fixture/假端口）。
- 分支 `work/m67-qqfail`，提交回报；不 push、不合并。

## 结果

- 分支：`work/m67-qqfail`（从 `d2bc5f4` 创建，已合并 wave 66 `53e8c46`）
- 提交：`7b9ef39` fix(消息监测): QQ 采集静默失败与误诊修复；`8aea5d0` 合并 origin/main；本结果随其后一次 docs 提交
- 验证：`swift build -j 2` exit 0；`swift test -j 2` exit 0；604 项测试 0 失败（含本波 4 项新测试）
- 文件清单：
  - `scripts/qqmonitor/qq_read_range.py`
  - `Sources/VoiceOSPlatform/QQMonitorHelper.swift`
  - `Sources/VoiceOSApp/MonitorCenter.swift`
  - `Sources/VoiceOSCore/MessageMonitor.swift`
  - `Tests/VoiceOSCoreTests/QQMonitorChecks.swift`
  - `Tests/VoiceOSCoreTests/MessageMonitorRunnerChecks.swift`
  - `Tests/VoiceOSCoreTests/MessageMonitorStorageChecks.swift`
- 判据落点：
  1. 读数成功后 `ensure_group_present` 以 `reader.group_names()` 校验群号；群库不可读或返回空时跳过；新错误码 `group_missing`（中文「群不存在或已退出，请重新选择目标群」）。runner 沿用异常路径 `failMonitorCursor`：报告 incomplete、来源带错误、`last_success_at` 不推进。测试 `testGroupMissingFailsReportAndDoesNotAdvanceCursor`。
  2. 脚本 `qq_root_listing_denied()` 对 FileNotFoundError 二次复核 `os.listdir(DEFAULT_QQ_ROOT)`，PermissionError 归为 `permission_denied`；诊断 `directoryProbeScript` 内做同样复核，`directoryProbeItem` 触发 `needsFullDiskAccess`。测试 `testPermissionRecheckClassifiesAsFullDiskAccessIssue`。
  3. `read_failure` 将 "valid key candidate" 归为 `key_invalid`，中文「QQ 可能已升级导致密钥失效，请重新导出密钥」；「检查 QQ 依赖」新增 `mirrorProbeScript`（`QQRecentReader.status()` 真实开库）与 `mirrorProbeItem`，可分类密钥轮换、缺 SQLCipher、权限与数据目录缺失。测试 `testValidKeyCandidateFailureClassifiesAsKeyInvalid`。
  4. `setMonitorQQStart` 统一调用 `alignMonitorCursorToStart`：改晚推进游标、改早回拨，去重吸收重叠；消息读取超时文案与 32 MB 预算文案指向「把起始时间调近后重试」。测试 `testLaterStartAdvancesMonitorCursor`。
  5. `CHATLAB_KINDS` 补 26→forward、2→other；`message_text` 将 `[消息类型 N]`/空内容替换为 `[合并转发]`/`[语音]`；`testFixturePayloadDecodesIntoContract` fixture 增补语音行。
- 遗留风险：
  - 群校验以本地群库为准，QQ 群库可能滞后于真实入群/退群状态，可能短暂误报或漏报 `group_missing`。
  - 诊断开库探测会刷新镜像（复制账号库），超大库耗时较长；60 秒超时归为一般失败。
  - 脚本内 `os.listdir` 复核分支只经 py_compile 与静态逻辑探针验证，未在真实 TCC 拒绝下实机验证（本波约束不启动真实 QQ 读取）。
  - 起始时间推进的 App 调用点（MonitorCenter）不在测试目标内；Core 语义由 `alignMonitorCursorToStart` 测试锁定。
