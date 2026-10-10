# VoiceOS 关键技术验证：初步报告

日期：2026-10-10。状态：第三阶段已开始，部分本地探针完成；不是整阶段通过或软件验收。

依据：[PRD v0.1](../product/prd.md)、[决策登记表](../product/decision-register.md)。本轮采用公开官方资料、本机能力查询和合成数据探针，不实现业务功能，不录制麦克风、不读取或修改个人提醒事项、不上传个人内容、不安装依赖或下载语音模型。

## 1. 产品审查结果

- P01：用户希望给予 AI 最大自由和信任。已将普通任务创建、目标拆解、弹性排期、重排、跟进和普通可逆调整落实为持续授权下的自主行为，不逐条审批；重要承诺和不可逆操作保留既定边界。
- P02：允许文本与相关授权历史云端处理，原始音频单独选择。仅本地限制覆盖来源及其衍生文本、摘要和检索上下文。
- P03：同日后续答复确认思源为可选集成，不成为首版依赖。
- P04：同日后续答复确认非紧急认知反馈默认静默，系统通知由用户开启；明确时效任务提醒仍按任务授权执行。
- P05/P06 尚未确认，实际提醒事项操作范围、服务凭据等运行配置尚未建立。

四项答复已同步到 PRD、审查问题与验收对照表；这不是当前机器上所有清单的操作许可或已有生产权限配置。后续产品答复没有改变本报告中的实测结果。

## 2. 环境与证据层级

| 项目 | 当前观测 |
|---|---|
| 系统 | macOS 27.0.1，Build 26A434，arm64 |
| 开发目录 | `/Applications/Xcode.app/Contents/Developer` |
| Swift | Apple Swift 6.3.2 |
| 显式选择的 macOS SDK | 26.5；探针目标 `arm64-apple-macosx26.0` |
| Python SQLite | 3.53.4 |
| 音频处理 | 本轮使用 AVFoundation；PATH 中未发现 ffmpeg，不安装它 |

默认 `xcrun --show-sdk-version` 一度指向不存在的 CommandLineTools SDK；显式 `--sdk macosx` 后可找到 Xcode SDK，并成功编译。没有修改系统开发目录或全局环境；不能仅凭这次错误判断 Xcode 不可用。

证据分三层：官方文档说明接口契约；本地探针说明当前环境中的有限行为；真实应用、权限、同步和真实语料验收仍待执行。命令行进程的授权状态不能代表尚不存在的 VoiceOS 应用身份。

## 3. H02/H03：本地语音与音频处理

### 3.1 能力查询

[能力快照](evidence/platform-capabilities-2026-10-10.json)显示：`SpeechTranscriber.isAvailable = true`，已安装 `zh_CN` 和 `zh_TW`；支持列表包含英语，但当前没有安装英语转写模型。本轮不下载资源。

Apple 官方说明该新转写模块需 macOS 26 起，并提供设备/语言可用性查询；其 SpeechAnalyzer 转写不向 Apple 服务器发送用户语音。这是候选本地转写路径，不意味着整套 VoiceOS 离线运行；GPT 认知仍遵循 D08。[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)、[语音识别权限说明](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)。

### 3.2 合成中文转写

方法：用本机 Tingting 语音将下列固定文本合成为 AIFF，再交给已安装的中文 SpeechAnalyzer 模型。未使用真实用户录音、麦克风或云端 API。

> 我并不认为记忆容量越大越好。只有在检索质量足够高的条件下，更多记忆才可能有帮助。嘉宾说这个方法总是有效，但我还没有验证。我想查一篇论文，不要替我创建明天到期的任务。

音频约 18.58 秒，本次分析约 0.56 秒。去掉标点与空白后，转写字符与参考文本一致；“并不认为”“只有在……条件下”“还没有验证”“不要替我创建明天到期的任务”均保留。标点和句子边界发生变化，因此理解层仍需保留原文片段并处理归属，不能把流畅标点当作语义正确的证明。

原始结果、参考文本、合成语音名、音频 SHA-256 与检查项见[转写证据](evidence/local-transcription-2026-10-10.json)。这里只是一个合成样本，不能推导真人中文准确率、长期吞吐、中英混合表现或英语质量，也没有验证 GPT 的任务提取。

### 3.3 文件处理

合成 1 秒、16 kHz、单声道的 440 Hz 音频，原生写入并读取 WAV，导出 M4A，再读取音轨与时长。WAV 16000 帧、M4A 一个音轨，两者读取时长均为 1 秒；没有使用麦克风。[文件处理证据](evidence/audio-file-2026-10-10.json)。

