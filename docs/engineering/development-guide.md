# VoiceOS 开发预览与复现

日期：2026-10-10。此版本包含文件输入、文本理解与用户文字行动闭环；尚不是完整 MVP。当前状态与证据见 [M1 实施记录](m1-file-input.md)、[逐字稿增量记录](m2-transcript-provenance.md)、[认知基础记录](m2-cognitive-foundation.md)及 [权限/端口记录](m2-source-policy-model-port.md)与[真实驱动记录](m2-responses-driver.md)与[控制中心理解记录](m2-control-center-understanding.md)与[候选审阅记录](m2-claim-review.md)及[提醒事项反馈](m3-reminders-feedback.md)。

## 打开应用

在项目根目录执行 `python3 scripts/app/build.py`，生成 `dist/VoiceOS.app`，可在访达中双击打开。构建使用本机 Xcode SDK，不改变全局开发环境；开发预览采用本地临时签名，bundle ID 为 `local.voiceos.app`。测试机器最低部署目标暂设 macOS 26，不代表已验证所有 macOS 26 设备或确定了正式支持列表。

应用点击“导入文件”，选择音频或视频。完整复制与音轨解码验证通过后显示“原件已保存”，再由已安装的 Apple 中文模型本地转写。默认打开不请求麦克风或提醒事项权限、不下载模型、不上传文本或音频。开发启动脚本可加载既有本地模型配置，读取配置不触发发送。原件只有点击“打开保存的原件”才交给默认播放器，不自动播放。

有效扩展名候选：m4a、mp3、wav、aiff/aif、caf、aac、flac、mp4、mov、m4v；实际支持还取决于系统能否完整解码音轨。当前真实样本验证仅覆盖 M4A 与含音轨 MP4。没有可处理音轨的视频会返回原因，不能将扩展名清单当成所有编码的支持承诺。模型不可用时保留原件和失败原因；已安装模型查询通过后才启动转写，无云端回退。

导入内容一律是外部/未知说话人来源，不创建个人观点或任务。逐字稿标为尚未人工校对，空结果也保留为实际空输出，不推断没有人声。主列表搜索仍为文件名/逐字稿文字匹配；独立“查找历史文字”在含模型构建中提供本机语义候选，见[原生召回记录](m4-native-semantic-recall.md)。

逐字稿可查看来源时间片段、更正文字和查看版本历史。更正保留原稿，当前更正版的时间定位标为未确认；此处只表示识别文字更正。片段播放由用户点击发起，实际对齐质量待人工核对。

## 数据与生命周期

默认目录为 `~/Library/Application Support/VoiceOS`，包括 `voiceos.sqlite`、独立 `assets/`、未完成副本 `staging/` 和进程锁。目录/新媒体/数据库限制为本人访问；这不是加密。SQLite WAL、FULL 同步、文件/目录同步是进程退出恢复的实现基础，不等于断电或磁盘损坏保障。

关闭控制中心的产品行为是让应用宿主继续运行；真正退出后，下一次打开会检查保存窗口、原件摘要/解码和未结束转写任务。转写 worker 由应用模型持有，避免绑定 SwiftUI 窗口任务的取消。相同资料库不允许第二个进程同时写入。故障/不完整副本保留诊断状态，不自动删除用户原文件或把不完整录制当已完成输入。

可用 `VOICEOS_DATA_DIR` 指定隔离数据目录，例如：

```sh
VOICEOS_DATA_DIR="$PWD/runtime/my-local-test" dist/VoiceOS.app/Contents/MacOS/VoiceOS
```

不要同时打开使用同一资料库的应用与检查工具。测试默认放在 Git 忽略的 runtime 中；演示数据没有移入默认个人资料库。

## 导出与空库恢复

工具栏提供默认结构化导出和可选原件打包。当前包格式 `VoiceOS-local-package` v14，存储 schema 15，含 manifest 与 sources/assets/jobs/transcripts/transcript_versions/transcript_revisions/contexts/context_inputs/model_attempts/claims/source_policy_revisions/claim_reviews/actions/action_revisions/reminder_links/reminder_observations/action_feedback/relevance_attempts/relevance_inputs/cognitive_feedback_ignores/cognitive_feedback_preferences/conversations/conversation_user_turns 二十三类 UTF-8 JSONL；仍可恢复旧 v1/schema 2 、v2/schema 3 、v3/schema 4 、v4/schema 5 、v5/schema 6 、v6/schema 7 、v7/schema 8 、v8/schema 9 、v9/schema 10 、v10/schema 11 、v11/schema 12 、v12/schema 13 与 v13/schema 14 包。它仅覆盖当前已实现的实体，未来新增实体时必须升级格式。包含外部身份映射和回读历史，不包含凭据或系统权限；恢复不携带本机持续连接授权。

