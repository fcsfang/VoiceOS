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