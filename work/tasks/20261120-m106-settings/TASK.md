# 波 106：设置页遗留功能缺口

## 背景

设置页审计的五项在 9da2244 复核后仍然存在，均有精确证据与最小修法（见下）。与波 105 的文件所有权冲突，故排在 105 合并之后施工。

## 项目与修法

### S6 QQ 设置打开即校验
- 证据：`WorkspaceMonitorView.swift:56-66` onAppear 只回填路径，不探测；`pythonCheck/keyCheck` 不渲染，直到用户点选择或手动检查。
- 修法：设置分段出现时（onAppear / onChange(of: showsSettings)）对非空 qqKeyPath 调 `QQMonitorHelper.keyIsReadable`、异步跑一次 checkPython 填 qqPythonProbe；`MonitorCenter.swift:324-331` 的 `try?` 起始时间改显式错误，来源行显示「配置无效」。

### S7 设置 JSON 解码失败可见
- 证据：`MonitorCenter.swift:20-26/43-49` 两个 Store 的 load 用 `try?`，失败静默返回默认值；`VoiceOSApp.swift:258` 启动装载。
- 修法：load 返回诊断（或置 `settingsDecodeFailed` 标志），监测设置页显示「设置无法读取，已使用默认值，请重新保存」；保存 encode 失败不再吞掉。顺带 `MessageMonitor.swift:525` source_status_json 解码失败不再退化为空数组。

### S9 存储统计读取失败显示「无法读取」
- 证据：`DatabaseBackup.swift:56-79` 全部 `try?` 归 0；`LibraryStorageUsage` 非可选字段；`WorkspaceView.swift:1910-1918` storageLine 只有「统计中/具体字节」。
- 修法：directoryBytes 返回 `Int64?`（不存在=0，枚举失败=nil）；usage 增加失败标记（或可选字段）；storageLine 对失败显示「无法读取」；备份摘要同样区分不可读与未生成。

### S10 隐私与云端摘要卡
- 证据：设置页无任何隐私块；相关文案散落五处。
- 修法：模型与服务之后加「隐私与云端」卡：只在本机（录音/原件/数据库/模型密钥/QQ 密钥）与会发送（转写与材料文本、监测原文仅授权、英文反馈所选文字、任务发起文字），细节用 DisclosureGroup。

### S11 监测设置深链
- 证据：设置页 `WorkspaceView.swift:1739` 只 `go(.monitor)`；`showsSettings` 是 WorkspaceMonitorView 私有 @State。
- 修法：ControlCenter 加一次性 `monitorSettingsRequested` 标记；设置行先置位再跳转，WorkspaceMonitorView 消费后切到设置分段。

## 约束

行为修复类；测试补充 S7/S9 的纯逻辑用例；构建锁与真实退出码；不写实时库、不重启；worktree 分支合并。

## 施工记录

### S6 QQ 设置打开即校验
- `Sources/VoiceOSApp/WorkspaceMonitorView.swift:61` 装载 QQ 设置时同时记录解码诊断；`:69-70`、`:80-84` 设置分段出现（onAppear / onChange(of: showsSettings)）时触发探测；`:983` 对非空密钥路径调用 `QQMonitorHelper.keyIsReadable` 写入 `qqKeyReadable`，并在无结果时异步跑一次 `checkPython` 填 `qqPythonProbe`（已有结果不重复拉进程）。
- `Sources/VoiceOSApp/MonitorCenter.swift:133/364` 新增 `MonitorSourceStart` 三态并以显式 do/catch 解析配置；`WorkspaceMonitorView.swift:739` 来源行解析失败显示「配置无效」，未设置仍显示「尚未设置起始时间」。