这验证两种简单音频容器的本机处理路径，不验证真实麦克风录制、MP3、多音轨、视频画面、损坏文件、长录音、原始文件迁移或合盖恢复。AVAudioRecorder 能提供文件录制及停止能力；实际录制可靠性仍需另测。[Apple 录制接口](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)。

### 3.4 候选方案与取舍

| 方案 | 当前证据 | 收益 | 未解决的代价/边界 |
|---|---|---|---|
| Apple SpeechAnalyzer 本地转写 | 当前 Mac 可用；一个中文合成样本跑通 | 音频可留本地，可复用原生音频接口 | macOS/设备/语言资源限制；真实术语、中英混合及噪声待测 |
| OpenAI 文件转写 | 官方接口资料已查；未调用 | 可作为用户单独选择的云端方案 | 音频上传选择、成本、服务可达性和真实质量待测 |
| 其他本地转写后端 | 尚未安装或测量 | 可评估更广的系统兼容性和可移植性 | 分发、运行资源、模型维护与质量均需证据 |

OpenAI 当前文件转写说明列出单次文件上限 25 MB 及支持格式；带说话人标签、时间索引等能力需要按所选模型另核对。长录音必须在适配层保留分段时间偏移，不能把接口上限变成产品不支持长录音的默认结论。[文件转写说明](https://developers.openai.com/api/docs/guides/speech-to-text)。

工程建议：优先把当前 Mac 的本地中文方案纳入真实样本比较，同时保留可替换转写适配接口；尚未作最终选型或最低系统版本承诺。

## 4. H09：Apple 提醒事项集成

### 4.1 官方契约

Apple 的 EventKit 支持提醒事项读写；`requestFullAccessToReminders` 在 macOS 14 起提供完整访问请求。读取提醒事项需要完整权限，系统没有按某一清单授予读取权限的接口。VoiceOS 的“授权清单”必须在自己的访问和执行层限制，不能把系统弹窗描述为只开放 VoiceOS 清单。[访问事件存储](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)、[提醒事项完整访问](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoreminders(completion:))。

`EKEventStoreChangedNotification` 只说明存储发生变化，不列出具体变更；收到后已读取对象需要重新获取。完成回读和冲突分析应基于实际重取与内外映射，不能只把通知当作某个任务完成。[变更通知](https://developer.apple.com/documentation/eventkit/ekeventstorechangednotification)。

沙盒化 Mac 应用还需相应 entitlement 和权限说明；应在有稳定应用身份的最小验证程序上验证打包、权限授予/拒绝/撤销，而不是把命令行编译成功当作生产授权成功。使用描述和签名细节在原生集成验证中核实。

### 4.2 本机检查与尚未验证

本机只查询授权枚举，提醒事项返回未决定；没有初始化用于读取资料的事件存储、请求权限或访问清单。探针能编译 EventKit，但没有验证创建、完成回读、外部编辑、iCloud 延迟、删除、超时未知结果、权限撤销或重复执行。

后续最小实验应在明确的合成测试清单内创建带操作身份的测试项，回读其 ID/字段，再验证外部完成、编辑、删除、断网和中断恢复。不能只通过标题或变更通知判定成功。测试清单和应用权限准备好之前不对真实任务自动写入。

候选集成方式：原生 EventKit 适配器；或轻量控制中心/独立核心通过本机原生桥接访问 EventKit。当前证据支持继续调查原生接口，不决定整个 Core 必须使用 Swift。桥接需要额外验证进程身份、权限归属、通信与分发维护。

## 5. H08/D08：持久状态和恢复原语

方法：在独立临时 SQLite 数据库中启用 WAL 和 synchronous=FULL，子进程插入合成操作后直接退出；分别在提交后和提交前中断，再重新打开数据库。

四项检查通过：已提交行仍可见；未提交行回滚；重复操作身份被唯一约束拒绝且最终只有一行；数据库完整性检查为 ok。[进程中断证据](evidence/sqlite-crash-2026-10-10.json)。临时数据库自动清理，未访问个人数据。

结论仅限持久化原语。没有验证音频文件与数据库之间的一致性、生产任务编排、实际 Mac 睡眠/唤醒、磁盘耗尽、断电或外部提醒事项幂等。SQLite 事务不会自动给跨资源写入提供一致性，需要在架构中设计操作记录、结果核对和恢复路径。

SQLite 官方说明 WAL 有伴随文件和检查点机制；备份不能只在运行中盲拷主数据库，未来也不能把共享 WAL 文件当作跨设备同步方案。[SQLite WAL](https://www.sqlite.org/wal.html)。

工程建议：SQLite 可进入单机持久状态候选。对照方案仍需评估；当前不是数据库 ADR，也没有证明完整任务恢复能力。

## 6. H04：云端数据控制调查

OpenAI 官方数据控制页区分应用状态与滥用监控日志。`store=false` 不能等同账户启用 Zero Data Retention；Responses 默认存储、后台执行、缓存和工具各有保留边界。音频转写端点在当前表中列为无应用状态和滥用监控保留，但这不自动覆盖其他端点或第三方代理。[OpenAI 数据控制](https://developers.openai.com/api/docs/guides/your-data)。

建议后续 ADR 评估：由 VoiceOS 自有历史管理上下文，减少依赖服务端会话状态；按来源权限组装请求，并记录实际端点/模型/功能的保留说明。具体服务、账户配置和缓存策略尚未核对，本轮没有请求 API 或检查/打印密钥。

P02 的文本授权不是音频上传授权，也不能通过摘要绕过仅本地限制。资料和模型输出中的指令不应覆盖来源权限或执行策略；此机制仍需实际请求拦截测试，目前不能声称 AC-16 已通过。

## 7. 验证状态与后续顺序

| 事项 | 当前状态 | 下一项证据 |
|---|---|---|
| H01 GPT 路由 | 未实测 | 合成表达的归属、候选和行动提取；成本/时延与质量 |
| H02 转写 | 一个本地中文合成样本完成；云端/英语/真人未测 | 真人与术语、否定、长录音、中英混合；经单独选择的云端对照 |
| H03 捕获 | WAV/M4A 合成文件路径验证 | 真录制、多音轨与视频导入、格式边界、原始落盘和中断 |
| H04 数据控制 | 官方契约调查 | 来源及衍生数据的实际上传拦截、账户保留规则 |
| H05 行动自主 | 产品原则确认；风险机制未测 | 普通自主操作和重要动作拦截的对照样本 |
| H06 主动反馈 | 未实测；P04 默认静默已确认 | 默认无认知系统通知、用户开启/关闭、静默关联、暂停、预算和去重 |
| H07 记忆关联 | 未实测 | 正负关联、矛盾、纠错冻结后的检索 |
| H08 持久与迁移 | SQLite 四项原语检查通过 | 跨文件一致性、备份恢复、历史/关系迁移 |
| H09 外部集成 | EventKit 契约与编译验证；P03 思源可选已确认 | 有应用身份的测试清单写入/回读/冲突/中断；思源适配不阻塞首版 |
| H10 指标口径 | 测试设计草稿 | 样本定义、人工标注、观察窗口与统计规则 |

建议下个验证切片：原生音频/提醒事项的最小验证载体与真实样本转写对照。并行准备 GPT 合成文本评估及记忆正负样本；不从本报告直接跳到完整软件实现。阶段 3 仍在进行，架构、数据模型和 ADR 尚未冻结。

## 8. 复现入口

探针源码在 `scripts/probes/`，只用于技术验证；中间二进制、合成音频及缓存在被 Git 忽略的 `tmp/research/`。公开的 JSON 证据只含环境元数据和合成内容。

```sh
mkdir -p tmp/research
env -u SDKROOT xcrun --sdk macosx swiftc -target arm64-apple-macosx26.0 -parse-as-library scripts/probes/platform-capabilities.swift -o tmp/research/platform-capabilities
tmp/research/platform-capabilities
env -u SDKROOT xcrun --sdk macosx swiftc -target arm64-apple-macosx26.0 -parse-as-library scripts/probes/audio-file-capabilities.swift -o tmp/research/audio-file-capabilities
tmp/research/audio-file-capabilities tmp/research/synthetic-audio-new
python3 scripts/probes/sqlite-crash-capabilities.py
env -u SDKROOT xcrun --sdk macosx swiftc -target arm64-apple-macosx26.0 -parse-as-library scripts/probes/local-transcription.swift -o tmp/research/local-transcription
/usr/bin/say -v 'Tingting (中文（中国大陆）)' -o tmp/research/synthetic-zh-new.aiff '我并不认为记忆容量越大越好。只有在检索质量足够高的条件下，更多记忆才可能有帮助。嘉宾说这个方法总是有效，但我还没有验证。我想查一篇论文，不要替我创建明天到期的任务。'
tmp/research/local-transcription tmp/research/synthetic-zh-new.aiff zh_CN
```

复现时使用新的合成输出目录，避免覆盖先前证据。中文模型不存在时，本地转写探针会失败并说明，不自动下载。语音合成和探针需当前平台的相应资源，其他设备不保证得到相同耗时与输出。