导出记录文件数量、长度、SHA-256 与未打包原件 ID；原件包先核验原件，再逐字节复制核验。包先在临时目录生成，完成后改名到新目标；不覆盖现有目录。当前同步 actor 快照依靠单写者和原件不可变契约，尚未实现删除，因此不存在资产删除竞态；加入删除/异步导出前必须实现 pin 与取消屏障，不能照搬当前边界。

控制中心提供“从迁移包恢复…”及“打开已有资料库…”，也保留开发工具入口。恢复后可在独立窗口继续使用，主库保留，默认库位置不自动替换。只恢复到不存在的新目录，先检查格式、文件摘要、身份唯一性、字段与外键/版本关联、路径逃逸/符号链接、完整媒体解码及数据库完整性；预检失败不建立目标资料库。未包含原件的来源为 reference_only，文本可读、原件不伪装可播放。所有未完成 jobs 暂停，明确重试才运行；恢复和启动不会自动外写；已有提醒事项关联须重新明确选清单后回读。

```sh
.build/debug/voiceos-check export "$PWD/runtime/my-local-test" "$PWD/runtime/package-text"
.build/debug/voiceos-check export "$PWD/runtime/my-local-test" "$PWD/runtime/package-with-media" media
.build/debug/voiceos-check restore "$PWD/runtime/restored" "$PWD/runtime/package-with-media"
VOICEOS_DATA_DIR="$PWD/runtime/restored" dist/VoiceOS.app/Contents/MacOS/VoiceOS
```

已导出副本需要用户自行保管，不提供加密或自动保留管理。现有库合并、数据删除和完整产品 schema 的迁移未实现，不用于承诺长期个人数据管理已完备。

## 工程入口与验证

- `Sources/VoiceOSCore`：SQLite、命令身份、可靠媒体副本、恢复、持久转写 jobs、版本历史、临时本地上下文与迁移包。
- `Sources/VoiceOSPlatform`：完整音轨解码与已安装 Apple Speech；通过协议与 Core 隔离。
- `Sources/VoiceOSApp`：SwiftUI 控制中心与应用持有的后台 worker。
- `Sources/VoiceOSCheck`：与应用使用同一核心的进程集成检查入口，不是另一套保存实现。
- `Tests/VoiceOSCoreTests`：命令重复/身份、原件独立、损坏隔离、空输出、重试、单写者、Unicode 和迁移拒绝边界。

```sh
env -u SDKROOT xcrun --sdk macosx swift test
python3 scripts/app/build.py
python3 scripts/app/validate.py --audio /absolute/authorized-short.m4a --video /absolute/authorized-video.mp4 --output "$PWD/runtime/new-test-run"
```

集成脚本要求新的输出目录；原件只读，对受管测试副本注入破坏。`VOICEOS_TEST_CRASH_AT` 仅由检查程序读取；正式应用不读取该变量。案例日志可能含私有路径，仅脱敏汇总适合进入仓库。API key 保持忽略，不用密钥填充示例命令。

## 认知切片检查

当前支持真实文本理解与行动提取；以下夹具用于本地故障验证。`voiceos-check cognition-fixture` 与 `correction-fixture` 专用于隔离开发库，生成明确测试注记，不是用户功能。原生应用不调用它们。

```sh
python3 scripts/app/validate_cognition.py --package "$PWD/runtime/authorized-package-with-transcript" --output "$PWD/runtime/new-cognition-run"
```

脚本要求新输出目录，要求输入包有且仅有一份非空逐字稿且没有认知回执，恢复后在独立测试库实际终止十三个进程，核对提交及冻结原子性，不发送请求或操作提醒事项。查看候选时 current 表示依据未失效；未验证仍是未验证。历史被保留不等于认可。

来源详情可允许文本用于云端或限制为仅本地。授权按钮只更新权限，不触发网络发送。配置文本模型后，点击“理解这份文字”才发送选中资料的文字；原始音视频权限独立，保持本机处理。

使用现有模型配置启动开发预览：`python3 scripts/app/run.py`。也可直接打开应用并通过“配置文本模型…”选择项目 `.env`。这不会自动发送内容。配置暂为开发文件，正式钥匙串待实现；同一文字/权限/模型身份的已完成、失败或未知调用不会重复发送，详见[控制中心理解记录](m2-control-center-understanding.md)与[候选审阅记录](m2-claim-review.md)及[提醒事项反馈](m3-reminders-feedback.md)。

