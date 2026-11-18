# 波 62 任务书（2026-11-18）：QQ 采集的完全磁盘访问诊断与引导

## 背景（本机实测 2026-11-18 09:25）

用验证目录的真密钥对应用自带脚本 `scripts/qqmonitor/qq_read_range.py` 做只读冒烟：Bash 与用户终端两个进程都在打开 QQ 容器库时失败：

```
PermissionError: [Errno 1] Operation not permitted:
~/Library/Containers/com.tencent.qq/Data/Library/Application Support/QQ/nt_qq_.../nt_db/nt_msg.db
```

脚本把它归类为 `key_invalid / 密钥或 QQ 数据无法读取`。实测确认：密钥本身有效（昨晚验证通过），真正缺的是 macOS TCC 的「完全磁盘访问权限」。VoiceOS.app 作为启动辅助脚本的父进程，必须在 系统设置 → 隐私与安全性 → 完全磁盘访问权限 中被授权，否则 QQ 采集必然失败。

现有 `QQMonitorHelper.diagnose` 与监测页诊断文案均未覆盖该情况（grep 全盘/磁盘访问/权限 无结果），用户会误以为是密钥错误而无从下手。

另有一个开发期事实：dist 每次重建会重签名 VoiceOS.app，TCC 授权可能在重建后失效，需要重新授权。文案应提示「若刚更新过应用，可能需要重新授权并重启应用」。

## 完成判据

1. 诊断分类：辅助脚本 stderr 的 `error.code` 增加/区分权限类（如 `permission_denied`），当 en 文本含 `Operation not permitted` 或 `PermissionError` 时归类为权限问题，中文提示「需要完全磁盘访问权限」，绝不再显示「密钥无效」误导。
2. 监测页诊断区：权限类问题时显示可操作步骤（系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 勾选 VoiceOS → 完全退出后重新打开 VoiceOS），并提供「打开系统设置」按钮（`NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)`，失败时退回打开系统设置应用）。
3. 「检查 QQ 依赖」在权限失败时同样给出上述指引；「列出群」失败时同样。
4. 权限正常时既有诊断与群列表行为不变。
5. 测试（≤2 个用例）：stderr 权限错误 JSON 归类为权限问题并带中文指引；密钥错误仍归类为密钥问题。纯解析/分类测试，不启动真实进程。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0；当前 main 590 项测试。

## 文件所有权

- `scripts/qqmonitor/qq_read_range.py`（错误码细分）
- `Sources/VoiceOSPlatform/QQMonitorHelper.swift`（诊断分类）
- `Sources/VoiceOSApp/WorkspaceMonitorView.swift` 与 `MonitorCenter.swift`（指引与按钮；只在监测相关区域加）
- 对应测试
- 不碰提醒同步、官网抓取、主题组织、全景、知识核查、分段理解。不加数据库迁移。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`。
- 绝不读写 ~/Library/Application Support/VoiceOS；测试隔离临时库。不要尝试修改 TCC 数据库或自动授予权限。
- 分支 `work/m62-qqperm`，提交回报；不 push、不合并、不重启应用。

## 结果

- 分支：`work/m62-qqperm`（从 main f675132 创建）
- 提交：本任务书所在提交
- 验证：`swift build -j 2` exit 0；`swift test -j 2` exit 0，592 项测试 0 失败（main 590 项 + 本次 2 项）
- 改动文件：
  - `scripts/qqmonitor/qq_read_range.py`：`PermissionError` 或 en 含 `Operation not permitted` 时改为 `permission_denied`，zh 明确「需要完全磁盘访问权限」及授权步骤与重新授权提示；其余错误码不变。
  - `Sources/VoiceOSPlatform/QQMonitorHelper.swift`：新增 `QQMonitorPermissionGuidance`（统一中文指引与 stderr 签名匹配 `Operation not permitted` / `PermissionError` / `permission_denied`）；`contractError` 把权限类 stderr（含旧脚本误报 `key_invalid` 的情况）统一归类为权限问题；环境探测与「检查 QQ 依赖」的数据目录项同样识别权限失败；`QQMonitorDiagnosisItem` 增加 `needsFullDiskAccess` 标记。
  - `Sources/VoiceOSApp/WorkspaceMonitorView.swift`：诊断区在权限失败时显示授权步骤，提供「打开系统设置」按钮（`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`，失败退回打开系统设置应用）；「检查 QQ 依赖」「列出群」失败共用该指引。
  - `Tests/VoiceOSCoreTests/QQMonitorChecks.swift`：2 个纯解析用例（权限 JSON 及旧脚本误报归为权限问题并带中文指引；密钥错误仍为密钥问题）。
- 判定规则一句话：stderr 中 `error.code == permission_denied`，或 en/zh/原始文本含 `Operation not permitted`、`PermissionError`、`permission_denied` 即判为完全磁盘访问权限问题，优先于按 code 的密钥提示。
- 遗留风险：密钥文件本身若位于 TCC 保护目录，其不可读仍显示为密钥问题（该路径未接入权限签名）；「检查 QQ 依赖」的数据目录探测若只做目录枚举而不打开 `nt_msg.db`，可能不触发 TCC，权限问题仍会在「列出群」或读取时暴露；未在真实 TCC 拒绝下端到端复跑（任务约束不修改 TCC、不重启应用），脚本分类由静态编译与解析测试覆盖。
