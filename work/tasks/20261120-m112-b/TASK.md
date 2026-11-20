# 波 112-B：设置页加载反馈与节奏收敛

## 背景

设置页的加载反馈不完整。存储扫描只有裸 spinner，分项同时显示「统计中…」，两处反馈并存且含义不清。导出只有 spinner。主题整理的提示只有文字。局部间距自成几档，7、15、10 与页面其余节奏不一致。本单元只改 `Sources/VoiceOSApp/WorkspaceView.swift` 的设置页区段与主题整理提示。行号为基线 1860671 修改后的位置。

## 逐条修法

### 1 存储扫描反馈合并

- 位置：`:1875` 扫描行，`:1951` `storageReadoutText`。
- 修法：扫描行改为 `ProgressView("正在统计存储…").controlSize(.small)`，由这一行统一承担扫描文案。`storageReadoutText(.scanning)` 返回空串，分项不再显示「统计中…」。扫描完成后分项按既有两态显示字节或「无法读取」。
- 一致性：`VoiceOSApp.swift:1319` 的 `refreshStorageUsage` 在同一个任务里先后设置 `storageScanBusy` 与 `storageUsage`。扫描行出现时分项必然处于 `.scanning`，两者不会错位。

### 2 导出反馈

- 位置：`:1835`。
- 修法：改为 `ProgressView("正在导出…").controlSize(.small)`，与同文件已有的带文字 ProgressView 写法一致。

### 3 主题整理提示

- 位置：`:1049-1054`。
- 修法：`HStack(spacing:8)` 内，`model.organizingTopics` 为真时加 `.small` ProgressView，与「AI 正在按内容连接主题…」同排。未整理时只显示原文字，不加 spinner。

### 4 节奏收敛

- `:1751` 「详细说明」段落 VStack 间距 6 改为 8。
- `:1776` 提醒待核对按钮 HStack 间距 10 改为 12。
- `:1815` 键盘快捷键 VStack 间距 6 改为 8。
- `:1865` 存储分项 VStack 间距 7 改为 8。
- `:1891` 「其他工作与维护」VStack 间距 15 改为 16。
- `:1897` 同组 `.padding(.top,15)` 改为 16。
- 麦克风标题与状态文字的 VStack 保留间距 6。它是「标题-说明」紧凑组，收紧是原意。
- 顶层 `WorkspaceMetrics.sectionGap`（24）与既有 HStack 12 未动。

### 5 未变项

- accessibility identifier 未动。
- 文案承诺未改。
- 页面结构未重构。

## 构建与测试

按任务给定的共享锁循环执行，工作目录为该工作树。真实退出码：

- `swift build -j 2`：`build_exit=0`
- `swift test -j 2`：`test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 44.846 (44.904) seconds`

## 未做与风险

- 未重启应用实机验证（任务禁止重启）。spinner 与文案只用构建和测试确认，没有截图。
- 分项在扫描期显示空值，扫描行单独承担文案。若 `libraryRoot` 为空，`refreshStorageUsage` 直接返回，`storageUsage` 保持 nil 且没有扫描行，分项为空白。改动前这一分支常驻「统计中…」。该分支只在无资料库时出现，本单元没有扩大处理。
- 主题整理 spinner 只在 `organizingTopics` 为真时出现。整理结束但主题仍为空时，文案回落到自动归组说明，与原语义一致。