候选可明确认可、拒绝或更正，认可保持证据状态独立，更正后重新待核对；审阅历史与原始模型结果随包保留。冻结候选只可回溯，详见[候选审阅记录](m2-claim-review.md)。

本地行动意图可在候选中显式记录，默认进入机会池，明确任务可完成；状态历史保留，认知/来源/权限版本变化会暂停依赖行动。行动语义详见[行动与机会池记录](m2-actions-opportunity.md)。明确任务的提醒事项创建与完成回读现已接入，详见[提醒事项反馈](m3-reminders-feedback.md)。

提醒事项入口：工具栏“连接提醒事项…”授予系统权限后选择明确清单，再从明确任务发送。选择后保存持续授权；原库重启自动恢复，导出恢复须重新连接。已有尝试只回读，不重建。仅本地来源依赖不可发送。当前本地完成/重新跟进不向外更新，外部状态以详情回读记录为准；应用内有变化通知、启动/激活/唤醒核对及五分钟兜底回读，工具栏可停止。详见[持续连接与自动回读](m3-continuous-reminders.md)。开发包包含提醒事项使用说明，正式沙盒与签名尚待验证。

## 用户文字与普通任务自主执行

“记录我的表达”保存自己的原文（最多 4000 Unicode scalar），默认仅本地；不伪造语音转写。音视频导入保持外部/未知身份。授权来源文字并理解后，可提取用户暂定表达与原话行动；已保存清单连接自动发送具有资格的普通任务，机会/AI 建议留本地，期限或复杂任务暂不自动发送。

连接保存会激活此前提取的普通任务；“暂停提醒事项连接”停止后台创建和回读。当前只同步标题，不设置日期/闹钟。更正同一已外发来源的新结果先留本地，避免自动重复承诺。操作和限制见[表达行动闭环](m3-expression-actions.md)。

`python3 scripts/app/validate_expression.py --output "$PWD/runtime/new-expression-check"` 在新隔离目录终止八个进程，检验文字与原子行动结果，无模型/外部写。云端合成 fixture 要求新目录并使用本地配置，禁止对已有目录重复请求；质量样本结果不代表全面验收。

行动结果与反思可选记录，默认仅本地保存；详情能回到关联行动历史，保存不更改任务或证据状态。实现与恢复边界见[行动反馈](m3-action-feedback.md)。

恢复与多库窗口的实际验证见[控制中心恢复](m3-package-restore-ui.md)。

控制中心“查找历史文字”按连续文字查询本机当前原文并返回出处；语义选项仅在独立工程夹具内验证，不对用户声称已支持跨措辞关联。见[检索记录](m4-local-retrieval.md)。

## 相关性开发验证

独立相关性调用、输入历史和恢复屏障已实现，实际文本驱动可复用同一本地配置。详情见[相关性驱动](m4-relevance-driver.md)。控制中心“查找历史文字”现支持从关键词结果选定原文、准备并执行文本模型相关性判断，再查看出处；见[界面实施记录](m4-relevance-control-center.md)。含模型构建现提供本机跨措辞候选召回；`build.py --semantic-model <已验证模型目录>` 显式加入资源。普通构建不包含模型，详见[原生召回](m4-native-semantic-recall.md)。

工具栏“静默回顾”展示已接纳且仍有效的相关原文；忽略、减少为每次一条及暂停持久保存，关闭不表示认可。见[当前实施与边界](m4-quiet-feedback.md)。

点击“开始我的口述”才请求麦克风并录制本人表达；“停止并保存”通过原件核对后进入本地转写。中断片段保留待核对，录制中不导出；带原件导出遇未封存片段明确拒绝，结构化迁移不包含暂存音频。真实设备/权限/睡眠仍待验证，见[口述增量](m1-personal-dictation.md)。

设备限时测试可使用`python3 scripts/app/run.py --data-dir <独立测试目录> --capture-limit-seconds 10`；它不会自动启动麦克风，点击开始后由设备到时停止。用户已授权后续本地开发采集，无需逐次确认；音频上传仍单独选择。首次实测与时长偏差见[设备测试记录](m1-microphone-device-test.md)。

讨论数据基础与持久回复已实现，当前184项测试、包v15/schema16；控制中心讨论入口尚未接入。合成强退验证见[持久讨论回复](m4-durable-discussion-replies.md)。
