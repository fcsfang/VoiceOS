# VoiceOS 开发预览与复现

日期：2026-10-10。此版本包含 M1 文件输入切片与 M2 逐字稿来源/更正基础；尚不是完整 MVP。当前状态与证据见 [M1 实施记录](m1-file-input.md)、[逐字稿增量记录](m2-transcript-provenance.md)、[认知基础记录](m2-cognitive-foundation.md)及 [权限/端口记录](m2-source-policy-model-port.md)与[真实驱动记录](m2-responses-driver.md)。

## 打开应用

在项目根目录执行 `python3 scripts/app/build.py`，生成 `dist/VoiceOS.app`，可在访达中双击打开。构建使用本机 Xcode SDK，不改变全局开发环境；开发预览采用本地临时签名，bundle ID 为 `local.voiceos.app`。测试机器最低部署目标暂设 macOS 26，不代表已验证所有 macOS 26 设备或确定了正式支持列表。

应用点击“导入文件”，选择音频或视频。完整复制与音轨解码验证通过后显示“原件已保存”，再由已安装的 Apple 中文模型本地转写。首次不请求麦克风或提醒事项权限、不下载模型、不读取 .env、不上传文本或音频。原件只有点击“打开保存的原件”才交给默认播放器，不自动播放。

有效扩展名候选：m4a、mp3、wav、aiff/aif、caf、aac、flac、mp4、mov、m4v；实际支持还取决于系统能否完整解码音轨。当前真实样本验证仅覆盖 M4A 与含音轨 MP4。没有可处理音轨的视频会返回原因，不能将扩展名清单当成所有编码的支持承诺。模型不可用时保留原件和失败原因；已安装模型查询通过后才启动转写，无云端回退。

导入内容一律是外部/未知说话人来源，不创建个人观点或任务。逐字稿标为尚未人工校对，空结果也保留为实际空输出，不推断没有人声。搜索只做文件名/逐字稿文字匹配，没有语义检索。

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

工具栏提供默认结构化导出和可选原件打包。当前包格式 `VoiceOS-local-package` v4，存储 schema 5，含 manifest 与 sources/assets/jobs/transcripts/transcript_versions/transcript_revisions/contexts/context_inputs/model_attempts/claims/source_policy_revisions 十一类 UTF-8 JSONL；仍可恢复旧 v1/schema 2 、v2/schema 3 与 v3/schema 4 包。它仅覆盖当前已实现的实体，未来认知/行动加入时必须升级格式。没有凭据或外部连接数据。

导出记录文件数量、长度、SHA-256 与未打包原件 ID；原件包先核验原件，再逐字节复制核验。包先在临时目录生成，完成后改名到新目标；不覆盖现有目录。当前同步 actor 快照依靠单写者和原件不可变契约，尚未实现删除，因此不存在资产删除竞态；加入删除/异步导出前必须实现 pin 与取消屏障，不能照搬当前边界。

恢复入口暂为开发工具，尚未加入控制中心。只恢复到不存在的新目录，先检查格式、文件摘要、身份唯一性、字段与外键/版本关联、路径逃逸/符号链接、完整媒体解码及数据库完整性；预检失败不建立目标资料库。未包含原件的来源为 reference_only，文本可读、原件不伪装可播放。所有未完成 jobs 暂停，明确重试才运行；此版本没有外写适配器。

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

当前只有本地候选存储与失效机制，未接真实模型自动理解。`voiceos-check cognition-fixture` 与 `correction-fixture` 专用于隔离开发库，生成明确测试注记，不是用户功能。原生应用不调用它们。

```sh
python3 scripts/app/validate_cognition.py --package "$PWD/runtime/authorized-package-with-transcript" --output "$PWD/runtime/new-cognition-run"
```

脚本要求新输出目录，要求输入包有非空逐字稿且没有认知回执，恢复后在独立测试库实际终止七个进程，核对提交及冻结原子性，不发送请求或操作提醒事项。查看候选时 current 表示依据未失效；未验证仍是未验证。历史被保留不等于认可。

来源详情可允许文本用于云端或限制为仅本地。Core 已有真实文本驱动，控制中心尚未装配云端执行入口；点击只更新授权与依赖状态，不触发网络发送。原始音视频权限独立，保持本机处理。
