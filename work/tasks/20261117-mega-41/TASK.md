# 波 41：设置与存储（占用可视、清理、登录自启、备份保留）

来源：只读发现者 H（设置、数据管理与系统集成）。实测数据目录 6.7GB（sqlite 305MB、assets 1.8GiB、Backups 1.9GiB、LocalSpeech 2.7GiB），设置页只显示备份份数，应用内无法查看或清理。录音流水线单元（发现者 G）报告到达后并入本波，见文末追加节。

## 完成判据

1. 设置页新增「存储与清理」段：显示资料库（sqlite+WAL）、原件、备份、本地语音模型、镜像各目录体积（ByteCountFormatter），并提供「在访达中显示资料库」。
2. 本地语音模型可清理：二次确认（说明将停用本地 Qwen 语音、需重新下载），删除后体积显示刷新；模型使用中（转录进行）时禁用。
3. 备份：显示备份总占用；保留份数可选 3/7/14（AppStorage，默认 7，立即生效）；提供「立即清理旧备份」；prune 同步删除对应 -wal/-shm 侧车，并清扫现存孤儿侧车（实测 11 个 shm、7 个 sqlite）。
4. 登录时启动开关：SMAppService.mainApp register/unregister，回显系统状态，失败显示原因。
5. 菜单栏菜单追加「设置…」与「每周回顾…」，复用既有 openSettings/openWeeklyReview。
6. swift build 与 swift test 真实退出码 0（476 基础上新增存储统计测试）。

## 共享契约

- 体积统计放核心（DatabaseBackup.swift 或同级新函数）：一次性扫描给定目录，返回各类体积，可测试（临时目录夹具）；不递归进入符号链接。
- SMAppService 仅在 VoiceOSApp 层使用；偏好键 `voiceos.launchAtLogin` 与 `voiceos.backupRetention`。
- prune 侧车：删除备份文件时同步 `.sqlite-wal`/`.sqlite-shm`；孤儿清扫只处理 Backups 目录内、无对应 .sqlite 的侧车。
- 不改备份创建/恢复逻辑本身。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| SA 设置与存储 | `work/m41-sa` / `.worktrees/m41-sa` | `Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSCore/DatabaseBackup.swift`、`Tests/VoiceOSCoreTests/`（备份相关） | 判据 1-5 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- H 证据：设置全段 WorkspaceView.swift:1567-1648 无容量项；DatabaseBackup.swift:42/54 retain 默认 7、调用点 VoiceOSApp.swift:1116 不传参；prune 只删 .sqlite（DatabaseBackup.swift:306-315）；菜单清单 VoiceOSApp.swift:3651-3688，openSettings:3819、openWeeklyReview:3841 已存在；Onboarding.swift:14 承诺菜单栏常驻。
- 已排除：原件无孤儿（80/80 对应）、库无碎片（freelist 0）、导出/恢复已齐——不要重做。
- SA 负责的语音模型删除只删 LocalSpeech 目录内容并在状态行说明后果；不动 chooseLocalSpeech 配置逻辑。
- 协调者纪律：构建与测试后台直跑并记录真实退出码；重启先过 scripts/app/restart_preflight.sh。

## 验证基线

- 目录体积：sqlite 305MB、assets 1.8GiB、Backups 1.9GiB（7 份 + 11 孤儿 shm）、LocalSpeech 2.7GiB、Mirror 4.8MB。
- 用户在用机器：重启进空闲窗口。

## 结果（完成后填）

## 追加：发现者 G（录音流水线）与单元 GA

G 的核心结论（留给波 42 的大改）：停止录音后 `finishDictation` 立即进入整段整理，`dictationBusyReason` 含 fullRecordingBusy，下一次口述被锁（实测 31 秒口述 3 分 43 秒才出转写）；「停止即封存、整理后台化」是波 42 的头号项。本轮先修中断死路。

### GA 单元（追加进本波）

- 文件（独占）：`Sources/VoiceOSApp/WorkspaceProcessingView.swift`、`Sources/VoiceOSApp/WorkspaceSourceView.swift`，允许新增 `Sources/VoiceOSApp/DictationRecoveryControls.swift`。不改 VoiceOSApp.swift（SA 独占）。
- 判据 7：中断录音（interrupted / 无 job 的 failed）在处理页与材料页有「保存可解码片段」入口，调用既有 `recoverDictation`（VoiceOSApp.swift:988-993，已有实现无调用者），并给「移入回收站」退出路径；处理中禁用与状态提示齐全；恢复成功后材料进入正常整理链路。

## 结果（2026-11-17 傍晚）

- SA：存储与清理段（五类体积 + 合计 + 在访达中显示）、本地语音模型删除（二次确认、转录中禁用、删除后刷新）、备份保留 3/7/14（默认 7，创建备份时生效）、立即清理旧备份、prune 同步删侧车、每次启动与手动清理时清扫孤儿侧车、登录自启（SMAppService，状态回显四态）、菜单栏补「设置…」「每周回顾…」。核心新增 LibraryStorageUsage 与 directoryBytes；5 条测试。
- GA：中断录音恢复——处理页与材料页「保存可解码片段」（调用既有却无人调用的 recoverDictation，成功后进入正常整理链路）与「移入回收站」（先封存再回收，避免核心拒绝 interrupted 状态）；处理中禁用、失败显示原因；控件复用单一 dictationRecoveryPending 谓词。
- 集成期修正两处：LibraryStorageUsage 嵌在 DatabaseBackup 内导致 app 模块不可见，提为顶层类型；directoryBytes 使用 Foundation enumerator 时，对指向目录的符号链接 skipDescendants 会连带跳过后续兄弟目录的子项（已用独立最小实验复现），改手写递归，零对称链接跟随。
- 验证（真实退出码）：swift build 0（Build complete! 67.34s）；swift test 0，481 项 0 失败（476 基础上新增 5）。
- 说明：SMAppService 仅在 .app 包内有效，开发态显示 notFound 属预期；保留份数在下次备份或手动清理时生效（界面已注明）。
