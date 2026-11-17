# 波 42：口述停即解锁、整理后台化与通知；全景到主题的桥

来源：发现者 G 提案 1+4（录音锁死与完成通知）与 F 提案 4（全景区域无主题入口）。两单元文件不相交。

## 完成判据

1. 停止口述后录音入口立即解放：停止只做封存与转写入队，AI 校正与观点整理改为后台任务；同一时刻再按 ⌥⌘D / 菜单 / 窗口按钮可以开始下一段录音，忙态文案说明「上一段正在后台整理」而不是「请等待」。
2. 后台整理与新录音互不踩踏：整理串行执行、失败可见；上一段整理完成时的 UI 刷新不得覆盖新录音的录音态；录音冲突出现在任何时序下都安全（继续录音优先）。
3. 口述整理完成或失败发本地通知（沿用既有 LocalNotice 与授权闸门）：成功带材料名与「打开材料」，失败带原因；窗口内状态条同步。
4. 全景区域检查器加「在主题中查看」：用区域内证据的 sourceIDs 与已链接主题求交，取重合最多者跳转主题页并选中；无重合主题时给出原因（未挂主题/不足）。
5. swift build 与 swift test 真实退出码 0（481 项基础上新增，如核心有变化）。

## 共享契约

- DA：忙碌判定拆分——录音可用性只取决于录音设备与封存；后台整理有独立状态位（如 organizingSourceID），不复用 fullRecordingBusy 锁录音入口；已存在的「停止并整理」流程保留为默认体验（后台化而非删除整理）。
- DA 不改录音采集层；不动 Qwen 转录本身。
- PB：主题匹配只读现有 links（主题—材料关联），不新建数据通道；导航走既有 go(.themes)+selectTopic 通道；无匹配时状态行说明。
- 两单元都不动对方文件。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| DA 口述后台化 | `work/m42-da` / `.worktrees/m42-da` | `Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSCore/WorkspaceProcessingStatus.swift`（如涉忙态文案） | 判据 1、2、3 |
| PB 全景主题桥 | `work/m42-pb` / `.worktrees/m42-pb` | `Sources/VoiceOSApp/ThoughtPanoramaView.swift`、`Sources/VoiceOSApp/WorkspaceView.swift` | 判据 4 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- DA：G 实测「31 秒口述 3 分 43 秒才落转写」；锁定点 dictationBusyReason/fullRecordingBusy 与 finishDictation→organizeSavedRecording（VoiceOSApp.swift:924-993、1822-1845）。通知点 LocalNotice 既有三类调用（2678、4830、4837）；completeFullOrganization 末尾 1894-1900。后台化时注意 processTranscriptions 与 organizing 的互斥（读码决定用现有 job 队列还是 Task 包装），报告说明。
- PB：ReaderActions 无主题入口（ThoughtPanoramaView.swift:686-692），WorkspaceView.swift:705-714 未传回调；主题选择通道在 WorkspaceTopicReadingView（选中状态）；区域 evidence 的 sourceIDs 在轮廓/区域数据里。
- 协调者纪律：构建与测试后台直跑并记录真实退出码；重启先过 scripts/app/restart_preflight.sh。

## 验证基线

- 实时库：53 份音频、80 个 transcription job 全 completed；31.3 秒口述到转写落库 3 分 43 秒（2026-11-15）；主题 28 个、16 个跨材料、全景主题 44。
- 用户可能随时回来用机器：重启进空闲窗口。

## 结果（完成后填）