### S7 设置解码失败可见
- `Sources/VoiceOSApp/MonitorCenter.swift:18-45`、`:58-77` 两个 Store 增加 `loadResult()`（含 decodeFailed）与保存 Bool 返回；`VoiceOSApp.swift:259-263` 新增 `monitorSettingsDecodeFailed`、`monitorSettingsSaveFailed`、`monitorQQSettingsDecodeFailed` 诊断标志，启动装载走 `MonitorSettingsBootstrap`。
- `WorkspaceMonitorView.swift:753` 监测设置页顶部显示一次性 `WorkspaceNoticeText`「设置无法读取，已使用默认值，请重新保存」，无按钮；成功保存后标志清零（`VoiceOSApp.swift:281-289`）。
- `Sources/VoiceOSCore/MessageMonitor.swift:95/529-547` 报告新增 `sourceStatusUnreadable`，`source_status_json` 解码失败不再退化为空数组；`WorkspaceMonitorView.swift:608` 报告来源行显示「状态无法读取」。

### S9 存储统计失败显示「无法读取」
- `Sources/VoiceOSCore/DatabaseBackup.swift:5-21` 分类字节改 `Int64?`、`totalBytes` 在任一分类不可读时返回 nil；`:100-120` `directoryBytes` 目录不存在=0、枚举失败=nil（嵌套目录不可读向上传播 nil）；`:37/58-72` 新增 `BackupAvailability` 并让 `summary` 复用它。
- `Sources/VoiceOSApp/WorkspaceView.swift:1863-1870/1941-1961` `storageLine` 三态（统计中/无法读取/字节）；`:1905` 删除确认文案区分无法读取；`VoiceOSApp.swift:1424-1436` 备份摘要区分不可读（「备份目录无法读取」）与未生成。
- 测试：`Tests/VoiceOSCoreTests/StorageUsageChecks.swift:106` 临时目录 chmod 000 后断言 `assetsBytes`/`totalBytes` 为 nil（环境无法模拟时 XCTSkip）、`:120` 备份可用性区分 none 与 unreadable。

### S10 隐私与云端卡
- `Sources/VoiceOSApp/WorkspaceView.swift:1739-1760` 模型与服务之后新增 `WorkspaceCard`「隐私与云端」，两行摘要照任务书原文，`DisclosureGroup` 展开六条细则，复用既有各页文案口径，未新增承诺。

### S11 监测设置深链
- `Sources/VoiceOSApp/VoiceOSApp.swift:263` 新增一次性 `monitorSettingsRequested`；`WorkspaceView.swift:1764` 设置行先置位再 `go(.monitor)`；`WorkspaceMonitorView.swift:69/84/996` onAppear 与 onChange 消费，清零后切到设置分段。

### 构建与测试（真实退出码）
- 命令：任务书给定的构建锁脚本（`/tmp/voiceos-swift-build.lock`，`swift build -j 2` 后 `swift test -j 2`）。
- `build_exit=0`，`test_exit=0`。
- `Executed 668 tests, with 0 failures (0 unexpected) in 45.191 seconds`；日志中无跳过用例（唯一 "skipped" 命中是既有测试文案）。
- 代码与测试提交：`b037751`。

### 未做 / 取舍风险
- S7 的 Store 诊断位于 VoiceOSApp target，测试目标只依赖 VoiceOSCore/VoiceOSPlatform，未为其补单测；可测的报告解码路径已由 Core 用例覆盖。
- S9 权限失败路径依赖本机文件权限，root 环境下自动 XCTSkip；本次为普通用户运行，未跳过。嵌套子目录读失败会把整个分类记为「无法读取」，属于保守取舍。
- 备份不可读时 `backupCount` 仍为 0，界面隐藏「N 份」细节，以「无法读取」为准。
- S6 探测为惰性：密钥路径每次分段出现都读一次（同步、廉价）；Python 探针在拿到结果前不重复启动进程，手动改路径后仍以「检查 QQ 依赖」按钮刷新。
- 深链标记是进程内一次性状态，不持久化，重启后不重放。
- 未写实时库、未重启应用、未 push、未合并。