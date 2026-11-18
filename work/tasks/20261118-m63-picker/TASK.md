# 波 63 任务书（2026-11-18）：QQ 绑定表单的文件选择与自检

## 背景（用户反馈 2026-11-18 10:23）

用户已按引导设置完全磁盘访问权限，云端分析授权已打开。但 QQ 绑定要求手填两个长路径（venv 的 python、database.key），用户明确表示「密钥文件 qq 数据目录我都不会设置」。产品的绑定表单只有 TextField，没有文件选择器；用户不应该靠手抄路径。

## 完成判据

1. Python 解释器与密钥文件两个输入框旁各加「浏览…」按钮，弹出系统文件选择面板（NSOpenPanel，经现有 SwiftUI 集成方式；不要引入第三方库）。选择 Python 时限制为可执行文件，选择密钥时不限类型但默认指向用户主目录。
2. 选择后立即做轻量自检：Python 执行 `-c "import qqnt_export_macos"`（子进程，超时 10 秒）并在字段下方显示一行结果（可用 / 缺少 qqnt_export_macos / 无法执行）；密钥文件检查存在、可读、非空（不读取内容、不打印内容）。
3. 账号字段改为占位提示「可选；留空自动选择（多数情况留空即可）」，保留手动输入能力。
4. 「列出群」成功后，若已选群候选，账号字段自动填成该群所在的账号（从辅助脚本返回的账号信息；若脚本不返回账号则不填，不猜）。
5. 设置表单的既有行为（保存、检查依赖、列出群、起始时间）不变；不改变绑定数据格式。
6. 构建真实退出码 0；若加测试，只测自检结果分类（注入假进程输出），不加 UI 快照。当前 main 592 项测试。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceMonitorView.swift`（表单）
- `Sources/VoiceOSApp/MonitorCenter.swift`（自检与账号回填所需最小增量）
- `Sources/VoiceOSPlatform/QQMonitorHelper.swift` 若需要群列表返回账号字段（附加字段，不改既有契约）
- 对应测试（可选）
- 不碰提醒同步、官网抓取、主题组织、全景、知识核查、分段理解。不加数据库迁移。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`。
- 绝不读写 ~/Library/Application Support/VoiceOS；不在测试里启动真实进程读取真实 QQ。
- 分支 `work/m63-picker`，提交回报；不 push、不合并、不重启应用。

## 结果

- 分支：`work/m63-picker`（从 main 0164625 创建）
- 提交：本任务书所在提交
- 验证：`swift build -j 2` exit 0；`swift test -j 2` exit 0，593 项测试 0 失败（main 592 项 + 本次 1 项）。脚本改动在测试后追加，另以仓库同款 `py_compile`、AST 解析与假 reader 探针复验：读取器有 `nt_db` 时列群响应返回账号，无 `nt_db` 时省略账号且既有键不变。
- 改动文件：
  - `Sources/VoiceOSApp/WorkspaceMonitorView.swift`：Python 与密钥两个路径行的「选择…」按钮在主线已存在，本次补上选择器约束与自检。Python 面板用 `NSOpenSavePanelDelegate` 只允许可执行文件与目录；密钥面板不限类型并从用户主目录起步。选择后立即自检，Python 以子进程执行 `-c "import qqnt_export_macos"`（10 秒超时），字段下方显示「可用 / 缺少 qqnt_export_macos / 无法执行」；密钥检查存在、可读、非空并在字段下方显示可用性，不读取或打印内容。账号占位改为「可选；留空自动选择（多数情况留空即可）」。列出群成功后，若已选群候选仍在列表中，账号填为脚本返回的账号；选择候选时同样回填。取消选择不改现有值。
  - `Sources/VoiceOSPlatform/QQMonitorHelper.swift`：新增 `QQMonitorPythonProbe`（三种分类与中文标签）、`checkPython(_:)`（10 秒子进程）与纯函数 `classifyPythonProbe(exitCode:stderr:)`；`keyIsReadable` 改为公开复用。新增 `QQMonitorConversationList` 与 `conversationList(settings:)`，解析响应中可选的 `account`；`conversations(settings:)` 与 `decodeConversations` 保留原契约并委托新实现。
  - `Sources/VoiceOSApp/MonitorCenter.swift`：`loadQQMonitorConversations()` 返回脚本给出的可选账号，群列表与状态文案不变。
  - `scripts/qqmonitor/qq_read_range.py`：列群响应附加可选 `account`（读取器 `nt_db` 的账号目录名）；读取器无该属性时省略字段，其余键与错误契约不变。
  - `Tests/VoiceOSCoreTests/QQPythonProbeChecks.swift`：1 个分类用例，注入退出码与 stderr，覆盖可用、缺少 qqnt_export_macos、无法执行与启动失败。
- 自检交互一句话：选中 Python 后字段下方先显示「正在检查…」，再落到三种结果之一；选中密钥后立刻显示可用或不可用，两种检查都不读取密钥内容。
- 遗留风险：自动回填的账号是 QQ 数据目录名（`nt_qq_…`），即读取器要求的同一标识，不是用户想象中的 QQ 号，界面未另加解释；Python 自检只证明能导入库，不覆盖密钥、QQ 数据目录与完全磁盘访问权限，仍可能需要「检查 QQ 依赖」；本次未在真实 TCC 与真实 QQ 上实机走查选择器与自检（约束为不重启应用、不读真实 QQ），面板约束与自检结果由构建、纯函数测试与脚本探针覆盖；任务书原文要求「浏览…」按钮，主线既有按钮文案保留为「选择…」。
